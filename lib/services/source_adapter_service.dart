import 'dart:convert';
import 'dart:collection';

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

/// 图源状态与适配器调用门面。
///
/// 图源配置由所有实例共享；适配器按服务实例缓存，以隔离 Cookie 和请求状态。
class SourceAdapterService {
  SourceAdapterService();

  static final SourceAdapterService instance = SourceAdapterService();
  static const int _maxCachedAdapters = 24;

  final _SourceCatalog _catalog = _SourceCatalog.instance;
  final Map<String, ({AdapterBase adapter, DateTime? revision})> _adapterCache =
      {};

  Future<void> init() async {
    await Future.wait<void>([BundledRuleStore.load(), _catalog.init()]);
  }

  void dispose() {
    for (final entry in _adapterCache.values) {
      entry.adapter.dispose();
    }
    _adapterCache.clear();
  }

  Listenable get customSourcesListenable => _catalog;

  List<CustomSourceConfig> get allCustomSources => _catalog.customSources;

  List<CustomSourceConfig> get enabledCustomSources =>
      _catalog.enabledCustomSources;

  CustomSourceConfig? customSourceById(String id) =>
      _catalog.customSourceById(id);

  CustomSourceConfig? customSourceByName(String name) =>
      _catalog.customSourceByName(name);

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

  Future<bool> reorderCustomSource(int oldIndex, int newIndex) =>
      _catalog.reorderCustomSource(oldIndex, newIndex);

  Future<int> setAllCustomSourcesEnabled(bool enabled) =>
      _catalog.setAllCustomSourcesEnabled(enabled);

  Future<int> importCustomSource(String input) async {
    final count = await _catalog.importCustomSource(input);
    if (count > 0) {
      _removeAdaptersWhere(AdapterRegistry.isBuiltinSource);
    }
    return count;
  }

  String? exportCustomSource(String id) => _catalog.exportCustomSource(id);

  String? exportCustomSourceAsJson(String id) =>
      _catalog.exportCustomSourceAsJson(id);

  String exportAllCustomSources() => _catalog.exportAllCustomSources();

  Future<void> clearAllCustomSources() async {
    await _catalog.clearCustomSources();
    _removeAdaptersWhere(AdapterRegistry.isCustomSource);
  }

  List<AdapterDescriptor> get allBuiltinSources => _catalog.builtinSources;

  List<AdapterDescriptor> get enabledBuiltinSources =>
      _catalog.enabledBuiltinSources;

  List<AdapterDescriptor> get enabledQuickSearchSources =>
      _catalog.quickSearchSources;

  bool isBuiltinSourceEnabled(String key) => _catalog.isBuiltinEnabled(key);

  Future<void> toggleBuiltinSource(String key) =>
      _catalog.toggleBuiltinSource(key);

  Future<void> setBuiltinSourceEnabled(String key, bool enabled) =>
      _catalog.setBuiltinEnabled(key, enabled);

  Future<void> enableAllBuiltinSources() => _catalog.enableAllBuiltins();

  Future<void> disableAllBuiltinSources() => _catalog.disableAllBuiltins();

  Future<void> reorderBuiltinSource(int oldIndex, int newIndex) =>
      _catalog.reorderBuiltinSource(oldIndex, newIndex);

  CustomSourceConfig? builtinSourceById(String key) =>
      _catalog.builtinSourceById(key);

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

  AdapterBase? getBuiltinAdapter(String key) {
    final override = _catalog.builtinOverrideById(key);
    return _getOrCreateAdapter(
      key,
      revision: override?.updatedAt,
      create: () => override == null
          ? AdapterRegistry.createAdapter(key)
          : PipelineSourceAdapter(RuleMigrator.ruleForConfig(override)),
    );
  }

