import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:html/parser.dart' show parse;

import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/episode.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/engine/anime_rule_ops.dart';
import 'package:baka/source/engine/pipeline_host.dart';
import 'package:baka/source/engine/torrent_records.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/runtime/request_scheduler.dart';

typedef PipelinePlayResult = ({
  String url,
  Map<String, String> mediaHeaders,
  List<String> cookieNames,
  List<String> cookiePrefixes,
});

/// 单次管线执行的可变状态。
class _PipelineContext {
  _PipelineContext({
    required this.host,
    required String baseUrl,
    required String inputName,
    required Object input,
    required this.priority,
  }) : vars = <String, Object?>{
         baseUrlVar: baseUrl,
         inputName: input,
         timestampVar: DateTime.now().millisecondsSinceEpoch.toString(),
       },
       value = input,
       pageUrl = '',
       _seriesById = <String, Series>{},
       _sources = <Source>[],
       mediaHeaders = const <String, String>{},
       cookieNames = const <String>[],
       cookiePrefixes = const <String>[];

  _PipelineContext._trial(_PipelineContext source)
    : host = source.host,
      vars = Map<String, Object?>.of(source.vars),
      priority = source.priority,
      value = source.value,
      pageUrl = source.pageUrl,
      _seriesById = source._seriesById,
      _sources = source._sources,
      mediaHeaders = source.mediaHeaders,
      cookieNames = source.cookieNames,
      cookiePrefixes = source.cookiePrefixes;

  static const String baseUrlVar = 'baseUrl';
  static const String timestampVar = 'timestamp';

  final PipelineHost host;
  final Map<String, Object?> vars;
  final RequestPriority priority;

  Object? value;
  String pageUrl;
  final Map<String, Series> _seriesById;
  final List<Source> _sources;
  Map<String, String> mediaHeaders;
  List<String> cookieNames;
  List<String> cookiePrefixes;

  /// 当前分支实际执行过的结果输出操作数。
  int sinkRuns = 0;

  String get currentString => value is String ? value as String : '';
  String get baseUrl => vars[baseUrlVar]?.toString() ?? '';
  int get outputCount => _seriesById.length + _sources.length;
  List<Series> get seriesOut => _seriesById.values.toList(growable: false);
  List<Source> get sourceResults => _sources;

  _PipelineContext trial() => _PipelineContext._trial(this);

  void commit(_PipelineContext trial) {
    value = trial.value;
    pageUrl = trial.pageUrl;
    vars
      ..clear()
      ..addAll(trial.vars);
    mediaHeaders = trial.mediaHeaders;
    cookieNames = trial.cookieNames;
    cookiePrefixes = trial.cookiePrefixes;
    sinkRuns += trial.sinkRuns;
  }

  void emitSeries(Iterable<Series> values) {
    for (final series in values) {
      addSeries(series);
    }
  }

  void addSeries(Series series) {
    if (!_seriesById.containsKey(series.seriesId)) {
      _seriesById[series.seriesId] = series;
    }
  }

  void emitSources(Iterable<Source> values) {
    _sources.addAll(values);
  }

  void beginSink() => sinkRuns++;
}

typedef _OpHandler =
    FutureOr<void> Function(
      PipelineInterpreter,
      PipelineStep,
      _PipelineContext,
    );

/// anx-rule/2 顺序解释器；实例无状态，可并发复用。
class PipelineInterpreter {
  const PipelineInterpreter();

  static final RegExp _templatePattern = RegExp(r'\{([a-zA-Z0-9_]+)(:raw)?\}');
  static final RegExp _viewportMetaPattern = RegExp(
    r'''<meta\b(?=[^>]*\bname\s*=\s*["']viewport["'])[^>]*\bid\s*=\s*["']([^"']+)["'][^>]*>''',
    caseSensitive: false,
  );
  static final RegExp _charsetMetaPattern = RegExp(
    r'''<meta\b(?=[^>]*\bcharset\s*=)[^>]*\bid\s*=\s*["']([^"']+)["'][^>]*>''',
    caseSensitive: false,
  );
  static final RegExp _macCmsChallengePattern = RegExp(
    r'身份验证|安全验证|点击访问|smart_verify|请输入验证码|verify_check|/verify/index\.html|雷池 WAF|altcha-widget|aegis_altcha',
    caseSensitive: false,
  );
  static final RegExp _smartVerifyButtonPattern = RegExp(
    r'''\bid\s*=\s*["']smart-verify-btn["']''',
    caseSensitive: false,
  );
  static final RegExp _verifyCheckUrlPattern = RegExp(
    r'''["']([^"']*verify_check[^"']*)["']''',
    caseSensitive: false,
  );
  static final RegExp _verifyCheckKeyPattern = RegExp(
    r'new\s+Uint8Array\s*\(\s*\[([^\]]+)\]\s*\)',
    caseSensitive: false,
  );
  static final RegExp _ecPlayerConfigPattern = RegExp(
    r'''(?:let|var)\s+ConFig\s*=\s*(\{[\s\S]*?\})\s*,\s*box\s*=''',
    caseSensitive: false,
  );
  static final RegExp _nonHexPattern = RegExp(r'[^0-9a-fA-F]');
  static final RegExp _httpSchemePattern = RegExp(
    r'^https?://',
    caseSensitive: false,
  );
  static final RegExp _trailingSlashesPattern = RegExp(r'/+$');

  /// 规则里的 `regex`/`replace` pattern 绝大多数是固定串，却在每个源 × 每次
  /// 搜索时重新编译。按 pattern+flags 缓存编译结果，超限整体清空兜底
  /// （含模板变量的动态 pattern 不会无界增长）。
  static const _regexCacheLimit = 64;
  static final Map<String, RegExp> _regexCache = {};

  static RegExp _cachedRegExp(
    String pattern, {
    bool ignoreCase = false,
    bool dotAll = false,
  }) {
    final key = '$pattern\u0000${ignoreCase ? 1 : 0}${dotAll ? 1 : 0}';
    final hit = _regexCache[key];
    if (hit != null) return hit;
    final regex = RegExp(pattern, caseSensitive: !ignoreCase, dotAll: dotAll);
    if (_regexCache.length >= _regexCacheLimit) _regexCache.clear();
    return _regexCache[key] = regex;
  }

  Future<List<Series>> runSearch(
    SourceRule rule,
    PipelineHost host,
    String keyword, {
    RequestPriority priority = RequestPriority.search,
  }) async {
    final ctx = _PipelineContext(
      host: host,
      baseUrl: rule.baseUrl,
      inputName: 'keyword',
      input: keyword,
      priority: priority,
    );
    await _runSteps(rule.search, ctx);
    return ctx.seriesOut;
  }

  Future<List<Source>> runDetail(
    SourceRule rule,
    PipelineHost host,
    String seriesId, {
    RequestPriority priority = RequestPriority.search,
  }) async {
    final ctx = _PipelineContext(
      host: host,
      baseUrl: rule.baseUrl,
      inputName: 'seriesId',
      input: seriesId,
      priority: priority,
    );
    ctx.pageUrl = host.toAbsolute(seriesId, rule.baseUrl);
    await _runSteps(rule.detail, ctx);
    return ctx.sourceResults;
  }

  Future<String> runPlay(
    SourceRule rule,
    PipelineHost host,
    String episodeId, {
    RequestPriority priority = RequestPriority.play,
  }) async =>
      (await runPlayMedia(rule, host, episodeId, priority: priority)).url;

  Future<PipelinePlayResult> runPlayMedia(
    SourceRule rule,
    PipelineHost host,
    String episodeId, {
    RequestPriority priority = RequestPriority.play,
  }) async {
    final ctx = _PipelineContext(
      host: host,
      baseUrl: rule.baseUrl,
      inputName: 'episodeId',
      input: episodeId,
      priority: priority,
    );
    ctx.pageUrl = host.toAbsolute(episodeId, rule.baseUrl);
    await _runSteps(rule.play, ctx);
    final url = ctx.currentString;
    if (url.isEmpty) {
      return (
        url: '',
        mediaHeaders: const <String, String>{},
        cookieNames: const <String>[],
        cookiePrefixes: const <String>[],
      );
    }
    return (
      url: host.normalizeUrl(url, ctx.pageUrl),
      mediaHeaders: ctx.mediaHeaders,
      cookieNames: ctx.cookieNames,
      cookiePrefixes: ctx.cookiePrefixes,
    );
  }

