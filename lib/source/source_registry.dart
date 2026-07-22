import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/models/episode.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/source/store/bundled_rule_store.dart';
import 'package:baka/source/store/rule_migrator.dart';
import 'package:flutter/material.dart';

typedef AdapterFactory = AdapterBase? Function();

AdapterBase? _createBundledRuleAdapter(String key) {
  final rule = BundledRuleStore.ruleFor(key);
  return rule == null ? null : PipelineSourceAdapter(rule);
}

class AdapterDescriptor {
  final String key;
  final String displayName;
  final String playerContent;
  final String? idPattern;
  final bool quickSearchEnabled;
  final IconData icon;
  final Color color;
  final String? statusLabel;
  final AdapterFactory factory;

  const AdapterDescriptor({
    required this.key,
    required this.displayName,
    required this.playerContent,
    required this.icon,
    required this.color,
    required this.factory,
    this.idPattern,
    this.quickSearchEnabled = true,
    this.statusLabel,
  });

  AdapterBase? createAdapter() {
    return factory();
  }

  Map<String, dynamic> buildSearchResult(
    Series series, {
    String fallbackDescription = '',
  }) => _buildSearchResultPayload(
    series,
    key,
    displayName,
    fallbackDescription: fallbackDescription,
  );

  int resolveNumericId(String seriesId) {
    final idStr = idPattern != null
        ? (RegExp(idPattern!).firstMatch(seriesId)?.group(1) ?? seriesId)
        : seriesId;
    return int.tryParse(idStr) ?? _stableHash(idStr);
  }

  Future<Map<String, dynamic>?> buildPlayerData({
    required AdapterBase adapter,
    required Map<String, dynamic> item,
  }) async {
    final sources = await adapter.getSourcesWithContext(
      item['seriesId'].toString(),
      item,
    );
    return _buildPlayerPayload(
      sourceKey: key,
      displayName: displayName,
      content: playerContent,
      item: item,
      sources: sources,
      numericId: resolveNumericId(item['seriesId'].toString()),
    );
  }
}

class AdapterRegistry {
  static const String customSourcePrefix = 'custom_';

