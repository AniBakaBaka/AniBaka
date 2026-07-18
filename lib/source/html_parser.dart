import 'package:html/dom.dart' show Document, Element;
import 'package:html/parser.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/episode.dart';
import 'package:baka/source/models/source.dart';

/// HTML parsing for search results and episode lists.
///
/// Replaces HtmlSearchMixin (245 lines) + EpisodeListMixin (491 lines) with
/// ~200 lines of stateless functions. Key simplifications:
/// - 10 search selectors → 5; 15+ title-link selectors → 3
/// - 3-level parent traversal link finder → querySelector + fallback
/// - 15 list selectors → 8; 11 tab selectors → 5
/// - Removed _pruneNestedEpisodeContainers (over-engineered)
/// - Episode number parsing: 5 patterns + 3 tuple patterns → 2 patterns + 2 tuple patterns
/// - Removed _groupLinksByPattern fallback (rarely used, covered by container logic)
class HtmlParser {
  HtmlParser._();

  // ── Search ──────────────────────────────────────────────────────────

  static const _searchSelectors = [
    '.module-items .module-item',
    '.stui-vodlist__box',
    '.search-list .item',
    'ul.items li',
    '.list-item',
  ];

  static const _titleLinkSelectors = [
    'a[title]',
    'h1 a, h2 a, h3 a, h4 a',
    '.module-card-item-title a, .stui-vodlist__title a',
  ];

  /// Parse search results from HTML.
  static List<Series> parseSearchResults(
    String html, {
    required String baseUrl,
    List<String>? selectors,
    String? detailPattern,
  }) {
    final doc = parse(html);
    final allSelectors = [...(selectors ?? const []), ..._searchSelectors];

    for (final selector in allSelectors) {
      if (selector.trim().isEmpty) continue;
      try {
        final elements = doc.querySelectorAll(selector);
        if (elements.isEmpty) continue;
        final results = elements
            .map((e) => _parseSeriesElement(e, baseUrl, detailPattern))
            .whereType<Series>()
            .toList();
        if (results.isNotEmpty) return results;
      } catch (_) {}
    }

    if (detailPattern != null && detailPattern.isNotEmpty) {
      return _fallbackByDetailLinks(doc, baseUrl, detailPattern);
    }
    return [];
  }

  static Series? _parseSeriesElement(Element element, String baseUrl, String? detailPattern) {
    final link = _findLink(element, detailPattern);
    if (link == null) return null;

    final href = link.attributes['href'] ?? '';
    if (href.isEmpty || href.startsWith('javascript')) return null;
    if (detailPattern != null && !href.contains(detailPattern)) return null;

    final name = _extractTitle(element, link);
    if (name.isEmpty) return null;

    return Series(
      _toAbsolute(href, baseUrl),
      name,
      image: _extractImage(element, baseUrl),
    );
  }

  static Element? _findLink(Element element, String? detailPattern) {
    for (final selector in _titleLinkSelectors) {
      try {
        final matches = element.querySelectorAll(selector);
        for (final link in matches) {
          if (_isUsableLink(link, detailPattern)) return link;
        }
      } catch (_) {}
    }
    if (element.localName == 'a' && _isUsableLink(element, detailPattern)) {
      return element;
    }
    return element.querySelector('a');
  }

  static bool _isUsableLink(Element link, String? detailPattern) {
    final href = link.attributes['href'] ?? '';
    if (href.isEmpty || href.startsWith('javascript')) return false;
    if (detailPattern != null && !href.contains(detailPattern)) return false;
    return true;
  }

  static String _extractTitle(Element element, Element link) {
    final title = link.attributes['title']?.trim() ?? '';
    if (title.length > 1 && title.length < 100) return title;

    final header = element.querySelector('h1, h2, h3, h4, .title')?.text.trim() ?? '';
    if (header.length > 1 && header.length < 100) return header;

    final alt = element.querySelector('img')?.attributes['alt']?.trim() ?? '';
    if (alt.length > 1 && alt.length < 100) return alt;

    final text = link.text.trim();
    if (text.length > 1 && text.length < 100) return text;
    return '';
  }

