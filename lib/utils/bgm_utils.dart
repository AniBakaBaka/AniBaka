import 'dart:convert';

import 'package:baka/utils/reg_utils.dart';

class BgmInfo {
  final double? score;
  final int? subjectId;
  final String? imageUrl;

  const BgmInfo({this.score, this.subjectId, this.imageUrl});
}

class BgmSubjectInfo {
  final int subjectId;
  final String? name;
  final String? nameCn;
  final String? summary;
  final String? imageUrl;
  final double? score;
  final List<String> aliases;
  final bool hasDetail;

  late final List<String> searchTitles = BgmUtils.buildSearchTitles([
    nameCn,
    name,
    ...aliases,
  ]);

  BgmSubjectInfo({
    required this.subjectId,
    this.name,
    this.nameCn,
    this.summary,
    this.imageUrl,
    this.score,
    this.aliases = const [],
    this.hasDetail = false,
  });
}

class BgmUtils {
  static final _spaceRe = RegExp(r'\s+');
  static final _trailingBracketRe = RegExp(
    r'\s*[\(\[（【][^\)\]）】]+[\)\]）】]\s*$',
  );

  static final _bbQuoteRe = RegExp(r'\[quote\].*?\[/quote\]', dotAll: true);
  static final _bbImgRe = RegExp(r'\[img\](.*?)\[/img\]', caseSensitive: false);
  static final _bbTagRe = RegExp(r'\[/?[a-zA-Z]+(?:=[^\]]+)?\]');
  static final _bgmEmojiRe = RegExp(r'\(bgm\d+\)');

  static final _seasonNumRe = RegExp(
    r'第\s*([一二三四五六七八九十]+|\d+)\s*[季期]|season\s*(\d+)|\bs(\d+)\b|part\s*(\d+)',
    caseSensitive: false,
  );

  static final _yyyymmddRe = RegExp(r'^\d{8}');
  static final _plainDateRe = RegExp(
    r'^(\d{4})[-/.年]?(\d{1,2})(?:[-/.月]?(\d{1,2}))?',
  );
  static final _airDateKeyRe = RegExp(r'放送|上映|发售|首播');