  Future<void> _runSteps(List<PipelineStep> steps, _PipelineContext ctx) async {
    for (final step in steps) {
      final result = _runStep(step, ctx);
      if (result is Future<void>) await result;
    }
  }

  /// op 名 → 执行函数的路由表。同步 op 一律使用块体，避免把非 void
  /// 返回值当 Future 误 await；异步 op 直接透传 Future。
  static final Map<String, _OpHandler> _opHandlers = {
    'template': (self, step, ctx) {
      ctx.value = self._render(step.str('value') ?? '', ctx);
    },
    'setVar': (self, step, ctx) {
      ctx.vars[step.str('name') ?? '_'] = self._render(
        step.str('value') ?? '',
        ctx,
      );
    },
    'query': (self, step, ctx) {
      self._opQuery(step, ctx);
    },
    'fetch': _handleFetch,
    'follow': _handleFetch,
    'select': (self, step, ctx) {
      self._opSelect(step, ctx);
    },
    'regex': (self, step, ctx) {
      self._opRegex(step, ctx);
    },
    'replace': (self, step, ctx) {
      self._opReplace(step, ctx);
    },
    'json': (self, step, ctx) {
      self._opJson(step, ctx);
    },
    'pick': (self, step, ctx) {
      self._opPick(step, ctx);
    },
    'crypto': (self, step, ctx) {
      self._opCrypto(step, ctx);
    },
    'baseN': (self, step, ctx) {
      self._opBaseN(step, ctx);
    },
    'ecPlayer': (self, step, ctx) {
      self._opEcPlayer(step, ctx);
    },
    'maccmsVerify': (self, step, ctx) => self._opMacCmsVerify(step, ctx),
    'first': (self, step, ctx) => self._opFirst(step, ctx),
    'searchList': (self, step, ctx) {
      self._opSearchList(step, ctx);
    },
    'jsonSeries': (self, step, ctx) {
      self._opJsonSeries(step, ctx);
    },
    'episodes': (self, step, ctx) {
      self._opEpisodes(step, ctx);
    },
    'jsonEpisodes': (self, step, ctx) {
      self._opJsonEpisodes(step, ctx);
    },
    'maccmsApiEpisodes': (self, step, ctx) {
      self._opMaccmsApiEpisodes(step, ctx);
    },
    'videoUrl': (self, step, ctx) {
      self._opVideoUrl(step, ctx);
    },
    'setMediaHeaders': (self, step, ctx) {
      self._opSetMediaHeaders(step, ctx);
    },
    'playerAaaa': (self, step, ctx) {
      self._opPlayerAaaa(step, ctx);
    },
    'playerDecrypt': (self, step, ctx) {
      self._opPlayerDecrypt(step, ctx);
    },
    'sniff': (self, step, ctx) => self._opSniff(step, ctx),
    'anime1Search': (self, step, ctx) => self._opAnime1Search(step, ctx),
    'anime1Detail': (self, step, ctx) => self._opAnime1Detail(step, ctx),
    'anime1Play': (self, step, ctx) => self._opAnime1Play(step, ctx),
    'hhPlayer': (self, step, ctx) => self._opHhPlayer(step, ctx),
    'torrentRecords': (self, step, ctx) {
      self._opTorrentRecords(step, ctx);
    },
    'maccmsSuggest': (self, step, ctx) => self._opMaccmsSuggest(step, ctx),
  };

  static Future<void> _handleFetch(
    PipelineInterpreter self,
    PipelineStep step,
    _PipelineContext ctx,
  ) => self._opFetch(step, ctx);

  FutureOr<void> _runStep(PipelineStep step, _PipelineContext ctx) {
    final handler = _opHandlers[step.op];
    if (handler == null) {
      _debugLog('[pipeline] 未知 op: ${step.op}');
      ctx.value = '';
      return null;
    }
    return handler(this, step, ctx);
  }

  /// `fetch` / `follow`：发起 HTTP 请求，当前值变为响应体。
  /// `follow` 默认使用当前值作为 URL。
  Future<void> _opFetch(PipelineStep step, _PipelineContext ctx) async {
    final template = step.str('url');
    final rawUrl = template != null && template.isNotEmpty
        ? _render(template, ctx)
        : ctx.currentString;
    if (rawUrl.trim().isEmpty) {
      ctx.value = '';
      return;
    }

    final url = ctx.host.toAbsolute(
      rawUrl.trim(),
      ctx.pageUrl.isEmpty ? ctx.baseUrl : ctx.pageUrl,
    );
    final method = (step.str('method') ?? 'GET').toUpperCase();
    final headers = _renderMap(step.params['headers'], ctx);
    Object? body;
    final bodyParam = step.params['body'];
    if (bodyParam is Map) {
      body = {
        for (final entry in bodyParam.entries)
          entry.key.toString(): _render(entry.value.toString(), ctx),
      };
    } else if (bodyParam is String) {
      body = _render(bodyParam, ctx);
    }

    ctx.value = await ctx.host.fetch(
      url,
      method: method,
      headers: headers.isEmpty ? null : headers,
      body: body,
      referer: ctx.pageUrl.isEmpty ? null : ctx.pageUrl,
      contentType: step.str('contentType'),
      priority: ctx.priority,
    );
    ctx.pageUrl = url;
  }

  /// `select`：CSS 选择器取值。all=true 取列表，否则取单值（attr 或文本）。
  void _opSelect(PipelineStep step, _PipelineContext ctx) {
    final html = ctx.currentString;
    final selector = step.str('css') ?? '';
    final attr = step.str('attr') ?? 'text';
    if (selector.isEmpty) {
      ctx.value = '';
      return;
    }
    if (step.flag('all')) {
      ctx.value = ctx.host.selectAll(html, selector, attr);
    } else {
      ctx.value = ctx.host.selectAttr(html, selector, attr) ?? '';
    }
  }

  /// `regex`：正则提取。group 默认 1；all=true 返回所有匹配的该组。
  void _opQuery(PipelineStep step, _PipelineContext ctx) {
    final name = step.str('name') ?? step.str('key') ?? '';
    if (name.isEmpty) {
      ctx.value = '';
      return;
    }

    final input = step.str('input') != null
        ? _render(step.str('input')!, ctx)
        : (ctx.pageUrl.isNotEmpty ? ctx.pageUrl : ctx.currentString);
    var value = '';
    try {
      value = Uri.parse(input).queryParameters[name] ?? '';
    } catch (_) {}
    if (value.isEmpty) {
      value = step.str('default') ?? '';
    }

    final varName = step.str('var');
    if (varName != null && varName.isNotEmpty) {
      ctx.vars[varName] = value;
    }
    ctx.value = value;
  }

  void _opRegex(PipelineStep step, _PipelineContext ctx) {
    final source = ctx.currentString;
    final pattern = _render(step.str('pattern') ?? '', ctx);
    if (pattern.isEmpty) {
      ctx.value = '';
      return;
    }
    final group = step.intValue('group') ?? 1;
    try {
      final regex = _cachedRegExp(pattern, ignoreCase: step.flag('ignoreCase'));
      if (step.flag('all')) {
        final values = <String>[];
        for (final match in regex.allMatches(source)) {
          final value = group <= match.groupCount
              ? match.group(group) ?? ''
              : '';
          if (value.isNotEmpty) values.add(value);
        }
        ctx.value = values;
      } else {
        final match = regex.firstMatch(source);
        ctx.value = (match != null && group <= match.groupCount)
            ? (match.group(group) ?? '')
            : '';
      }
    } catch (e) {
      _debugLog('[pipeline] regex 错误: $e');
      ctx.value = '';
    }
  }

