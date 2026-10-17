import 'package:baka/core/network_service.dart';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:baka/instance.dart';
import 'package:baka/api/request_cache.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/source/source_registry.dart';

enum RuleInstallResult { added, updated, failed }

enum InstallStatus { notInstalled, upToDate, updateAvailable }

typedef RuleInstallInfo = ({CustomSourceConfig? source, InstallStatus status});

/// Official anx-rulehub/2 repository client and installer.
late RuleRepositoryService ruleRepository;

class RuleRepositoryService extends ChangeNotifier {
  RuleRepositoryService(this.adapters, this.catalog) {
    catalog.addListener(_rebuildCatalog);
  }
  final SourceAdapterService adapters;
  final SourceCatalog catalog;
  List<RuleHubIndex> _indices = const [];
  RuleHubCatalog hubCatalog = const RuleHubCatalog.empty();
  final Set<String> _offlineSubscriptions = {};
  bool _disposed = false;
  int _fetchGeneration = 0;
  Future<void>? _checking;
  Future<void> _installQueue = Future.value();
  DateTime? _lastCheck;

  int get updateCount => hubCatalog.updates.length;
  bool get usingCachedIndices =>
      _offlineSubscriptions.any(subscriptions.contains);

  void _rebuildCatalog() {
    if (_disposed) return;
    hubCatalog = RuleHubCatalog.build(_indices, this);
    notifyListeners();
  }

  /// Called after startup and on resume. Never blocks launching the app.
  Future<void> checkForUpdates() {
    if (_disposed) return Future.value();
    if (_checking != null) return _checking!;
    final lastCheck = _lastCheck;
    if (lastCheck != null && DateTime.now().difference(lastCheck) < _cacheTtl) {
      return Future.value();
    }
    return _checking = _checkForUpdates().whenComplete(() => _checking = null);
  }

  Future<void> _checkForUpdates() async {
    try {
      await adapters.init();
      if (_disposed) return;
      if (_indices.isEmpty) {
        _indices = [for (final url in subscriptions) ?_loadPersistedIndex(url)];
        _rebuildCatalog();
      }
      await fetchAll();
    } catch (error) {
      debugPrint('[RuleHub] Update check failed: $error');
    }
  }

  static const String directSubscription =
      'https://raw.githubusercontent.com/AniBakaBaka/AniBakaRule/main/index.json';
  static const String githubMirrorPrefix = 'https://gh.dpik.top/';
  static const String mirrorSubscription =
      '$githubMirrorPrefix$directSubscription';
  static const String defaultSubscription = mirrorSubscription;
  static const String assetScheme = 'asset://';
  static const _subscriptionsKey = 'rule_hub_subscriptions';
  static const _cacheKeyPrefix = 'rule_hub_cache:';
  static const _cacheTtl = Duration(minutes: 10);

  static const _legacyOfficialSubscriptions = {
    'https://cdn.jsdelivr.net/gh/AniBakaBaka/AniBakaRule@main/index.json',
    directSubscription,
  };

