import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/runtime/webview_task_queue.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as webview_windows;

/// Cancellation scope for queued background WebView work.
///
/// A source adapter owns one scope. Disposing that adapter invalidates work
/// already running or waiting in the shared WebView queue without affecting
/// tasks submitted later by another adapter.
class WebViewTaskScope {
  RequestCancelToken _token = RequestCancelToken();
  void cancel() {
    _token.cancel();
    _token = RequestCancelToken();
  }
}

/// 后台 WebView 适配器：加载页面、嗅探视频直链、抓取渲染后的 HTML 与 cookie。
///
/// 设计要点：
/// - 共享单个控制器，任务经任务队列串行执行，互不争用；
/// - 嗅探脚本每个文档只安装一次，靠 Hook（media src / XHR / fetch /
///   JSON.parse / PerformanceObserver）事件驱动地捕获媒体 URL；
/// - Dart 侧轮询只读取一个变量，未命中时才触发一次增量兜底扫描，
///   不再反复注入大段脚本或全量重扫页面。
class WebViewAdapter {
  /// Desktop User-Agent shared by Dio and opt-in WebView rendering.
  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

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

  function considerFrame(el) {
    if (!el || S.frame || S.best) return;
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

  var framePerfIndex = new WeakMap();
  function scanFrame(el) {
    considerFrame(el);
    if (!el || S.best) return;
    try {
      var w = el.contentWindow;
      var d = el.contentDocument;
      if (!w || !d) return;
      consider(w.__bakaSniffer && w.__bakaSniffer.best, 1);
      scanPlayerConfig(w);
      if (S.best) return;
      var nodes = d.querySelectorAll('video, source, iframe, embed, object');
      for (var i = 0; i < nodes.length && i < 50; i++) {
        var node = nodes[i];
        if (node.tagName === 'IFRAME') {
          considerFrame(node);
          continue;
        }
        consider(node.currentSrc || node.src || node.data ||
          (node.getAttribute && (node.getAttribute('src') || node.getAttribute('data-src') || node.getAttribute('data'))), 1);
      }
      for (var g = 0; g < GLOBALS.length; g++) scanObj(w[GLOBALS[g]], 4);
      var entries = w.performance.getEntriesByType('resource');
      var index = framePerfIndex.get(el) || 0;
      for (; index < entries.length; index++) consider(entries[index].name, 1);
      framePerfIndex.set(el, index);
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
    scanPlayerConfig(window);
    if (S.best) return S.best;
    try {
      var nodes = document.querySelectorAll('video, source, iframe, embed, object');
      for (var i = 0; i < nodes.length && i < 50; i++) {
        var el = nodes[i];
        if (el.tagName === 'IFRAME') {
          scanFrame(el);
          continue;
        }
        consider(el.currentSrc || el.src || el.data ||
          (el.getAttribute && (el.getAttribute('src') || el.getAttribute('data-src') || el.getAttribute('data'))), 1);
      }
    } catch (e) {}
    try {
      for (var g = 0; g < GLOBALS.length; g++) scanObj(window[GLOBALS[g]], 4);
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
      "(function(){if(window.__bakaWebviewStale)return '';var s=window.__bakaSniffer;return s?(s.best||s.scan()):'$_snifferMissing';})()";
  static const String _snifferFollowFrameScript =
      "(function(){if(window.__bakaWebviewStale||document.readyState==='loading')return false;var s=window.__bakaSniffer;return !!(s&&s.followFrame&&s.followFrame());})()";

  /// 读取当前文档 JS 可见的 cookie（HttpOnly cookie 读不到，符合预期）。
  static const String _cookieReadScript =
      "(function(){try{return document.cookie||'';}catch(e){return '';}})()";

  /// 提取整页 HTML；复位占位页返回空串，避免误当作目标页面内容。
  static const String _htmlExtractScript = r'''
(function () {
  if (window.__bakaWebviewStale || location.href === 'about:blank' || document.title === 'baka-webview-reset') return '';
  return document.documentElement ? document.documentElement.outerHTML : '';
})()''';

  /// 读取目标文档加载状态；复位占位页返回空串（视作"尚未到达目标页"）。
  static const String _readyStateScript = r'''
(function () {
  if (window.__bakaWebviewStale || location.href === 'about:blank' || document.title === 'baka-webview-reset') return '';
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
  function scan(root) {
    if (root.nodeType !== 1) return;
    if (root.tagName === 'VIDEO' || root.tagName === 'AUDIO') bind(root);
    root.querySelectorAll('video, audio').forEach(bind);
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
      new MutationObserver(function (changes) {
        for (var i = 0; i < changes.length; i++) {
          changes[i].addedNodes.forEach(scan);
        }
      }).observe(document.documentElement, { childList: true, subtree: true });
    } catch (e) {}
    document.querySelectorAll('video, audio').forEach(bind);
  }
  if (document.documentElement) start();
  else document.addEventListener('DOMContentLoaded', start, { once: true });
})();
''';

  static const String _mediaSnifferScript =
      '$_muteMediaScript\n$_snifferScript';

  /// 复位时停止所有媒体播放（含可访问的同源 iframe）。
  static const String _stopMediaScript = r'''
(function () {
  // 导航尚未提交时旧文档仍可执行 JS，轮询不能再读取它的嗅探或 HTML 结果。
  window.__bakaWebviewStale = true;
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

  static webview_windows.WebviewController? _desktopController;
  static WebViewController? _mobileController;
  static final _tasks = WebViewTaskQueue();

  static Future<webview_windows.WebviewController>
  _getDesktopController() async {
    if (_desktopController != null) return _desktopController!;
    SourceOperation.check();
    final controller = webview_windows.WebviewController();
    var disposed = false;
    void disposeController() {
      if (disposed) return;
      disposed = true;
      unawaited(controller.dispose().catchError((_) {}));
    }

    final detach = SourceOperation.current?.token.onCancel(disposeController);
    try {
      await controller.initialize();
      SourceOperation.check();
      await controller.setUserAgent(desktopUserAgent);
      SourceOperation.check();
      // 文档创建期注入，覆盖 iframe 与页面最早期的请求：先静音，后嗅探。
      await controller.addScriptToExecuteOnDocumentCreated(_mediaSnifferScript);
      SourceOperation.check();
    } catch (e) {
      disposeController();
      rethrow;
    } finally {
      detach?.call();
    }
    SourceOperation.check();
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
    SourceOperation.check();
    await controller.loadStringContent(_blankPage);
    SourceOperation.check();
  }

  static List<MapEntry<String, String>> _parseCookieHeader(
    String? cookieHeader,
  ) {
    if (cookieHeader == null || cookieHeader.isEmpty) return const [];
    final cookies = <MapEntry<String, String>>[];
    for (final part in cookieHeader.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final name = part.substring(0, separator).trim();
      if (name.isEmpty) continue;
      cookies.add(MapEntry(name, part.substring(separator + 1).trim()));
    }
    return cookies;
  }

  /// 轮询目标文档的 `location.hostname`，确认控制器已停留在期望站点。
  ///
  /// `WebviewController.url` 是单订阅流，每个控制器只能监听一次；共享控制器
  /// 会被多次 Cookie 播种任务复用，因此这里改为轮询文档自身的 host。
  static Future<bool> _waitForDesktopHost(
    webview_windows.WebviewController controller,
    String host, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final watch = Stopwatch()..start();
    final timeoutMicros = timeout.inMicroseconds;
    while (watch.elapsedMicroseconds < timeoutMicros) {
      SourceOperation.check();
      try {
        if (_cleanJsResult(
              await controller.executeScript('location.hostname'),
            ) ==
            host) {
          return true;
        }
      } catch (_) {}
      await SourceOperation.delay(const Duration(milliseconds: 150));
      SourceOperation.check();
    }
    return false;
  }

  static Future<void> _seedDesktopCookies(
    webview_windows.WebviewController controller,
    Uri target,
    List<MapEntry<String, String>> cookies,
  ) async {
    if (cookies.isEmpty || !target.hasScheme || target.host.isEmpty) return;
    final origin = target.replace(path: '/', query: '', fragment: '');
    await controller.loadUrl(origin.toString());
    // 只有确认当前文档确实属于目标站点才写入，避免重定向到第三方域后
    // 把会话 Cookie 写错域（浏览器也会拒绝跨域赋值）。
    SourceOperation.check();
    if (!await _waitForDesktopHost(controller, target.host)) return;
    for (final cookie in cookies) {
      SourceOperation.check();
      final assignment = '${cookie.key}=${cookie.value}; path=/';
      try {
        await controller.executeScript(
          'document.cookie=${jsonEncode(assignment)}',
        );
      } catch (_) {}
      SourceOperation.check();
    }
  }

  static Future<void> _seedMobileCookies(
    Uri target,
    List<MapEntry<String, String>> cookies,
  ) async {
    if (cookies.isEmpty || target.host.isEmpty) return;
    final manager = WebViewCookieManager();
    for (final cookie in cookies) {
      SourceOperation.check();
      await manager.setCookie(
        WebViewCookie(
          name: cookie.key,
          value: cookie.value,
          domain: target.host,
        ),
      );
    }
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
    String? cookieHeader,
    WebViewTaskScope? taskScope,
  }) {
    final owner = taskScope?._token;
    Future<void> Function()? reset;
    webview_windows.WebviewController? desktop;
    WebViewController? mobile;
    void discard() {
      if (desktop != null && identical(_desktopController, desktop)) {
        _desktopController = null;
      }
      if (mobile != null && identical(_mobileController, mobile)) {
        _mobileController = null;
      }
      if (desktop != null) {
        unawaited(desktop!.dispose().catchError((_) {}));
      }
    }

    return _tasks.run<T>(
      timeout: timeout,
      owner: owner,
      onExpired: onCancelled,
      cleanup: () => reset?.call() ?? Future<void>.value(),
      discard: discard,
      action: (operation) async {
        var cancelled = false;
        bool taskCancelled() => cancelled || operation.isCancelled;

        if (taskCancelled()) return onCancelled();

        try {
          final cookies = _parseCookieHeader(cookieHeader);
          late Future<dynamic> Function(String) exec;
          if (Platform.isWindows) {
            final controller = await operation.wait(_getDesktopController());
            desktop = controller;
            reset = () => _resetDesktop(controller);
            exec = controller.executeScript;
            await controller.setUserAgent(userAgent).catchError((_) {});
            SourceOperation.check();
            if (cookies.isNotEmpty) {
              await _seedDesktopCookies(controller, Uri.parse(url), cookies);
              SourceOperation.check();
              // Cookie 播种页也可能仍可读取，导航提交前将其排除。
              await controller.executeScript('window.__bakaWebviewStale=true');
              SourceOperation.check();
            }
            if (taskCancelled()) return onCancelled();
            await controller.loadUrl(url);
          } else {
            final controller = _mobileController ??= WebViewController();
            mobile = controller;
            exec = controller.runJavaScriptReturningResult;
            reset = () async {
              await controller
                  .setNavigationDelegate(NavigationDelegate())
                  .catchError((_) {});
              SourceOperation.check();
              await controller
                  .runJavaScript(_stopMediaScript)
                  .catchError((_) {});
              SourceOperation.check();
              await controller.loadRequest(Uri.parse('about:blank'));
              SourceOperation.check();
            };
            await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
            SourceOperation.check();
            await controller.setUserAgent(
              Instances.isTV ? desktopUserAgent : userAgent,
            );
            SourceOperation.check();
            if (cookies.isNotEmpty) {
              await _seedMobileCookies(Uri.parse(url), cookies);
              SourceOperation.check();
            }
            void inject(String _) {
              if (!taskCancelled()) {
                unawaited(
                  controller
                      .runJavaScript(_mediaSnifferScript)
                      .catchError((_) {}),
                );
              }
            }

            if (sniff) {
              await controller.setNavigationDelegate(
                NavigationDelegate(
                  onPageStarted: inject,
                  onPageFinished: inject,
                ),
              );
              SourceOperation.check();
            }
            if (taskCancelled()) return onCancelled();
            await controller.loadRequest(Uri.parse(url));
          }
          if (taskCancelled()) return onCancelled();
          // A timed-out poll may resume later; it must not touch the next task's page.
          return await poll(
            (js) => taskCancelled() ? Future.value('') : exec(js),
            taskCancelled,
          );
        } catch (_) {
          return taskCancelled() ? onCancelled() : onTimeout();
        } finally {
          cancelled = true;
        }
      },
    );
  }

  static String _cleanJsResult(dynamic result) {
    if (result == null) return '';
    var s = result.toString().trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        s = (jsonDecode(s) as String).trim();
      } catch (_) {
        s = s.substring(1, s.length - 1).trim();
      }
    }
    if (s == 'null' || s == 'undefined' || s.startsWith('blob:')) return '';
    return s;
  }

  /// Polls until a URL is found; the task deadline ends the loop.
  static Future<String?> _pollSniffedUrl(
    Future<dynamic> Function(String js) exec,
    bool Function() cancelled,
    bool followEmbeddedPlayer,
  ) async {
    var followedEmbeddedPlayer = false;
    var intervalMs = 250;
    while (!cancelled()) {
      try {
        final url = _cleanJsResult(await exec(_snifferPollScript));
        if (url == _snifferMissing) {
          await exec(_mediaSnifferScript);
        } else if (url.isNotEmpty) {
          return url;
        }
        if (followEmbeddedPlayer && !followedEmbeddedPlayer) {
          followedEmbeddedPlayer =
              _cleanJsResult(await exec(_snifferFollowFrameScript)) == 'true';
        }
      } catch (_) {}
      await SourceOperation.delay(Duration(milliseconds: intervalMs));
      if (intervalMs < 750) intervalMs += 125;
    }
    return null;
  }

  static final RegExp _transientChallengePattern = RegExp(
    r'X-GE-UA-Step|DokiDoki CDN|dooki\.cloud|'
    r'<title>\s*(?:安全检查中|Just a moment|身份验证|安全验证)|'
    r'please enable javascript and (?:cookies|refresh)|'
    r'checking your browser before accessing|window\._cf_chl_opt|'
    r'__cf_chl_|cf-browser-verification|ddos-guard|'
    r'smart-verify-btn|smart_verify|altcha-widget|aegis_altcha',
    caseSensitive: false,
  );

  static final RegExp _macCmsSmartVerifyPattern = RegExp(
    r'smart-verify-btn|smart_verify',
    caseSensitive: false,
  );

  /// Polls until the page is ready; the task deadline ends the loop.
  static Future<(String, String)> _pollPageContent(
    Future<dynamic> Function(String js) exec,
    bool Function() cancelled, {
    required Duration settleDelay,
    bool Function(String html)? isReady,
  }) async {
    var settled = settleDelay == Duration.zero;
    while (!cancelled()) {
      try {
        // Explicit readiness can succeed before slow subresources finish loading.
        // Without it, wait for the target document's load event.
        if (isReady == null &&
            _cleanJsResult(await exec(_readyStateScript)) != 'complete') {
          await SourceOperation.delay(const Duration(milliseconds: 250));
          continue;
        }
        if (!settled) {
          await SourceOperation.delay(settleDelay);
          settled = true;
        }
        final current = _cleanJsResult(await exec(_htmlExtractScript));
        if (current.isNotEmpty) {
          // JS/CDN challenge 页面只是中间态。即使文档已经 complete，也要
          // 等其自动 POST / reload 完成后再把 HTML 交给管线。
          final transient = _transientChallengePattern.hasMatch(current);
          if (!transient && (isReady == null || isReady(current))) {
            final cookies = _cleanJsResult(await exec(_cookieReadScript));
            return (current, cookies);
          }
          // MacCMS 智能验证页：自动点击验证按钮，页面会自行 POST 并 reload。
          if (transient && _macCmsSmartVerifyPattern.hasMatch(current)) {
            try {
              await exec(
                'try{var b=document.getElementById("smart-verify-btn");'
                'if(b&&!b.disabled&&!b.__bakaVerifyClicked){'
                'b.click();b.__bakaVerifyClicked=true;}}catch(e){}',
              );
            } catch (_) {}
          }
        }
      } catch (_) {}
      await SourceOperation.delay(const Duration(milliseconds: 700));
    }

    return ('', '');
  }

  /// 加载播放器页面并嗅探视频直链，未嗅到返回 null。
  static Future<String?> extractVideoUrl(
    String playerUrl, {
    String? userAgent,
    String? cookieHeader,
    bool followEmbeddedPlayer = false,
    WebViewTaskScope? taskScope,
  }) => _run(
    url: playerUrl,
    userAgent: userAgent ?? desktopUserAgent,
    timeout: const Duration(seconds: 60),
    sniff: true,
    cookieHeader: cookieHeader,
    taskScope: taskScope,
    poll: (exec, cancelled) =>
        _pollSniffedUrl(exec, cancelled, followEmbeddedPlayer),
    onTimeout: () => null,
    onCancelled: () => null,
  );

  /// 加载页面并返回 (HTML, JS 可见 cookie)。
  /// cookie 可由调用方回写到 Dio 的 CookieJar 以延续普通渲染会话。
  static Future<(String html, String cookies)> getPageContentWithCookies(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = Duration.zero,
    String? userAgent,
    WebViewTaskScope? taskScope,
  }) => _run(
    url: url,
    userAgent: userAgent ?? desktopUserAgent,
    timeout: timeout,
    sniff: false,
    taskScope: taskScope,
    poll: (exec, cancelled) => _pollPageContent(
      exec,
      cancelled,
      settleDelay: settleDelay,
      isReady: isReady,
    ),
    onTimeout: () => throw Exception('获取页面内容超时'),
    onCancelled: () => ('', ''),
  );
}
