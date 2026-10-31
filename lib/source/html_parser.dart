import 'dart:collection';
import 'package:html/dom.dart' show Document, Element, Text;
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/video_url_extractor.dart';

/// Shared HTML parsing. Each pipeline execution owns one last-page cache.
class HtmlParser {
  String? _html;
  Document? _document;

  Document documentFor(String html) {
    if (!identical(html, _html)) {
      _document = html_parser.parse(html);
      _html = html;
    }
    return _document!;
  }

  static List<Series> parseSearchResults(
    Document doc, {
    required String baseUrl,
    List<String> selectors = const [],
    String? detailPattern,
    String? listXPath,
    String nameXPath = '',
    String linkXPath = '',
    String? linkSelector,
    String? titleSelector,
    String titleAttr = 'text',
    String? imageSelector,
    String imageAttr = 'src',
  }) {
    if (listXPath != null) {
      final results = <Series>[];
      final nodes = doc.documentElement!.queryXPath(listXPath).nodes;
      for (final node in nodes) {
        final link = linkXPath.isEmpty ? node : node.queryXPath(linkXPath).node;
        final href = link?.attributes['href'] ?? '';
        if (href.isEmpty) continue;
        final seriesId = VideoUrlExtractor.toAbsolute(href, baseUrl);
        if (seriesId.isEmpty) continue;
        final name =
            (nameXPath.isEmpty
                    ? node.node.text
                    : node.queryXPath(nameXPath).node?.text)
                ?.trim() ??
            '';
        if (name.isNotEmpty) results.add(Series(seriesId, name));
      }
      return results;
    }
    for (final selector in selectors) {
      if (selector.trim().isEmpty) continue;
      final elements = doc.querySelectorAll(selector);
      if (elements.isEmpty) continue;
      final results = <Series>[];
      for (final element in elements) {
        final series = _parseSeriesElement(
          element,
          baseUrl,
          detailPattern,
          linkSelector,
          titleSelector,
          titleAttr,
          imageSelector,
          imageAttr,
        );
        if (series != null) results.add(series);
      }
      if (results.isNotEmpty) return results;
    }
    return const [];
  }

  static Series? _parseSeriesElement(
    Element element,
    String baseUrl,
    String? detailPattern,
    String? linkSelector,
    String? titleSelector,
    String titleAttr,
    String? imageSelector,
    String imageAttr,
  ) {
    final link = linkSelector == null
        ? (element.localName == 'a'
              ? element
              : element.querySelector('a[href]'))
        : _select(element, linkSelector);
    if (link == null || !_isUsableLink(link, detailPattern)) return null;
    final href = VideoUrlExtractor.toAbsolute(
      link.attributes['href']!,
      baseUrl,
    );
    if (href.isEmpty) return null;
    final title = titleSelector == null
        ? link
        : _select(element, titleSelector);
    final name = _value(title, titleAttr);
    if (name.isEmpty) return null;
    final src = imageSelector == null
        ? ''
        : _value(_select(element, imageSelector), imageAttr);
    return Series(
      href,
      name,
      image: src.isEmpty ? null : VideoUrlExtractor.toAbsolute(src, baseUrl),
    );
  }

  static Element? _select(Element element, String selector) =>
      selector.isEmpty ? element : element.querySelector(selector);

  static String _value(Element? element, String attr) =>
      (switch (attr) {
        'text' => element?.text,
        'ownText' =>
          element?.nodes.whereType<Text>().map((node) => node.text).join(),
        _ => element?.attributes[attr],
      })?.trim() ??
      '';

  static bool _isUsableLink(Element link, String? detailPattern) {
    final href = link.attributes['href'] ?? '';
    if (href.isEmpty || href.startsWith('javascript')) return false;
    if (detailPattern != null && !href.contains(detailPattern)) return false;
    return true;
  }

  static final _wsRegex = RegExp(r'\s+');

