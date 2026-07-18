import 'dart:convert';

import 'package:html/parser.dart';

import 'package:baka/source/models/episode.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';

typedef Anime1PageFetcher = Future<String> Function(String url);

/// One parsed Anime1 category page.
class Anime1EpisodePage {
  const Anime1EpisodePage({required this.tokens, this.nextPageUrl});

  final List<String> tokens;
  final String? nextPageUrl;
}

/// Values extracted from an HHPlayer iframe before its form API request.
class HhPlayerBootstrap {
  const HhPlayerBootstrap({
    required this.encryptedUrl,
    required this.timestamp,
    required this.key,
  });

  final String encryptedUrl;
  final String timestamp;
  final String key;
}

/// Pure protocol helpers shared by rule-backed Anime1 and HHPlayer ops.
///
/// Network endpoints, selectors, cookie names, regexes, success codes, and
/// substitution maps are deliberately supplied by rule-step parameters. This
/// file only owns the stable protocol shapes and is therefore independently
/// fixture-testable.
class AnimeRuleOps {
  AnimeRuleOps._();

  /// Parses Anime1's array-of-arrays catalog and applies the adapter's original
  /// bidirectional substring match.
  static List<Series> parseAnime1Catalog(
    String payload,
    String keyword, {
    required int idIndex,
    required int nameIndex,
    required bool caseSensitive,
  }) {
    final query = keyword.trim();
    if (query.isEmpty || idIndex < 0 || nameIndex < 0) return const [];

    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];