  static String? _extractImage(Element element, String baseUrl) {
    final img = element.querySelector('img');
    final src = img?.attributes['data-original'] ??
        img?.attributes['data-src'] ??
        img?.attributes['src'] ??
        element.querySelector('[data-original]')?.attributes['data-original'] ??
        element.querySelector('[data-src]')?.attributes['data-src'] ??
        element.attributes['data-original'] ??
        element.attributes['data-src'] ??
        element.attributes['src'];
    return (src != null && src.isNotEmpty) ? _toAbsolute(src, baseUrl) : null;
  }

  static List<Series> _fallbackByDetailLinks(Document doc, String baseUrl, String pattern) {
    final seen = <String>{};
    return doc
        .querySelectorAll('a[href*="$pattern"]')
        .where((link) => seen.add(link.attributes['href'] ?? ''))
        .map((link) {
          final href = (link.attributes['href'] ?? '').trim();
          if (href.isEmpty) return null;
          final name = (link.attributes['title'] ?? link.text).trim();
          if (name.length < 2) return null;
          return Series(_toAbsolute(href, baseUrl), name);
        })
        .whereType<Series>()
        .toList();
  }

  // ── Episodes ────────────────────────────────────────────────────────

  static const _tabSelectors = [
    '.play_source_tab a',
    '.anthology-tab a',
    '.module-tab-item',
    '.play-source-tab span',
    '.player-tab',
  ];

  static const _listSelectors = [
    '.anthology-list-play',
    '.module-player-list',
    '.module-play-list',
    '.play-list',
    '.playlist',
    '.episode-list',
    '.content_playlist',
    'ul.hl-plays-list',
  ];

  static final _explicitEpisodePatterns = [
    RegExp(r'[?&](?:nid|episode|ep)=(\d+)(?:&|$)', caseSensitive: false),
    RegExp(r'/sid/\d+/nid/(\d+)', caseSensitive: false),
  ];

  static final _tuplePatterns = [
    RegExp(r'/(?:vod)?play/[^/?#]+?-(\d+)-(\d+)', caseSensitive: false),
    RegExp(r'/(?:vod/)?play/[^/?#]+?_(\d+)_(\d+)', caseSensitive: false),
  ];

  static final _wsRegex = RegExp(r'\s+');

  /// Parse episode sources from a detail page Document.
  static List<Source> parseSources(
    Document doc, {
    required String baseUrl,
    List<String>? listSelectors,
    List<String>? tabSelectors,
  }) {
    final labels = _findTabLabels(doc, tabSelectors ?? _tabSelectors);
    final selectors = listSelectors ?? _listSelectors;

    for (final selector in selectors) {
      final containers = doc.querySelectorAll(selector);
      if (containers.isEmpty) continue;

      if (containers.length == 1) {
        final episodes = _extractEpisodes(containers[0], baseUrl);
        if (episodes.isNotEmpty) return [Source(episodes, _sourceName(0, labels))];
        continue;
      }

      final sources = <Source>[];
      for (final container in containers) {
        final episodes = _extractEpisodes(container, baseUrl);
        if (episodes.isEmpty) continue;
        sources.add(Source(episodes, _sourceName(sources.length, labels)));
      }
      final deduped = _dedupe(sources);
      if (deduped.isNotEmpty) return deduped;
    }
    return [];
  }