  static final List<AdapterDescriptor> builtinSources = [
    AdapterDescriptor(
      key: 'akianime',
      displayName: 'AkiAnime',
      playerContent: '来源: AkiAnime。',
      icon: Icons.video_library,
      color: const Color(0xFFE07A5F),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('akianime'),
    ),
    AdapterDescriptor(
      key: 'cycani',
      displayName: 'Cycani',
      playerContent: '来源: Cycani。',
      idPattern: r'/bangumi/(\d+)',
      icon: Icons.animation_rounded,
      color: const Color(0xFF7E57C2),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('cycani'),
    ),
    AdapterDescriptor(
      key: 'anime7',
      displayName: 'Anime7',
      playerContent: '来源: Anime7。',
      icon: Icons.movie_creation_outlined,
      color: const Color(0xFF26C6DA),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('anime7'),
    ),
    AdapterDescriptor(
      key: 'dm84',
      displayName: 'DM84',
      playerContent: '来源: DM84。',
      idPattern: r'/v/(\d+)\.html',
      icon: Icons.live_tv_rounded,
      color: const Color(0xFFFF7043),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('dm84'),
    ),
    AdapterDescriptor(
      key: 'fsdm02',
      displayName: '番薯动漫',
      playerContent: '来源: 番薯动漫。',
      icon: Icons.play_circle_fill_rounded,
      color: const Color(0xFFFF8A65),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('fsdm02'),
    ),
    AdapterDescriptor(
      key: 'enlienli',
      displayName: 'OmoFun',
      playerContent: '来源: OmoFun Enlienli。',
      icon: Icons.play_circle_outline,
      color: const Color(0xFF42A5F5),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('enlienli'),
    ),
    AdapterDescriptor(
      key: 'girigirilove',
      displayName: 'GirigiriLove',
      playerContent: '来源: GirigiriLove。',
      idPattern: r'/GV(\d+)',
      icon: Icons.favorite_rounded,
      color: const Color(0xFFEC407A),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('girigirilove'),
    ),
    AdapterDescriptor(
      key: 'lm6',
      displayName: '路漫漫',
      playerContent: '来源: 路漫漫动漫。',
      icon: Icons.school_rounded,
      color: const Color(0xFF66BB6A),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('lm6'),
    ),
    AdapterDescriptor(
      key: 'jcydmz',
      displayName: '囧次元',
      playerContent: '来源: 囧次元。',
      idPattern: r'/vod/detail/id/(\d+)',
      icon: Icons.smart_display_rounded,
      color: const Color(0xFFEF5350),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('jcydmz'),
    ),
    AdapterDescriptor(
      key: 'mgnacg',
      displayName: 'Mgnacg',
      playerContent: '来源: Mgnacg。',
      idPattern: r'/media/(\d+)/?',
      icon: Icons.rocket_launch_outlined,
      color: const Color(0xFFFFB74D),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('mgnacg'),
    ),
    AdapterDescriptor(
      key: 'skr_skr2',
      displayName: '樱之空',
      playerContent: '来源: 樱之空动漫。',
      icon: Icons.local_florist_rounded,
      color: const Color(0xFFAB47BC),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('skr_skr2'),
    ),
    AdapterDescriptor(
      key: 'tvtfun',
      displayName: 'TvTFun',
      playerContent: '来源: TvTFun。',
      icon: Icons.stream_rounded,
      color: const Color(0xFF5C6BC0),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('tvtfun'),
    ),
    AdapterDescriptor(
      key: 'xifanacg',
      displayName: 'Xifanacg',
      playerContent: '来源: Xifanacg。',
      idPattern: r'/bangumi/(\d+)',
      icon: Icons.cloud_circle_outlined,
      color: const Color(0xFF26A69A),
      statusLabel: '第三方源',
      factory: () => _createBundledRuleAdapter('xifanacg'),
    ),
  ];

  static final Map<String, AdapterDescriptor> _builtinSourceMap = {
    for (final source in builtinSources) source.key: source,
  };

  static final List<AdapterDescriptor> quickSearchSources = builtinSources
      .where((source) => source.quickSearchEnabled)
      .toList(growable: false);

  static AdapterDescriptor? descriptorFor(String key) => _builtinSourceMap[key];

  static bool isBuiltinSource(String source) =>
      _builtinSourceMap.containsKey(source);

  static String customSourceKey(String id) => '$customSourcePrefix$id';

  static bool isCustomSource(String source) =>
      source.startsWith(customSourcePrefix);

  static bool isAdapterSource(String? source) {
    return source != null &&
        source.isNotEmpty &&
        (isBuiltinSource(source) || isCustomSource(source));
  }

  static AdapterBase? createAdapter(String key) {
    return descriptorFor(key)?.createAdapter();
  }

  static AdapterBase? createAdapterForSource(
    String? source, {
    CustomSourceConfig? customSourceConfig,
  }) {
    if (source == null || source.isEmpty) {
      return null;
    }

    if (isCustomSource(source)) {
      if (customSourceConfig == null) {
        return null;
      }

      return PipelineSourceAdapter(
        RuleMigrator.ruleForConfig(customSourceConfig),
      );
    }

    return createAdapter(source);
  }
}

Map<String, dynamic> _buildSearchResultPayload(
  Series series,
  String sourceKey,
  String sourceDisplayName, {
  String fallbackDescription = '',
  CustomSourceConfig? sourceConfig,
}) {
  return {
    'title': series.name,
    'seriesId': series.seriesId,
    'description': series.description ?? fallbackDescription,
    'image': series.image,
    'source': sourceKey,
    'sourceDisplayName': sourceDisplayName,
    if (series.bgmId != null) 'bgmId': series.bgmId,
    if (series.score != null) 'score': series.score,
    if (series.image?.isNotEmpty ?? false) 'bgmImageUrl': series.image,
    'sourceConfig': ?sourceConfig,
  };
}

