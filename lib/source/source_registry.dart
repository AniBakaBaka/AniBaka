import 'package:flutter/material.dart';

import 'package:baka/source/source_adapter.dart';
import 'package:baka/source/store/bundled_rule_store.dart';

/// A built-in source; its rule ships as `assets/rules/<key>.json`.
class AdapterDescriptor {
  AdapterDescriptor({
    required this.key,
    required this.displayName,
    required this.icon,
    required this.color,
    String? idPattern,
  }) : _idPattern = idPattern == null ? null : RegExp(idPattern);

  final String key;
  final String displayName;
  final IconData icon;
  final Color color;
  final RegExp? _idPattern;

  int resolveNumericId(String seriesId) {
    final id = _idPattern?.firstMatch(seriesId)?.group(1) ?? seriesId;
    return int.tryParse(id) ?? stableSourceId(id);
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
    ),
    AdapterDescriptor(
      key: '7sefun',
      displayName: '七色番',
      idPattern: r'/voddetail/(\d+)\.html',
      icon: Icons.movie_creation_outlined,
      color: const Color(0xFF26C6DA),
    ),
    AdapterDescriptor(
      key: '2kdm',
      displayName: 'MuteFun',
      idPattern: r'/voddetail/(\d+)\.html',
      icon: Icons.smart_display_rounded,
      color: const Color(0xFF42A5F5),
    ),
    AdapterDescriptor(
      key: 'dm84',
      displayName: 'DM84',
      idPattern: r'/v/(\d+)\.html',
      icon: Icons.live_tv_rounded,
      color: const Color(0xFFFF7043),
    ),
    AdapterDescriptor(
      key: 'fsdm02',
      displayName: '番薯动漫',
      icon: Icons.play_circle_fill_rounded,
      color: const Color(0xFFFF8A65),
    ),
    AdapterDescriptor(
      key: 'girigirilove',
      displayName: 'GirigiriLove',
      idPattern: r'/GV(\d+)',
      icon: Icons.favorite_rounded,
      color: const Color(0xFFEC407A),
    ),
    AdapterDescriptor(
      key: 'girigirilove_beta',
      displayName: 'GirigiriLove Beta',
      idPattern: r'/detail/(\d+)',
      icon: Icons.favorite_rounded,
      color: const Color(0xFFEC407A),
    ),
    AdapterDescriptor(
      key: 'lm6',
      displayName: '路漫漫',
      icon: Icons.school_rounded,
      color: const Color(0xFF66BB6A),
    ),
    AdapterDescriptor(
      key: 'mgnacg',
      displayName: 'Mgnacg',
      idPattern: r'/media/(\d+)/?',
      icon: Icons.rocket_launch_outlined,
      color: const Color(0xFFFFB74D),
    ),
    AdapterDescriptor(
      key: 'ios_mifun',
      displayName: 'MiFun',
      icon: Icons.ondemand_video_rounded,
      color: const Color(0xFF00ACC1),
    ),
    AdapterDescriptor(
      key: 'xifanacg',
      displayName: 'Xifanacg Next',
      idPattern: r'/anime/(\d+)',
      icon: Icons.cloud_circle_outlined,
      color: const Color(0xFF26A69A),
    ),
    AdapterDescriptor(
      key: 'tvtfun',
      displayName: 'TvTFun',
      icon: Icons.live_tv_rounded,
      color: const Color(0xFF5C6BC0),
    ),
    AdapterDescriptor(
      key: 'moonci',
      displayName: 'Moonci',
      idPattern: r'/anime/(\d+)',
      icon: Icons.nightlight_round,
      color: const Color(0xFF3949AB),
    ),
    AdapterDescriptor(
      key: 'silisili',
      displayName: '嘶哩嘶哩',
      icon: Icons.play_circle_outline_rounded,
      color: const Color(0xFF7E57C2),
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

  static bool isAdapterSource(String? source) =>
      source != null && (isBuiltinSource(source) || isCustomSource(source));

  static SourceAdapter? createAdapter(String key) =>
      switch (BundledRuleStore.ruleFor(key)) {
        final rule? => SourceAdapter(rule),
        null => null,
      };
}

int stableSourceId(String input) {
  var hash = 0x811c9dc5;
  for (var index = 0; index < input.length; index++) {
    hash ^= input.codeUnitAt(index);
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash == 0 ? input.length + 1 : hash;
}
