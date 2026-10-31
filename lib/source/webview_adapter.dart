import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as win;

import 'package:baka/instance.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/runtime/source_operation.dart';

/// Evaluates [script] in the task's page and returns its result as a string.
typedef _Js = Future<String> Function(String script);

/// 后台 WebView 适配器：加载页面、嗅探视频直链、抓取渲染后的 HTML 与 cookie。
///
/// 设计要点：
/// - 共享单个控制器，任务经 [WebViewTaskQueue] 串行执行，互不争用；
/// - 嗅探脚本每个文档只安装一次，靠 Hook（media src / XHR / fetch /
///   JSON.parse / PerformanceObserver）事件驱动地捕获媒体 URL；
/// - Dart 侧轮询只读取一个变量，未命中时才触发一次增量兜底扫描。
abstract final class WebViewAdapter {
  /// Desktop User-Agent shared by Dio and opt-in WebView rendering.
  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

  static const _pollInterval = Duration(milliseconds: 500);

  /// 视频嗅探脚本，幂等安装。
  ///
  /// 捕获到的最优 URL 存于 `window.__bakaSniffer.best`（rank 越小越优）；
  /// `scan()` 是按需兜底：只在尚未命中时扫描 DOM、常见全局变量与
  /// 新增的 performance 资源条目（带索引游标，不重扫旧条目）。
  static const String _snifferScript = r'''
(function () {
  if (window.__bakaSniffer) return;
  var S = window.__bakaSniffer = {
    best: '', rank: 9, frame: '', frameFollowed: false
  };

  var RE_BAD = /adposter|advertis|\/ads?\/|ad\.m3u8|ad\.mp4|poster|thumbnail|loading\.|ploading|(?:pre|mid|post)roll|commercial|promo\.|mime=image|image\/|解密失败|解析失败|decrypt(?:ion)?[_ .-]?fail|\.(?:jpe?g|png|webp|gif|bmp|svg)(?:[?#\/&]|$)/i;
  var RANKS = [
    /\.m3u8(?:[?#\/&]|$)|type=m3u8|\/hls\//i,
    /\/video\/tos\/|mime_?type=video|mime=video|sign\.byte(?:tos|img)|bytefcdn/i,
    /\.mp4(?:[?#\/&]|$)/i,
    /\.flv(?:[?#\/&]|$)/i,
    /\.(?:mkv|avi)(?:[?#\/&]|$)/i,
    /\.mknvideo(?:[?#\/&]|$)/i,
    /\.ts(?:[?#\/&]|$)/i,
    /\.aliyuncs\.com|\.myqcloud\.com|cloudflarestorage|objstorage|bilivideo\.com/i
  ];
  var RE_URL = /(?:https?:)?\/\/[^"'<>\s\\{}()]+?(?:\.(?:m3u8|mp4|flv|mkv|avi|ts|mknvideo)(?![\w.])|\/hls\/|\/video\/tos\/|type=m3u8|mime_?type=video|mime=video|sign\.byte|bytefcdn|\.aliyuncs\.com|\.myqcloud\.com|cloudflarestorage|objstorage|bilivideo\.com)[^"'<>\s\\{}()]*/i;
  var RE_URL_G = new RegExp(RE_URL.source, 'ig');
  var NESTED = ['url', 'u', 'src', 'file', 'video', 'videoUrl', 'play_url', 'path'];
  var GLOBALS = ['info', 'stray', 'player', 'config', 'PlayConfig'];

  function clean(v) {
    if (typeof v !== 'string') return '';
    var t = v.trim();
    for (var i = 0; i < 2; i++) {
      var n = t.replace(/&amp;/g, '&').replace(/\\u0026/ig, '&').replace(/\\u002f/ig, '/')
        .replace(/\\\//g, '/').replace(/^["']+|["']+$/g, '');
      // Decode an encoded URL envelope, never an already usable URL's signed query.
      if (!/^(?:https?:\/\/|\/)/i.test(n)) {
        try { var d = decodeURIComponent(n); if (d !== n) n = d; } catch (e) {}
      }
      if (n === t) break;
      t = n;
    }
    return t;
  }

  function consider(v, depth) {
    var s = clean(v);
    if (!s || s.length > 4096) return;
    if (/^(?:blob:|about:|data:|javascript:)/i.test(s)) return;
    if (s.slice(0, 2) === '//') {
      s = location.protocol + s;
    } else if (s.charAt(0) === '/') {
      try { s = new URL(s, location.href).href; } catch (e) { return; }
    } else if (!/^https?:\/\//i.test(s)) {
      var m = RE_URL.exec(s);
      if (m) consider(m[0], depth);
      return;
    }

    if (!RE_BAD.test(s)) {
      for (var r = 0; r < RANKS.length; r++) {
        if (RANKS[r].test(s)) {
          if (r < S.rank || (r === S.rank && s.length < S.best.length)) {
            S.best = s;
            S.rank = r;
            if (window.top !== window) {
              try { window.top.postMessage({ __baka: s }, '*'); } catch (e) {}
            }
          }
          break;
        }
      }
    }

    if (depth > 0 && s.indexOf('=') !== -1) {
      try {
        var q = new URL(s).searchParams;
        for (var i = 0; i < NESTED.length; i++) {
          var nested = q.get(NESTED[i]);
          if (nested) consider(nested, depth - 1);
        }
      } catch (e) {}
    }
  }

  function scanText(text) {
    if (typeof text !== 'string' || !text || S.rank === 0) return;
    if (text.length > 262144) text = text.slice(0, 262144);
    if (text.indexOf('\\/') !== -1) text = text.replace(/\\\//g, '/');
    if (text.indexOf('\\u') !== -1) {
      text = text.replace(/\\u0026/ig, '&').replace(/\\u002f/ig, '/');
    }
    RE_URL_G.lastIndex = 0;
    var m, n = 0;
    while (n++ < 24 && (m = RE_URL_G.exec(text))) consider(m[0], 1);
  }

  function scanObj(v, depth, budget) {
    budget = budget || { n: 400 };
    if (!v || depth < 0 || --budget.n < 0) return;
    if (typeof v === 'string') {
      if (v.length <= 4096) consider(v, 1); else scanText(v);
      return;
    }
    if (typeof v !== 'object') return;
    if (Array.isArray(v)) {
      for (var i = 0; i < v.length && i < 20; i++) scanObj(v[i], depth - 1, budget);
      return;
    }
    var keys;
    try { keys = Object.keys(v); } catch (e) { return; }
    for (var k = 0; k < keys.length && k < 40; k++) {
      try { scanObj(v[keys[k]], depth - 1, budget); } catch (e) {}
    }
  }

  function scanGlobals(w) {
    for (var g = 0; g < GLOBALS.length; g++) scanObj(w[GLOBALS[g]], 4);
  }

  // MacCMS exposes the current episode before its player and remote scripts load.
  // Match playerAaaa's encoding contract; do not scan url_next or other episodes.
  function scanPlayerConfig(w) {
    try {
      var p = w.player_aaaa;
      if (!p || typeof p.url !== 'string') return;
      var u = p.url, mode = String(p.encrypt || 0);
      if (mode === '2') {
        var bytes = w.atob(u.replace(/-/g, '+').replace(/_/g, '/'));
        u = new TextDecoder('utf-8', { fatal: true }).decode(
          Uint8Array.from(bytes, function (c) { return c.charCodeAt(0); }));
      }
      if (mode === '1' || (mode === '2' && u.indexOf('%') !== -1)) {
        u = decodeURIComponent(u);
      } else if (mode !== '0' && mode !== '2') {
        return;
      }
      consider(u, 1);
    } catch (e) {}
  }

  // Resource entries are read incrementally; a new document has a new Performance.
  var perfSeen = new WeakMap();
  function scanPerf(w) {
    var p = w.performance, entries = p.getEntriesByType('resource');
    for (var i = perfSeen.get(p) || 0; i < entries.length; i++) consider(entries[i].name, 1);
    perfSeen.set(p, entries.length);
  }

  function considerFrame(el) {
    if (S.frame || S.best) return;
    var raw = '';
    try { raw = el.src || el.getAttribute('src') || ''; } catch (e) {}
    if (!raw || RE_BAD.test(raw)) return;
    var hint = (el.id || '') + ' ' + (el.className || '') + ' ' + raw;
    if (!/(?:player|play|parser|jiexi|url=)/i.test(hint)) return;
    try {
      var absolute = new URL(raw, location.href).href;
      if (/^https?:\/\//i.test(absolute) && absolute !== location.href) {
        S.frame = absolute;
      }
    } catch (e) {}
  }

  // Media nodes of doc; the top document also looks into same-origin iframes.
  function scanNodes(doc, top) {
    var nodes = doc.querySelectorAll('video, source, iframe, embed, object');
    for (var i = 0; i < nodes.length && i < 50; i++) {
      var node = nodes[i];
      if (node.tagName !== 'IFRAME') {
        consider(node.currentSrc || node.src || node.data || node.getAttribute('src') ||
          node.getAttribute('data-src') || node.getAttribute('data'), 1);
      } else if (top) {
        scanFrame(node);
      } else {
        considerFrame(node);
      }
    }
  }

  function scanFrame(el) {
    considerFrame(el);
    if (S.best) return;
    try {
      var w = el.contentWindow;
      var d = el.contentDocument;
      if (!w || !d) return;
      consider(w.__bakaSniffer && w.__bakaSniffer.best, 1);
      scanPlayerConfig(w);
      if (S.best) return;
      scanNodes(d, false);
      scanGlobals(w);
      scanPerf(w);
    } catch (e) {}
  }

  function hookSrc(proto) {
    try {
      var d = Object.getOwnPropertyDescriptor(proto, 'src');
      if (!d || !d.set) return;
      Object.defineProperty(proto, 'src', {
        get: function () { return d.get.call(this); },
        set: function (v) { consider(v, 1); d.set.call(this, v); }
      });
    } catch (e) {}
  }
  hookSrc(HTMLMediaElement.prototype);
  hookSrc(HTMLSourceElement.prototype);

  document.addEventListener('loadstart', function (e) {
    var t = e.target;
    if (t && t.tagName === 'VIDEO') consider(t.currentSrc || t.src, 1);
  }, true);

  try {
    var xhrOpen = XMLHttpRequest.prototype.open;
    var xhrSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      consider(url, 1);
      return xhrOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      try {
        this.addEventListener('loadend', function () {
          consider(this.responseURL, 1);
          if (this.responseType === '' || this.responseType === 'text') {
            try { scanText(this.responseText); } catch (e) {}
          }
        });
      } catch (e) {}
      return xhrSend.apply(this, arguments);
    };
  } catch (e) {}

  try {
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function (input) {
        try { consider(typeof input === 'string' ? input : input && input.url, 1); } catch (e) {}
        return origFetch.apply(this, arguments).then(function (res) {
          try {
            consider(res.url, 1);
            var ct = (res.headers && res.headers.get('content-type')) || '';
            if (S.rank > 0 && res.clone && /json|text|mpegurl|xml/i.test(ct)) {
              res.clone().text().then(scanText)['catch'](function () {});
            }
          } catch (e) {}
          return res;
        });
      };
    }
  } catch (e) {}

  try {
    var origParse = JSON.parse;
    JSON.parse = function () {
      var v = origParse.apply(this, arguments);
      if (S.rank > 0) { try { scanObj(v, 4); } catch (e) {} }
      return v;
    };
  } catch (e) {}

  try {
    new PerformanceObserver(function (list) {
      var es = list.getEntries();
      for (var i = 0; i < es.length; i++) consider(es[i].name, 1);
    }).observe({ entryTypes: ['resource'] });
  } catch (e) {}

  window.addEventListener('message', function (e) {
    var d = e.data;
    if (d && typeof d.__baka === 'string') consider(d.__baka, 1);
  });

  S.scan = function () {
    if (S.best) return S.best;
    scanPlayerConfig(window);
    if (S.best) return S.best;
    try { scanNodes(document, true); } catch (e) {}
    try { scanGlobals(window); } catch (e) {}
    try { scanPerf(window); } catch (e) {}
    return S.best;
  };
  S.followFrame = function () {
    if (S.best || S.frameFollowed) return false;
    S.scan();
    if (!S.frame) return false;
    S.frameFollowed = true;
    try {
      location.assign(S.frame);
      return true;
    } catch (e) {
      return false;
    }
  };
})();
''';