  final Dio _dio = NetworkService.createDio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
      headers: const {'Accept': 'application/json'},
    ),
  );
  final _memoryCache = RequestCache<String, RuleHubIndex>(
    limit: 32,
    ttl: _cacheTtl,
  );

  @override
  void dispose() {
    _disposed = true;
    catalog.removeListener(_rebuildCatalog);
    _dio.close(force: true);
    _memoryCache.clear();
    super.dispose();
  }

  List<String> get subscriptions {
    final stored = Instances.sp.getStringList(_subscriptionsKey);
    final values = stored == null || stored.isEmpty
        ? const <String>[defaultSubscription]
        : stored;
    final set = <String>{};
    for (final value in values) {
      final trimmed = value.trim();
      set.add(
        _legacyOfficialSubscriptions.contains(trimmed)
            ? defaultSubscription
            : trimmed,
      );
    }
    return set.toList();
  }

  Future<bool> addSubscription(String url) async {
    final value = url.trim();
    if (!_isHttpUrl(value)) return false;
    final current = subscriptions;
    if (current.contains(value)) return false;
    current.add(value);
    _lastCheck = null;
    await Instances.sp.setStringList(_subscriptionsKey, current);
    notifyListeners();
    return true;
  }

  Future<bool> removeSubscription(String url) async {
    final value = url.trim();
    final current = subscriptions;
    if (!current.remove(value)) return false;
    _lastCheck = null;
    _memoryCache.remove(value);
    _indices = _indices.where((index) => index.sourceUrl != value).toList();
    _offlineSubscriptions.remove(value);
    await Instances.sp.setStringList(_subscriptionsKey, current);
    await Instances.sp.remove('$_cacheKeyPrefix$value');
    _rebuildCatalog();
    return true;
  }

  Future<List<RuleHubIndex>> fetchAll({bool forceRefresh = false}) async {
    final generation = ++_fetchGeneration;
    await adapters.init();
    if (_disposed) return const [];
    final results = await Future.wait([
      for (final url in subscriptions)
        fetchIndex(url, forceRefresh: forceRefresh).then<RuleHubIndex?>(
          (index) => index,
          onError: (Object error, StackTrace stack) {
            debugPrint('[RuleHub] Failed to fetch $url: $error');
            return null;
          },
        ),
    ]);
    final indices = results.whereType<RuleHubIndex>().toList(growable: false);
    if (!_disposed && generation == _fetchGeneration) {
      final active = subscriptions.toSet();
      _indices = indices
          .where((index) => active.contains(index.sourceUrl))
          .toList();
      _lastCheck = DateTime.now();
      _rebuildCatalog();
    }
    return indices;
  }

  Future<RuleHubIndex> fetchIndex(String url, {bool forceRefresh = false}) {
    final local = url.startsWith(assetScheme);
    return _memoryCache.get(url, () async {
      try {
        final body = await _getString(url, forceRefresh: forceRefresh);
        final index = _parseIndex(body, url);
        _offlineSubscriptions.remove(url);
        if (!local && subscriptions.contains(url)) {
          await Instances.sp.setString('$_cacheKeyPrefix$url', body);
        }
        return index;
      } catch (_) {
        _offlineSubscriptions.add(url);
        final persisted = local ? null : _loadPersistedIndex(url);
        if (persisted != null) return persisted;
        rethrow;
      }
    }, refresh: forceRefresh || local);
  }

  Future<CustomSourceConfig> resolveConfig(
    RuleHubItem item, {
    required String indexUrl,
    bool forceRefresh = false,
  }) async {
    final body = await _getString(
      resolveRuleUrl(indexUrl, item.file),
      forceRefresh: forceRefresh,
    );
    final decoded = SourceCodec.decode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Rule file must contain one JSON object');
    }
    final config = CustomSourceConfig.fromJson(decoded);
    if (config.id != item.id) {
      throw FormatException('Rule id ${config.id} does not match ${item.id}');
    }
    return config;
  }

  Future<RuleInstallResult> install(
    RuleHubItem item, {
    required String indexUrl,
  }) async {
    try {
      final config = await resolveConfig(
        item,
        indexUrl: indexUrl,
        forceRefresh: true,
      );
      await adapters.init();

      // Downloads may overlap, but each config and its revision must finish
      // saving before the next install reads or changes the catalog.
      final pending = _installQueue.then((_) => _installResolved(item, config));
      _installQueue = pending.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      );
      return await pending;
    } catch (error) {
      debugPrint('[RuleHub] Failed to install ${item.name}: $error');
      return RuleInstallResult.failed;
    }
  }

  Future<RuleInstallResult> _installResolved(
    RuleHubItem item,
    CustomSourceConfig config,
  ) async {
    if (AdapterRegistry.isBuiltinSource(item.id)) {
      if (!await catalog.updateBuiltinSource(
        item.id,
        config,
        revision: item.version,
      )) {
        return RuleInstallResult.failed;
      }
      return RuleInstallResult.updated;
    }

    final existing = catalog.customSourceById(item.id);
    final now = DateTime.now();
    final next = existing == null
        ? config.copyWith(updatedAt: now)
        : config.copyWith(
            enabled: existing.enabled,
            createdAt: existing.createdAt,
            updatedAt: now,
          );
    final installed = existing == null
        ? await catalog.addCustomSource(next)
        : await catalog.updateCustomSource(next);
    if (!installed) return RuleInstallResult.failed;
    await _saveInstalledVersion(item);
    _rebuildCatalog();
    return existing == null
        ? RuleInstallResult.added
        : RuleInstallResult.updated;
  }

  Map<RuleHubItem, RuleInstallInfo> inspectItems(Iterable<RuleHubItem> items) {
    final result = Map<RuleHubItem, RuleInstallInfo>.identity();
    for (final item in items) {
      final builtin = AdapterRegistry.isBuiltinSource(item.id);
      final source = builtin
          ? catalog.builtinSourceById(item.id)
          : catalog.customSourceById(item.id);
      final installedVersion = catalog.installedVersionFor(item.id);
      result[item] = (
        source: source,
        status: source == null
            ? InstallStatus.notInstalled
            : installedVersion < item.version
            ? InstallStatus.updateAvailable
            : InstallStatus.upToDate,
      );
    }
    return result;
  }

  Future<void> _saveInstalledVersion(RuleHubItem item) => Instances.sp.setInt(
    SourceCatalog.installedVersionKey(item.id),
    item.version,
  );

  RuleHubIndex _parseIndex(String body, String url) => RuleHubIndex.fromJson(
    jsonDecode(body) as Map<String, dynamic>,
    sourceUrl: url,
  );

  RuleHubIndex? _loadPersistedIndex(String url) {
    final body = Instances.sp.getString('$_cacheKeyPrefix$url');
    if (body == null) return null;
    try {
      return _parseIndex(body, url);
    } catch (_) {
      return null;
    }
  }

  Future<String> _getString(String url, {bool forceRefresh = false}) async {
    if (url.startsWith(assetScheme)) {
      return rootBundle.loadString(url.substring(assetScheme.length));
    }
    final options = forceRefresh
        ? Options(
            headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
          )
        : null;
    try {
      return await _downloadString(url, options);
    } catch (_) {
      final direct = _directMirrorTarget(url);
      if (direct == null) rethrow;
      return _downloadString(direct, options);
    }
  }

  Future<String> _downloadString(String url, Options? options) async {
    final response = await _dio.get<String>(url, options: options);
    final body = response.data;
    if (body == null || body.isEmpty) {
      throw const FormatException('Empty rule repository response');
    }
    return body;
  }

  static String resolveRuleUrl(String indexUrl, String relative) {
    if (_isHttpUrl(relative)) return relative;
    if (indexUrl.startsWith(assetScheme)) {
      final slash = indexUrl.lastIndexOf('/');
      return '${indexUrl.substring(0, slash + 1)}$relative';
    }
    final direct = _directMirrorTarget(indexUrl);
    if (direct != null) {
      return '$githubMirrorPrefix${Uri.parse(direct).resolve(relative)}';
    }
    return Uri.parse(indexUrl).resolve(relative).toString();
  }

  static String? _directMirrorTarget(String url) =>
      url.startsWith(githubMirrorPrefix)
      ? url.substring(githubMirrorPrefix.length)
      : null;

  static bool _isHttpUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }
}

