import 'package:html/dom.dart' show Document, Element;
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/episode.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/video_url_extractor.dart';

/// Stateless HTML parsing for search results and episode lists.
class HtmlParser {
  HtmlParser._();

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

  static List<Series> parseSearchResults(
    Document doc, {
    required String baseUrl,
    List<String>? selectors,
    String? detailPattern,
  }) {
    final allSelectors =
        selectors?.followedBy(_searchSelectors) ?? _searchSelectors;

    for (final selector in allSelectors) {
      if (selector.trim().isEmpty) continue;
      try {
        final elements = doc.querySelectorAll(selector);
        if (elements.isEmpty) continue;
        final results = <Series>[];
        for (final element in elements) {
          final series = _parseSeriesElement(element, baseUrl, detailPattern);
          if (series != null) results.add(series);
        }
        if (results.isNotEmpty) return results;
      } catch (_) {}
    }

    if (detailPattern != null && detailPattern.isNotEmpty) {
      return _fallbackByDetailLinks(doc, baseUrl, detailPattern);
    }
    return [];
  }

  static Series? _parseSeriesElement(
    Element element,
    String baseUrl,
    String? detailPattern,
  ) {
    final link = _findLink(element, detailPattern);
    if (link == null) return null;

    if (!_isUsableLink(link, detailPattern)) return null;
    final href = link.attributes['href'] ?? '';

    final name = _extractTitle(element, link);
    if (name.isEmpty) return null;

    return Series(
      VideoUrlExtractor.toAbsolute(href, baseUrl),
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

    final header =
        element.querySelector('h1, h2, h3, h4, .title')?.text.trim() ?? '';
    if (header.length > 1 && header.length < 100) return header;

    final alt = element.querySelector('img')?.attributes['alt']?.trim() ?? '';
    if (alt.length > 1 && alt.length < 100) return alt;

    final text = link.text.trim();
    if (text.length > 1 && text.length < 100) return text;
    return '';
  }

  static String? _extractImage(Element element, String baseUrl) {
    final img = element.querySelector('img');
    final src =
        img?.attributes['data-original'] ??
        img?.attributes['data-src'] ??
        img?.attributes['src'] ??
        element.querySelector('[data-original]')?.attributes['data-original'] ??
        element.querySelector('[data-src]')?.attributes['data-src'] ??
        element.attributes['data-original'] ??
        element.attributes['data-src'] ??
        element.attributes['src'];
    return (src != null && src.isNotEmpty)
        ? VideoUrlExtractor.toAbsolute(src, baseUrl)
        : null;
  }

  static List<Series> _fallbackByDetailLinks(
    Document doc,
    String baseUrl,
    String pattern,
  ) {
    final seen = <String>{};
    final results = <Series>[];
    for (final link in doc.querySelectorAll('a[href*="$pattern"]')) {
      final href = (link.attributes['href'] ?? '').trim();
      if (href.isEmpty || !seen.add(href)) continue;
      final name = (link.attributes['title'] ?? link.text).trim();
      if (name.length < 2) continue;
      results.add(Series(VideoUrlExtractor.toAbsolute(href, baseUrl), name));
    }
    return results;
  }

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
  static final _trailingDigitsRegex = RegExp(r'\d+$');

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
      final episodeId = VideoUrlExtractor.toAbsolute(hrefs[i], baseUrl);
      if (!seen.add(episodeId)) continue;

      final number = episodeNumbers[i];
      final index = (number != null && number > 0)
          ? number - 1
          : episodes.length;
      final name = validLinks[i].text.trim().replaceAll(_wsRegex, ' ');
      episodes.add(
        Episode(episodeId, index, name.isEmpty ? 'Episode ${index + 1}' : name),
      );
    }
    return episodes;
  }

  static List<int?> _resolveEpisodeNumbers(List<String> hrefs) {
    final numbers = List<int?>.filled(hrefs.length, null);
    final tuples = <({int index, int first, int second})>[];
    int? firstColumn0;
    int? firstColumn1;
    var column0Varies = false;
    var column1Varies = false;

    for (var i = 0; i < hrefs.length; i++) {
      final normalized = hrefs[i].replaceAll(r'\/', '/');
      var found = false;
      for (final pattern in _explicitEpisodePatterns) {
        final match = pattern.firstMatch(normalized);
        if (match != null) {
          final n = int.tryParse(match.group(1) ?? '');
          if (n != null && n > 0) {
            numbers[i] = n;
            found = true;
            break;
          }
        }
      }
      if (found) continue;

      for (final pattern in _tuplePatterns) {
        final match = pattern.firstMatch(normalized);
        if (match != null) {
          final a = int.tryParse(match.group(1) ?? '');
          final b = int.tryParse(match.group(2) ?? '');
          if (a != null && b != null) {
            firstColumn0 ??= a;
            firstColumn1 ??= b;
            column0Varies |= a != firstColumn0;
            column1Varies |= b != firstColumn1;
            tuples.add((index: i, first: a, second: b));
            break;
          }
        }
      }
    }

    if (tuples.isNotEmpty) {
      final useFirst = column0Varies && !column1Varies;
      final useSecond = column1Varies && !column0Varies;
      if (useFirst || useSecond) {
        for (final tuple in tuples) {
          numbers[tuple.index] = useFirst ? tuple.first : tuple.second;
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
          final labels = <String>[];
          for (final element in elements) {
            final label = element.text.trim();
            if (label.isNotEmpty) labels.add(label);
          }
          if (labels.isNotEmpty) return labels;
        }
      } catch (_) {}
    }
    return [];
  }

  static String _sourceName(int index, List<String> labels) {
    if (index < labels.length) {
      final label = labels[index]
          .trim()
          .replaceAll(_trailingDigitsRegex, '')
          .trim();
      if (label.isNotEmpty && label.length < 50) return label;
    }
    return '播放源 ${index + 1}';
  }

  static List<Source> _dedupe(List<Source> sources) {
    final seen = <String>{};
    return [
      for (final source in sources)
        if (seen.add(source.episodes.map((e) => e.episodeId).join('\x00')))
          source,
    ];
  }
}