  /// 强制静音后台 WebView 中的媒体元素，防止漏出声音。
  static const String _muteScript = r'''
(function () {
  if (window.__bakaMuted) return;
  window.__bakaMuted = true;
  function silence(m) { m.muted = true; m.volume = 0; }
  try {
    var play = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function () {
      silence(this);
      return play.apply(this, arguments);
    };
  } catch (e) {}
  // Media events do not bubble, but capture listeners see every element.
  ['loadstart', 'play', 'volumechange'].forEach(function (type) {
    document.addEventListener(type, function (e) {
      if (e.target instanceof HTMLMediaElement) silence(e.target);
    }, true);
  });
})();
''';

  static const String _sniffScripts = '$_muteScript\n$_snifferScript';

  /// 导航尚未提交时旧文档仍可执行 JS；复位与 Cookie 播种页都会打上此标记，
  /// 轮询只读取目标文档。
  static const String _staleScript = 'window.__bakaWebviewStale=true';
  static const String _notTarget =
      'window.__bakaWebviewStale||location.href==="about:blank"';

  /// 嗅探器缺失（脚本尚未注入到当前文档）时返回哨兵值，由 Dart 侧补注入。
  static const String _snifferMissing = '__baka_missing__';
  static const String _sniffPollScript =
      "(function(){if($_notTarget)return '';var s=window.__bakaSniffer;"
      "return s?(s.best||s.scan()):'$_snifferMissing';})()";
  static const String _followFrameScript =
      "(function(){if($_notTarget||document.readyState==='loading')return '';"
      "var s=window.__bakaSniffer;return s&&s.followFrame()?'1':'';})()";
  static const String _htmlScript =
      "(function(){return $_notTarget?'':document.documentElement.outerHTML;})()";
  static const String _loadedHtmlScript =
      "(function(){return $_notTarget||document.readyState!=='complete'?'':"
      'document.documentElement.outerHTML;})()';

