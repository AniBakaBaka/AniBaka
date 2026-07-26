import 'dart:io';

import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as webview_windows;
import 'package:baka/instance.dart';

/// Cancellation scope for queued background WebView work.
///
/// A source adapter owns one scope. Disposing that adapter invalidates work
/// already running or waiting in the shared WebView queue without affecting
/// tasks submitted later by another adapter.
class WebViewTaskScope {
  int _generation = 0;

  void cancel() => _generation++;
}

/// 后台 WebView 适配器：加载页面、嗅探视频直链、抓取渲染后的 HTML 与 cookie。
///
/// 设计要点：
/// - 共享单个控制器，任务经 [_enqueue] 串行执行，互不争用；
/// - 嗅探脚本每个文档只安装一次，靠 Hook（media src / XHR / fetch /
///   JSON.parse / PerformanceObserver）事件驱动地捕获媒体 URL；
/// - Dart 侧轮询只读取一个变量，未命中时才触发一次增量兜底扫描，
///   不再反复注入大段脚本或全量重扫页面。
class WebViewAdapter {
  /// Desktop User-Agent shared by Dio and opt-in WebView rendering.
  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

  /// 移动端 User-Agent
  static const String mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 10; SM-G973F) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';

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

  function clean(v) {
    if (typeof v !== 'string') return '';
    var t = v.trim();
    for (var i = 0; i < 2; i++) {
      var n = t.replace(/&amp;/g, '&').replace(/\\u0026/ig, '&').replace(/\\u002f/ig, '/')
        .replace(/\\\//g, '/').replace(/^["']+|["']+$/g, '');
      try { var d = decodeURIComponent(n); if (d !== n) n = d; } catch (e) {}
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

    var lower = s.toLowerCase();
    if (!RE_BAD.test(lower)) {
      for (var r = 0; r < RANKS.length; r++) {
        if (RANKS[r].test(lower)) {
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

  function considerFrame(el) {
    if (!el || S.frame || S.best) return;
    var raw = '';
    try { raw = el.src || el.getAttribute('src') || ''; } catch (e) {}
    if (!raw || RE_BAD.test(raw)) return;
    var hint = ((el.id || '') + ' ' + (el.className || '') + ' ' + raw).toLowerCase();
    if (!/(?:player|play|parser|jiexi|url=)/.test(hint)) return;
    try {
      var absolute = new URL(raw, location.href).href;
      if (/^https?:\/\//i.test(absolute) && absolute !== location.href) {
        S.frame = absolute;
      }
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

  var perfIndex = 0;
  S.scan = function () {
    if (S.best) return S.best;
    try {
      var nodes = document.querySelectorAll('video, source, iframe, embed, object');
      for (var i = 0; i < nodes.length && i < 50; i++) {
        var el = nodes[i];
        if (el.tagName === 'IFRAME') {
          considerFrame(el);
          continue;
        }
        consider(el.currentSrc || el.src || el.data ||
          (el.getAttribute && (el.getAttribute('src') || el.getAttribute('data-src') || el.getAttribute('data'))), 1);
      }
    } catch (e) {}
    try {
      var globals = [window.info, window.stray, window.player, window.config, window.PlayConfig];
      for (var g = 0; g < globals.length; g++) scanObj(globals[g], 4);
    } catch (e) {}
    try {
      var entries = performance.getEntriesByType('resource');
      for (; perfIndex < entries.length; perfIndex++) consider(entries[perfIndex].name, 1);
    } catch (e) {}
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

  /// 轮询读取嗅探结果；未命中时触发一次增量扫描。
  /// 嗅探器缺失（脚本尚未注入到当前文档）时返回哨兵值，由 Dart 侧补注入。
  static const String _snifferMissing = '__baka_missing__';
  static const String _snifferPollScript =
      "(function(){var s=window.__bakaSniffer;return s?(s.best||s.scan()):'$_snifferMissing';})()";
  static const String _snifferFollowFrameScript =
      '(function(){var s=window.__bakaSniffer;return !!(s&&s.followFrame&&s.followFrame());})()';

  /// 读取当前文档 JS 可见的 cookie（HttpOnly cookie 读不到，符合预期）。
  static const String _cookieReadScript =
      "(function(){try{return document.cookie||'';}catch(e){return '';}})()";

  /// 提取整页 HTML；复位占位页返回空串，避免误当作目标页面内容。
  static const String _htmlExtractScript = r'''
(function () {
  if (location.href === 'about:blank' || document.title === 'baka-webview-reset') return '';
  return document.documentElement ? document.documentElement.outerHTML : '';
})()''';

  /// 读取目标文档加载状态；复位占位页返回空串（视作"尚未到达目标页"）。
  static const String _readyStateScript = r'''
(function () {
  if (location.href === 'about:blank' || document.title === 'baka-webview-reset') return '';
  return document.readyState || '';
})()''';

  /// 强制静音后台 WebView 中的媒体元素，防止嗅探时漏出声音。
  static const String _muteMediaScript = r'''
(function () {
  if (window.__bakaMuted) return;
  window.__bakaMuted = true;

  function silence(m) {
    if (!m) return;
    m.muted = true; m.defaultMuted = true; m.volume = 0;
    try { m.setAttribute('muted', ''); } catch (e) {}
  }
  function bind(m) {
    if (!m || m.__bakaMuteBound) return;
    m.__bakaMuteBound = true;
    silence(m);
    ['play', 'volumechange'].forEach(function (ev) {
      m.addEventListener(ev, function () { silence(m); }, true);
    });
  }
  function scan() {
    document.querySelectorAll('video, audio').forEach(bind);
  }

  try {
    var origPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function () {
      silence(this);
      return origPlay.apply(this, arguments);
    };
  } catch (e) {}

  function start() {
    try {
      new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}
    scan();
  }
  if (document.documentElement) start();
  else document.addEventListener('DOMContentLoaded', start, { once: true });
})();
''';

  /// 复位时停止所有媒体播放（含可访问的同源 iframe）。
  static const String _stopMediaScript = r'''
(function () {
  function stop(doc) {
    if (!doc) return;
    doc.querySelectorAll('video, audio').forEach(function (m) {
      try { m.pause(); m.removeAttribute('autoplay'); m.src = ''; m.load(); } catch (e) {}
    });
  }
  stop(document);
  for (var i = 0; i < window.frames.length; i++) {
    try { stop(window.frames[i].document); } catch (e) {}
  }
})();
''';

  static const String _blankPage =
      '<!DOCTYPE html><html><head><meta charset="utf-8" /><title>baka-webview-reset</title></head>'
      '<body style="margin:0;background:#000;"></body></html>';

  static bool get _isDesktop => Platform.isWindows || Platform.isMacOS;

  static webview_windows.WebviewController? _desktopController;
  static WebViewController? _mobileController;
  static Future<void> _queue = Future.value();

  /// 共享控制器上的任务串行化，避免并发任务互相覆盖页面。
  static Future<T> _enqueue<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Future<webview_windows.WebviewController>
  _getDesktopController() async {
    if (_desktopController != null) return _desktopController!;
    final controller = webview_windows.WebviewController();
    try {
      await controller.initialize();
      await controller.setUserAgent(desktopUserAgent);
      // 文档创建期注入，覆盖 iframe 与页面最早期的请求：先静音，后嗅探。
      await controller.addScriptToExecuteOnDocumentCreated(_muteMediaScript);
      await controller.addScriptToExecuteOnDocumentCreated(_snifferScript);
    } catch (e) {
      try {
        controller.dispose();
      } catch (_) {}
      rethrow;
    }
    _desktopController = controller;
    return controller;
  }

  static Future<void> _resetDesktop(
    webview_windows.WebviewController controller,
  ) async {
    await Future.wait([
      controller.executeScript(_stopMediaScript).catchError((_) {}),
      controller.stop().catchError((_) {}),
    ]);
    await controller.loadStringContent(_blankPage).catchError((_) {});
  }

  /// 加载 [url] 后运行 [poll] 直至其返回或超时；结束时复位控制器。
  ///
  /// [poll] 应在 `cancelled()` 为真时尽快退出，避免影响队列中的下一个任务。
  static Future<T> _run<T>({
    required String url,
    required String userAgent,
    required Duration timeout,
    required bool sniff,
    required Future<T> Function(
      Future<dynamic> Function(String js) exec,
      bool Function() cancelled,
    )
    poll,
    required T Function() onTimeout,
    required T Function() onCancelled,
    WebViewTaskScope? taskScope,
  }) {
    // Capture before enqueueing. If the owning adapter is disposed while this
    // task is waiting behind another page, it must not start later.
    final taskGeneration = taskScope?._generation;
    return _enqueue(() async {
      var cancelled = false;
      bool taskCancelled() =>
          cancelled ||
          (taskScope != null && taskScope._generation != taskGeneration);

      if (taskCancelled()) return onCancelled();

      if (_isDesktop) {
        final controller = await _getDesktopController();
        if (taskCancelled()) return onCancelled();
        try {
          await controller.setUserAgent(userAgent).catchError((_) {});
          await controller.loadUrl(url);
          if (taskCancelled()) return onCancelled();
          final result = poll(controller.executeScript, taskCancelled);
          return await result.timeout(timeout, onTimeout: onTimeout);
        } finally {
          cancelled = true;
          await _resetDesktop(controller);
        }
      }

      try {
        final controller = _mobileController ??= WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted);
        // TV 环境下强制使用桌面 UA 伪装，以绕过大部分针对移动端的反爬虫及验证码检测
        final effectiveUserAgent = Instances.isTV
            ? desktopUserAgent
            : userAgent;
        await controller.setUserAgent(effectiveUserAgent);
        if (sniff) {
          // 移动端没有文档创建期注入，在导航前后各补一次（脚本幂等）。
          controller.setNavigationDelegate(
            NavigationDelegate(
              onPageStarted: (_) {
                controller.runJavaScript(_snifferScript).catchError((_) {});
              },
              onPageFinished: (_) {
                controller.runJavaScript(_snifferScript).catchError((_) {});
              },
            ),
          );
        }
        await controller.loadRequest(Uri.parse(url));
        if (taskCancelled()) return onCancelled();
        final result = poll(
          controller.runJavaScriptReturningResult,
          taskCancelled,
        );
        return await result.timeout(timeout, onTimeout: onTimeout);
      } catch (_) {
        return taskCancelled() ? onCancelled() : onTimeout();
      } finally {
        cancelled = true;
        final controller = _mobileController;
        if (controller != null) {
          controller.setNavigationDelegate(NavigationDelegate());
          controller.loadRequest(Uri.parse('about:blank')).catchError((_) {});
        }
      }
    });
  }

  static String _cleanJsResult(dynamic result) {
    if (result == null) return '';
    final s = result.toString().replaceAll(RegExp(r'^"|"$'), '').trim();
    if (s == 'null' || s == 'undefined' || s.startsWith('blob:')) return '';
    return s;
  }

  static final RegExp _escapePattern = RegExp(
    r'\\u([0-9a-fA-F]{4})|\\(["\\/nrt])',
  );

  static String _decodeUnicodeEscapes(String input) {
    if (!input.contains(r'\')) return input;
    return input.replaceAllMapped(_escapePattern, (m) {
      final hex = m.group(1);
      if (hex != null) return String.fromCharCode(int.parse(hex, radix: 16));
      return switch (m.group(2)!) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        final c => c,
      };
    });
  }

  static Future<String?> _pollSniffedUrl(
    Future<dynamic> Function(String js) exec,
    bool Function() cancelled,
    Duration timeout,
    bool followEmbeddedPlayer,
  ) async {
    final deadline = DateTime.now().add(timeout);
    final followAfter = DateTime.now().add(const Duration(milliseconds: 1200));
    var followedEmbeddedPlayer = false;
    var intervalMs = 250;
    while (!cancelled() && DateTime.now().isBefore(deadline)) {
      try {
        final url = _cleanJsResult(await exec(_snifferPollScript));
        if (url == _snifferMissing) {
          await exec(_snifferScript);
        } else if (url.isNotEmpty) {
          return url;
        }
        if (followEmbeddedPlayer &&
            !followedEmbeddedPlayer &&
            DateTime.now().isAfter(followAfter)) {
          followedEmbeddedPlayer = true;
          await exec(_snifferFollowFrameScript);
        }
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: intervalMs));
      if (intervalMs < 750) intervalMs += 125;
    }
    return null;
  }

  static final RegExp _transientChallengePattern = RegExp(
    r'X-GE-UA-Step|ge_ua_p|DokiDoki CDN|dooki\.cloud|'
    r'<title>\s*(?:安全检查中|Just a moment|身份验证|安全验证)|'
    r'please enable javascript and (?:cookies|refresh)|'
    r'checking your browser before accessing|window\._cf_chl_opt|'
    r'__cf_chl_|cf-browser-verification|ddos-guard|'
    r'smart-verify-btn|smart_verify|altcha-widget|aegis_altcha',
    caseSensitive: false,
  );

  static bool _isTransientChallengeHtml(String html) {
    if (html.trim().isEmpty) return false;
    return _transientChallengePattern.hasMatch(html);
  }

  static final RegExp _macCmsSmartVerifyPattern = RegExp(
    r'smart-verify-btn|smart_verify',
    caseSensitive: false,
  );

  static bool _isMacCmsSmartVerifyPage(String html) {
    if (html.trim().isEmpty) return false;
    return _macCmsSmartVerifyPattern.hasMatch(html);
  }

  static Future<(String, String)> _pollPageContent(
    Future<dynamic> Function(String js) exec,
    bool Function() cancelled, {
    required Duration timeout,
    required Duration settleDelay,
    bool Function(String html)? isReady,
  }) async {
    final deadline = DateTime.now().add(timeout);

    // 先等目标文档加载完成（复位页视作未到达），最多 6 秒，防止读到半截 HTML。
    final loadWaitCap = DateTime.now().add(const Duration(seconds: 6));
    while (!cancelled() &&
        DateTime.now().isBefore(loadWaitCap) &&
        DateTime.now().isBefore(deadline)) {
      try {
        if (_cleanJsResult(await exec(_readyStateScript)) == 'complete') break;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 250));
    }

    // 静置，给页面 JS 留出渲染时间。
    if (settleDelay > Duration.zero) await Future.delayed(settleDelay);

    var html = '';
    while (!cancelled() && DateTime.now().isBefore(deadline)) {
      try {
        final current = _decodeUnicodeEscapes(
          _cleanJsResult(await exec(_htmlExtractScript)),
        );
        if (current.isNotEmpty) {
          html = current;
          // MacCMS 智能验证页：自动点击验证按钮，页面会自行 POST 并 reload。
          if (_isMacCmsSmartVerifyPage(current)) {
            try {
              await exec(
                'try{var b=document.getElementById("smart-verify-btn");'
                'if(b)b.click();}catch(e){}',
              );
            } catch (_) {}
          }
          // JS/CDN challenge 页面只是中间态。即使文档已经 complete，也要
          // 等其自动 POST / reload 完成后再把 HTML 交给管线。
          if (!_isTransientChallengeHtml(current) &&
              (isReady == null || isReady(current))) {
            break;
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 700));
    }

    var cookies = '';
    try {
      cookies = _cleanJsResult(await exec(_cookieReadScript));
    } catch (_) {}
    return (html, cookies);
  }

  /// 加载播放器页面并嗅探视频直链，未嗅到返回 null。
  static Future<String?> extractVideoUrl(
    String playerUrl, {
    String? userAgent,
    bool followEmbeddedPlayer = false,
    WebViewTaskScope? taskScope,
  }) => _run(
    url: playerUrl,
    userAgent: userAgent ?? desktopUserAgent,
    timeout: const Duration(seconds: 60),
    sniff: true,
    taskScope: taskScope,
    poll: (exec, cancelled) => _pollSniffedUrl(
      exec,
      cancelled,
      const Duration(seconds: 58),
      followEmbeddedPlayer,
    ),
    onTimeout: () => null,
    onCancelled: () => null,
  );

  /// 短超时嗅探：适合直链就写在页面状态（全局变量 / DOM）里的站点。
  static Future<String?> extractVideoUrlFromPageState(
    String playerUrl, {
    String? userAgent,
    Duration timeout = const Duration(seconds: 8),
    WebViewTaskScope? taskScope,
  }) => _run(
    url: playerUrl,
    userAgent: userAgent ?? desktopUserAgent,
    timeout: timeout + const Duration(seconds: 5),
    sniff: true,
    taskScope: taskScope,
    poll: (exec, cancelled) => _pollSniffedUrl(exec, cancelled, timeout, false),
    onTimeout: () => null,
    onCancelled: () => null,
  );

  /// 加载页面并返回 (HTML, JS 可见 cookie)。
  /// cookie 可由调用方回写到 Dio 的 CookieJar 以延续普通渲染会话。
  static Future<(String html, String cookies)> getPageContentWithCookies(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 1),
    String? userAgent,
    WebViewTaskScope? taskScope,
  }) => _run(
    url: url,
    userAgent: userAgent ?? desktopUserAgent,
    timeout: timeout + settleDelay + const Duration(seconds: 5),
    sniff: false,
    taskScope: taskScope,
    poll: (exec, cancelled) => _pollPageContent(
      exec,
      cancelled,
      timeout: timeout,
      settleDelay: settleDelay,
      isReady: isReady,
    ),
    onTimeout: () => throw Exception('获取页面内容超时'),
    onCancelled: () => ('', ''),
  );

  static Future<String> getPageContent(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 1),
    String? userAgent,
    WebViewTaskScope? taskScope,
  }) async => (await getPageContentWithCookies(
    url,
    isReady: isReady,
    timeout: timeout,
    settleDelay: settleDelay,
    userAgent: userAgent,
    taskScope: taskScope,
  )).$1;
}
