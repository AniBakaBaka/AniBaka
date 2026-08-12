import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/services/source/rule_version_store.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/store/bundled_rule_store.dart';
import 'package:baka/source/store/rule_migrator.dart';

/// 适配器的创建、缓存与搜索/播放调用入口。
///
/// 只读的源配置查询请直连 [SourceCatalog.instance]；本服务保留会牵动
/// 适配器缓存失效的变更操作（增删改源、导入、重置）。
/// 所有调用方共享一个适配器 LRU，避免重复缓存 Cookie、DOM 和请求连接。
class SourceAdapterService {
  SourceAdapterService._() {
    _catalog.addListener(_pruneAdapters);
  }

  static final SourceAdapterService instance = SourceAdapterService._();
  static const int _maxCachedAdapters = 24;

  final SourceCatalog _catalog = SourceCatalog.instance;

  /// LinkedHashMap insertion order = LRU (re-insert on hit).
  final LinkedHashMap<String, ({AdapterBase adapter, DateTime? revision})>
  _adapterCache = LinkedHashMap();

  Future<void> init() async {
    await Future.wait<void>([BundledRuleStore.load(), _catalog.init()]);
  }

  AdapterBase? _createAdapterFor(String source) {
    if (AdapterRegistry.isCustomSource(source)) {
      final sourceId = source.substring(
        AdapterRegistry.customSourcePrefix.length,
      );
      final resolved = _catalog.customSourceById(sourceId);
      if (resolved == null) return null;
      return PipelineSourceAdapter(RuleMigrator.ruleForConfig(resolved));
    }

    final override = _catalog.builtinOverrideById(source);
    return override == null
        ? AdapterRegistry.createAdapter(source)
        : PipelineSourceAdapter(RuleMigrator.ruleForConfig(override));
  }

  AdapterBase? _builtinAdapter(String key) {
    final override = _catalog.builtinOverrideById(key);
    return _getOrCreateAdapter(
      key,
      revision: override?.updatedAt,
      create: () => _createAdapterFor(key),
    );
  }

  AdapterBase? _customAdapter(String id) {
    final config = _catalog.customSourceById(id);
    final sourceKey = AdapterRegistry.customSourceKey(id);
    if (config == null) {
      _removeAdapter(sourceKey);
      return null;
    }

    return _getOrCreateAdapter(
      sourceKey,
      revision: config.updatedAt,
      create: () => _createAdapterFor(sourceKey),
    );
  }

  Future<List<Map<String, dynamic>>> search(
    String sourceKey,
    String query, {
    String fallbackDescription = '',
    bool skipBgmEnhancement = false,
  }) async {
    final adapter = adapterFor(sourceKey);
    if (adapter == null) throw StateError('视频源不可用: $sourceKey');
    final displayName = _displayName(sourceKey);
    final results = await adapter.search(
      query,
      enhanceWithBgm: !skipBgmEnhancement,
    );
    return [
      for (final series in results)
        <String, dynamic>{
          'title': series.name,
          'seriesId': series.seriesId,
          'description': series.description ?? fallbackDescription,
          'subtitle': series.description ?? fallbackDescription,
          'image': series.image,
          'content': series.image,
          'source': sourceKey,
          'sourceDisplayName': displayName,
          'tag': displayName,
          if (series.bgmId != null) 'bgmId': series.bgmId,
          if (series.score != null) 'score': series.score,
          if (series.image?.isNotEmpty ?? false) 'bgmImageUrl': series.image,
        },
    ];
  }

  Future<Map<String, dynamic>?> buildPlayerData(
    Map<String, dynamic> item,
  ) async {
    final sourceKey = item['source']?.toString();
    if (sourceKey == null || sourceKey.isEmpty) return null;

    final adapter = adapterFor(sourceKey);
    if (adapter == null) throw StateError('视频源不可用: $sourceKey');
    final seriesId = item['seriesId'] as String;
    final catalog = await adapter.getPlaybackCatalog(seriesId);
    if (catalog.isEmpty) return null;

    final descriptor = AdapterRegistry.descriptorFor(sourceKey);
    final custom = AdapterRegistry.isCustomSource(sourceKey)
        ? _catalog.customSourceById(
            sourceKey.substring(AdapterRegistry.customSourcePrefix.length),
          )
        : null;
    final displayName = descriptor?.displayName ?? custom!.name;
    item
      ..['id'] =
          descriptor?.resolveNumericId(seriesId) ?? stableSourceId(seriesId)
      ..['seriesUrl'] = seriesId
      ..['currPlayIndex'] = 0
      ..['currUrl'] = 1
      ..['sourceDisplayName'] = displayName
      ..['sort'] = '番剧'
      ..['content'] = custom == null || custom.description.isEmpty
          ? '来源: $displayName'
          : custom.description
      ..['tag'] = displayName
      ..['videoList'] = catalog.episodes
      ..['sourceNames'] = catalog.sourceNames;
    return item;
  }