  /// 读取当前文档 JS 可见的 cookie（HttpOnly cookie 读不到，符合预期）。
  static const String _cookieScript = 'document.cookie';

  /// MacCMS 智能验证页：点击验证按钮后页面会自行 POST 并 reload。
  static const String _clickVerifyScript =
      '(function(){var b=document.getElementById("smart-verify-btn");'
      'if(b&&!b.disabled&&!b.__bakaClicked){b.__bakaClicked=true;b.click();}'
      'return "";})()';

  static const String _blankPage =
      '<!DOCTYPE html><html><head><meta charset="utf-8" />'
      '<script>window.__bakaWebviewStale=true</script></head>'
      '<body style="margin:0;background:#000;"></body></html>';

  /// JS/CDN challenge 页面只是中间态，会自动 POST / reload。
  static final RegExp _challengePattern = RegExp(
    r'X-GE-UA-Step|DokiDoki CDN|dooki\.cloud|'
    r'<title>\s*(?:安全检查中|Just a moment|身份验证|安全验证)|'
    r'please enable javascript and (?:cookies|refresh)|'
    r'checking your browser before accessing|window\._cf_chl_opt|'
    r'__cf_chl_|cf-browser-verification|ddos-guard|'
    r'smart-verify-btn|smart_verify|altcha-widget|aegis_altcha',
    caseSensitive: false,
  );

