import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/runtime/request_scheduler.dart';

/// 管线解释器与「宿主」（适配器）之间的契约。
///
/// 解释器只依赖这个窄接口，因此可以脱离 Flutter/网络单元测试，
/// 而真实实现（[PipelineSourceAdapter]）负责把重活（HTTP、DOM 解析、
/// 视频直链择优）委托给已经过实战检验的 mixin，避免在解释器里重复造轮子。
abstract class PipelineHost {
  String get baseUrl;

  /// 规则声明的全局请求头。
  Map<String, String> get ruleHeaders;

  /// 是否允许 WebView 渲染/嗅探。
  bool get allowWebview;

  /// 将相对 URL 转为绝对 URL。
  String toAbsolute(String url, String base);

  /// 归一化解析出的 URL（去转义、解码、抽取嵌套直链）。
  String normalizeUrl(String url, String pageUrl);

  /// 是否为可播放视频直链。
  bool isPlayable(String url);

  /// 经调度器发起 HTTP 请求，返回响应体文本。
  ///
  /// [contentType] 为 `form` 时以 `application/x-www-form-urlencoded` 发送 Map
  /// 请求体；默认按 Dio 常规（Map→JSON）处理。
  Future<String> fetch(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    Object? body,
    String? referer,
    String? contentType,
    RequestPriority priority = RequestPriority.search,
    RequestCancelToken? cancelToken,
  });

  /// 用 CSS 选择器从 HTML 解析搜索结果列表。
  List<Series> parseSearchList(
    String html, {
    required List<String> selectors,
    String? detailPattern,
  });

  /// 用 XPath 从 HTML 解析搜索结果列表。
  List<Series> parseSearchListXPath(
    String html, {
    required String listXPath,
    required String nameXPath,
    required String linkXPath,
  });

  /// 从详情页 HTML 解析播放线路与剧集（CSS）。
  List<Source> parseEpisodes(
    String html, {
    required List<String> listSelectors,
    List<String>? tabSelectors,
  });

  /// 从详情页 HTML 解析播放线路与剧集（XPath）。
  List<Source> parseEpisodesXPath(
    String html, {
    required String roadsXPath,
    required String itemsXPath,
  });

  /// 从任意内容中择优提取视频直链。
  String extractVideoUrl(String content, String pageUrl);

  /// 用 CSS 选择器取单值（元素属性或文本）。
  String? selectAttr(String html, String selector, String attr);

  /// 用 CSS 选择器取多个元素的属性/文本。
  List<String> selectAll(String html, String selector, String attr);

  /// WebView 渲染取页面 HTML；未启用返回空串。
  Future<String> renderWithWebview(String url);

  /// WebView 嗅探视频直链；未启用返回空串。
  Future<String> sniffWithWebview(String url);
}

/// 可选的 WebView HTML 就绪等待能力。
///
/// 普通测试宿主只需实现 [PipelineHost.renderWithWebview]；真实宿主实现本接口后，
/// 管线里的 `sniff(goal: html)` 可以把规则声明的就绪条件和超时参数传到底层
/// WebView，避免在 JS challenge 或客户端渲染尚未完成时过早读取 HTML。
abstract class PipelineWebviewReadyHost {
  Future<String> renderWithWebviewReady(
    String url, {
    bool Function(String html)? isReady,
    Duration timeout = const Duration(seconds: 30),
    Duration settleDelay = const Duration(seconds: 1),
  });
}
