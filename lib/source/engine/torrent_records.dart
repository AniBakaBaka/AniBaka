import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:baka/source/models/episode.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';

/// A normalized release row from an HTML torrent catalogue.
class TorrentReleaseRecord {
  const TorrentReleaseRecord({
    required this.title,
    required this.resourceId,
    required this.animeName,
    required this.fansub,
    required this.sourceName,
    required this.size,
    required this.image,
    required this.episode,
    required this.score,
    required this.excluded,
    required this.order,
  });

  final String title;
  final String resourceId;
  final String animeName;
  final String fansub;
  final String sourceName;
  final String size;
  final String image;
  final double? episode;
  final int score;
  final bool excluded;
  final int order;
}

/// Rule-configured parser used by the `torrentRecords` pipeline operation.
class TorrentRecordParser {
  TorrentRecordParser._();

  static final Expando<_TorrentRecordConfig> _configCache =
      Expando<_TorrentRecordConfig>('torrent-record-config');
  static final RegExp _whitespacePattern = RegExp(r'\s+');
  static final RegExp _trailingSlashPattern = RegExp(r'/+$');
  static final RegExp _templatePattern = RegExp(r'\{([a-zA-Z0-9_]+)(:raw)?\}');
  static final RegExp _keyNoisePattern = RegExp(
    r'[^a-z0-9\u3040-\u30ff\u3400-\u9fff]+',
  );
  static final RegExp _nthChildPattern = RegExp(
    r'^([a-zA-Z][\w-]*)?:nth-child\((\d+)\)$',
  );

  static _TorrentRecordConfig _configFor(Map<String, dynamic> params) =>
      _configCache[params] ??= _TorrentRecordConfig(params);

  static List<Series> parseSeries({
    required String html,
    required Map<String, dynamic> params,
    required String baseUrl,
    String contextUrl = '',
  }) {
    if (html.trim().isEmpty) return const <Series>[];
    final config = _configFor(params);
    final document = html_parser.parse(html);
    final base = Uri.tryParse(baseUrl);
    final rows = _selectRows(document, config.rowSelectors);
    final records = _recordsFromRows(
      rows,
      config: config,
      baseUrl: baseUrl,
      base: base,
      needScore: false,
    );

    final grouped = <String, List<TorrentReleaseRecord>>{};
    final displayNames = <String, String>{};
    for (final record in records) {
      if (record.excluded ||
          (config.requireResource && record.resourceId.isEmpty)) {
        continue;
      }
      final name = record.animeName.isNotEmpty
          ? record.animeName
          : record.title;
      final key = _normalizeKey(name);
      if (key.isEmpty) continue;
      (grouped[key] ??= <TorrentReleaseRecord>[]).add(record);
      displayNames.putIfAbsent(key, () => name);
    }

    final results = <Series>[];
    for (final entry in grouped.entries) {
      final records = entry.value;
      final first = records.first;
      final name = displayNames[entry.key] ?? first.title;
      final fansubs = <String>[];
      final seenFansubs = <String>{};
      var image = '';
      for (final record in records) {
        if (record.fansub.isNotEmpty && seenFansubs.add(record.fansub)) {
          fansubs.add(record.fansub);
        }
        if (image.isEmpty && record.image.isNotEmpty) image = record.image;
      }
      final variables = _variables(
        record: first,
        baseUrl: baseUrl,
        animeName: name,
        count: records.length,
        fansubs: fansubs,
      );
      final id = config.seriesIdTemplate.isEmpty
          ? first.resourceId
          : _render(config.seriesIdTemplate, variables);
      if (id.trim().isEmpty) continue;
      final description = config.descriptionTemplate.isEmpty
          ? ''
          : _render(config.descriptionTemplate, variables);
      results.add(
        Series(
          _absolute(id, baseUrl, base),
          name,
          description: description.isEmpty ? null : description,
          image: image.isEmpty ? null : image,
        ),
      );
    }
    return results;
  }