  static win.WebviewController? _desktopController;
  static WebViewController? _mobileController;
  static bool _mobileSniffing = false;
  static final _tasks = WebViewTaskQueue();

  /// 加载播放器页面并嗅探视频直链，未嗅到返回空串。
  static Future<String> sniff(
    String url, {
    required String userAgent,
    String? cookieHeader,
    bool followEmbeddedPlayer = false,
  }) async =>
      await _run(
        url,
        userAgent: userAgent,
        timeout: const Duration(seconds: 60),
        sniff: true,
        cookieHeader: cookieHeader,
        poll: (js) => _pollSniffed(js, followEmbeddedPlayer),
      ) ??
      '';

  /// 加载页面并返回 (HTML, JS 可见 cookie)；截止前未就绪返回空。
  static Future<(String html, String cookies)> render(
    String url, {
    String userAgent = desktopUserAgent,
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = Duration.zero,
  }) async =>
      await _run(
        url,
        userAgent: userAgent,
        timeout: timeout,
        poll: (js) => _pollPage(js, isReady, settleDelay),
      ) ??
      ('', '');

  /// `name=value` pairs of a Cookie header or `document.cookie`.
  static Iterable<(String, String)> cookiePairs(String header) sync* {
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final name = part.substring(0, eq).trim();
      if (name.isNotEmpty) yield (name, part.substring(eq + 1).trim());
    }
  }

  /// 加载 [url] 后运行 [poll] 直至其返回或任务截止；结束时复位控制器。
  static Future<T?> _run<T>(
    String url, {
    required String userAgent,
    required Duration timeout,
    required Future<T> Function(_Js js) poll,
    bool sniff = false,
    String? cookieHeader,
  }) {
    Future<void> Function()? reset;
    void Function()? discard;
    return _tasks.run(
      timeout: timeout,
      cleanup: () => reset?.call() ?? Future.value(),
      discard: () => discard?.call(),
      action: () async {
        final cookies = cookieHeader == null
            ? const <(String, String)>[]
            : cookiePairs(cookieHeader).toList();
        final _Js js;
        if (Platform.isWindows) {
          final controller = await _desktop();
          discard = () {
            if (identical(_desktopController, controller)) {
              _desktopController = null;
            }
            unawaited(controller.dispose());
          };
          Future<String?>? sniffer;
          reset = () async {
            await controller.executeScript(_staleScript);
            if (await sniffer case final id?) {
              await controller.removeScriptToExecuteOnDocumentCreated(id);
            }
            await controller.stop();
            await controller.loadStringContent(_blankPage);
          };
          js = _evaluator(controller.executeScript);
          await controller.setUserAgent(userAgent);
          // Each raw controller call is preceded by a check: work resuming
          // after the deadline must not navigate the reset browser.
          SourceOperation.check();
          if (cookies.isNotEmpty) {
            await _seedDesktop(controller, js, Uri.parse(url), cookies);
            SourceOperation.check();
          }
          if (sniff) {
            await (sniffer = controller.addScriptToExecuteOnDocumentCreated(
              _snifferScript,
            ));
            SourceOperation.check();
          }
          await controller.loadUrl(url);
        } else {
          final controller = _mobileController ??= await _createMobile();
          discard = () {
            if (identical(_mobileController, controller)) {
              _mobileController = null;
            }
          };
          reset = () async {
            _mobileSniffing = false;
            await controller.runJavaScript(_staleScript);
            await controller.loadRequest(Uri.parse('about:blank'));
          };
          js = _evaluator(controller.runJavaScriptReturningResult);
          await controller.setUserAgent(
            Instances.isTV ? desktopUserAgent : userAgent,
          );
          if (cookies.isNotEmpty) {
            final manager = WebViewCookieManager();
            final host = Uri.parse(url).host;
            for (final (name, value) in cookies) {
              await manager.setCookie(
                WebViewCookie(name: name, value: value, domain: host),
              );
            }
          }
          SourceOperation.check();
          _mobileSniffing = sniff;
          await controller.loadRequest(Uri.parse(url));
        }
        return poll(js);
      },
    );
  }

  static Future<win.WebviewController> _desktop() async {
    if (_desktopController case final controller?) return controller;
    final controller = win.WebviewController();
    try {
      await controller.initialize();
      // Every document is muted from creation; the sniffer is added per task.
      await controller.addScriptToExecuteOnDocumentCreated(_muteScript);
      SourceOperation.check();
    } catch (_) {
      unawaited(controller.dispose());
      rethrow;
    }
    return _desktopController = controller;
  }

  /// webview_flutter can only inject after navigation starts, so the sniffer
  /// is re-injected on each page of a sniff task.
  static Future<WebViewController> _createMobile() async {
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    void inject(String _) {
      if (!_mobileSniffing) return;
      unawaited(controller.runJavaScript(_sniffScripts).catchError((_) {}));
    }

    await controller.setNavigationDelegate(
      NavigationDelegate(onPageStarted: inject, onPageFinished: inject),
    );
    return controller;
  }

  /// Windows and iOS return the script's value; Android returns the JSON
  /// encoding of strings.
  static _Js _evaluator(
    Future<Object?> Function(String) evaluate,
  ) => (script) async {
    // A timed-out poll may resume later; it must not touch the next task's page.
    SourceOperation.check();
    try {
      final value = await evaluate(script);
      return Platform.isAndroid && value is String
          ? '${jsonDecode(value) ?? ''}'
          : '${value ?? ''}';
    } catch (_) {
      return ''; // Scripts fail while the document is being replaced.
    }
  };

  /// Cookies are written from a document on the target host, so the target's
  /// own request carries them. Redirects may land on another host.
  static Future<void> _seedDesktop(
    win.WebviewController controller,
    _Js js,
    Uri target,
    List<(String, String)> cookies,
  ) async {
    final assignments = jsonEncode([
      for (final (name, value) in cookies) '$name=$value; path=/',
    ]);
    final seed =
        '(function(){if($_notTarget)return "";'
        'if(location.hostname===${jsonEncode(target.host)})'
        '$assignments.forEach(function(c){document.cookie=c});'
        '$_staleScript;return "1";})()';
    final events = StreamIterator(controller.loadingState);
    try {
      var next = events.moveNext(); // Subscribe before navigating.
      await controller.loadUrl('${target.origin}/');
      while (await SourceOperation.current!.wait(next)) {
        if (events.current == win.LoadingState.navigationCompleted &&
            await js(seed) == '1') {
          return;
        }
        next = events.moveNext();
      }
    } finally {
      await events.cancel();
    }
  }

  /// Polls until a URL is found; the task deadline ends the loop.
  static Future<String> _pollSniffed(_Js js, bool followEmbeddedPlayer) async {
    var follow = followEmbeddedPlayer;
    while (true) {
      final url = await js(_sniffPollScript);
      if (url == _snifferMissing) {
        await js(_sniffScripts);
      } else if (url.isNotEmpty) {
        return url;
      } else if (follow && await js(_followFrameScript) == '1') {
        follow = false;
      }
      await SourceOperation.delay(_pollInterval);
    }
  }

  /// Polls until the page is ready; the task deadline ends the loop.
  static Future<(String, String)> _pollPage(
    _Js js,
    bool Function(String html)? isReady,
    Duration settleDelay,
  ) async {
    // Explicit readiness can succeed before slow subresources finish loading.
    // Without it, wait for the target document's load event.
    final script = isReady == null ? _loadedHtmlScript : _htmlScript;
    var settled = settleDelay == Duration.zero;
    while (true) {
      final html = await js(script);
      if (html.isNotEmpty) {
        if (!settled) {
          settled = true;
          await SourceOperation.delay(settleDelay);
          continue;
        }
        if (_challengePattern.hasMatch(html)) {
          if (html.contains('smart-verify-btn')) await js(_clickVerifyScript);
        } else if (isReady?.call(html) ?? true) {
          return (html, await js(_cookieScript));
        }
      }
      await SourceOperation.delay(_pollInterval);
    }
  }
}