Map<String, dynamic> buildCustomSourceSearchResult(
  CustomSourceConfig config,
  Series series, {
  String fallbackDescription = '',
}) => _buildSearchResultPayload(
  series,
  AdapterRegistry.customSourceKey(config.id),
  config.name,
  fallbackDescription: fallbackDescription,
  sourceConfig: config,
);

Future<Map<String, dynamic>?> buildCustomSourcePlayerData({
  required CustomSourceConfig config,
  required AdapterBase adapter,
  required Map<String, dynamic> item,
}) async {
  final sources = await adapter.getSourcesWithContext(
    item['seriesId'].toString(),
    item,
  );
  return _buildPlayerPayload(
    sourceKey: AdapterRegistry.customSourceKey(config.id),
    displayName: config.name,
    content: config.description.isEmpty
        ? '来源: ${config.name}'
        : config.description,
    item: item,
    sources: sources,
    numericId: _stableHash(item['seriesId'].toString()),
    sourceConfig: config,
  );
}

Map<String, dynamic>? _buildPlayerPayload({
  required String sourceKey,
  required String displayName,
  required String content,
  required Map<String, dynamic> item,
  required List<Source> sources,
  required int numericId,
  CustomSourceConfig? sourceConfig,
}) {
  if (sources.isEmpty) {
    debugPrint('$displayName: no episode data found for ${item['seriesId']}');
    return null;
  }

  final videoList = buildAdapterVideoList(sources);
  if (videoList.isEmpty) {
    debugPrint(
      '$displayName: no playable episodes found for ${item['seriesId']}',
    );
    return null;
  }

  final sourceNames = sources
      .asMap()
      .entries
      .map((entry) => entry.value.sourceName ?? '线路${entry.key + 1}')
      .toList(growable: false);

  return {
    'id': numericId,
    'seriesUrl': item['seriesId'].toString(),
    'title': item['title']?.toString() ?? '',
    'description': item['description']?.toString() ?? '',
    'image': item['image']?.toString() ?? '',
    'videos': videoList.join('\n'),
    'currPlayIndex': 0,
    'currUrl': 1,
    'source': sourceKey,
    'sourceDisplayName': displayName,
    'sort': '番剧',
    'content': content,
    'pv': '114514',
    'tag': displayName,
    'uv': '',
    'videoList': videoList,
    'sourceNames': sourceNames,
    if (item['bgmId'] != null) 'bgmId': item['bgmId'],
    if (item['score'] != null) 'score': item['score'],
    if (item['bgmImageUrl']?.toString().isNotEmpty ?? false)
      'bgmImageUrl': item['bgmImageUrl'],
    ...?sourceConfig == null
        ? null
        : <String, dynamic>{'sourceConfig': sourceConfig},
  };
}

List<String> buildAdapterVideoList(List<Source> sources) {
  var maxEpisodeIndex = -1;
  final episodesBySource = sources
      .map((source) {
        final episodes = <int, Episode>{};
        for (var i = 0; i < source.episodes.length; i++) {
          final ep = source.episodes[i];
          final idx = ep.episode >= 0 ? ep.episode : i;
          episodes[idx] = ep;
          if (idx > maxEpisodeIndex) maxEpisodeIndex = idx;
        }
        return episodes;
      })
      .toList(growable: false);

  final videoList = <String>[];
  for (var i = 0; i <= maxEpisodeIndex; i++) {
    String? title;
    final parts = <String>[];
    for (final sourceEpisodes in episodesBySource) {
      final ep = sourceEpisodes[i];
      if (ep != null) {
        title ??= ep.name;
        parts.add(ep.episodeId);
      }
    }
    if (title != null && parts.isNotEmpty) {
      videoList.add([title, ...parts].join(r'$'));
    }
  }
  return videoList;
}

int _stableHash(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash == 0 ? input.length + 1 : hash;
}