  static List<Source> parseSources(
    Document doc, {
    required String baseUrl,
    List<String> listSelectors = const [],
    List<String> tabSelectors = const [],
    String tabAttr = 'text',
    String? roadsXPath,
    String itemsXPath = '',
    RegExp? episodeNumberPattern,
  }) {
    if (roadsXPath != null) {
      final sources = <Source>[];
      for (final road in doc.documentElement!.queryXPath(roadsXPath).nodes) {
        final items = road.queryXPath(itemsXPath).nodes;
        final episodes = <Episode>[];
        for (var i = 0; i < items.length; i++) {
          final href = items[i].attributes['href'] ?? '';
          if (href.isEmpty) continue;
          final episodeId = VideoUrlExtractor.toAbsolute(href, baseUrl);
          final index = _episodeIndex(
            href,
            episodes.length,
            episodeNumberPattern,
          );
          if (episodeId.isEmpty || index == null) continue;
          final name = items[i].node.text?.replaceAll(_wsRegex, '') ?? '';
          episodes.add(
            Episode(episodeId, index, name.isEmpty ? '第${index + 1}集' : name),
          );
        }
        if (episodes.isNotEmpty) {
          sources.add(Source(episodes, '播放列表${sources.length + 1}'));
        }
      }
      return sources;
    }
    final labels = _findTabLabels(doc, tabSelectors, tabAttr);

    for (final selector in listSelectors) {
      if (selector.trim().isEmpty) continue;
      final containers = doc.querySelectorAll(selector);
      if (containers.isEmpty) continue;

      final sources = <Source>[];
      final seen = HashSet<List<Episode>>(
        equals: _sameEpisodeIds,
        hashCode: (episodes) =>
            Object.hashAll(episodes.map((e) => e.episodeId)),
      );
      var sourceIndex = 0;
      for (final container in containers) {
        final episodes = _extractEpisodes(
          container,
          baseUrl,
          episodeNumberPattern,
        );
        if (episodes.isEmpty) continue;
        final index = sourceIndex++;
        if (!seen.add(episodes)) continue;
        sources.add(Source(episodes, _sourceName(index, labels)));
      }
      if (sources.isNotEmpty) return sources;
    }
    return [];
  }

  static bool _sameEpisodeIds(List<Episode> a, List<Episode> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].episodeId != b[i].episodeId) return false;
    }
    return true;
  }

  static List<Episode> _extractEpisodes(
    Element container,
    String baseUrl,
    RegExp? episodeNumberPattern,
  ) {
    final links = container.querySelectorAll('a');
    final episodes = <Episode>[];
    final seen = <String>{};
    for (final link in links) {
      final href = (link.attributes['href'] ?? '').trim();
      if (href.isEmpty ||
          href.toLowerCase().startsWith('javascript:') ||
          href.startsWith('#')) {
        continue;
      }
      final episodeId = VideoUrlExtractor.toAbsolute(href, baseUrl);
      if (episodeId.isEmpty) continue;
      if (!seen.add(episodeId)) continue;

      final index = _episodeIndex(href, episodes.length, episodeNumberPattern);
      if (index == null) continue;
      final name = link.text.trim().replaceAll(_wsRegex, ' ');
      episodes.add(
        Episode(episodeId, index, name.isEmpty ? 'Episode ${index + 1}' : name),
      );
    }
    return episodes;
  }

  static int? _episodeIndex(String href, int position, RegExp? pattern) {
    if (pattern == null) return position;
    final match = pattern.firstMatch(href);
    if (match == null) return null;
    if (match.groupCount < 1) {
      throw const FormatException('episodeNumberPattern 必须捕获集数');
    }
    final number = int.tryParse(match.group(1) ?? '');
    return number != null && number > 0 ? number - 1 : null;
  }

  static List<String> _findTabLabels(
    Document doc,
    List<String> selectors,
    String attr,
  ) {
    for (final selector in selectors) {
      final elements = doc.querySelectorAll(selector);
      final labels = <String>[];
      for (final element in elements) {
        final label = _value(element, attr);
        if (label.isNotEmpty) labels.add(label);
      }
      if (labels.isNotEmpty) return labels;
    }
    return [];
  }

  static String _sourceName(int index, List<String> labels) {
    if (index < labels.length) {
      final label = labels[index].trim();
      if (label.isNotEmpty) return label;
    }
    return '播放源 ${index + 1}';
  }
}