/// Serial ownership of the shared browser. The deadline includes queue time.
/// Finished and cancelled tasks reset the browser within [run]'s
/// `cleanupTimeout`; a failed task or a stuck reset discards it.
/// Returns null when the deadline or the caller cancels the task.
@visibleForTesting
class WebViewTaskQueue {
  Future<void> _tail = Future.value();

  Future<T?> run<T>({
    required Duration timeout,
    required Future<T> Function() action,
    required Future<void> Function() cleanup,
    required void Function() discard,
    Duration cleanupTimeout = const Duration(seconds: 2),
  }) async {
    final deadline = SourceOperation(
      parent: SourceOperation.current,
      timeout: timeout,
    );
    final result = _tail.then<T?>((_) async {
      if (deadline.isCancelled) return null;
      final execution = SourceOperation(parent: deadline);
      var failed = false;
      try {
        return await execution.run(action);
      } on RequestCancelledException {
        return null;
      } catch (_) {
        failed = true;
        rethrow;
      } finally {
        execution
          ..cancel() // Late platform completions cannot start more work.
          ..close();
        if (failed) {
          discard();
        } else {
          final reset = SourceOperation(timeout: cleanupTimeout);
          try {
            await reset.run(cleanup);
          } catch (_) {
            discard();
          } finally {
            reset
              ..cancel()
              ..close();
          }
        }
      }
    });
    _tail = result.then((_) {}, onError: (Object _) {});
    try {
      return await deadline.wait(result);
    } on RequestCancelledException {
      return null;
    } finally {
      deadline.close();
    }
  }
}