class RuleHubCatalog {
  final Map<String, RuleHubEntry> installedBySourceId;
  final List<RuleHubEntry> available;
  final List<RuleHubEntry> installable;
  final List<RuleHubEntry> updates;

  const RuleHubCatalog.empty()
    : installedBySourceId = const {},
      available = const [],
      installable = const [],
      updates = const [];

  RuleHubCatalog({
    required this.installedBySourceId,
    required this.available,
    required this.installable,
    required this.updates,
  });

  factory RuleHubCatalog.build(
    List<RuleHubIndex> indices,
    RuleRepositoryService repo,
  ) {
    final rawRules = <({RuleHubItem item, String indexUrl})>[
      for (final index in indices)
        for (final item in index.rules) (item: item, indexUrl: index.sourceUrl),
    ];
    if (rawRules.isEmpty) return const RuleHubCatalog.empty();

    final inspected = repo.inspectItems(rawRules.map((rule) => rule.item));
    final installed = <String, RuleHubEntry>{};
    final available = <String, RuleHubEntry>{};

    for (final raw in rawRules) {
      final info = inspected[raw.item]!;
      final rule = RuleHubEntry(
        item: raw.item,
        indexUrl: raw.indexUrl,
        status: info.status,
      );
      final sourceId = info.source?.id;
      if (sourceId != null) {
        final current = installed[sourceId];
        if (current == null || current.item.version < rule.item.version) {
          installed[sourceId] = rule;
        }
        continue;
      }

      final key = rule.catalogKey;
      final current = available[key];
      if (current == null || current.item.version < rule.item.version) {
        available[key] = rule;
      }
    }

    final availableRules = List<RuleHubEntry>.unmodifiable(available.values);
    return RuleHubCatalog(
      installedBySourceId: Map<String, RuleHubEntry>.unmodifiable(installed),
      available: availableRules,
      updates: List<RuleHubEntry>.unmodifiable(
        installed.values.where(
          (rule) =>
              rule.status == InstallStatus.updateAvailable &&
              rule.item.hasResolvableConfig,
        ),
      ),
      installable: List<RuleHubEntry>.unmodifiable(
        availableRules.where((rule) => rule.item.hasResolvableConfig),
      ),
    );
  }
}

class RuleHubEntry {
  final RuleHubItem item;
  final String indexUrl;
  final InstallStatus status;

  const RuleHubEntry({
    required this.item,
    required this.indexUrl,
    required this.status,
  });

  String get catalogKey =>
      '${item.id}\n${item.name}\n${item.baseUrl ?? ''}\n${item.file}';

  String get operationKey => '$indexUrl\n${item.id}';
}