  AdapterBase? getCustomAdapter(CustomSourceConfig config) {
    final activeConfig = _catalog.customSourceById(config.id) ?? config;
    final sourceKey = AdapterRegistry.customSourceKey(activeConfig.id);

    return _getOrCreateAdapter(
      sourceKey,
      revision: activeConfig.updatedAt,
      create: () => AdapterRegistry.createAdapterForSource(
        sourceKey,
        customSourceConfig: activeConfig,
      ),
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
    if (sourceKey == null || sourceKey.isEmpty) {
      return null;
    }

    if (AdapterRegistry.isCustomSource(sourceKey)) {
      final config = _resolveCustomSourceConfig(sourceKey, item);
      if (config == null) {
        return null;
      }

      final adapter = getCustomAdapter(config);
      if (adapter == null) {
        return null;
      }

      return buildCustomSourcePlayerData(
        config: config,
        adapter: adapter,
        item: item,
      );
    }

    final descriptor = AdapterRegistry.descriptorFor(sourceKey);
    if (descriptor == null) {
      return null;
    }

    final adapter = getBuiltinAdapter(descriptor.key);
    if (adapter == null) {
      return null;
    }

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
      _adapterCache[sourceKey] = cached;
      return cached.adapter;
    }
    cached?.adapter.dispose();

    final adapter = create();
    if (adapter != null) {
      if (_adapterCache.length >= _maxCachedAdapters) {
        _removeAdapter(_adapterCache.keys.first);
      }
      _adapterCache[sourceKey] = (adapter: adapter, revision: revision);
    }
    return adapter;
  }

  void _removeAdapter(String key) {
    _adapterCache.remove(key)?.adapter.dispose();
  }

  void _removeAdaptersWhere(bool Function(String key) test) {
    final keys = _adapterCache.keys.where(test).toList(growable: false);
    for (final key in keys) {
      _removeAdapter(key);
    }
  }
}

class _SourceCatalog extends ChangeNotifier {
  static const String _disabledKeysKey = 'disabled_builtin_sources';
  static const String _orderKeysKey = 'ordered_builtin_sources';
  static const String _customSourcesKey = 'custom_sources';
  static const String _builtinOverridesKey = 'builtin_source_overrides';

  _SourceCatalog._() {
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
  }

  static final _SourceCatalog instance = _SourceCatalog._();

  late Set<String> _disabledKeys;
  late List<AdapterDescriptor> _allSources;

  List<AdapterDescriptor> get builtinSources => _allSources;

  List<AdapterDescriptor> get enabledBuiltinSources => [
    for (final source in _allSources)
      if (isBuiltinEnabled(source.key)) source,
  ];

  List<AdapterDescriptor> get quickSearchSources => [
    for (final source in _allSources)
      if (source.quickSearchEnabled && isBuiltinEnabled(source.key)) source,
  ];

  bool isBuiltinEnabled(String key) => !_disabledKeys.contains(key);

  Future<void> toggleBuiltinSource(String key) =>
      setBuiltinEnabled(key, !isBuiltinEnabled(key));

  Future<void> setBuiltinEnabled(String key, bool enabled) async {
    final changed = enabled
        ? _disabledKeys.remove(key)
        : _disabledKeys.add(key);
    if (!changed) return;
    await Instances.sp.setStringList(
      _disabledKeysKey,
      _disabledKeys.toList(growable: false),
    );
  }

  Future<void> enableAllBuiltins() async {
    if (_disabledKeys.isEmpty) return;
    _disabledKeys.clear();
    await Instances.sp.setStringList(_disabledKeysKey, const <String>[]);
  }

  Future<void> disableAllBuiltins() async {
    final keys = AdapterRegistry.builtinSources
        .map((source) => source.key)
        .toSet();
    if (_disabledKeys.length == keys.length &&
        _disabledKeys.containsAll(keys)) {
      return;
    }
    _disabledKeys = keys;
    await Instances.sp.setStringList(
      _disabledKeysKey,
      keys.toList(growable: false),
    );
  }

  Future<void> reorderBuiltinSource(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _allSources.length) return;
    if (newIndex > _allSources.length) newIndex = _allSources.length;
    if (oldIndex < newIndex) newIndex -= 1;
    if (newIndex < 0 ||
        newIndex >= _allSources.length ||
        oldIndex == newIndex) {
      return;
    }