    final normalizedQuery = caseSensitive ? query : query.toLowerCase();
    final seen = <String>{};
    final results = <Series>[];
    for (final row in decoded) {
      if (row is! List || idIndex >= row.length || nameIndex >= row.length) {
        continue;
      }
      final id = row[idIndex]?.toString().trim() ?? '';
      final name = row[nameIndex]?.toString().trim() ?? '';
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;

      final normalizedName = caseSensitive ? name : name.toLowerCase();
      if (!normalizedName.contains(normalizedQuery) &&
          !normalizedQuery.contains(normalizedName)) {
        continue;
      }
      results.add(Series(id, name));
    }
    return results;
  }

  /// Extracts episode request tokens and the next category page URL.
  static Anime1EpisodePage parseAnime1EpisodePage(
    String html, {
    required String pageUrl,
    required String itemSelector,
    required String tokenAttribute,
    required String nextSelector,
  }) {
    if (html.trim().isEmpty || itemSelector.trim().isEmpty) {
      return const Anime1EpisodePage(tokens: []);
    }

    try {
      final document = parse(html);
      final seen = <String>{};
      final tokens = <String>[];
      for (final element in document.querySelectorAll(itemSelector)) {
        final token = (element.attributes[tokenAttribute] ?? '').trim();
        if (token.isNotEmpty && seen.add(token)) tokens.add(token);
      }

      String? nextPageUrl;
      if (nextSelector.trim().isNotEmpty) {
        final href = document
            .querySelector(nextSelector)
            ?.attributes['href']
            ?.trim();
        if (href != null && href.isNotEmpty) {
          nextPageUrl = Uri.parse(pageUrl).resolve(href).toString();
        }
      }
      return Anime1EpisodePage(tokens: tokens, nextPageUrl: nextPageUrl);
    } catch (_) {
      return const Anime1EpisodePage(tokens: []);
    }
  }

  /// Follows category pagination, deduplicates tokens, and optionally reverses
  /// the site's newest-first order into playlist order.
  static Future<List<String>> collectAnime1EpisodeTokens({
    required String firstPageUrl,
    required Anime1PageFetcher fetchPage,
    required String itemSelector,
    required String tokenAttribute,
    required String nextSelector,
    required int maxPages,
    required bool reverse,
  }) async {
    if (firstPageUrl.trim().isEmpty || maxPages <= 0) return const [];

    final visitedPages = <String>{};
    final seenTokens = <String>{};
    final tokens = <String>[];
    String? pageUrl = firstPageUrl;
    for (
      var page = 0;
      page < maxPages && pageUrl != null && visitedPages.add(pageUrl);
      page++
    ) {
      final html = await fetchPage(pageUrl);
      if (html.trim().isEmpty) break;
      final parsed = parseAnime1EpisodePage(
        html,
        pageUrl: pageUrl,
        itemSelector: itemSelector,
        tokenAttribute: tokenAttribute,
        nextSelector: nextSelector,
      );
      for (final token in parsed.tokens) {
        if (seenTokens.add(token)) tokens.add(token);
      }
      pageUrl = parsed.nextPageUrl;
    }

    return reverse ? tokens.reversed.toList(growable: false) : tokens;
  }

  /// Converts ordered Anime1 request tokens into the standard one-line source.
  static List<Source> buildAnime1Sources(
    List<String> tokens, {
    required String sourceName,
    required String episodeNameTemplate,
  }) {
    final episodes = <Episode>[];
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i].trim();
      if (token.isEmpty) continue;
      final oneBased = episodes.length + 1;
      final title = episodeNameTemplate
          .replaceAll('{index}', oneBased.toString())
          .replaceAll('{index0}', (oneBased - 1).toString());
      episodes.add(Episode(token, oneBased - 1, title));
    }
    if (episodes.isEmpty) return const [];
    return [Source(episodes, sourceName.trim().isEmpty ? null : sourceName)];
  }

  /// Parses and resolves the media URL returned by Anime1's play API.
  static String parseAnime1PlaybackUrl(
    String payload, {
    required String sourcePath,
    required String mediaBaseUrl,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return '';
    }

    final rawUrl = _jsonPath(decoded, sourcePath)?.toString().trim() ?? '';
    if (rawUrl.isEmpty) return '';
    try {
      return Uri.parse(mediaBaseUrl).resolve(rawUrl).toString();
    } catch (_) {
      return '';
    }
  }

  /// Parses the HHPlayer iframe contract and decodes its mapped base64 key.
  static HhPlayerBootstrap? parseHhPlayerBootstrap({
    required String iframeUrl,
    required String iframeHtml,
    required String urlQueryParam,
    required String timestampPattern,
    required int timestampGroup,
    required String encodedKeyPattern,
    required int encodedKeyGroup,
    required Map<String, String> charMap,
    required bool caseSensitive,
    required bool dotAll,
  }) {
    final encryptedUrl = extractRawQueryParameter(iframeUrl, urlQueryParam);
    final timestamp = _regexGroup(
      iframeHtml,
      timestampPattern,
      timestampGroup,
      caseSensitive: caseSensitive,
      dotAll: dotAll,
    );
    final encodedKey = _regexGroup(
      iframeHtml,
      encodedKeyPattern,
      encodedKeyGroup,
      caseSensitive: caseSensitive,
      dotAll: dotAll,
    );
    if (encryptedUrl.isEmpty || timestamp.isEmpty || encodedKey.isEmpty) {
      return null;
    }

    final key = decodeMappedBase64(encodedKey, charMap);
    if (key.isEmpty) return null;
    return HhPlayerBootstrap(
      encryptedUrl: encryptedUrl,
      timestamp: timestamp,
      key: key,
    );
  }

  /// Decodes base64, then applies a variable-length token-to-character map.
  static String decodeMappedBase64(
    String encoded,
    Map<String, String> charMap,
  ) {
    if (encoded.trim().isEmpty || charMap.isEmpty) return '';
    final String decoded;
    try {
      decoded = utf8.decode(base64.decode(base64.normalize(encoded.trim())));
    } catch (_) {
      return '';
    }

    final entries =
        charMap.entries.where((entry) => entry.key.isNotEmpty).toList()
          ..sort((a, b) => b.key.length.compareTo(a.key.length));
    final output = StringBuffer();
    var offset = 0;
    while (offset < decoded.length) {
      MapEntry<String, String>? matched;
      for (final entry in entries) {
        if (decoded.startsWith(entry.key, offset)) {
          matched = entry;
          break;
        }
      }
      if (matched == null) {
        output.write(decoded[offset]);
        offset++;
      } else {
        output.write(matched.value);
        offset += matched.key.length;
      }
    }
    return output.toString();
  }

  /// Extracts a query value without percent-decoding it. HHPlayer expects the
  /// same opaque value that appeared in the iframe URL before form encoding.
  static String extractRawQueryParameter(String url, String parameter) {
    if (url.isEmpty || parameter.isEmpty) return '';
    final normalized = url.replaceAll('&amp;', '&');
    final question = normalized.indexOf('?');
    if (question < 0 || question + 1 >= normalized.length) return '';
    final fragment = normalized.indexOf('#', question + 1);
    final query = normalized.substring(
      question + 1,
      fragment < 0 ? normalized.length : fragment,
    );
    for (final part in query.split('&')) {
      final separator = part.indexOf('=');
      final rawName = separator < 0 ? part : part.substring(0, separator);
      String name;
      try {
        name = Uri.decodeQueryComponent(rawName);
      } catch (_) {
        name = rawName;
      }
      if (name == parameter) {
        return separator < 0 ? '' : part.substring(separator + 1);
      }
    }
    return '';
  }

  /// Validates and extracts the playable URL from HHPlayer's JSON response.
  static String parseHhPlayerResponse(
    String payload, {
    required String codePath,
    required String successCode,
    required String urlPath,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return '';
    }
    final code = _jsonPath(decoded, codePath)?.toString() ?? '';
    if (code != successCode) return '';
    return _jsonPath(decoded, urlPath)?.toString().trim() ?? '';
  }

  static String _regexGroup(
    String input,
    String pattern,
    int group, {
    required bool caseSensitive,
    required bool dotAll,
  }) {
    if (input.isEmpty || pattern.isEmpty || group < 0) return '';
    try {
      final match = RegExp(
        pattern,
        caseSensitive: caseSensitive,
        dotAll: dotAll,
      ).firstMatch(input);
      if (match == null || group > match.groupCount) return '';
      return match.group(group)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  static Object? _jsonPath(Object? value, String path) {
    Object? current = value;
    if (path.trim().isEmpty) return current;
    for (final segment in path.split('.')) {
      if (segment.isEmpty) continue;
      final indexed = RegExp(r'^(.*?)\[(\d+)\]$').firstMatch(segment);
      if (indexed != null) {
        final key = indexed.group(1)!;
        final index = int.parse(indexed.group(2)!);
        if (key.isNotEmpty) {
          current = current is Map ? current[key] : null;
        }
        current = current is List && index < current.length
            ? current[index]
            : null;
      } else {
        current = current is Map ? current[segment] : null;
      }
      if (current == null) return null;
    }
    return current;
  }
}
