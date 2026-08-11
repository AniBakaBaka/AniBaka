import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/store/bundled_rule_store.dart';
import 'package:flutter/material.dart';

typedef AdapterFactory = AdapterBase? Function();

AdapterBase? _createBundledRuleAdapter(String key) {
  final rule = BundledRuleStore.ruleFor(key);
  return rule == null ? null : PipelineSourceAdapter(rule);
}

class AdapterDescriptor {
  final String key;
  final String displayName;
  final String? idPattern;
  final IconData icon;
  final Color color;
  final AdapterFactory factory;

  String get statusLabel => '第三方源';

  const AdapterDescriptor({
    required this.key,
    required this.displayName,
    required this.icon,
    required this.color,
    required this.factory,
    this.idPattern,
  });

  AdapterBase? createAdapter() {
    return factory();
  }

  int resolveNumericId(String seriesId) {
    final idStr = idPattern != null
        ? (RegExp(idPattern!).firstMatch(seriesId)?.group(1) ?? seriesId)
        : seriesId;
    return int.tryParse(idStr) ?? stableSourceId(idStr);
  }
}

class AdapterRegistry {
  static const String customSourcePrefix = 'custom_';

  static final List<AdapterDescriptor> builtinSources = [
    AdapterDescriptor(
      key: 'akianime',
      displayName: 'AkiAnime',
      icon: Icons.video_library,
      color: const Color(0xFFE07A5F),
      factory: () => _createBundledRuleAdapter('akianime'),
    ),
    AdapterDescriptor(
      key: 'anime7',
      displayName: 'Anime7',
      icon: Icons.movie_creation_outlined,
      color: const Color(0xFF26C6DA),
      factory: () => _createBundledRuleAdapter('anime7'),
    ),
    AdapterDescriptor(
      key: 'dm84',
      displayName: 'DM84',
      idPattern: r'/v/(\d+)\.html',
      icon: Icons.live_tv_rounded,
      color: const Color(0xFFFF7043),
      factory: () => _createBundledRuleAdapter('dm84'),
    ),
    AdapterDescriptor(
      key: 'fsdm02',
      displayName: '番薯动漫',
      icon: Icons.play_circle_fill_rounded,
      color: const Color(0xFFFF8A65),
      factory: () => _createBundledRuleAdapter('fsdm02'),
    ),
    AdapterDescriptor(
      key: 'girigirilove',
      displayName: 'GirigiriLove',
      idPattern: r'/GV(\d+)',
      icon: Icons.favorite_rounded,
      color: const Color(0xFFEC407A),
      factory: () => _createBundledRuleAdapter('girigirilove'),
    ),
    AdapterDescriptor(
      key: 'lm6',
      displayName: '路漫漫',
      icon: Icons.school_rounded,
      color: const Color(0xFF66BB6A),
      factory: () => _createBundledRuleAdapter('lm6'),
    ),
    AdapterDescriptor(
      key: 'jcydmz',
      displayName: '囧次元',
      idPattern: r'/vod/detail/id/(\d+)',
      icon: Icons.smart_display_rounded,
      color: const Color(0xFFEF5350),
      factory: () => _createBundledRuleAdapter('jcydmz'),
    ),
    AdapterDescriptor(
      key: 'mgnacg',
      displayName: 'Mgnacg',
      idPattern: r'/media/(\d+)/?',
      icon: Icons.rocket_launch_outlined,
      color: const Color(0xFFFFB74D),
      factory: () => _createBundledRuleAdapter('mgnacg'),
    ),
    AdapterDescriptor(
      key: 'ios_mifun',
      displayName: 'MiFun',
      icon: Icons.ondemand_video_rounded,
      color: const Color(0xFF00ACC1),
      factory: () => _createBundledRuleAdapter('ios_mifun'),
    ),
    AdapterDescriptor(
      key: 'xifanacg',
      displayName: 'Xifanacg',
      idPattern: r'/bangumi/(\d+)',
      icon: Icons.cloud_circle_outlined,
      color: const Color(0xFF26A69A),
      factory: () => _createBundledRuleAdapter('xifanacg'),
    ),
    AdapterDescriptor(
      key: 'tvtfun',
      displayName: 'TvTFun',
      icon: Icons.live_tv_rounded,
      color: const Color(0xFF5C6BC0),
      factory: () => _createBundledRuleAdapter('tvtfun'),
    ),
    AdapterDescriptor(
      key: 'moonci',
      displayName: 'Moonci',
      idPattern: r'/anime/(\d+)',
      icon: Icons.nightlight_round,
      color: const Color(0xFF3949AB),
      factory: () => _createBundledRuleAdapter('moonci'),
    ),
    AdapterDescriptor(
      key: 'silisili',
      displayName: '嘶哩嘶哩',
      icon: Icons.play_circle_outline_rounded,
      color: const Color(0xFF7E57C2),
      factory: () => _createBundledRuleAdapter('silisili'),
    ),
  ];

  static final Map<String, AdapterDescriptor> _builtinSourceMap = {
    for (final source in builtinSources) source.key: source,
  };

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
}

int stableSourceId(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash == 0 ? input.length + 1 : hash;
}
