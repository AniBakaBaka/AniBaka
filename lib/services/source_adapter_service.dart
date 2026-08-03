import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/store/bundled_rule_store.dart';
import 'package:baka/source/store/rule_migrator.dart';

/// 适配器的创建、缓存与搜索/播放调用入口。
///
/// 只读的源配置查询请直连 [SourceCatalog.instance]；本服务保留会牵动
/// 适配器缓存失效的变更操作（增删改源、导入、重置）。
/// 适配器按服务实例缓存，以隔离 Cookie 和请求状态。
class SourceAdapterService {
  SourceAdapterService();

  static final SourceAdapterService instance = SourceAdapterService();
  static const int _maxCachedAdapters = 24;

  final SourceCatalog _catalog = SourceCatalog.instance;

  /// LinkedHashMap insertion order = LRU (re-insert on hit).
  final LinkedHashMap<String, ({AdapterBase adapter, DateTime? revision})>
  _adapterCache = LinkedHashMap();

  Future<void> init() async {
    await Future.wait<void>([BundledRuleStore.load(), _catalog.init()]);
  }

  void dispose() {
    for (final entry in _adapterCache.values) {
      entry.adapter.dispose();
    }
    _adapterCache.clear();
  }

  Future<bool> addCustomSource(CustomSourceConfig source) async {
    if (AdapterRegistry.isBuiltinSource(source.id)) {
      return updateBuiltinSource(source.id, source);
    }
    return _catalog.addCustomSource(source);
  }

  Future<bool> updateCustomSource(CustomSourceConfig source) async {
    if (AdapterRegistry.isBuiltinSource(source.id)) {
      return updateBuiltinSource(source.id, source);
    }
    return _catalog.updateCustomSource(source);
  }

  Future<bool> deleteCustomSource(String id) async {
    final ok = await _catalog.deleteCustomSource(id);
    if (ok) _removeAdapter(AdapterRegistry.customSourceKey(id));
    return ok;
  }

  Future<int> importCustomSource(String input) async {
    final count = await _catalog.importCustomSource(input);
    if (count > 0) {
      _removeAdaptersWhere(AdapterRegistry.isBuiltinSource);
    }
    return count;
  }

  Future<void> clearAllCustomSources() async {
    await _catalog.clearCustomSources();
    _removeAdaptersWhere(AdapterRegistry.isCustomSource);
  }

  Future<bool> updateBuiltinSource(
    String key,
    CustomSourceConfig source,
  ) async {
    final updated = await _catalog.updateBuiltinSource(key, source);
    if (updated) _removeAdapter(key);
    return updated;
  }

  Future<bool> resetBuiltinSource(String key) async {
    final reset = await _catalog.resetBuiltinSource(key);
    if (reset) _removeAdapter(key);
    return reset;
  }

  AdapterBase? createAdapterFor(
    String source, {
    CustomSourceConfig? config,
    Map? item,
  }) {
    if (AdapterRegistry.isCustomSource(source)) {
      final sourceId = source.substring(
        AdapterRegistry.customSourcePrefix.length,
      );
      var resolved = _catalog.customSourceById(sourceId) ?? config;
      if (resolved == null) {
        final sourceConfig = item?['sourceConfig'];
        if (sourceConfig is CustomSourceConfig) resolved = sourceConfig;
      }
      if (resolved == null) return null;
      return PipelineSourceAdapter(RuleMigrator.ruleForConfig(resolved));
    }

    final override = _catalog.builtinOverrideById(source);
    return override == null
        ? AdapterRegistry.createAdapter(source)
        : PipelineSourceAdapter(RuleMigrator.ruleForConfig(override));
  }

  AdapterBase? getBuiltinAdapter(String key) {
    final override = _catalog.builtinOverrideById(key);
    return _getOrCreateAdapter(
      key,
      revision: override?.updatedAt,
      create: () => createAdapterFor(key),
    );
  }