  static Map<String, dynamic>? parseJsonMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String && raw.isNotEmpty) {
      return jsonDecode(raw) as Map<String, dynamic>;
    }
    return null;
  }

  static List<dynamic> parseJsonList(dynamic raw) {
    if (raw is List) return raw;
    if (raw is String && raw.isNotEmpty) {
      return jsonDecode(raw) as List<dynamic>;
    }
    return const [];
  }

  static Map<String, dynamic>? asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    return null;
  }

  static List<Map<String, dynamic>> asMapList(dynamic value) {
    if (value is! List) return const [];
    return value.cast<Map<String, dynamic>>();
  }

  static int? toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? toDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static String? trimmed(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static String? pickImageUrl(dynamic rawImages) {
    if (rawImages is! Map) return null;
    return trimmed(
      rawImages['large'] ??
          rawImages['common'] ??
          rawImages['medium'] ??
          rawImages['small'],
    );
  }

  /// Returns a cached cover URL that does not redirect the client to
  /// Bangumi's blocked image host.
  static String bgmCoverProxyUrl(int subjectId) {
    final source = Uri.https(
      'api.bgm.tv',
      '/v0/subjects/$subjectId/image',
      const {'type': 'large'},
    );
    return bgmImageProxyUrl(source.toString());
  }

  /// WordPress Photon 等 CDN：`https://i1.wp.com/lain.bgm.tv/...`。
  /// p1.anibaka.com 返回的头像常已包过一层；再套 wsrv.nl 会 400。
  static final _wpPhotonHostRe = RegExp(
    r'^i\d+\.wp\.com$',
    caseSensitive: false,
  );

  /// 从 avatar map / 字符串中取可用头像 URL（优先 medium）。
  static String pickAvatarUrl(dynamic avatar) {
    if (avatar is String) return trimmed(avatar) ?? '';
    if (avatar is! Map) return '';
    return trimmed(
          avatar['medium'] ??
              avatar['large'] ??
              avatar['small'] ??
              avatar['common'],
        ) ??
        '';
  }

  /// Wraps any Bangumi image URL (lain.bgm.tv is blocked for many users)
  /// with the same wsrv.nl cache used by search covers.
  static String bgmImageProxyUrl(String url, {int width = 360}) {
    if (url.isEmpty) return url;
    if (url.contains('wsrv.nl')) return url;
    final formatted = _normalizeBgmImageSource(url);
    if (formatted.isEmpty) return '';
    return Uri.https('wsrv.nl', '/', {
      'url': formatted,
      'w': '$width',
      'output': 'webp',
      'q': '85',
    }).toString();
  }

  /// 规范化图片源地址：补全协议、拆掉已存在的 Photon 嵌套代理。
  static String _normalizeBgmImageSource(String url) {
    var formatted = url.trim();
    if (formatted.isEmpty) return '';
    if (formatted.startsWith('//')) {
      formatted = 'https:$formatted';
    }

    final uri = Uri.tryParse(formatted);
    if (uri == null || !uri.hasScheme) return formatted;

    // https://i1.wp.com/lain.bgm.tv/r/100/pic/user/...jpg?r=1
    // → https://lain.bgm.tv/r/100/pic/user/...jpg?r=1
    if (_wpPhotonHostRe.hasMatch(uri.host) && uri.pathSegments.isNotEmpty) {
      final originHost = uri.pathSegments.first;
      final restSegments = uri.pathSegments.skip(1).toList();
      final path = restSegments.isEmpty ? '/' : '/${restSegments.join('/')}';
      return Uri(
        scheme: 'https',
        host: originHost,
        path: path,
        query: uri.hasQuery ? uri.query : null,
      ).toString();
    }

    return formatted;
  }

  /// Picks the backdrop supplied by AniBaka's TMDB image source.
  ///
  /// Prefer a Chinese backdrop when the API provides multiple TMDB variants.
  static String? pickAniBakaTmdbBackdrop(Map<String, dynamic>? detail) {
    final images = detail?['images'];
    if (images is! Map) return null;
    final candidates = images['backdrops'];
    if (candidates is! List) return null;
    Map<String, dynamic>? fallback;

    for (final candidate in candidates.cast<Map<String, dynamic>>()) {
      if (trimmed(candidate['source'])?.toLowerCase() != 'tmdb') continue;
      fallback ??= candidate;
      if (trimmed(candidate['lang'])?.toLowerCase() == 'zh') {
        return trimmed(candidate['url']) ?? trimmed(candidate['thumbnail']);
      }
    }

    return trimmed(fallback?['url']) ?? trimmed(fallback?['thumbnail']);
  }

  static double? extractScore(dynamic rating) {
    final score = (rating is Map) ? rating['score'] : null;
    return (score is num && score > 0) ? score.toDouble() : null;
  }

  static String? _readBgmImageUrl(Map data) {
    final detail = data['bgmDetailData'] as Map?;
    return trimmed(data['bgmImageUrl']) ?? pickImageUrl(detail?['images']);
  }

  static String? _readContentImage(dynamic content) {
    final suo = trimmed(getSuo(content?.toString()));
    return (suo == kDefaultImage) ? null : suo;
  }

  static BgmInfo readFromData(Map data) {
    final detail = data['bgmDetailData'] as Map?;
    return BgmInfo(
      subjectId: toInt(data['bgmId'] ?? detail?['id']),
      score: toDouble(data['score'] ?? extractScore(detail?['rating'])),
      imageUrl: _readBgmImageUrl(data),
    );
  }

  static String? resolveCoverImage(Map data, {BgmInfo? bgmInfo}) {
    return trimmed(bgmInfo?.imageUrl) ??
        _readBgmImageUrl(data) ??
        trimmed(data['image']) ??
        _readContentImage(data['content']);
  }

  static void normalizeCoverImage(Map data, {BgmInfo? bgmInfo}) {
    final coverUrl = resolveCoverImage(data, bgmInfo: bgmInfo);
    if (coverUrl != null) data['bgmImageUrl'] = coverUrl;
  }

  static void writeToData(Map data, BgmInfo info) {
    if (info.subjectId != null) data['bgmId'] = info.subjectId;
    if (info.score != null) data['score'] = info.score;
    if (info.imageUrl != null) data['bgmImageUrl'] = info.imageUrl;
    normalizeCoverImage(data, bgmInfo: info);
  }

  static int? extractSeason(String text) {
    final m = _seasonNumRe.firstMatch(text);
    if (m == null) return null;
    final cn = m.group(1);
    if (cn != null) {
      return int.tryParse(cn) ?? _parseChineseNumber(cn);
    }
    return int.tryParse(m.group(2) ?? m.group(3) ?? m.group(4) ?? '');
  }

  /// 解析 1-99 范围内的中文数字（一、十二、二十三……）。
  static int? _parseChineseNumber(String raw) {
    const digits = <String, int>{
      '零': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    final tenIndex = raw.indexOf('十');
    if (tenIndex == -1) return digits[raw];

    final tens = tenIndex == 0 ? 1 : digits[raw.substring(0, tenIndex)];
    final onesPart = raw.substring(tenIndex + 1);
    final ones = onesPart.isEmpty ? 0 : digits[onesPart];
    if (tens == null || ones == null) return null;
    return tens * 10 + ones;
  }

  static String formatTimeString(String raw, String prefix) {
    if (raw.length >= 8 && _yyyymmddRe.hasMatch(raw)) {
      return '$prefix ${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6, 8)}';
    }
    return '$prefix ${raw.length >= 10 ? raw.substring(0, 10) : raw}';
  }

  static String? formatPlainDate(dynamic raw) {
    final text = trimmed(raw);
    if (text == null) return null;

    final match = _plainDateRe.firstMatch(text);
    if (match != null) {
      final y = int.tryParse(match.group(1) ?? '');
      final m = int.tryParse(match.group(2) ?? '');
      final d = int.tryParse(match.group(3) ?? '');
      if (y != null && y > 0 && m != null && m > 0) {
        return (d == null || d <= 0) ? '$y.$m' : '$y.$m.$d';
      }
    }

    final parsed = DateTime.tryParse(text);
    if (parsed != null) return '${parsed.year}.${parsed.month}.${parsed.day}';
    return null;
  }

  static String? formatAirDate(Map data) {
    final detail = asMap(data['bgmDetailData']);
    final candidates = [
      data['airDate'],
      detail?['date'],
      detail?['air_date'],
      detail?['airDate'],
    ];

    for (final value in candidates) {
      final formatted = formatPlainDate(value);
      if (formatted != null) return formatted;
    }

    return _extractInfoboxAirDate(detail?['infobox']) ??
        formatPlainDate(data['time']);
  }

  static String? _extractInfoboxAirDate(dynamic rawInfobox) {
    for (final item in asMapList(rawInfobox)) {
      final key = item['key']?.toString() ?? '';
      if (_airDateKeyRe.hasMatch(key)) {
        final formatted = _formatInfoboxDateValue(item['value']);
        if (formatted != null) return formatted;
      }
    }
    return null;
  }

  static String? _formatInfoboxDateValue(dynamic value) {
    final formatted = formatPlainDate(value);
    if (formatted != null) return formatted;
    if (value is List) {
      for (final item in value) {
        final nested = _formatInfoboxDateValue(item);
        if (nested != null) return nested;
      }
    } else if (value is Map) {
      for (final item in value.values) {
        final nested = _formatInfoboxDateValue(item);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  static String cleanBbCode(String text) => text
      .replaceAll(_bbQuoteRe, '')
      .replaceAll(_bbTagRe, '')
      .replaceAll(_bgmEmojiRe, '')
      .trim();

  static RegExp get bbImgPattern => _bbImgRe;

  /// 匹配用归一化：剥离季/篇后缀，小写，仅保留中英文与数字。
  static String normalizeTitle(String title) =>
      keepTitleUnits(RegUtils.extractBaseTitle(title));

  static bool _isTitleUnit(int unit) =>
      (unit >= 0x61 && unit <= 0x7A) || // a-z
      (unit >= 0x30 && unit <= 0x39) || // 0-9
      (unit >= 0x4E00 && unit <= 0x9FA5); // CJK

  /// 单趟扫描完成「小写 + 过滤」，取代 `toLowerCase()` 与正则 `replaceAll`
  /// 各分配一次全串的写法；输入已是规范形式时原样返回，零分配。
  static String keepTitleUnits(String text) {
    var i = 0;
    while (i < text.length && _isTitleUnit(text.codeUnitAt(i))) {
      i++;
    }
    if (i == text.length) return text;

    final buffer = StringBuffer(text.substring(0, i));
    for (; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0x41 && unit <= 0x5A) {
        buffer.writeCharCode(unit + 0x20); // A-Z -> a-z
      } else if (unit == 0x130) {
        buffer.writeCharCode(0x69); // İ 小写为 i + 组合点，组合点本就会被过滤
      } else if (unit == 0x212A) {
        buffer.writeCharCode(0x6B); // 开尔文符号 K 小写为 k
      } else if (_isTitleUnit(unit)) {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString();
  }

  /// 仅保留汉字，用于派生「纯中文」搜索变体。
  static String chineseOnly(String text) {
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0x4E00 && unit <= 0x9FA5) buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }

  /// 为每个标题派生搜索变体（原文 / 去季号 / 去尾括号 / 纯中文），按归一化去重。
  static List<String> buildSearchTitles(Iterable<String?> titles) {
    final values = <String>[];
    final seen = <String>{};

    void add(String value, String key) {
      if (key.isNotEmpty && seen.add(key)) values.add(value);
    }

    for (final raw in titles) {
      final title = trimmed(raw)?.replaceAll(_spaceRe, ' ');
      if (title == null) continue;

      final base = RegUtils.extractBaseTitle(title);
      add(title, keepTitleUnits(base));

      final base2 = RegUtils.extractBaseTitle(base);
      if (base2 != base) add(base, keepTitleUnits(base2));

      if (_endsWithBracket(title)) {
        final stripped = title.replaceFirst(_trailingBracketRe, '');
        if (stripped.isNotEmpty) {
          add(stripped, keepTitleUnits(RegUtils.extractBaseTitle(stripped)));
        }
      }

      final zh = chineseOnly(title);
      if (zh.isNotEmpty) {
        add(zh, keepTitleUnits(RegUtils.extractBaseTitle(zh)));
      }
    }
    return values;
  }

  static bool _endsWithBracket(String title) {
    final tail = title.trimRight();
    if (tail.isEmpty) return false;
    return switch (tail.codeUnitAt(tail.length - 1)) {
      0x29 || 0x5D || 0xFF09 || 0x3011 => true,
      _ => false,
    };
  }
}
