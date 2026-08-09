import 'package:baka/source/video_url_extractor.dart';
import 'package:baka/services/torrent/torrent_model.dart';

/// 线路 token / 媒体 URL 的就绪分类。
///
/// 搜索结果里的线路字段经常是「剧集页 URL」或「站点内部 id」，
/// 不能因为以 `http` 开头就当直链播放。只有真正可播的媒体地址才算
/// [MediaTokenKind.directMedia]。
enum MediaTokenKind {
  /// m3u8 / mp4 / 签名 CDN / 对象存储等，可直接交给播放器。
  directMedia,

  /// magnet / torrent。
  torrent,

  /// 需要走源适配器 `resolvePlaybackMedia` 再取真实地址。
  needsResolve,

  empty,
}

class MediaReadiness {
  MediaReadiness._();

  /// 分类单条线路 token。
  static MediaTokenKind classify(String? token) {
    final value = token?.trim() ?? '';
    if (value.isEmpty) return MediaTokenKind.empty;
    if (isTorrentLink(value)) return MediaTokenKind.torrent;
    if (_looksLikeDirectMedia(value)) return MediaTokenKind.directMedia;
    return MediaTokenKind.needsResolve;
  }

  /// 已解析出的播放地址是否可接受为“可播”。
  ///
  /// 比 [classify] 更宽松：适配器返回的部分对象存储链接未必带扩展名，
  /// 但仍可交给播放器；HTML 落地页、图片等仍会被拒绝。
  static bool isAcceptablePlaybackUrl(String? url) {
    final value = url?.trim() ?? '';
    if (value.isEmpty) return false;
    if (isTorrentLink(value)) return true;
    if (VideoUrlExtractor.isPlayable(value)) return true;
    if (VideoUrlExtractor.isVideoUrl(value)) return true;
    // 少数源返回无扩展名的 https 流地址，只要不像 HTML 页就放行。
    if (_looksLikeBareStream(value)) return true;
    return false;
  }

  static bool isDirectMedia(String? token) =>
      classify(token) == MediaTokenKind.directMedia;

  static bool needsResolve(String? token) =>
      classify(token) == MediaTokenKind.needsResolve;

  static bool _looksLikeDirectMedia(String value) {
    if (VideoUrlExtractor.isPlayable(value)) return true;
    if (VideoUrlExtractor.isVideoUrl(value)) return true;
    return false;
  }

  static bool _looksLikeBareStream(String value) {
    final lower = value.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    // 明显的站点页面路径：不当作媒体。
    if (_htmlPagePath.hasMatch(lower)) return false;
    if (lower.contains('mime=image') || lower.contains('image/')) return false;
    // 无路径或纯域名也不像媒体。
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return false;
    final path = uri.path;
    if (path.isEmpty || path == '/') return false;
    // 带常见页面后缀则拒绝。
    if (_pageExt.hasMatch(path)) return false;
    return true;
  }

  static final RegExp _htmlPagePath = RegExp(
    r'(?:/play/|/video/|/vod/|/bangumi/|/detail/|/ep/|/episode/|/watch/|'
    r'\.html?(?:[?#/&]|$)|/index\.php)',
    caseSensitive: false,
  );

  static final RegExp _pageExt = RegExp(
    r'\.(?:html?|php|aspx?|jsp)(?:[?#/&]|$)',
    caseSensitive: false,
  );
}
