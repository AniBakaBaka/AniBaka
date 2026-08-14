import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:baka/instance.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/services/source/rule_version_store.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/source/store/bundled_rule_store.dart';

enum RuleInstallResult { added, updated, failed }

enum InstallStatus { notInstalled, upToDate, updateAvailable }

typedef RuleInstallInfo = ({CustomSourceConfig? source, InstallStatus status});

/// Official anx-rulehub/2 repository client and installer.
class RuleRepositoryService extends ChangeNotifier {
  RuleRepositoryService._();

  static final RuleRepositoryService instance = RuleRepositoryService._();

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

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
      headers: const {'Accept': 'application/json'},
    ),
  );
  final Map<String, ({RuleHubIndex index, int expiresAt})> _memoryCache = {};

  List<String> get subscriptions {
    final stored = Instances.sp.getStringList(_subscriptionsKey);
    final values = stored == null || stored.isEmpty
        ? const <String>[defaultSubscription]
        : stored;
    return {
      for (final value in values)
        _legacyOfficialSubscriptions.contains(value.trim())
            ? defaultSubscription
            : value.trim(),
    }.toList();
  }

  Future<bool> addSubscription(String url) async {
    final value = url.trim();
    if (!_isHttpUrl(value)) return false;
    final current = subscriptions;
    if (current.contains(value)) return false;
    current.add(value);
    await Instances.sp.setStringList(_subscriptionsKey, current);
    notifyListeners();
    return true;
  }

  Future<bool> removeSubscription(String url) async {
    final value = url.trim();
    final current = subscriptions;
    if (!current.remove(value)) return false;
    await Instances.sp.setStringList(_subscriptionsKey, current);
    await Instances.sp.remove('$_cacheKeyPrefix$value');
    _memoryCache.remove(value);
    notifyListeners();
    return true;
  }

  Future<List<RuleHubIndex>> fetchAll({bool forceRefresh = false}) async {
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
    return results.whereType<RuleHubIndex>().toList(growable: false);
  }

  Future<RuleHubIndex> fetchIndex(
    String url, {
    bool forceRefresh = false,
  }) async {
    final local = url.startsWith(assetScheme);
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _memoryCache[url];
    if (!forceRefresh && !local && cached != null && now < cached.expiresAt) {
      return cached.index;
    }

    try {
      final body = await _getString(url, forceRefresh: forceRefresh);
      final index = _parseIndex(body, url);
      if (!local) {
        _memoryCache[url] = (
          index: index,
          expiresAt: now + _cacheTtl.inMilliseconds,
        );
        await Instances.sp.setString('$_cacheKeyPrefix$url', body);
      }
      return index;
    } catch (_) {
      final persisted = local ? null : _loadPersistedIndex(url);
      if (persisted != null) return persisted;
      rethrow;
    }
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
      final adapters = SourceAdapterService.instance;
      await adapters.init();
      final catalog = SourceCatalog.instance;

      if (AdapterRegistry.isBuiltinSource(item.id)) {
        if (!await catalog.updateBuiltinSource(item.id, config)) {
          return RuleInstallResult.failed;
        }
        await _saveInstalledVersion(item);
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
      return existing == null
          ? RuleInstallResult.added
          : RuleInstallResult.updated;
    } catch (error) {
      debugPrint('[RuleHub] Failed to install ${item.name}: $error');
      return RuleInstallResult.failed;
    }
  }

  Map<RuleHubItem, RuleInstallInfo> inspectItems(Iterable<RuleHubItem> items) {
    final catalog = SourceCatalog.instance;
    final result = Map<RuleHubItem, RuleInstallInfo>.identity();
    for (final item in items) {
      final builtin = AdapterRegistry.isBuiltinSource(item.id);
      final source = builtin
          ? catalog.builtinSourceById(item.id)
          : catalog.customSourceById(item.id);
      final installedVersion =
          Instances.sp.getInt(ruleHubVersionKey(item.id)) ??
          (builtin ? BundledRuleStore.versionFor(item.id) : 0);
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

  Future<void> _saveInstalledVersion(RuleHubItem item) =>
      Instances.sp.setInt(ruleHubVersionKey(item.id), item.version);

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