    final sources = _allSources.toList(growable: true);
    final source = sources.removeAt(oldIndex);
    sources.insert(newIndex, source);
    _allSources = List<AdapterDescriptor>.unmodifiable(sources);
    await Instances.sp.setStringList(
      _orderKeysKey,
      sources.map((item) => item.key).toList(growable: false),
    );
  }

  final List<CustomSourceConfig> _customSources = <CustomSourceConfig>[];
  final Map<String, CustomSourceConfig> _builtinOverrides =
      <String, CustomSourceConfig>{};
  late final List<CustomSourceConfig> _customSourcesView;
  final Map<String, int> _customIndexById = <String, int>{};
  Future<void>? _initialization;

  Future<void> init() => _initialization ??= _loadSources();

  Future<void> _loadSources() async {
    final storedOverrides = AppStorage.customSourcesBox.get(
      _builtinOverridesKey,
    );
    if (storedOverrides is List) {
      for (final json in storedOverrides.whereType<Map>()) {
        final source = CustomSourceConfig.fromJson(
          Map<String, dynamic>.from(json),
        );
        if (AdapterRegistry.isBuiltinSource(source.id)) {
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
          final current = _builtinOverrides[source.id];
          if (current == null || source.updatedAt.isAfter(current.updatedAt)) {
            _builtinOverrides[source.id] = source;
          }
          migratedBuiltin = true;
        } else {
          _customSources.add(source);
        }
      }
      if (migratedBuiltin) await _commit();
    }
    _rebuildCustomIndex();
  }

  Future<void> _commit() async {
    _rebuildCustomIndex();
    await Future.wait<void>([
      AppStorage.customSourcesBox.put(
        _customSourcesKey,
        _customSources.map((source) => source.toJson()).toList(growable: false),
      ),
      AppStorage.customSourcesBox.put(
        _builtinOverridesKey,
        _builtinOverrides.values
            .map((source) => source.toJson())
            .toList(growable: false),
      ),
    ]);
    notifyListeners();
  }

  void _rebuildCustomIndex() {
    _customIndexById.clear();
    for (var i = 0; i < _customSources.length; i++) {
      _customIndexById[_customSources[i].id] = i;
    }
  }

  List<CustomSourceConfig> get customSources => _customSourcesView;

  List<CustomSourceConfig> get enabledCustomSources => [
    for (final source in _customSources)
      if (source.enabled) source,
  ];

  CustomSourceConfig? customSourceById(String id) {
    final index = _customIndexById[id];
    return index == null ? null : _customSources[index];
  }

  CustomSourceConfig? customSourceByName(String name) {
    for (final source in _customSources) {
      if (source.name == name) return source;
    }
    return null;
  }

  CustomSourceConfig? builtinOverrideById(String key) => _builtinOverrides[key];

  CustomSourceConfig? builtinSourceById(String key) {
    final override = _builtinOverrides[key];
    if (override != null) return override;
    final rule = BundledRuleStore.ruleFor(key);
    return rule == null ? null : CustomSourceConfig.fromJson(rule.toJson());
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
    if (oldIndex < 0 || oldIndex >= _customSources.length) return false;
    if (newIndex > _customSources.length) newIndex = _customSources.length;
    if (oldIndex < newIndex) newIndex -= 1;
    if (newIndex < 0 ||
        newIndex >= _customSources.length ||
        oldIndex == newIndex) {
      return false;
    }

    final source = _customSources.removeAt(oldIndex);
    _customSources.insert(newIndex, source);
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

  String? exportCustomSource(String id) {
    final source = customSourceById(id);
    if (source == null) return null;
    return _encodeToUri(<CustomSourceConfig>[source]);
  }

  String? exportCustomSourceAsJson(String id) {
    final source = customSourceById(id);
    if (source == null) return null;
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(source.toJson());
  }

  String exportAllCustomSources() => _encodeToUri(_customSources);

  String _encodeToUri(List<CustomSourceConfig> sources) {
    return SourceCodec.encode(
      sources.map((source) => source.toJson()).toList(growable: false),
    );
  }

  Future<void> clearCustomSources() async {
    if (_customSources.isEmpty) return;
    _customSources.clear();
    await _commit();
  }
}