  static List<Episode> _extractEpisodes(Element container, String baseUrl) {
    final links = container.querySelectorAll('a');
    if (links.isEmpty) return [];

    final validLinks = <Element>[];
    final hrefs = <String>[];
    for (final link in links) {
      final href = (link.attributes['href'] ?? '').trim();
      if (href.isEmpty || href.contains('javascript') || href.startsWith('#')) {
        continue;
      }
      validLinks.add(link);
      hrefs.add(href);
    }

    if (validLinks.isEmpty) return [];

    final episodeNumbers = _resolveEpisodeNumbers(hrefs);

    final episodes = <Episode>[];
    final seen = <String>{};
    for (var i = 0; i < validLinks.length; i++) {
      final episodeId = _toAbsolute(hrefs[i], baseUrl);
      if (!seen.add(episodeId)) continue;

      final number = episodeNumbers[i];
      final index = (number != null && number > 0) ? number - 1 : episodes.length;
      final name = validLinks[i].text.trim().replaceAll(_wsRegex, ' ');
      episodes.add(Episode(episodeId, index, name.isEmpty ? 'Episode ${index + 1}' : name));
    }
    return episodes;
  }

  static List<int?> _resolveEpisodeNumbers(List<String> hrefs) {
    final numbers = List<int?>.filled(hrefs.length, null);
    final tupleIndices = <int>[];
    final tuples = <List<int>>[];

    for (var i = 0; i < hrefs.length; i++) {
      final normalized = hrefs[i].replaceAll(r'\/', '/');
      var found = false;
      for (final pattern in _explicitEpisodePatterns) {
        final match = pattern.firstMatch(normalized);
        if (match != null) {
          final n = int.tryParse(match.group(1) ?? '');
          if (n != null && n > 0) { numbers[i] = n; found = true; break; }
        }
      }
      if (found) continue;

      for (final pattern in _tuplePatterns) {
        final match = pattern.firstMatch(normalized);
        if (match != null) {
          final a = int.tryParse(match.group(1) ?? '');
          final b = int.tryParse(match.group(2) ?? '');
          if (a != null && b != null) {
            tupleIndices.add(i);
            tuples.add([a, b]);
            break;
          }
        }
      }
    }

    if (tuples.isNotEmpty) {
      final col0 = tuples.map((t) => t[0]).toSet();
      final col1 = tuples.map((t) => t[1]).toSet();
      final useFirst = col0.length > 1 && col1.length == 1;
      final useSecond = col1.length > 1 && col0.length == 1;
      if (useFirst || useSecond) {
        for (var j = 0; j < tupleIndices.length; j++) {
          numbers[tupleIndices[j]] = useFirst ? tuples[j][0] : tuples[j][1];
        }
      }
    }
    return numbers;
  }

  static List<String> _findTabLabels(Document doc, List<String> selectors) {
    for (final selector in selectors) {
      try {
        final elements = doc.querySelectorAll(selector);
        if (elements.isNotEmpty) {
          return elements.map((e) => e.text.trim()).where((s) => s.isNotEmpty).toList();
        }
      } catch (_) {}
    }
    return [];
  }

  static String _sourceName(int index, List<String> labels) {
    if (index < labels.length) {
      final label = labels[index]
          .trim()
          .replaceAll(RegExp(r'\d+$'), '')
          .trim();
      if (label.isNotEmpty && label.length < 50) return label;
    }
    return '播放源 ${index + 1}';
  }

  static List<Source> _dedupe(List<Source> sources) {
    final seen = <String>{};
    return sources.where((source) {
      final sig = source.episodes.map((e) => e.episodeId).join('\n');
      return sig.isNotEmpty && seen.add(sig);
    }).toList();
  }

  // ── URL helper ──────────────────────────────────────────────────────

  static String _toAbsolute(String url, String baseUrl) {
    if (url.isEmpty) return url;
    if (url.startsWith('http')) return url;
    if (url.startsWith('//')) {
      final scheme = Uri.tryParse(baseUrl)?.scheme ?? 'https';
      return '$scheme:$url';
    }
    try {
      return Uri.parse(baseUrl).resolve(url).toString();
    } catch (_) {
      final sep = url.startsWith('/') || baseUrl.endsWith('/') ? '' : '/';
      return '$baseUrl$sep$url';
    }
  }
}