  static List<Source> parseSources({
    required String html,
    required Map<String, dynamic> params,
    required String baseUrl,
    String contextUrl = '',
  }) {
    if (html.trim().isEmpty) return const <Source>[];
    final config = _configFor(params);
    final document = html_parser.parse(html);
    final base = Uri.tryParse(baseUrl);
    final expectedAnimeKey = _normalizeKey(
      _expectedAnimeName(config, contextUrl: contextUrl),
    );

    final containers = _selectRows(document, config.sourceContainerSelectors);
    if (containers.isNotEmpty) {
      final labels = _selectRows(document, config.sourceLabelSelectors);
      final results = <Source>[];
      for (var i = 0; i < containers.length; i++) {
        final label = i < labels.length
            ? _elementValue(labels[i], config.sourceLabelAttrs)
            : '';
        final rows = _selectRows(containers[i], config.rowSelectors);
        final records = _recordsFromRows(
          rows,
          config: config,
          baseUrl: baseUrl,
          base: base,
          forcedSourceName: label,
          needImage: false,
        );
        final source = _buildSource(
          records,
          sourceName: label.isEmpty ? config.unknownSourceName : label,
          expectedAnimeKey: expectedAnimeKey,
          config: config,
          baseUrl: baseUrl,
        );
        if (source != null) results.add(source);
      }
      return results;
    }

    final rows = _selectRows(document, config.rowSelectors);
    final records = _recordsFromRows(
      rows,
      config: config,
      baseUrl: baseUrl,
      base: base,
      needImage: false,
    );
    final grouped = <String, List<TorrentReleaseRecord>>{};
    final displayNames = <String, String>{};
    for (final record in records) {
      final name = record.sourceName.isNotEmpty
          ? record.sourceName
          : config.unknownSourceName;
      final key = _normalizeKey(name);
      (grouped[key] ??= <TorrentReleaseRecord>[]).add(record);
      displayNames.putIfAbsent(key, () => name);
    }

    final results = <Source>[];
    for (final entry in grouped.entries) {
      final source = _buildSource(
        entry.value,
        sourceName: displayNames[entry.key] ?? config.unknownSourceName,
        expectedAnimeKey: expectedAnimeKey,
        config: config,
        baseUrl: baseUrl,
      );
      if (source != null) results.add(source);
    }
    return results;
  }

  static List<TorrentReleaseRecord> parseRecords({
    required String html,
    required Map<String, dynamic> params,
    required String baseUrl,
  }) {
    if (html.trim().isEmpty) return const <TorrentReleaseRecord>[];
    final config = _configFor(params);
    final document = html_parser.parse(html);
    return _recordsFromRows(
      _selectRows(document, config.rowSelectors),
      config: config,
      baseUrl: baseUrl,
      base: Uri.tryParse(baseUrl),
    );
  }

  static List<Element> _selectRows(dynamic root, List<String> selectors) {
    for (final selector in selectors) {
      if (selector.trim().isEmpty) continue;
      try {
        final elements = root.querySelectorAll(selector) as List<Element>;
        if (elements.isNotEmpty) return elements;
      } catch (_) {}
    }
    return const <Element>[];
  }