  /// 按 source key 取（或创建）缓存中的适配器实例。
  ///
  /// 与 [buildPlayerData] 共用同一 LRU 缓存，保证搜索/探针阶段的 Cookie
  /// 与后续 `resolvePlaybackMedia` 一致。
  AdapterBase? adapterFor(String sourceKey) {
    if (sourceKey.isEmpty || sourceKey == 'internal') return null;

    if (AdapterRegistry.isCustomSource(sourceKey)) {
      return _customAdapter(
        sourceKey.substring(AdapterRegistry.customSourcePrefix.length),
      );
    }

    return _builtinAdapter(sourceKey);
  }

  String _displayName(String sourceKey) {
    final builtin = AdapterRegistry.descriptorFor(sourceKey);
    if (builtin != null) return builtin.displayName;
    final id = sourceKey.substring(AdapterRegistry.customSourcePrefix.length);
    return _catalog.customSourceById(id)!.name;
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

  void _pruneAdapters() {
    _adapterCache.removeWhere((key, entry) {
      final revision = AdapterRegistry.isCustomSource(key)
          ? _catalog
                .customSourceById(
                  key.substring(AdapterRegistry.customSourcePrefix.length),
                )
                ?.updatedAt
          : _catalog.builtinOverrideById(key)?.updatedAt;
      if (revision == entry.revision) return false;
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
    var storageChanged = false;
    final staleVersionKeys = <String>[];

    void loadBuiltinOverride(CustomSourceConfig source) {
      if (_bundledRuleReplacesKnownLegacyOverride(source)) {
        storageChanged = true;
        staleVersionKeys.add(ruleHubVersionKey(source.id));
        return;
      }
      final current = _builtinOverrides[source.id];
      if (current == null || source.updatedAt.isAfter(current.updatedAt)) {
        _builtinOverrides[source.id] = source;
      }
    }

    final storedOverrides = AppStorage.customSourcesBox.get(
      _builtinOverridesKey,
    );
    if (storedOverrides is List) {
      for (final json in storedOverrides.whereType<Map>()) {
        final source = CustomSourceConfig.fromJson(
          Map<String, dynamic>.from(json),
        );
        if (AdapterRegistry.isBuiltinSource(source.id)) {
          loadBuiltinOverride(source);
        }
      }
    }

    final storedSources = AppStorage.customSourcesBox.get(_customSourcesKey);
    if (storedSources is List) {
      for (final json in storedSources.whereType<Map>()) {
        final source = CustomSourceConfig.fromJson(
          Map<String, dynamic>.from(json),
        );
        if (AdapterRegistry.isBuiltinSource(source.id)) {
          loadBuiltinOverride(source);
          storageChanged = true;
        } else {
          _customSources.add(source);
        }
      }
    }

    if (staleVersionKeys.isNotEmpty) {
      await Future.wait(staleVersionKeys.toSet().map(Instances.sp.remove));
    }
    if (storageChanged) {
      await _commit();
      return;
    }
    _rebuildCustomIndex();
  }

  bool _bundledRuleReplacesKnownLegacyOverride(CustomSourceConfig source) {
    if (source.id != 'xifanacg') return false;
    final legacyHost = Uri.tryParse(source.baseUrl)?.host.toLowerCase();
    if (legacyHost != 'anime.xifanacg.com') return false;
    final installedVersion = Instances.sp.getInt(ruleHubVersionKey(source.id));
    return installedVersion == null ||
        BundledRuleStore.versionFor(source.id) > installedVersion;
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

  CustomSourceConfig? builtinOverrideById(String key) {
    final override = _builtinOverrides[key];
    if (override == null || _bundledRuleReplacesKnownLegacyOverride(override)) {
      return null;
    }
    return override;
  }

  /// 内置源的只读配置视图。
  /// （override 命中优先于查表，更新/重置只写 _builtinOverrides）。
  CustomSourceConfig? builtinSourceById(String key) {
    final override = builtinOverrideById(key);
    if (override != null) return override;

    final cached = _bundledConfigCache[key];
    if (cached != null) return cached;

    final rule = BundledRuleStore.ruleFor(key);
    if (rule == null) return null;
    return _bundledConfigCache[key] = CustomSourceConfig.fromJson(
      rule.toJson(),
    );
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
    if (newIndex < 0 || newIndex >= list.length || oldIndex == newIndex) {
      return null;
    }
    final copy = List<T>.of(list);
    final item = copy.removeAt(oldIndex);
    copy.insert(newIndex, item);
    return copy;
  }
}