  /// `replace`：字符串或正则替换。
  ///
  /// - `pattern`：待替换文本；`regex=true` 时按正则解释。
  /// - `replacement`：替换文本，默认空串。
  /// - `input`：可选模板；默认使用当前字符串值。
  /// - `first`：仅替换首个命中；默认替换全部。
  void _opReplace(PipelineStep step, _PipelineContext ctx) {
    final pattern = _render(step.str('pattern') ?? '', ctx);
    if (pattern.isEmpty) {
      ctx.value = '';
      return;
    }
    final replacement = _render(step.str('replacement') ?? '', ctx);
    final source = step.str('input') != null
        ? _render(step.str('input')!, ctx)
        : ctx.currentString;

    try {
      if (step.flag('regex')) {
        final regex = _cachedRegExp(
          pattern,
          ignoreCase: step.flag('ignoreCase'),
          dotAll: step.flag('dotAll'),
        );
        ctx.value = step.flag('first')
            ? source.replaceFirst(regex, replacement)
            : source.replaceAll(regex, replacement);
      } else {
        ctx.value = step.flag('first')
            ? source.replaceFirst(pattern, replacement)
            : source.replaceAll(pattern, replacement);
      }
    } catch (e) {
      _debugLog('[pipeline] replace 错误: $e');
      ctx.value = '';
    }
  }

  /// `json`：从 JSON（当前值为字符串则先解析）按点路径取值。
  void _opJson(PipelineStep step, _PipelineContext ctx) {
    final data = _asJson(ctx.value);
    final path = step.str('path') ?? '';
    var val = AnimeRuleOps.jsonPath(data, path);
    if ((val == null || val == '') && path.isNotEmpty) {
      if (path.startsWith('data.')) {
        val = AnimeRuleOps.jsonPath(data, path.substring(5));
      } else if (!path.contains('.')) {
        val = AnimeRuleOps.jsonPath(data, 'data.$path');
      }
    }
    ctx.value = val;
  }

  /// `crypto`：加解密 / 摘要变换。
  ///
  /// - `algo`：`base64` / `md5` / `sha1` / `sha256` / `aes-cbc` / `aes-gcm`。
  /// - `mode`：`encrypt` / `decrypt`（默认 decrypt；摘要类忽略）。
  /// - `input`：模板，默认取当前值。
  /// - `key` / `iv`：模板；配 `keyEncoding` / `ivEncoding`（`utf8`/`base64`/`hex`）
  ///   决定如何转成字节。派生密钥场景（如站点把 AES key 拆散在页面里、
  ///   前端拼接后 base64）用 `template` 先拼好、`keyEncoding: base64` 即可。
  /// - `ivRandom`：整数，忽略 `iv` 改用 N 字节安全随机 IV（GCM 加密必需）。
  /// - `ivVar`：把本次使用的 IV（base64）写入该变量，供后续构造请求体引用。
  /// - `inputEncoding`：AES 解密时输入密文的编码（`base64` 默认 / `hex`）。
  /// - `outputEncoding`：AES 加密输出编码（`base64` 默认 / `hex`）；
  ///   AES 解密输出按明文文本处理。
  void _opPick(PipelineStep step, _PipelineContext ctx) {
    final index = int.tryParse(_render(step.str('index') ?? '0', ctx).trim());
    final value = ctx.value;
    if (index == null || index < 0 || value is! List || index >= value.length) {
      ctx.value = '';
      return;
    }
    ctx.value = value[index]?.toString() ?? '';
  }

  void _opCrypto(PipelineStep step, _PipelineContext ctx) {
    final algo = (step.str('algo') ?? '').toLowerCase();
    final mode = (step.str('mode') ?? 'decrypt').toLowerCase();
    final input = step.str('input') != null
        ? _render(step.str('input')!, ctx)
        : ctx.currentString;

    try {
      switch (algo) {
        case 'base64':
          // 解码失败时保留原值：playerAaaa 已按 encrypt 字段自动解码，
          // 此时输入可能已是明文 URL，不应视为管线失败。
          ctx.value = mode == 'encrypt'
              ? base64.encode(utf8.encode(input))
              : _tryBase64Decode(input);
          break;
        case 'md5':
          ctx.value = md5.convert(utf8.encode(input)).toString();
          break;
        case 'sha1':
          ctx.value = sha1.convert(utf8.encode(input)).toString();
          break;
        case 'sha256':
          ctx.value = sha256.convert(utf8.encode(input)).toString();
          break;
        case 'aes-cbc':
          ctx.value = _aes(step, ctx, input, enc.AESMode.cbc, mode);
          break;
        case 'aes-gcm':
          ctx.value = _aes(step, ctx, input, enc.AESMode.gcm, mode);
          break;
        default:
          _debugLog('[pipeline] 未知 crypto algo: $algo');
      }
    } catch (e) {
      _debugLog('[pipeline] crypto 错误: $e');
      ctx.value = '';
    }
  }

  static String _tryBase64Decode(String input) {
    try {
      return utf8.decode(base64.decode(base64.normalize(input.trim())));
    } catch (_) {
      return input;
    }
  }