  static List<TorrentReleaseRecord> _recordsFromRows(
    List<Element> rows, {
    required _TorrentRecordConfig config,
    required String baseUrl,
    required Uri? base,
    String forcedSourceName = '',
    bool needScore = true,
    bool needImage = true,
  }) {
    final records = <TorrentReleaseRecord>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final title = _firstValue(row, config.titleSelectors, config.titleAttrs);
      if (title.isEmpty) continue;
      final rawId = _firstValue(row, config.idSelectors, config.idAttrs);
      if (config.requireResource && rawId.isEmpty) continue;
      final exactSource = _firstValue(
        row,
        config.exactSourceSelectors,
        config.exactSourceAttrs,
      );
      final resourceId = _attachExactSource(
        rawId,
        exactSource: exactSource,
        baseUrl: baseUrl,
        base: base,
      );
      final explicitSourceName = forcedSourceName.isNotEmpty
          ? forcedSourceName
          : _firstValue(
              row,
              config.sourceNameSelectors,
              config.sourceNameAttrs,
            );
      final size = _firstValue(row, config.sizeSelectors, config.sizeAttrs);
      final rawImage = needImage
          ? _firstValue(row, config.imageSelectors, config.imageAttrs)
          : '';
      final parts = _parseRelease(
        title,
        explicitSourceName: explicitSourceName,
        config: config,
      );
      final sourceName = explicitSourceName.isNotEmpty
          ? explicitSourceName
          : parts.fansub;
      records.add(
        TorrentReleaseRecord(
          title: title,
          resourceId: resourceId,
          animeName: parts.animeName,
          fansub: parts.fansub,
          sourceName: sourceName,
          size: size,
          image: rawImage.isEmpty ? '' : _absolute(rawImage, baseUrl, base),
          episode: parts.episode,
          score: needScore ? _score(title, sourceName, config) : 0,
          excluded: parts.excluded,
          order: i,
        ),
      );
    }
    return records;
  }

  static ({String animeName, String fansub, double? episode, bool excluded})
  _parseRelease(
    String title, {
    required String explicitSourceName,
    required _TorrentRecordConfig config,
  }) {
    final excluded = config.excludePatterns.any(
      (pattern) => pattern.firstMatch(title) != null,
    );
    double? episode;
    for (final pattern in config.episodePatterns) {
      final match = pattern.firstMatch(title);
      if (match == null) continue;
      final raw = pattern.group(match);
      final parsed = double.tryParse(raw);
      if (parsed != null) {
        episode = parsed;
        break;
      }
    }

    var fansub = explicitSourceName.trim();
    if (fansub.isEmpty && config.fansubPattern != null) {
      final match = config.fansubPattern!.firstMatch(title);
      if (match != null) fansub = config.fansubPattern!.group(match).trim();
    }

    var animeName = '';
    for (final pattern in config.animeNamePatterns) {
      final match = pattern.firstMatch(title);
      if (match == null) continue;
      animeName = pattern.group(match).trim();
      if (animeName.isNotEmpty) break;
    }
    if (animeName.isEmpty) {
      var core = title;
      for (final replacement in config.titleStripPatterns) {
        core = replacement.replaceAll(core);
      }
      if (episode != null) {
        for (final pattern in config.episodePatterns) {
          final match = pattern.firstMatch(core);
          if (match == null) continue;
          core = core.replaceRange(match.start, match.end, '');
          break;
        }
      }
      for (final replacement in config.animeCleanupPatterns) {
        core = replacement.replaceAll(core);
      }
      core = core.replaceAll(_whitespacePattern, ' ').trim();
      for (final separator in config.animeNameSeparators) {
        final index = core.indexOf(separator);
        if (index >= 0) {
          core = core.substring(0, index).trim();
          break;
        }
      }
      animeName = core;
    }

    return (
      animeName: animeName,
      fansub: fansub,
      episode: episode,
      excluded: excluded,
    );
  }

  static int _score(
    String title,
    String sourceName,
    _TorrentRecordConfig config,
  ) {
    var score = sourceName.isEmpty ? 0 : config.sourceNameBonus;
    for (final rule in config.scoreRules) {
      if (rule.pattern.firstMatch(title) != null) score += rule.score;
    }
    return score;
  }

  static Source? _buildSource(
    List<TorrentReleaseRecord> records, {
    required String sourceName,
    required String expectedAnimeKey,
    required _TorrentRecordConfig config,
    required String baseUrl,
  }) {
    if (config.episodeIndexMode == 'number') {
      final selected = <int, TorrentReleaseRecord>{};
      for (final record in records) {
        if (record.excluded || record.resourceId.isEmpty) continue;
        if (expectedAnimeKey.isNotEmpty &&
            _normalizeKey(record.animeName) != expectedAnimeKey) {
          continue;
        }
        final episode = record.episode;
        if (episode == null || episode <= 0) continue;
        if (!config.allowFractionalEpisode && episode != episode.truncate()) {
          continue;
        }
        final index = episode.floor() - 1;
        final existing = selected[index];
        if (existing == null ||
            (config.dedupeByEpisode && record.score > existing.score) ||
            ((!config.dedupeByEpisode || record.score == existing.score) &&
                _compareRecords(record, existing, config.sortDescending) < 0)) {
          selected[index] = record;
        }
      }
      final indexes = selected.keys.toList()..sort();
      final episodes = <Episode>[];
      for (final index in indexes) {
        final record = selected[index]!;
        episodes.add(
          Episode(
            record.resourceId,
            index,
            _episodeName(record, index, config, baseUrl),
          ),
        );
      }
      return episodes.isEmpty ? null : Source(episodes, sourceName);
    }

    final filtered = <TorrentReleaseRecord>[];
    for (final record in records) {
      if (record.excluded || record.resourceId.isEmpty) continue;
      if (config.requireEpisodeNumber && record.episode == null) continue;
      if (expectedAnimeKey.isNotEmpty &&
          _normalizeKey(record.animeName) != expectedAnimeKey) {
        continue;
      }
      filtered.add(record);
    }
    if (filtered.isEmpty) return null;
    filtered.sort((a, b) => _compareRecords(a, b, config.sortDescending));
    final episodes = <Episode>[];
    for (var i = 0; i < filtered.length; i++) {
      final record = filtered[i];
      episodes.add(
        Episode(record.resourceId, i, _episodeName(record, i, config, baseUrl)),
      );
    }
    return episodes.isEmpty ? null : Source(episodes, sourceName);
  }

  static int _compareRecords(
    TorrentReleaseRecord a,
    TorrentReleaseRecord b,
    bool descending,
  ) {
    final ae = a.episode;
    final be = b.episode;
    int result;
    if (ae != null && be != null) {
      result = ae.compareTo(be);
    } else if (ae != null) {
      result = -1;
    } else if (be != null) {
      result = 1;
    } else {
      result = a.title.compareTo(b.title);
    }
    if (result == 0) result = a.order.compareTo(b.order);
    return descending ? -result : result;
  }

  static String _episodeName(
    TorrentReleaseRecord record,
    int index,
    _TorrentRecordConfig config,
    String baseUrl,
  ) {
    if (config.episodeNameTemplate.isEmpty || record.episode == null) {
      return record.title;
    }
    final name = _render(
      config.episodeNameTemplate,
      _variables(record: record, baseUrl: baseUrl, episodeIndex: index),
    ).trim();
    return name.isEmpty ? record.title : name;
  }

  static String _expectedAnimeName(
    _TorrentRecordConfig config, {
    required String contextUrl,
  }) {
    if (config.expectedAnimeName.isNotEmpty) {
      return config.expectedAnimeName;
    }
    final query = config.expectedAnimeNameQuery;
    if (query.isEmpty || contextUrl.isEmpty) return '';
    try {
      return Uri.parse(contextUrl).queryParameters[query]?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  static String _firstValue(
    Element row,
    List<_RowAccessor> accessors,
    List<String> attrs,
  ) {
    for (final accessor in accessors) {
      final element = accessor.resolve(row);
      if (element == null) continue;
      final value = _elementValue(element, attrs);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _elementValue(Element element, List<String> attrs) {
    for (final attr in attrs) {
      final value = attr == 'text'
          ? element.text.replaceAll(_whitespacePattern, ' ').trim()
          : (element.attributes[attr]?.trim() ?? '');
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static Map<String, String> _variables({
    required TorrentReleaseRecord record,
    required String baseUrl,
    String? animeName,
    int? episodeIndex,
    int? count,
    List<String>? fansubs,
  }) {
    final episode = record.episode;
    return <String, String>{
      'title': record.title,
      'id': record.resourceId,
      'animeName': animeName ?? record.animeName,
      'fansub': record.fansub,
      'sourceName': record.sourceName,
      'size': record.size,
      'sizeSuffix': record.size.isEmpty ? '' : ' [${record.size}]',
      'episode': episode == null ? '' : _formatNumber(episode),
      'episodeIndex': episodeIndex?.toString() ?? '',
      'count': count?.toString() ?? '',
      'fansubs': fansubs?.join(', ') ?? '',
      'baseUrl': baseUrl.replaceFirst(_trailingSlashPattern, ''),
    };
  }

  static String _render(String template, Map<String, String> variables) {
    return template.replaceAllMapped(_templatePattern, (match) {
      final value = variables[match.group(1)] ?? '';
      return match.group(2) == null ? Uri.encodeQueryComponent(value) : value;
    });
  }

  static String _absolute(String value, String baseUrl, Uri? base) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.toLowerCase().startsWith('magnet:')) {
      return trimmed;
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme) return trimmed;
    if (base != null) {
      try {
        return base.resolve(trimmed).toString();
      } catch (_) {}
    }
    final separator = baseUrl.endsWith('/') || trimmed.startsWith('/')
        ? ''
        : '/';
    return '$baseUrl$separator$trimmed';
  }

  static String _attachExactSource(
    String resourceId, {
    required String exactSource,
    required String baseUrl,
    required Uri? base,
  }) {
    final id = resourceId.trim();
    if (id.isEmpty) return '';
    if (!id.toLowerCase().startsWith('magnet:') || exactSource.trim().isEmpty) {
      return _absolute(id, baseUrl, base);
    }

    final exactUrl = _absolute(exactSource, baseUrl, base);
    if (exactUrl.isEmpty) return id;
    try {
      final uri = Uri.parse(id);
      if ((uri.queryParametersAll['xs'] ?? const <String>[]).contains(
        exactUrl,
      )) {
        return id;
      }
    } catch (_) {
      return id;
    }
    final separator = id.contains('?') ? '&' : '?';
    return '$id${separator}xs=${Uri.encodeQueryComponent(exactUrl)}';
  }

  static String _normalizeKey(String value) =>
      value.toLowerCase().replaceAll(_keyNoisePattern, '');

  static String _formatNumber(double value) => value == value.truncate()
      ? value.truncate().toString()
      : value.toString();
}

class _TorrentRecordConfig {
  _TorrentRecordConfig(Map<String, dynamic> params)
    : rowSelectors = _aliased(params, 'rowSelector'),
      sourceContainerSelectors = _aliased(params, 'sourceContainerSelector'),
      sourceLabelSelectors = _aliased(params, 'sourceLabelSelector'),
      sourceLabelAttrs = _aliased(
        params,
        'sourceLabelAttr',
        fallback: const <String>['text'],
      ),
      titleSelectors = _accessors(_aliased(params, 'titleSelector')),
      titleAttrs = _aliased(
        params,
        'titleAttr',
        fallback: const <String>['text'],
      ),
      idSelectors = _accessors(_aliased(params, 'idSelector')),
      idAttrs = _aliased(params, 'idAttr', fallback: const <String>['href']),
      exactSourceSelectors = _accessors(
        _aliased(params, 'exactSourceSelector'),
      ),
      exactSourceAttrs = _aliased(
        params,
        'exactSourceAttr',
        fallback: const <String>['href'],
      ),
      sourceNameSelectors = _accessors(_aliased(params, 'sourceNameSelector')),
      sourceNameAttrs = _aliased(
        params,
        'sourceNameAttr',
        fallback: const <String>['text'],
      ),
      sizeSelectors = _accessors(_aliased(params, 'sizeSelector')),
      sizeAttrs = _aliased(
        params,
        'sizeAttr',
        fallback: const <String>['text'],
      ),
      imageSelectors = _accessors(_aliased(params, 'imageSelector')),
      imageAttrs = _aliased(
        params,
        'imageAttr',
        fallback: const <String>['data-src', 'src'],
      ),
      episodePatterns = _patterns(params['episodePatterns']),
      excludePatterns = _patterns(params['excludePatterns']),
      animeNamePatterns = _patterns(params['animeNamePatterns']),
      titleStripPatterns = _replacements(params['titleStripPatterns']),
      animeCleanupPatterns = _replacements(params['animeCleanupPatterns']),
      animeNameSeparators = _strings(params['animeNameSeparators']),
      fansubPattern = _optionalPattern(params['fansubPattern']),
      scoreRules = _scoreRules(params['scoreRules']),
      seriesIdTemplate = params['seriesIdTemplate']?.toString() ?? '',
      descriptionTemplate = params['descriptionTemplate']?.toString() ?? '',
      episodeNameTemplate = params['episodeNameTemplate']?.toString() ?? '',
      episodeIndexMode =
          (params['episodeIndexMode']?.toString().toLowerCase() ?? 'sequence'),
      expectedAnimeName = params['expectedAnimeName']?.toString().trim() ?? '',
      expectedAnimeNameQuery =
          params['expectedAnimeNameQuery']?.toString().trim() ?? '',
      unknownSourceName =
          params['unknownSourceName']?.toString().trim() ?? 'Unknown',
      requireResource = _flag(params['requireResource'], fallback: true),
      requireEpisodeNumber = _flag(params['requireEpisodeNumber']),
      allowFractionalEpisode = _flag(params['allowFractionalEpisode']),
      dedupeByEpisode = _flag(params['dedupeByEpisode'], fallback: true),
      sortDescending = _flag(params['sortDescending']),
      sourceNameBonus = _integer(params['sourceNameBonus']);

  final List<String> rowSelectors;
  final List<String> sourceContainerSelectors;
  final List<String> sourceLabelSelectors;
  final List<String> sourceLabelAttrs;
  final List<_RowAccessor> titleSelectors;
  final List<String> titleAttrs;
  final List<_RowAccessor> idSelectors;
  final List<String> idAttrs;
  final List<_RowAccessor> exactSourceSelectors;
  final List<String> exactSourceAttrs;
  final List<_RowAccessor> sourceNameSelectors;
  final List<String> sourceNameAttrs;
  final List<_RowAccessor> sizeSelectors;
  final List<String> sizeAttrs;
  final List<_RowAccessor> imageSelectors;
  final List<String> imageAttrs;
  final List<_PatternSpec> episodePatterns;
  final List<_PatternSpec> excludePatterns;
  final List<_PatternSpec> animeNamePatterns;
  final List<_ReplacementSpec> titleStripPatterns;
  final List<_ReplacementSpec> animeCleanupPatterns;
  final List<String> animeNameSeparators;
  final _PatternSpec? fansubPattern;
  final List<_ScoreRule> scoreRules;
  final String seriesIdTemplate;
  final String descriptionTemplate;
  final String episodeNameTemplate;
  final String episodeIndexMode;
  final String expectedAnimeName;
  final String expectedAnimeNameQuery;
  final String unknownSourceName;
  final bool requireResource;
  final bool requireEpisodeNumber;
  final bool allowFractionalEpisode;
  final bool dedupeByEpisode;
  final bool sortDescending;
  final int sourceNameBonus;

  static List<String> _aliased(
    Map<String, dynamic> params,
    String singular, {
    List<String> fallback = const <String>[],
  }) => _strings(
    params['${singular}s'] ?? params[singular],
    fallback: fallback,
  );

  static List<_RowAccessor> _accessors(List<String> selectors) =>
      selectors.map(_RowAccessor.compile).toList(growable: false);

  static List<String> _strings(
    Object? value, {
    List<String> fallback = const <String>[],
  }) {
    if (value is String) {
      final item = value.trim();
      return item.isEmpty ? fallback : <String>[item];
    }
    if (value is List) {
      final items = value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
      return items.isEmpty ? fallback : items;
    }
    return fallback;
  }

  static List<_PatternSpec> _patterns(Object? value) {
    if (value is! List) return const <_PatternSpec>[];
    return value
        .map(_PatternSpec.fromValue)
        .whereType<_PatternSpec>()
        .toList(growable: false);
  }

  static _PatternSpec? _optionalPattern(Object? value) =>
      _PatternSpec.fromValue(value);

  static List<_ReplacementSpec> _replacements(Object? value) {
    if (value is! List) return const <_ReplacementSpec>[];
    return value
        .map(_ReplacementSpec.fromValue)
        .whereType<_ReplacementSpec>()
        .toList(growable: false);
  }

  static List<_ScoreRule> _scoreRules(Object? value) {
    if (value is! List) return const <_ScoreRule>[];
    return value
        .map(_ScoreRule.fromValue)
        .whereType<_ScoreRule>()
        .toList(growable: false);
  }

  static bool _flag(Object? value, {bool fallback = false}) {
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    return fallback;
  }

  static int _integer(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _RowAccessor {
  const _RowAccessor.css(String this._selector)
    : _nthIndex = null,
      _nthTag = null;

  const _RowAccessor.nth(int this._nthIndex, this._nthTag) : _selector = null;

  const _RowAccessor.none()
    : _selector = null,
      _nthIndex = null,
      _nthTag = null;

  final String? _selector;
  final int? _nthIndex;
  final String? _nthTag;

  Element? resolve(Element row) {
    final index = _nthIndex;
    if (index != null) {
      if (index >= row.children.length) return null;
      final candidate = row.children[index];
      return _nthTag == null || candidate.localName == _nthTag
          ? candidate
          : null;
    }
    final selector = _selector;
    if (selector == null) return null;
    if (selector.isEmpty) return row;
    try {
      return row.querySelector(selector);
    } catch (_) {
      return null;
    }
  }

  static _RowAccessor compile(String selector) {
    final nthChild = TorrentRecordParser._nthChildPattern.firstMatch(selector);
    if (nthChild == null) return _RowAccessor.css(selector);
    final index = (int.tryParse(nthChild.group(2)!) ?? 0) - 1;
    if (index < 0) return const _RowAccessor.none();
    return _RowAccessor.nth(index, nthChild.group(1)?.toLowerCase());
  }
}

class _PatternSpec {
  _PatternSpec(this.regExp, this.groupIndex);

  final RegExp regExp;
  final int groupIndex;

  RegExpMatch? firstMatch(String value) => regExp.firstMatch(value);

  String group(RegExpMatch match) {
    if (groupIndex < 0 || groupIndex > match.groupCount) return '';
    return match.group(groupIndex) ?? '';
  }

  static _PatternSpec? fromValue(Object? value) {
    String pattern;
    var group = 1;
    var caseSensitive = false;
    var multiLine = false;
    var dotAll = false;
    if (value is String) {
      pattern = value;
    } else if (value is Map) {
      pattern = value['pattern']?.toString() ?? '';
      group = _TorrentRecordConfig._integer(value['group']);
      if (value['group'] == null) group = 1;
      caseSensitive = _TorrentRecordConfig._flag(value['caseSensitive']);
      multiLine = _TorrentRecordConfig._flag(value['multiLine']);
      dotAll = _TorrentRecordConfig._flag(value['dotAll']);
    } else {
      return null;
    }
    if (pattern.isEmpty) return null;
    try {
      return _PatternSpec(
        RegExp(
          pattern,
          caseSensitive: caseSensitive,
          multiLine: multiLine,
          dotAll: dotAll,
        ),
        group,
      );
    } catch (_) {
      return null;
    }
  }
}

class _ReplacementSpec {
  _ReplacementSpec(this.pattern, this.replacement);

  final RegExp pattern;
  final String replacement;

  String replaceAll(String value) => value.replaceAll(pattern, replacement);

  static _ReplacementSpec? fromValue(Object? value) {
    String pattern;
    var replacement = '';
    var caseSensitive = false;
    if (value is String) {
      pattern = value;
    } else if (value is Map) {
      pattern = value['pattern']?.toString() ?? '';
      replacement = value['replacement']?.toString() ?? '';
      caseSensitive = _TorrentRecordConfig._flag(value['caseSensitive']);
    } else {
      return null;
    }
    if (pattern.isEmpty) return null;
    try {
      return _ReplacementSpec(
        RegExp(pattern, caseSensitive: caseSensitive),
        replacement,
      );
    } catch (_) {
      return null;
    }
  }
}

class _ScoreRule {
  _ScoreRule(this.pattern, this.score);

  final _PatternSpec pattern;
  final int score;

  static _ScoreRule? fromValue(Object? value) {
    if (value is! Map) return null;
    final pattern = _PatternSpec.fromValue(value);
    if (pattern == null) return null;
    return _ScoreRule(pattern, _TorrentRecordConfig._integer(value['score']));
  }
}