  AdapterBase? getCustomAdapter(CustomSourceConfig config) {
    final activeConfig = _catalog.customSourceById(config.id) ?? config;
    final sourceKey = AdapterRegistry.customSourceKey(activeConfig.id);

    return _getOrCreateAdapter(
      sourceKey,
      revision: activeConfig.updatedAt,
      create: () => createAdapterFor(sourceKey, config: activeConfig),
    );
  }

  Future<List<Map<String, dynamic>>> searchBuiltin(
    String query,
    AdapterDescriptor descriptor, {
    String fallbackDescription = '',
    bool skipBgmEnhancement = false,
  }) => _search(
    adapter: getBuiltinAdapter(descriptor.key),
    query: query,
    enhanceWithBgm: !skipBgmEnhancement,
    buildResult: (series) => descriptor.buildSearchResult(
      series,
      fallbackDescription: fallbackDescription,
    ),
  );

  Future<List<Map<String, dynamic>>> searchCustom(
    String query,
    CustomSourceConfig config, {
    String fallbackDescription = '',
    bool skipBgmEnhancement = false,
  }) {
    final activeConfig = _catalog.customSourceById(config.id) ?? config;
    return _search(
      adapter: getCustomAdapter(activeConfig),
      query: query,
      enhanceWithBgm: !skipBgmEnhancement,
      buildResult: (series) => buildCustomSourceSearchResult(
        activeConfig,
        series,
        fallbackDescription: fallbackDescription,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _search({
    required AdapterBase? adapter,
    required String query,
    required bool enhanceWithBgm,
    required Map<String, dynamic> Function(Series) buildResult,
  }) async {
    if (adapter == null) return const <Map<String, dynamic>>[];
    final results = await adapter.search(
      '',
      query,
      enhanceWithBgm: enhanceWithBgm,
    );
    return results.map(buildResult).toList(growable: false);
  }

  Future<Map<String, dynamic>?> buildPlayerData(
    Map<String, dynamic> item,
  ) async {
    final sourceKey = item['source']?.toString();
    if (sourceKey == null || sourceKey.isEmpty) return null;

    if (AdapterRegistry.isCustomSource(sourceKey)) {
      final config = _resolveCustomSourceConfig(sourceKey, item);
      if (config == null) return null;
      final adapter = getCustomAdapter(config);
      if (adapter == null) return null;
      return buildCustomSourcePlayerData(
        config: config,
        adapter: adapter,
        item: item,
      );
    }

    final descriptor = AdapterRegistry.descriptorFor(sourceKey);
    if (descriptor == null) return null;
    final adapter = getBuiltinAdapter(descriptor.key);
    if (adapter == null) return null;
    return descriptor.buildPlayerData(adapter: adapter, item: item);
  }

  CustomSourceConfig? _resolveCustomSourceConfig(
    String sourceKey,
    Map<String, dynamic> item,
  ) {
    final sourceId = sourceKey.substring(
      AdapterRegistry.customSourcePrefix.length,
    );
    final current = _catalog.customSourceById(sourceId);
    if (current != null) return current;

    final sourceConfig = item['sourceConfig'];
    if (sourceConfig is CustomSourceConfig) {
      return _catalog.customSourceById(sourceConfig.id) ?? sourceConfig;
    }
    return null;
  }

  AdapterBase? _getOrCreateAdapter(
    String sourceKey, {
    required DateTime? revision,
    required AdapterBase? Function() create,
  }) {
    final cached = _adapterCache.remove(sourceKey);
    if (cached != null && cached.revision == revision) {
      // Re-insert moves entry to MRU end (LinkedHashMap order).
      _adapterCache[sourceKey] = cached;
      return cached.adapter;
    }
    cached?.adapter.dispose();

    final adapter = create();
    if (adapter == null) return null;

    while (_adapterCache.length >= _maxCachedAdapters) {
      final oldest = _adapterCache.keys.first;
      _adapterCache.remove(oldest)?.adapter.dispose();
    }
    _adapterCache[sourceKey] = (adapter: adapter, revision: revision);
    return adapter;
  }

  void _removeAdapter(String key) {
    _adapterCache.remove(key)?.adapter.dispose();
  }

  void _removeAdaptersWhere(bool Function(String key) test) {
    _adapterCache.removeWhere((key, entry) {
      if (!test(key)) return false;
      entry.adapter.dispose();
      return true;
    });
  }
}

/// Shared catalog of builtin enable/order state and custom sources.
///
/// Derived views are rebuilt only on mutation, not on every read.
class SourceCatalog extends ChangeNotifier {
  static const String _disabledKeysKey = 'disabled_builtin_sources';
  static const String _orderKeysKey = 'ordered_builtin_sources';
  static const String _customSourcesKey = 'custom_sources';
  static const String _builtinOverridesKey = 'builtin_source_overrides';

  SourceCatalog._() {
    _disabledKeys = Instances.sp.getStringList(_disabledKeysKey)?.toSet() ?? {};
    final usedKeys = <String>{};
    final ordered = <AdapterDescriptor>[];
    for (final key
        in Instances.sp.getStringList(_orderKeysKey) ?? const <String>[]) {
      final source = AdapterRegistry.descriptorFor(key);
      if (source != null && usedKeys.add(key)) ordered.add(source);
    }
    for (final source in AdapterRegistry.builtinSources) {
      if (usedKeys.add(source.key)) ordered.add(source);
    }
    _allSources = List<AdapterDescriptor>.unmodifiable(ordered);
    _customSourcesView = UnmodifiableListView<CustomSourceConfig>(
      _customSources,
    );
    _rebuildBuiltinViews();
  }

  static final SourceCatalog instance = SourceCatalog._();

  late Set<String> _disabledKeys;
  late List<AdapterDescriptor> _allSources;
  late List<AdapterDescriptor> _enabledBuiltin;

  final List<CustomSourceConfig> _customSources = <CustomSourceConfig>[];
  final Map<String, CustomSourceConfig> _builtinOverrides =
      <String, CustomSourceConfig>{};
  final Map<String, CustomSourceConfig> _bundledConfigCache =
      <String, CustomSourceConfig>{};
  late final List<CustomSourceConfig> _customSourcesView;
  final Map<String, int> _customIndexById = <String, int>{};
  final Map<String, int> _customIndexByName = <String, int>{};
  List<CustomSourceConfig> _enabledCustom = const [];
  Future<void>? _initialization;

  List<AdapterDescriptor> get builtinSources => _allSources;
  List<AdapterDescriptor> get enabledBuiltinSources => _enabledBuiltin;
  List<AdapterDescriptor> get quickSearchSources => _enabledBuiltin;

  bool isBuiltinEnabled(String key) => !_disabledKeys.contains(key);

  Future<void> toggleBuiltinSource(String key) =>
      setBuiltinEnabled(key, !isBuiltinEnabled(key));

  Future<void> setBuiltinEnabled(String key, bool enabled) async {
    final changed = enabled
        ? _disabledKeys.remove(key)
        : _disabledKeys.add(key);
    if (!changed) return;
    _rebuildBuiltinViews();
    await Instances.sp.setStringList(
      _disabledKeysKey,
      _disabledKeys.toList(growable: false),
    );
  }

  Future<void> enableAllBuiltins() async {
    if (_disabledKeys.isEmpty) return;
    _disabledKeys.clear();
    _rebuildBuiltinViews();
    await Instances.sp.setStringList(_disabledKeysKey, const <String>[]);
  }

  Future<void> reorderBuiltinSource(int oldIndex, int newIndex) async {
    final next = _reorderList(_allSources, oldIndex, newIndex);
    if (next == null) return;
    _allSources = List<AdapterDescriptor>.unmodifiable(next);
    _rebuildBuiltinViews();
    await Instances.sp.setStringList(
      _orderKeysKey,
      next.map((item) => item.key).toList(growable: false),
    );
  }

  void _rebuildBuiltinViews() {
    final enabled = <AdapterDescriptor>[];
    for (final source in _allSources) {
      if (_disabledKeys.contains(source.key)) continue;
      enabled.add(source);
    }
    _enabledBuiltin = List<AdapterDescriptor>.unmodifiable(enabled);
  }

  Future<void> init() => _initialization ??= _loadSources();

  Future<void> _loadSources() async {
    var legacyCleaned = false;
    final storedOverrides = AppStorage.customSourcesBox.get(
      _builtinOverridesKey,
    );
    if (storedOverrides is List) {
      for (final json in storedOverrides.whereType<Map>()) {
        final source = CustomSourceConfig.fromJson(
          Map<String, dynamic>.from(json),
        );
        if (AdapterRegistry.isBuiltinSource(source.id)) {
          if (source.id == 'cycani' && _isLegacyCycaniConfig(source)) {
            legacyCleaned = true;
            continue;
          }
          _builtinOverrides[source.id] = source;
        }
      }
    }

    final storedSources = AppStorage.customSourcesBox.get(_customSourcesKey);
    if (storedSources is List) {
      var migratedBuiltin = false;
      for (final json in storedSources.whereType<Map>()) {
        final source = CustomSourceConfig.fromJson(
          Map<String, dynamic>.from(json),
        );
        if (AdapterRegistry.isBuiltinSource(source.id)) {
          if (source.id == 'cycani' && _isLegacyCycaniConfig(source)) {
            legacyCleaned = true;
            continue;
          }
          final current = _builtinOverrides[source.id];
          if (current == null || source.updatedAt.isAfter(current.updatedAt)) {
            _builtinOverrides[source.id] = source;
          }
          migratedBuiltin = true;
        } else {
          _customSources.add(source);
        }
      }
      if (migratedBuiltin || legacyCleaned) {
        await _commit();
        return;
      }
    }
    if (legacyCleaned) {
      await _commit();
      return;
    }
    _rebuildCustomIndex();
  }

  Future<void> _commit() async {
    _rebuildCustomIndex();
    await Future.wait<void>([
      AppStorage.customSourcesBox.put(
        _customSourcesKey,
        _customSources.map((s) => s.toJson()).toList(growable: false),
      ),
      AppStorage.customSourcesBox.put(
        _builtinOverridesKey,
        _builtinOverrides.values.map((s) => s.toJson()).toList(growable: false),
      ),
    ]);
    notifyListeners();
  }

  void _rebuildCustomIndex() {
    _customIndexById.clear();
    _customIndexByName.clear();
    final enabled = <CustomSourceConfig>[];
    for (var i = 0; i < _customSources.length; i++) {
      final source = _customSources[i];
      _customIndexById[source.id] = i;
      _customIndexByName[source.name] = i;
      if (source.enabled) enabled.add(source);
    }
    _enabledCustom = List<CustomSourceConfig>.unmodifiable(enabled);
  }

  List<CustomSourceConfig> get customSources => _customSourcesView;

  List<CustomSourceConfig> get enabledCustomSources => _enabledCustom;

  CustomSourceConfig? customSourceById(String id) {
    final index = _customIndexById[id];
    return index == null ? null : _customSources[index];
  }

  CustomSourceConfig? customSourceByName(String name) {
    final index = _customIndexByName[name];
    return index == null ? null : _customSources[index];
  }

  CustomSourceConfig? builtinOverrideById(String key) => _builtinOverrides[key];

  /// 内置源的只读配置视图。
  /// （override 命中优先于查表，更新/重置只写 _builtinOverrides）。
  CustomSourceConfig? builtinSourceById(String key) {
    final override = _builtinOverrides[key];
    if (override != null) return override;

    final cached = _bundledConfigCache[key];
    if (cached != null) return cached;

    final rule = BundledRuleStore.ruleFor(key);
    if (rule == null) return null;
    return _bundledConfigCache[key] = CustomSourceConfig.fromJson(rule.toJson());
  }

  Future<bool> updateBuiltinSource(
    String key,
    CustomSourceConfig source,
  ) async {
    if (!AdapterRegistry.isBuiltinSource(key) || source.id != key) return false;
    final validation = RuleValidator.validate(
      RuleMigrator.ruleForConfig(source),
    );
    if (!validation.isValid) return false;
    _builtinOverrides[key] = source.copyWith(updatedAt: DateTime.now());
    await _commit();
    return true;
  }

  Future<bool> resetBuiltinSource(String key) async {
    if (_builtinOverrides.remove(key) == null) return false;
    await _commit();
    return true;
  }

  Future<bool> addCustomSource(CustomSourceConfig source) async {
    if (_customIndexById.containsKey(source.id)) return false;
    _customSources.add(source);
    await _commit();
    return true;
  }

  Future<bool> updateCustomSource(CustomSourceConfig source) async {
    final index = _customIndexById[source.id];
    if (index == null) return false;
    _customSources[index] = source.copyWith(updatedAt: DateTime.now());
    await _commit();
    return true;
  }

  Future<bool> deleteCustomSource(String id) async {
    final index = _customIndexById[id];
    if (index == null) return false;
    _customSources.removeAt(index);
    await _commit();
    return true;
  }

  Future<bool> reorderCustomSource(int oldIndex, int newIndex) async {
    final next = _reorderList(_customSources, oldIndex, newIndex);
    if (next == null) return false;
    _customSources
      ..clear()
      ..addAll(next);
    await _commit();
    return true;
  }

  Future<int> setAllCustomSourcesEnabled(bool enabled) async {
    final now = DateTime.now();
    var updatedCount = 0;
    for (var i = 0; i < _customSources.length; i++) {
      final source = _customSources[i];
      if (source.enabled == enabled) continue;
      _customSources[i] = source.copyWith(enabled: enabled, updatedAt: now);
      updatedCount++;
    }
    if (updatedCount == 0) return 0;
    await _commit();
    return updatedCount;
  }

  Future<int> importCustomSource(String input) async {
    try {
      final decoded = SourceCodec.decode(input.trim());
      final items = switch (decoded) {
        Map() => <Map>[decoded],
        List() => decoded.whereType<Map>(),
        _ => const <Map>[],
      };
      final now = DateTime.now();
      var count = 0;
      for (final item in items) {
        try {
          final source = _sourceFromJson(Map<String, dynamic>.from(item));
          if (AdapterRegistry.isBuiltinSource(source.id)) {
            _builtinOverrides[source.id] = source.copyWith(updatedAt: now);
            count++;
            continue;
          }
          final index = _customIndexById[source.id];
          if (index == null) {
            _customIndexById[source.id] = _customSources.length;
            _customSources.add(source);
          } else {
            _customSources[index] = source.copyWith(updatedAt: now);
          }
          count++;
        } catch (e) {
          debugPrint('[SourceCatalog] 跳过无效规则: $e');
        }
      }
      if (count > 0) await _commit();
      return count;
    } catch (e) {
      debugPrint('[SourceCatalog] 导入失败: $e');
      return 0;
    }
  }

  CustomSourceConfig _sourceFromJson(Map<String, dynamic> json) {
    final config = CustomSourceConfig.fromJson(json);
    final validation = RuleValidator.validate(
      RuleMigrator.ruleForConfig(config),
    );
    if (!validation.isValid) {
      throw FormatException('规则校验失败: ${validation.errors.join('; ')}');
    }
    return config;
  }

  Future<void> clearCustomSources() async {
    if (_customSources.isEmpty) return;
    _customSources.clear();
    await _commit();
  }

  /// Shared list reorder used by builtin and custom sources.
  /// Returns null when indices are invalid / no-op.
  static List<T>? _reorderList<T>(List<T> list, int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= list.length) return null;
    var target = newIndex;
    if (target > list.length) target = list.length;
    if (oldIndex < target) target -= 1;
    if (target < 0 || target >= list.length || oldIndex == target) return null;
    final copy = List<T>.of(list);
    final item = copy.removeAt(oldIndex);
    copy.insert(target, item);
    return copy;
  }

  static bool _isLegacyCycaniConfig(CustomSourceConfig config) {
    final rawJson = jsonEncode(config.toJson());
    return rawJson.contains('/search/wd/') ||
        rawJson.contains('playerDecrypt') ||
        rawJson.contains('/search/{keyword}') ||
        !rawJson.contains('/api/videos/');
  }
}