  /// 按编码把字符串转成字节。
  static List<int> _decodeBytes(String value, String encoding) {
    switch (encoding) {
      case 'base64':
        return base64.decode(base64.normalize(value.trim()));
      case 'hex':
        final hex = value.trim().replaceAll(_nonHexPattern, '');
        return [
          for (var i = 0; i + 1 < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ];
      default:
        return utf8.encode(value);
    }
  }

  String _aes(
    PipelineStep step,
    _PipelineContext ctx,
    String input,
    enc.AESMode aesMode,
    String mode,
  ) {
    final keyBytes = _decodeBytes(
      _render(step.str('key') ?? '', ctx),
      (step.str('keyEncoding') ?? 'utf8').toLowerCase(),
    );

    final ivRandom = step.intValue('ivRandom');
    final enc.IV ivObj;
    if (ivRandom != null && ivRandom > 0) {
      ivObj = enc.IV.fromSecureRandom(ivRandom);
    } else {
      ivObj = enc.IV(
        Uint8List.fromList(
          _decodeBytes(
            _render(step.str('iv') ?? '', ctx),
            (step.str('ivEncoding') ?? 'utf8').toLowerCase(),
          ),
        ),
      );
    }
    final ivVar = step.str('ivVar');
    if (ivVar != null && ivVar.isNotEmpty) {
      ctx.vars[ivVar] = base64.encode(ivObj.bytes);
    }

    // GCM 不使用块填充；CBC 用 PKCS7。
    final encrypter = enc.Encrypter(
      enc.AES(
        enc.Key(Uint8List.fromList(keyBytes)),
        mode: aesMode,
        padding: aesMode == enc.AESMode.gcm ? null : 'PKCS7',
      ),
    );

    if (mode == 'encrypt') {
      final encrypted = encrypter.encrypt(input, iv: ivObj);
      return (step.str('outputEncoding') ?? 'base64').toLowerCase() == 'hex'
          ? encrypted.base16
          : encrypted.base64;
    }
    final cipherBytes = _decodeBytes(
      input,
      (step.str('inputEncoding') ?? 'base64').toLowerCase(),
    );
    return encrypter
        .decrypt(enc.Encrypted(Uint8List.fromList(cipherBytes)), iv: ivObj)
        .trim();
  }

  /// `baseN`：整数 ↔ 自定义字母表进制串（小端），可加固定前后缀。
  ///
  /// 用于把数值 id 编成站点短码路由。
  /// - `mode`：`encode`（默认，数字→短码） / `decode`（短码→数字）。
  /// - `alphabet`：进制字母表，长度即基数。
  /// - `prefix` / `suffix`：编码结果的固定前后缀（decode 时会先剥离）。
  /// - `input`：模板，默认取当前值。
  void _opBaseN(PipelineStep step, _PipelineContext ctx) {
    final alphabet = step.str('alphabet') ?? '';
    final mode = (step.str('mode') ?? 'encode').toLowerCase();
    final prefix = step.str('prefix') ?? '';
    final suffix = step.str('suffix') ?? '';
    final input =
        (step.str('input') != null
                ? _render(step.str('input')!, ctx)
                : ctx.currentString)
            .trim();
    if (alphabet.length < 2 || input.isEmpty) {
      ctx.value = input;
      return;
    }
    final base = alphabet.length;

    if (mode == 'decode') {
      var code = input;
      if (prefix.isNotEmpty && code.startsWith(prefix)) {
        code = code.substring(prefix.length);
      }
      if (suffix.isNotEmpty && code.endsWith(suffix)) {
        code = code.substring(0, code.length - suffix.length);
      }
      var value = 0;
      var place = 1;
      for (var i = 0; i < code.length; i++) {
        final digit = alphabet.indexOf(code[i]);
        if (digit < 0) {
          ctx.value = input;
          return;
        }
        value += digit * place;
        place *= base;
      }
      ctx.value = value.toString();
      return;
    }

    final number = int.tryParse(input);
    if (number == null || number < 0) {
      ctx.value = input;
      return;
    }
    ctx.value = '$prefix${_encodeLittleEndianBaseN(number, alphabet)}$suffix';
  }

  /// `maccmsSuggest`：封装 maccms 系列 suggest 搜索接口。
  /// 内部构造请求 URL，不暴露 ajax 路径。
  ///
  /// 可选参数：
  /// - `mid`：分类 ID，默认 `1`
  /// - `limit`：返回条数，默认 `20`
  /// - `headers`：额外请求头（默认附带 `X-Requested-With: XMLHttpRequest`）
  /// - `detailUrlTemplate`：详情页 URL 模板，如 `/bangumi/{id}.html`
  /// - `idTransform` / `idAlphabet` / `idPrefix` / `idSuffix`：ID 变换
  /// - `idKey` / `nameKey` / `imageKey` / `urlKey` / `descKey` / `listPath`
  /// - `verify`：是否在收到验证页时自动尝试 maccms smart_verify
  Future<void> _opMaccmsSuggest(PipelineStep step, _PipelineContext ctx) async {
    ctx.beginSink();
    final base = ctx.baseUrl;
    final mid = step.str('mid') ?? '1';
    final limit = step.str('limit') ?? '20';
    final keyword = ctx.vars['keyword']?.toString() ?? '';

    final headers = <String, String>{
      'X-Requested-With': 'XMLHttpRequest',
      ..._renderMap(step.params['headers'], ctx),
    };

    const paths = ['/index.php/ajax/suggest', '/ajax/suggest'];
    final listPath = step.str('listPath') ?? 'list';
    List<dynamic>? list;

    for (final path in paths) {
      final url = ctx.host.toAbsolute(
        '$path?mid=$mid&wd=${Uri.encodeComponent(keyword)}&limit=$limit',
        base,
      );
      final text = await ctx.host.fetch(
        url,
        headers: headers,
        priority: ctx.priority,
      );
      ctx.pageUrl = url;

      var candidate = text;
      if (step.flag('verify') && _needsMacCmsVerification(text)) {
        if (_supportsMacCmsSmartVerify(text)) {
          final verified = await _macCmsSmartVerify(url, ctx);
          if (verified != null) candidate = verified;
        }
      }

      final found = AnimeRuleOps.jsonPath(_asJson(candidate), listPath);
      if (found is List && found.isNotEmpty) {
        list = found;
        break;
      }
    }

    if (list != null) _appendJsonSeries(list, step, ctx);
  }

  void _opEcPlayer(PipelineStep step, _PipelineContext ctx) {
    final config = _tryJsonObject(
      _ecPlayerConfigPattern.firstMatch(ctx.currentString)?.group(1),
    );
    if (config == null) {
      ctx.value = '';
      return;
    }

    final encryptedUrl = config['url']?.toString().replaceAll(r'\/', '/') ?? '';
    final uid =
        AnimeRuleOps.jsonPath(config, 'config.uid')?.toString().trim() ?? '';
    if (encryptedUrl.isEmpty || uid.isEmpty) {
      ctx.value = '';
      return;
    }

    try {
      final key = _render(
        step.str('key') ?? '2890{uid}tB959C',
        ctx,
        extra: {'uid': uid},
      );
      final iv = _render(step.str('iv') ?? '2F131BE91247866E', ctx);
      final decrypted = enc.Encrypter(
        enc.AES(enc.Key.fromUtf8(key), mode: enc.AESMode.cbc, padding: 'PKCS7'),
      ).decrypt64(encryptedUrl, iv: enc.IV.fromUtf8(iv)).trim();
      ctx.value = ctx.host.normalizeUrl(
        decrypted.replaceAll(r'\/', '/'),
        ctx.pageUrl,
      );
    } catch (e) {
      _debugLog('[pipeline] ecPlayer 解密失败: $e');
      ctx.value = '';
    }
  }

  Future<void> _opMacCmsVerify(PipelineStep step, _PipelineContext ctx) async {
    final html = ctx.currentString;
    if (!_needsMacCmsVerification(html)) return;

    final verified = _supportsMacCmsVerifyCheck(html)
        ? await _macCmsVerifyCheck(html, ctx.pageUrl, ctx)
        : _supportsMacCmsSmartVerify(html)
        ? await _macCmsSmartVerify(ctx.pageUrl, ctx)
        : null;
    if (verified == null) {
      ctx.value = '';
      return;
    }
    ctx.value = verified;
  }

  /// 执行 maccms smart_verify 流程，成功后重新请求 [pageUrl] 并返回响应体。
  /// 失败时返回 `null`。
  Future<String?> _macCmsSmartVerify(
    String pageUrl,
    _PipelineContext ctx,
  ) async {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final token = md5
        .convert(utf8.encode('${ts}Lmm2026@VipS3cr3t!Kx9PqZ'))
        .toString();
    return _submitMacCmsVerify(
      '/index.php/ajax/smart_verify',
      {'smart_token': token, 'ts': ts.toString()},
      pageUrl,
      ctx,
    );
  }

  /// 以表单 POST 提交 MacCMS 验证请求；成功后重新请求 [pageUrl] 并返回
  /// 响应体，失败或 [pageUrl] 为空时返回 `null`。
  Future<String?> _submitMacCmsVerify(
    String verifyUrl,
    Map<String, String> body,
    String pageUrl,
    _PipelineContext ctx,
  ) async {
    final base = ctx.baseUrl.replaceFirst(_trailingSlashesPattern, '');
    final response = await ctx.host.fetch(
      ctx.host.toAbsolute(verifyUrl, base),
      method: 'POST',
      body: body,
      headers: const {'X-Requested-With': 'XMLHttpRequest'},
      referer: pageUrl.isEmpty ? '$base/' : pageUrl,
      contentType: 'form',
      priority: ctx.priority,
    );
    if (!_isMacCmsVerifySuccess(response) || pageUrl.isEmpty) return null;
    return ctx.host.fetch(
      pageUrl,
      referer: pageUrl,
      priority: ctx.priority,
    );
  }

  /// 执行部分 MacCMS 站点使用的时间戳异或验证流程。
  ///
  /// 页面会内嵌 `Uint8Array` 密钥，并把当前毫秒时间戳逐字节异或、
  /// Base64 编码后提交到 `verify_check`。Cookie 由宿主请求会话持久化。
  Future<String?> _macCmsVerifyCheck(
    String html,
    String pageUrl,
    _PipelineContext ctx,
  ) async {
    final urlMatch = _verifyCheckUrlPattern.firstMatch(html);
    final keyMatch = _verifyCheckKeyPattern.firstMatch(html);
    if (urlMatch == null || keyMatch == null) return null;

    final key = <int>[];
    for (final part in keyMatch.group(1)!.split(',')) {
      final value = part.trim();
      final parsed = value.toLowerCase().startsWith('0x')
          ? int.tryParse(value.substring(2), radix: 16)
          : int.tryParse(value);
      if (parsed == null || parsed < 0 || parsed > 255) return null;
      key.add(parsed);
    }
    if (key.isEmpty) return null;

    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final bytes = utf8.encode(timestamp);
    final token = base64.encode(
      List<int>.generate(
        bytes.length,
        (index) => bytes[index] ^ key[index % key.length],
      ),
    );

    final rawVerifyUrl = urlMatch
        .group(1)!
        .replaceAll(r'\/', '/')
        .replaceAll('&amp;', '&');
    return _submitMacCmsVerify(rawVerifyUrl, {'i': token}, pageUrl, ctx);
  }

  /// 依次试跑分支，仅提交首个成功分支的状态。
  Future<void> _opFirst(PipelineStep step, _PipelineContext ctx) async {
    final outputBefore = ctx.outputCount;
    for (final branch in step.branches) {
      final trial = ctx.trial();
      await _runSteps(branch, trial);
      final succeeded = trial.sinkRuns == 0
          ? _isNonEmpty(trial.value)
          : trial.outputCount > outputBefore;
      if (succeeded) {
        ctx.commit(trial);
        return;
      }
    }
    ctx.value = '';
  }

  /// `searchList`：CSS/XPath 解析搜索结果，追加到 seriesOut。
  void _opSearchList(PipelineStep step, _PipelineContext ctx) {
    ctx.beginSink();
    final html = ctx.currentString;
    if (html.isEmpty) return;
    List<Series> results;
    if (step.str('listXPath') != null) {
      results = ctx.host.parseSearchListXPath(
        html,
        listXPath: step.str('listXPath') ?? '',
        nameXPath: step.str('nameXPath') ?? '',
        linkXPath: step.str('linkXPath') ?? '',
      );
    } else {
      results = ctx.host.parseSearchList(
        html,
        selectors: step.strList('selectors'),
        detailPattern: step.str('detailPattern'),
      );
    }
    RegExp? namePattern;
    final nameFilter = step.str('nameFilter') ?? '';
    if (nameFilter.isNotEmpty) {
      try {
        namePattern = RegExp(nameFilter);
      } catch (e) {
        _debugLog('[pipeline] nameFilter 错误: $e');
      }
    }

    final keyword = step.flag('keywordMatch')
        ? (ctx.vars['keyword']?.toString() ?? '').toLowerCase()
        : '';
    for (var series in results) {
      final match = namePattern?.firstMatch(series.name);
      if (match != null && match.groupCount >= 1) {
        final clean = (match.group(1) ?? '').trim();
        if (clean.isNotEmpty && clean != series.name) {
          series = Series(
            series.seriesId,
            clean,
            image: series.image,
            description: series.description,
            bgmId: series.bgmId,
            score: series.score,
          );
        }
      }
      if (keyword.isEmpty || series.name.toLowerCase().contains(keyword)) {
        ctx.addSeries(series);
      }
    }
  }

  /// `jsonSeries`：从 JSON 列表构建 Series（JSON API 搜索）。
  void _opJsonSeries(PipelineStep step, _PipelineContext ctx) {
    ctx.beginSink();
    final rawData = _asJson(ctx.value);
    if (rawData == null) return;

    final listPath = step.str('listPath') ?? '';
    Object? target = AnimeRuleOps.jsonPath(rawData, listPath);
    if (target is! List) {
      if (rawData is List) {
        target = rawData;
      } else if (rawData is Map && rawData['data'] is List) {
        target = rawData['data'];
      } else if (rawData is Map && rawData['list'] is List) {
        target = rawData['list'];
      }
    }
    if (target is! List) return;

    _appendJsonSeries(target, step, ctx);
  }

  void _appendJsonSeries(
    List<dynamic> list,
    PipelineStep step,
    _PipelineContext ctx,
  ) {
    final idKey = step.str('idKey') ?? 'id';
    final nameKey = step.str('nameKey') ?? 'name';
    final imageKey = step.str('imageKey') ?? 'pic';
    final urlKey = step.str('urlKey');
    final template = step.str('detailUrlTemplate');
    final descKey = step.str('descKey');
    final baseUrl = ctx.baseUrl;

    final keyword = step.flag('keywordMatch')
        ? (ctx.vars['keyword']?.toString() ?? '').toLowerCase().trim()
        : '';

    for (final item in list) {
      if (item is! Map) continue;
      final name = item[nameKey]?.toString().trim() ?? '';
      if (name.isEmpty) continue;
      if (keyword.isNotEmpty) {
        final lowerName = name.toLowerCase();
        if (!lowerName.contains(keyword) && !keyword.contains(lowerName)) {
          continue;
        }
      }
      final rawId = item[idKey]?.toString().trim() ?? '';
      final id = _transformJsonSeriesId(rawId, step);
      final rawUrl = urlKey == null
          ? ''
          : item[urlKey]?.toString().trim() ?? '';
      String seriesUrl;
      if (rawUrl.isNotEmpty) {
        seriesUrl = ctx.host.toAbsolute(rawUrl, baseUrl);
      } else if (template != null && id.isNotEmpty) {
        seriesUrl = ctx.host.toAbsolute(
          template.replaceAll('{id}', id).replaceAll('{rawId}', rawId),
          baseUrl,
        );
      } else if (id.isNotEmpty) {
        seriesUrl = id;
      } else {
        continue;
      }
      final pic = item[imageKey]?.toString().trim() ?? '';
      ctx.addSeries(
        Series(
          seriesUrl,
          name,
          image: pic.isEmpty ? null : ctx.host.toAbsolute(pic, baseUrl),
          description: descKey == null ? null : item[descKey]?.toString(),
        ),
      );
    }
  }

  String _transformJsonSeriesId(String id, PipelineStep step) {
    if (id.isEmpty) return id;
    final transform = (step.str('idTransform') ?? '').toLowerCase();
    if (transform != 'basen') return id;

    final alphabet = step.str('idAlphabet') ?? step.str('alphabet') ?? '';
    if (alphabet.length < 2) return id;
    final numeric = int.tryParse(id);
    final encoded = numeric == null
        ? id
        : _encodeLittleEndianBaseN(numeric, alphabet);
    return '${step.str('idPrefix') ?? ''}$encoded${step.str('idSuffix') ?? ''}';
  }

  /// `episodes`：CSS/XPath 解析播放线路，追加到 sourcesOut。
  void _opEpisodes(PipelineStep step, _PipelineContext ctx) {
    ctx.beginSink();
    final html = ctx.currentString;
    if (html.isEmpty) return;
    List<Source> sources;
    if (step.str('roadsXPath') != null) {
      sources = ctx.host.parseEpisodesXPath(
        html,
        roadsXPath: step.str('roadsXPath') ?? '',
        itemsXPath: step.str('itemsXPath') ?? '',
      );
    } else {
      sources = ctx.host.parseEpisodes(
        html,
        listSelectors: step.strList('listSelectors'),
        tabSelectors: step.params['tabSelectors'] == null
            ? null
            : step.strList('tabSelectors'),
      );
    }
    if (step.flag('reverse')) {
      sources = sources.reversed.toList(growable: false);
    }
    ctx.emitSources(sources);
  }

  /// `jsonEpisodes`：从 JSON 构建播放线路（JSON API 详情）。
  ///
  /// - `sourcesPath`：多线路数组，每项通过 `episodesKey` 指向剧集数组。
  /// - `episodesPath`：单线路的扁平剧集数组，线路名由 `sourceName` 指定。
  void _opJsonEpisodes(PipelineStep step, _PipelineContext ctx) {
    ctx.beginSink();
    final data = _asJson(ctx.value);
    final episodesPath = step.str('episodesPath') ?? '';
    if (episodesPath.isNotEmpty) {
      final epList = AnimeRuleOps.jsonPath(data, episodesPath);
      if (epList is! List) return;
      final episodes = _buildJsonEpisodes(epList, step, ctx);
      if (episodes.isEmpty) return;
      final name = _render(step.str('sourceName') ?? '', ctx).trim();
      ctx.emitSources([Source(episodes, name.isEmpty ? null : name)]);
      return;
    }

    final sourcesList = AnimeRuleOps.jsonPath(
      data,
      step.str('sourcesPath') ?? '',
    );
    if (sourcesList is! List) return;

    final epListKey = step.str('episodesKey') ?? 'episodes';
    final sourceNameKey = step.str('sourceNameKey') ?? 'name';

    final result = <Source>[];
    for (final rawSource in sourcesList) {
      if (rawSource is! Map) continue;
      final epList = rawSource[epListKey];
      if (epList is! List) continue;
      final episodes = _buildJsonEpisodes(
        epList,
        step,
        ctx,
        sourceId: rawSource['id'],
      );
      if (episodes.isNotEmpty) {
        final name = rawSource[sourceNameKey]?.toString().trim();
        result.add(Source(episodes, name?.isNotEmpty == true ? name : null));
      }
    }
    ctx.emitSources(result);
  }

  /// `maccmsApiEpisodes`：解析 MacCMS provide API 的播放线路。
  /// `vod_play_url` 以 `$$$` 分线路、`#` 分剧集、`$` 分标题与地址。
  void _opMaccmsApiEpisodes(PipelineStep step, _PipelineContext ctx) {
    ctx.beginSink();
    final data = _asJson(ctx.value);
    final list = AnimeRuleOps.jsonPath(data, step.str('listPath') ?? 'list');
    if (list is! List || list.isEmpty) return;

    final requestedIndex = step.intValue('index') ?? 0;
    final index = requestedIndex.clamp(0, list.length - 1).toInt();
    final item = list[index];
    if (item is! Map) return;

    final sourceNames =
        item[step.str('fromKey') ?? 'vod_play_from']?.toString().split(
          r'$$$',
        ) ??
        const <String>[];
    final rawGroups = item[step.str('urlKey') ?? 'vod_play_url']
        ?.toString()
        .split(r'$$$');
    if (rawGroups == null) return;

    final directOnly = step.flag('directOnly');
    final sources = <Source>[];
    for (var sourceIndex = 0; sourceIndex < rawGroups.length; sourceIndex++) {
      final episodes = <Episode>[];
      for (final rawEntry in rawGroups[sourceIndex].split('#')) {
        final separator = rawEntry.indexOf(r'$');
        if (separator <= 0 || separator >= rawEntry.length - 1) continue;
        final title = rawEntry.substring(0, separator).trim();
        final rawId = rawEntry
            .substring(separator + 1)
            .trim()
            .replaceAll(r'\/', '/');
        if (rawId.isEmpty) continue;
        final isDirect = _httpSchemePattern.hasMatch(rawId);
        if (directOnly && !isDirect) continue;
        final episodeId = isDirect
            ? ctx.host.normalizeUrl(rawId, ctx.pageUrl)
            : rawId;
        episodes.add(
          Episode(
            episodeId,
            episodes.length,
            title.isEmpty ? 'Episode ${episodes.length + 1}' : title,
          ),
        );
      }
      if (episodes.isEmpty) continue;
      final rawName = sourceIndex < sourceNames.length
          ? sourceNames[sourceIndex].trim()
          : '';
      sources.add(
        Source(episodes, rawName.isEmpty ? '线路${sourceIndex + 1}' : rawName),
      );
    }
    if (step.flag('preferHls')) {
      // 单遍分桶，保持与原 where 过滤一致的相对顺序：HLS 线路整体前置。
      final hls = <Source>[];
      final others = <Source>[];
      for (final source in sources) {
        final isHls = source.episodes.any(
          (episode) => episode.episodeId.toLowerCase().contains('.m3u8'),
        );
        (isHls ? hls : others).add(source);
      }
      ctx.emitSources([...hls, ...others]);
      return;
    }
    ctx.emitSources(sources);
  }

  List<Episode> _buildJsonEpisodes(
    List<dynamic> epList,
    PipelineStep step,
    _PipelineContext ctx, {
    Object? sourceId,
  }) {
    final epNameKey = step.str('episodeNameKey') ?? step.str('nameKey') ?? 'name';
    final idTemplate =
        step.str('episodeIdTemplate') ?? step.str('detailUrlTemplate') ?? '{id}';
    final plainIdTemplate = idTemplate == '{id}';
    final rawIdTemplate = idTemplate == '{id:raw}';
    final episodes = <Episode>[];
    for (var i = 0; i < epList.length; i++) {
      final item = epList[i];
      if (item is! Map) continue;
      final hasDirectId = item.containsKey('id');
      final epId = plainIdTemplate && hasDirectId
          ? Uri.encodeComponent(item['id']?.toString() ?? '')
          : rawIdTemplate && hasDirectId
          ? item['id']?.toString() ?? ''
          : _render(
              idTemplate,
              ctx,
              extra: <String, String?>{
                for (final entry in item.entries)
                  entry.key.toString(): entry.value?.toString(),
                'source_id': sourceId?.toString() ?? '',
                'index': (i + 1).toString(),
              },
            );
      final title = item[epNameKey]?.toString().trim() ?? '';
      episodes.add(
        Episode(epId, i, title.isEmpty ? 'Episode ${i + 1}' : title),
      );
    }
    return episodes;
  }

  /// `videoUrl`：从当前内容中择优提取视频直链。
  ///
  /// 提取失败时把当前值清空：否则页面 HTML 会残留为「当前值」，
  /// 既让 `first` 误判分支成功（跳过 sniff 等后备分支），又会被
  /// runPlay 当作 URL 返回垃圾。
  void _opVideoUrl(PipelineStep step, _PipelineContext ctx) {
    final raw = ctx.currentString.trim();
    String url = '';
    if (_httpSchemePattern.hasMatch(raw) && !raw.contains('<html') && !raw.contains('{')) {
      url = raw;
    } else {
      url = ctx.host.extractVideoUrl(raw, ctx.pageUrl);
    }
    if (url.isNotEmpty) {
      try {
        url = Uri.encodeFull(Uri.decodeFull(url));
      } catch (_) {
        url = Uri.encodeFull(url);
      }
    }
    ctx.value = url;
  }

  /// `setMediaHeaders`：从当前 JSON 值中提取播放器请求头并设置到 ctx。
  /// `jsonPath`：headers 对象在 JSON 中的点路径（如 `data.headers`）。
  /// `headers`：可选的静态头，会与动态头合并（动态头优先）。
  void _opSetMediaHeaders(PipelineStep step, _PipelineContext ctx) {
    final staticHeaders = _renderMap(step.params['headers'], ctx);
    Map<String, String>? updated = staticHeaders.isEmpty ? null : staticHeaders;
    final jsonPath = step.str('jsonPath') ?? '';
    if (jsonPath.isNotEmpty) {
      final data = _asJson(ctx.value);
      final headers = AnimeRuleOps.jsonPath(data, jsonPath);
      if (headers is Map) {
        updated ??= Map<String, String>.of(ctx.mediaHeaders);
        for (final entry in headers.entries) {
          updated[entry.key.toString()] = entry.value?.toString() ?? '';
        }
      }
    }
    if (updated != null) ctx.mediaHeaders = updated;
  }

  /// `playerAaaa`：提取 MacCMS `player_aaaa` 变量 JSON 中的 url 键。
  /// 按 MacCMS 约定处理 `encrypt` 字段：0=原样，1=URL 编码，2=Base64+URL 编码。
  void _opPlayerAaaa(PipelineStep step, _PipelineContext ctx) {
    final html = ctx.currentString;
    final variable = RegExp.escape(step.str('var') ?? 'player_aaaa');
    final key = step.str('key') ?? 'url';
    final match = RegExp(
      variable + r'\s*=\s*(\{.*?\})\s*[;<]',
      dotAll: true,
    ).firstMatch(html);
    final obj = match == null ? null : _tryJsonObject(match.group(1));
    final url = obj?[key]?.toString() ?? '';
    ctx.value = _decodeMacCmsUrl(url, obj?['encrypt']).replaceAll(r'\/', '/');
  }

  /// `playerDecrypt`：解密一类 MacCMS 播放器页面的动态 meta-id AES URL。
  ///
  /// 页面把随机字符写入 viewport meta id，并用 charset meta id 的字符顺序
  /// 描述重排方式。重排后的 secret 与规则提供的 `salt` 拼接取 MD5；前 16
  /// 字符作为 IV、后 16 字符作为 key，以 AES-CBC/PKCS7 解密 `config.url`。
  /// Cycani 与 Mgnacg 共用这一协议，站点差异只保留在规则的 salt 中。
  void _opPlayerDecrypt(PipelineStep step, _PipelineContext ctx) {
    final html = ctx.currentString;
    final salt = _render(step.str('salt') ?? '', ctx);
    if (html.isEmpty || salt.isEmpty) {
      ctx.value = '';
      return;
    }

    try {
      final idPrefix = step.str('idPrefix') ?? 'now_';
      final viewportSelector = step.str('viewportSelector');
      final charsetSelector = step.str('charsetSelector');
      var viewportId = '';
      var charsetId = '';
      if (viewportSelector == null && charsetSelector == null) {
        viewportId = _viewportMetaPattern.firstMatch(html)?.group(1) ?? '';
        charsetId = _charsetMetaPattern.firstMatch(html)?.group(1) ?? '';
      }
      if (viewportSelector != null ||
          charsetSelector != null ||
          viewportId.isEmpty ||
          charsetId.isEmpty) {
        final document = parse(html);
        viewportId =
            document
                .querySelector(viewportSelector ?? 'meta[name="viewport"]')
                ?.attributes['id'] ??
            '';
        charsetId =
            document
                .querySelector(charsetSelector ?? 'meta[charset]')
                ?.attributes['id'] ??
            '';
      }
      if (idPrefix.isNotEmpty) {
        if (viewportId.startsWith(idPrefix)) {
          viewportId = viewportId.substring(idPrefix.length);
        }
        if (charsetId.startsWith(idPrefix)) {
          charsetId = charsetId.substring(idPrefix.length);
        }
      }

      final configVar = RegExp.escape(step.str('configVar') ?? 'config');
      final urlKey = RegExp.escape(step.str('urlKey') ?? 'url');
      final encryptedPattern =
          '''(?:var|let|const)?\\s*$configVar\\s*=\\s*\\{[\\s\\S]*?["']$urlKey["']\\s*:\\s*["']([^"']+)["']''';
      final encrypted =
          RegExp(
            encryptedPattern,
            caseSensitive: false,
          ).firstMatch(html)?.group(1)?.replaceAll(r'\/', '/').trim() ??
          '';

      final length = viewportId.length < charsetId.length
          ? viewportId.length
          : charsetId.length;
      if (length == 0 || encrypted.isEmpty) {
        ctx.value = '';
        return;
      }

      final order = List<int>.generate(length, (index) => index);
      order.sort((a, b) {
        final left = int.tryParse(charsetId[a]);
        final right = int.tryParse(charsetId[b]);
        if (left != null && right != null) return left.compareTo(right);
        return charsetId[a].compareTo(charsetId[b]);
      });
      final secret = StringBuffer();
      for (final index in order) {
        secret.write(viewportId[index]);
      }
      final hash = md5.convert(utf8.encode('$secret$salt')).toString();
      if (hash.length < 32) {
        ctx.value = '';
        return;
      }

      var cipherText = encrypted;
      if (cipherText.contains('%')) {
        try {
          cipherText = Uri.decodeComponent(cipherText);
        } catch (_) {}
      }
      final encrypter = enc.Encrypter(
        enc.AES(
          enc.Key.fromUtf8(hash.substring(16)),
          mode: enc.AESMode.cbc,
          padding: 'PKCS7',
        ),
      );
      ctx.value = encrypter
          .decrypt64(cipherText, iv: enc.IV.fromUtf8(hash.substring(0, 16)))
          .replaceAll(r'\/', '/')
          .trim();
    } catch (e) {
      _debugLog('[pipeline] playerDecrypt 错误: $e');
      ctx.value = '';
    }
  }

  static String _decodeMacCmsUrl(String url, dynamic encrypt) {
    if (url.isEmpty) return url;
    try {
      if (encrypt == 1 || encrypt == '1') {
        return Uri.decodeComponent(url);
      }
      if (encrypt == 2 || encrypt == '2') {
        final decoded = utf8.decode(base64.decode(base64.normalize(url)));
        return decoded.contains('%') ? Uri.decodeComponent(decoded) : decoded;
      }
    } catch (_) {}
    return url;
  }

  /// `sniff`：WebView 渲染或嗅探直链。
  Future<void> _opSniff(PipelineStep step, _PipelineContext ctx) async {
    if (!ctx.host.allowWebview) {
      ctx.value = '';
      return;
    }
    final url = step.str('url') != null
        ? ctx.host.toAbsolute(_render(step.str('url')!, ctx), ctx.baseUrl)
        : ctx.currentString;
    if (url.isEmpty) {
      ctx.value = '';
      return;
    }
    if ((step.str('goal') ?? 'video') == 'html') {
      final readyPatternText = step.str('readyRegex') == null
          ? ''
          : _render(step.str('readyRegex')!, ctx);
      RegExp? readyPattern;
      if (readyPatternText.isNotEmpty) {
        try {
          readyPattern = RegExp(
            readyPatternText,
            caseSensitive: !step.flag('readyIgnoreCase'),
            dotAll: true,
          );
        } catch (e) {
          _debugLog('[pipeline] sniff readyRegex 错误: $e');
        }
      }
      final readyContains = step
          .strList('readyContains')
          .map((value) => _render(value, ctx).toLowerCase())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      final rejectContains = step
          .strList('rejectContains')
          .map((value) => _render(value, ctx).toLowerCase())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      final hasReadyCondition =
          readyPattern != null || readyContains.isNotEmpty;
      final hasReadiness = hasReadyCondition || rejectContains.isNotEmpty;
      bool isReady(String html) {
        final lower = readyContains.isEmpty && rejectContains.isEmpty
            ? null
            : html.toLowerCase();
        if (lower != null && rejectContains.any(lower.contains)) return false;
        if (!hasReadyCondition) return true;
        return (readyPattern?.hasMatch(html) ?? false) ||
            (lower != null && readyContains.any(lower.contains));
      }

      final timeoutMs = (step.intValue('timeoutMs') ?? 30000)
          .clamp(1000, 120000)
          .toInt();
      final settleMs = (step.intValue('settleMs') ?? 1000)
          .clamp(0, 30000)
          .toInt();
      ctx.value = await ctx.host.renderWithWebview(
        url,
        isReady: hasReadiness ? isReady : null,
        timeout: Duration(milliseconds: timeoutMs),
        settleDelay: Duration(milliseconds: settleMs),
      );
    } else {
      ctx.value = await ctx.host.sniffWithWebview(url);
    }
  }

  /// `anime1Search`：从 Anime1 CloudFront catalog JSON 搜索番剧。
  Future<void> _opAnime1Search(PipelineStep step, _PipelineContext ctx) async {
    ctx.beginSink();
    final keyword = ctx.vars['keyword']?.toString().trim() ?? '';
    if (keyword.isEmpty) return;

    final url = ctx.host.toAbsolute(
      step.str('url') ?? 'https://d1zquzjgwo9yb.cloudfront.net/',
      ctx.baseUrl,
    );
    final payload = await ctx.host.fetch(
      url,
      priority: ctx.priority,
    );
    final results = AnimeRuleOps.parseAnime1Catalog(
      payload,
      keyword,
      idIndex: step.intValue('idIndex') ?? 0,
      nameIndex: step.intValue('nameIndex') ?? 1,
      caseSensitive: step.flag('caseSensitive'),
    );
    ctx.emitSeries(results);
  }

  /// `anime1Detail`：从 Anime1 分类页抓取 episode tokens，分页拼接后构建 Source。
  Future<void> _opAnime1Detail(PipelineStep step, _PipelineContext ctx) async {
    ctx.beginSink();
    final seriesId = ctx.vars['seriesId']?.toString() ?? ctx.currentString;
    if (seriesId.isEmpty) return;

    final urlTemplate =
        step.str('url') ?? 'https://anime1.me/?cat={seriesId:raw}';
    final firstPageUrl = ctx.host.toAbsolute(
      _render(urlTemplate, ctx),
      ctx.baseUrl,
    );

    final tokens = await AnimeRuleOps.collectAnime1EpisodeTokens(
      firstPageUrl: firstPageUrl,
      fetchPage: (pageUrl) => ctx.host.fetch(
        pageUrl,
        priority: ctx.priority,
      ),
      itemSelector: step.str('itemSelector') ?? 'video[data-apireq]',
      tokenAttribute: step.str('tokenAttribute') ?? 'data-apireq',
      nextSelector: step.str('nextSelector') ?? '.nav-previous a',
      maxPages: step.intValue('maxPages') ?? 32,
      reverse: step.flag('reverse'),
    );

    final sources = AnimeRuleOps.buildAnime1Sources(
      tokens,
      sourceName: step.str('sourceName') ?? 'Anime1',
      episodeNameTemplate: step.str('episodeNameTemplate') ?? '第{index}集',
    );
    ctx.emitSources(sources);
  }

  /// `anime1Play`：调用 Anime1 play API 解析媒体直链与所需 cookie。
  Future<void> _opAnime1Play(PipelineStep step, _PipelineContext ctx) async {
    final token = ctx.vars['episodeId']?.toString() ?? ctx.currentString;
    if (token.isEmpty) {
      ctx.value = '';
      return;
    }

    final url = ctx.host.toAbsolute(
      step.str('url') ?? 'https://v.anime1.me/api',
      ctx.baseUrl,
    );
    final tokenField = step.str('tokenField') ?? 'd';
    final payload = await ctx.host.fetch(
      url,
      method: 'POST',
      contentType: step.str('contentType') ?? 'form',
      body: {tokenField: Uri.decodeComponent(token)},
      headers: _renderMap(step.params['headers'], ctx),
      priority: ctx.priority,
    );

    final cookieNames = step.strList('cookieNames');
    final cookiePrefixes = step.strList('cookiePrefixes');
    ctx.value = AnimeRuleOps.parseAnime1PlaybackUrl(
      payload,
      sourcePath: step.str('sourcePath') ?? 's[0].src',
      mediaBaseUrl: step.str('mediaBaseUrl') ?? 'https://v.anime1.me/',
    );

    final mediaHeaders = _renderMap(step.params['mediaHeaders'], ctx);
    if (mediaHeaders.isNotEmpty) {
      ctx.mediaHeaders = mediaHeaders;
    }
    ctx.cookieNames = cookieNames;
    ctx.cookiePrefixes = cookiePrefixes;
  }

  /// `hhPlayer`：解析 HHPlayer iframe，提取加密参数后请求 API 获取直链。
  Future<void> _opHhPlayer(PipelineStep step, _PipelineContext ctx) async {
    final iframeUrl = ctx.currentString;
    if (iframeUrl.isEmpty) {
      ctx.value = '';
      return;
    }

    final iframeHtml = await ctx.host.fetch(
      ctx.host.toAbsolute(iframeUrl, ctx.baseUrl),
      priority: ctx.priority,
    );

    final charMapRaw = step.params['charMap'];
    final charMap = <String, String>{};
    if (charMapRaw is Map) {
      for (final entry in charMapRaw.entries) {
        charMap[entry.key.toString()] = entry.value.toString();
      }
    }

    final bootstrap = AnimeRuleOps.parseHhPlayerBootstrap(
      iframeUrl: iframeUrl,
      iframeHtml: iframeHtml,
      urlQueryParam: step.str('urlQueryParam') ?? 'url',
      timestampPattern: step.str('timestampPattern') ?? '',
      timestampGroup: step.intValue('timestampGroup') ?? 1,
      encodedKeyPattern: step.str('encodedKeyPattern') ?? '',
      encodedKeyGroup: step.intValue('encodedKeyGroup') ?? 1,
      charMap: charMap,
      caseSensitive: step.flag('caseSensitive'),
      dotAll: step.flag('dotAll'),
    );
    if (bootstrap == null) {
      ctx.value = '';
      return;
    }

    final apiUrl = ctx.host.toAbsolute(step.str('apiUrl') ?? '', ctx.baseUrl);
    final urlField = step.str('urlField') ?? 'url';
    final timestampField = step.str('timestampField') ?? 't';
    final keyField = step.str('keyField') ?? 'key';

    final body = <String, String>{
      urlField: bootstrap.encryptedUrl,
      timestampField: bootstrap.timestamp,
      keyField: bootstrap.key,
    };
    final fixedBody = step.params['fixedBody'];
    if (fixedBody is Map) {
      for (final entry in fixedBody.entries) {
        body[entry.key.toString()] = entry.value.toString();
      }
    }

    final headers = _renderMap(step.params['headers'], ctx);
    final payload = await ctx.host.fetch(
      apiUrl,
      method: 'POST',
      contentType: step.str('contentType') ?? 'form',
      body: body,
      headers: headers.isEmpty ? null : headers,
      priority: ctx.priority,
    );

    ctx.value = AnimeRuleOps.parseHhPlayerResponse(
      payload,
      codePath: step.str('codePath') ?? 'code',
      successCode: step.str('successCode') ?? '200',
      urlPath: step.str('urlPath') ?? 'url',
    );
  }

  /// `torrentRecords`：从 BT 资源站 HTML 解析种子记录。
  ///
  /// `mode: series`（search 阶段）按番名分组产出 Series；
  /// `mode: episodes`（detail 阶段）按字幕组分组产出 Source。
  void _opTorrentRecords(PipelineStep step, _PipelineContext ctx) {
    ctx.beginSink();
    final html = ctx.currentString;
    if (html.trim().isEmpty) return;

    final mode = (step.str('mode') ?? 'series').toLowerCase();
    final baseUrl = ctx.baseUrl;

    if (mode == 'episodes') {
      final sources = TorrentRecordParser.parseSources(
        html: html,
        params: step.params,
        baseUrl: baseUrl,
        contextUrl: ctx.pageUrl,
      );
      ctx.emitSources(sources);
    } else {
      final series = TorrentRecordParser.parseSeries(
        html: html,
        params: step.params,
        baseUrl: baseUrl,
      );
      ctx.emitSeries(series);
    }
  }

  String _encodeLittleEndianBaseN(int value, String alphabet) {
    if (alphabet.length < 2 || value < 0) return value.toString();
    if (value == 0) return alphabet[0];
    final base = alphabet.length;
    final buffer = StringBuffer();
    var remaining = value;
    while (remaining > 0) {
      buffer.write(alphabet[remaining % base]);
      remaining ~/= base;
    }
    return buffer.toString();
  }

  bool _needsMacCmsVerification(String html) {
    return html.isNotEmpty && _macCmsChallengePattern.hasMatch(html);
  }

  bool _supportsMacCmsSmartVerify(String html) {
    return html.contains('/index.php/ajax/smart_verify') ||
        _smartVerifyButtonPattern.hasMatch(html);
  }

  bool _supportsMacCmsVerifyCheck(String html) {
    return _verifyCheckUrlPattern.hasMatch(html) &&
        _verifyCheckKeyPattern.hasMatch(html);
  }

  bool _isMacCmsVerifySuccess(String data) {
    try {
      final json = jsonDecode(data);
      if (json is Map) {
        final code = json['code'];
        return code == 1 || code == 1000 || code == 200;
      }
    } catch (_) {}
    return false;
  }

  void _debugLog(String message) {
    assert(() {
      // ignore: avoid_print
      print(message);
      return true;
    }());
  }

  Map<String, String> _renderMap(Object? raw, _PipelineContext ctx) {
    if (raw is! Map) return const <String, String>{};
    return <String, String>{
      for (final entry in raw.entries)
        entry.key.toString(): _render(entry.value.toString(), ctx),
    };
  }

  /// 渲染字符串模板：把 `{name}` 替换为 [resolve] 的返回值（`null` 视为空串），
  /// 并做 URL 编码（除非用 `{name:raw}`）。
  static String renderTemplate(
    String template,
    String? Function(String name) resolve,
  ) {
    if (!template.contains('{')) return template;
    return template.replaceAllMapped(_templatePattern, (m) {
      final name = m.group(1)!;
      final raw = m.group(2) != null;
      final value = resolve(name) ?? '';
      return raw ? value : Uri.encodeComponent(value);
    });
  }

  /// 渲染字符串模板：把 `{name}` 替换为变量值。
  /// 内置变量：keyword/seriesId/episodeId/baseUrl/timestamp/url（当前字符串值）；
  /// keyword 会做 URL 编码（除非用 `{keyword:raw}`）。
  String _render(
    String template,
    _PipelineContext ctx, {
    Map<String, String?>? extra,
  }) {
    return renderTemplate(template, (name) {
      if (extra != null && extra.containsKey(name)) return extra[name];
      if (name == 'url') return ctx.currentString;
      return ctx.vars[name]?.toString();
    });
  }

  bool _isNonEmpty(Object? value) {
    if (value == null) return false;
    if (value is String) return value.trim().isNotEmpty;
    if (value is List) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }

  dynamic _asJson(Object? value) {
    if (value is String) {
      try {
        return jsonDecode(value.trim());
      } catch (_) {
        return null;
      }
    }
    return value;
  }

  Map<String, dynamic>? _tryJsonObject(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
