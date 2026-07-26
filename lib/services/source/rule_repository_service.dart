import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:baka/instance.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/source/store/bundled_rule_store.dart';

enum RuleInstallResult { added, updated, failed }

enum InstallStatus { notInstalled, upToDate, updateAvailable }

typedef RuleInstallInfo = ({CustomSourceConfig? source, InstallStatus status});

/// 规则仓库门面：管理订阅、索引缓存、规则解析和安装。
class RuleRepositoryService extends ChangeNotifier {
  RuleRepositoryService._();

  static final RuleRepositoryService instance = RuleRepositoryService._();

  static const String directSubscription =
      'https://raw.githubusercontent.com/AniBakaBaka/AniBakaRule/main/index.json';
  static const String jsDelivrSubscription =
      'https://cdn.jsdelivr.net/gh/AniBakaBaka/AniBakaRule@main/index.json';
  static const String githubAcceleratorPrefix = 'https://gh.dpik.top/';
  static const String acceleratedSubscription =
      '${githubAcceleratorPrefix}https://raw.githubusercontent.com/AniBakaBaka/AniBakaRule/main/index.json';
  static const String remoteSubscription = acceleratedSubscription;
  static const String assetScheme = 'asset://';
  static const String defaultSubscription = remoteSubscription;

  static const _subscriptionsKey = 'rule_hub_subscriptions';
  static const _cacheKeyPrefix = 'rule_hub_cache:';
  static const _versionKeyPrefix = 'rule_hub_version:';
  static const _sourceIdKeyPrefix = 'rule_hub_source_id:';
  static const _cacheTtl = Duration(minutes: 10);

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
      headers: const {'Accept': 'application/json, text/plain, */*'},
    ),
  );
  final Map<String, ({RuleHubIndex index, int expiresAt})> _memoryCache = {};

  List<String> get subscriptions => List.unmodifiable(_storedSubscriptions());

  Future<bool> addSubscription(String url) async {
    final normalized = _canonicalUrl(url.trim());
    if (!_isHttpUrl(normalized)) return false;

    final subscriptions = _storedSubscriptions();
    if (subscriptions.contains(normalized)) return false;

    subscriptions.add(normalized);
    await Instances.sp.setStringList(_subscriptionsKey, subscriptions);
    notifyListeners();
    return true;
  }

  Future<bool> removeSubscription(String url) async {
    final normalized = _canonicalUrl(url);
    final subscriptions = _storedSubscriptions();
    if (!subscriptions.remove(normalized)) return false;

    await Instances.sp.setStringList(_subscriptionsKey, subscriptions);
    await Instances.sp.remove('$_cacheKeyPrefix$normalized');
    _memoryCache
      ..remove(url)
      ..remove(normalized);
    notifyListeners();
    return true;
  }

  Future<List<RuleHubIndex>> fetchAll({bool forceRefresh = false}) async {
    final indices = <RuleHubIndex>[];
    for (final url in subscriptions) {
      try {
        indices.add(await fetchIndex(url, forceRefresh: forceRefresh));
      } catch (error) {
        debugPrint('[RuleHub] 拉取订阅失败 $url: $error');
      }
    }
    return indices;
  }

  Future<RuleHubIndex> fetchIndex(
    String url, {
    bool forceRefresh = false,
  }) async {
    url = _canonicalUrl(url);
    final local = _isLocalUrl(url);
    final cached = _memoryCache[url];
    if (!forceRefresh &&
        !local &&
        cached != null &&
        DateTime.now().millisecondsSinceEpoch < cached.expiresAt) {
      return cached.index;
    }
    _memoryCache.remove(url);

    try {
      final body = await _getString(url, forceRefresh: forceRefresh);
      final index = _parseIndex(body, url);
      if (!local) {
        _memoryCache[url] = (
          index: index,
          expiresAt:
              DateTime.now().millisecondsSinceEpoch + _cacheTtl.inMilliseconds,
        );
        await Instances.sp.setString('$_cacheKeyPrefix$url', body);
      }
      return index;
    } catch (_) {
      if (!local) {
        final fallback = _loadPersistedIndex(url);
        if (fallback != null) {
          debugPrint('[RuleHub] 网络失败，使用本地缓存 $url');
          return fallback;
        }
      }
      rethrow;
    }
  }

  Future<CustomSourceConfig> resolveConfig(
    RuleHubItem item, {
    required String indexUrl,
    bool forceRefresh = false,
  }) async {
    final encoded = item.config?.trim();
    if (encoded != null && encoded.isNotEmpty) {
      return _decodeConfig(SourceCodec.decode(encoded), item);
    }

    final inline = item.inline;
    if (inline != null && inline.isNotEmpty) {
      return _configFromJson(inline, item);
    }

    final file = item.file?.trim();
    if (file == null || file.isEmpty) {
      throw const FormatException('该规则没有可解析的配置');
    }

    final body = await _getString(
      resolveRuleUrl(indexUrl, file),
      forceRefresh: forceRefresh,
    );
    return _decodeConfig(SourceCodec.decode(body.trim()), item);
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
      final service = SourceAdapterService.instance;
      await service.init();

      final builtinKey = AdapterRegistry.isBuiltinSource(item.id)
          ? item.id
          : (AdapterRegistry.isBuiltinSource(config.id) ? config.id : null);
      if (builtinKey != null) {
        final updated = await service.updateBuiltinSource(
          builtinKey,
          config.copyWith(id: builtinKey),
        );
        if (!updated) return RuleInstallResult.failed;
        await _saveInstalledState(item, builtinKey);
        return RuleInstallResult.updated;
      }

      final existing = _findInstalledSource(item, config: config);
      final now = DateTime.now();
      final next = existing == null
          ? config.copyWith(updatedAt: now)
          : config.copyWith(
              id: existing.id,
              enabled: existing.enabled,
              createdAt: existing.createdAt,
              updatedAt: now,
            );
      final installed = existing == null
          ? await service.addCustomSource(next)
          : await service.updateCustomSource(next);

      if (!installed) return RuleInstallResult.failed;
      await _saveInstalledState(item, next.id);
      return existing == null
          ? RuleInstallResult.added
          : RuleInstallResult.updated;
    } catch (error) {
      debugPrint('[RuleHub] 安装失败 ${item.name}: $error');
      return RuleInstallResult.failed;
    }
  }

  /// 一次建立本地图源索引，再批量检查规则安装状态。
  Map<RuleHubItem, RuleInstallInfo> inspectItems(Iterable<RuleHubItem> items) {
    final installed = _InstalledSourceIndex(
      SourceCatalog.instance.customSources,
    );
    final result = Map<RuleHubItem, RuleInstallInfo>.identity();

    for (final item in items) {
      final storageKey = _storageKey(item);
      final builtin = AdapterRegistry.isBuiltinSource(item.id);
      final mappedId = storageKey == null
          ? null
          : Instances.sp.getString('$_sourceIdKeyPrefix$storageKey')?.trim();
      final source = builtin
          ? SourceCatalog.instance.builtinSourceById(item.id)
          : installed.find(item, mappedId: mappedId);
      final version = storageKey == null
          ? 0
          : Instances.sp.getInt('$_versionKeyPrefix$storageKey') ??
                (builtin ? BundledRuleStore.versionFor(item.id) : 0);
      result[item] = (
        source: source,
        status: source == null
            ? InstallStatus.notInstalled
            : version < item.version
            ? InstallStatus.updateAvailable
            : InstallStatus.upToDate,
      );
    }
    return result;
  }

  Future<void> _saveInstalledState(RuleHubItem item, String sourceId) async {
    final storageKey = _storageKey(item);
    if (storageKey == null) return;

    await Instances.sp.setInt('$_versionKeyPrefix$storageKey', item.version);
    await Instances.sp.setString('$_sourceIdKeyPrefix$storageKey', sourceId);
  }

  CustomSourceConfig? _findInstalledSource(
    RuleHubItem item, {
    CustomSourceConfig? config,
  }) {
    final catalog = SourceCatalog.instance;
    final storageKey = _storageKey(item);
    final mappedId = storageKey == null
        ? null
        : Instances.sp.getString('$_sourceIdKeyPrefix$storageKey')?.trim();

    if (mappedId?.isNotEmpty ?? false) {
      final source = catalog.customSourceById(mappedId!);
      if (source != null) return source;
    }

    final itemId = item.id.trim();
    if (itemId.isNotEmpty) {
      final source = catalog.customSourceById(itemId);
      if (source != null) return source;
    }
    final configId = config?.id.trim();
    if (configId?.isNotEmpty ?? false) {
      final source = catalog.customSourceById(configId!);
      if (source != null) return source;
    }

    final itemName = item.name.trim();
    if (itemName.isNotEmpty) {
      final source = catalog.customSourceByName(itemName);
      if (source != null) return source;
    }
    final configName = config?.name.trim();
    if (configName?.isNotEmpty ?? false) {
      final source = catalog.customSourceByName(configName!);
      if (source != null) return source;
    }

    final itemUrl = item.baseUrl?.trim();
    final configUrl = config?.baseUrl.trim();
    for (final source in catalog.customSources) {
      final url = source.baseUrl.trim();
      if ((itemUrl?.isNotEmpty ?? false) && url == itemUrl) return source;
      if ((configUrl?.isNotEmpty ?? false) && url == configUrl) return source;
    }
    return null;
  }

  String? _storageKey(RuleHubItem item) {
    final id = item.id.trim();
    if (id.isNotEmpty) return id;

    final name = item.name.trim();
    final baseUrl = item.baseUrl?.trim();
    final file = item.file?.trim();
    final parts = <String>[
      if (name.isNotEmpty) 'name:$name',
      if (baseUrl?.isNotEmpty ?? false) 'site:$baseUrl',
      if (file?.isNotEmpty ?? false) 'ref:$file',
    ];
    if (parts.isEmpty) return null;
    return _base64Url(utf8.encode(parts.join('|')));
  }

  CustomSourceConfig _decodeConfig(Object? decoded, RuleHubItem item) {
    if (decoded is Map) {
      return _configFromJson(Map<String, dynamic>.from(decoded), item);
    }
    if (decoded is List) {
      for (final value in decoded) {
        if (value is Map) {
          return _configFromJson(Map<String, dynamic>.from(value), item);
        }
      }
      throw const FormatException('编码配置为空');
    }
    throw const FormatException('编码配置格式无效');
  }

  CustomSourceConfig _configFromJson(
    Map<String, dynamic> json,
    RuleHubItem item,
  ) {
    final config = Map<String, dynamic>.from(json);
    final itemId = item.id.trim();
    final configId = config['id']?.toString().trim();
    final generatedKey =
        _storageKey(item) ?? _base64Url(utf8.encode(item.installKey));
    config['id'] = itemId.isNotEmpty
        ? itemId
        : configId?.isNotEmpty == true
        ? configId
        : 'rule_$generatedKey';

    final name = config['name']?.toString().trim();
    if (name == null || name.isEmpty) config['name'] = item.name;

    final baseUrl = config['baseUrl']?.toString().trim();
    if ((baseUrl == null || baseUrl.isEmpty) && item.baseUrl != null) {
      config['baseUrl'] = item.baseUrl;
    }
    final iconUrl = config['iconUrl']?.toString().trim();
    if ((iconUrl == null || iconUrl.isEmpty) && item.iconUrl != null) {
      config['iconUrl'] = item.iconUrl;
    }
    return CustomSourceConfig.fromJson(config);
  }

  RuleHubIndex _parseIndex(String body, String url) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('规则库索引格式无效');
    }
    return RuleHubIndex.fromJson(decoded, sourceUrl: url);
  }

  RuleHubIndex? _loadPersistedIndex(String url) {
    final body = Instances.sp.getString('$_cacheKeyPrefix$url');
    if (body == null || body.isEmpty) return null;
    try {
      return _parseIndex(body, url);
    } catch (_) {
      return null;
    }
  }

  Future<String> _getString(String url, {bool forceRefresh = false}) async {
    if (url.startsWith(assetScheme)) {
      return rootBundle.loadString(url.substring(assetScheme.length).trim());
    }

    final options = forceRefresh
        ? Options(
            headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
          )
        : null;
    Object? lastError;
    for (final candidate in _candidateUrls(url, forceRefresh)) {
      try {
        final body = (await _dio.get<String>(candidate, options: options)).data;
        if (body == null || body.trim().isEmpty) {
          throw const FormatException('远程返回空内容');
        }
        return body;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError ?? const FormatException('远程返回空内容');
  }

  static List<String> _candidateUrls(String url, bool forceRefresh) {
    final primary = _canonicalUrl(url);
    final direct = _toRawGitHubUrl(primary);
    final jsDelivr = _toJsDelivrUrl(direct ?? primary);
    final github = _toGitHubRepositoryUrl(direct ?? primary);
    final candidates = <String>[
      primary,
      if (jsDelivr != null && jsDelivr != primary) jsDelivr,
      if (direct != null && direct != primary) direct,
      if (github != null && github != primary) github,
    ];
    return forceRefresh
        ? candidates.map(_cacheBustedUrl).toList(growable: false)
        : candidates;
  }

  static String _cacheBustedUrl(String url) {
    final uri = Uri.parse(url);
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParameters,
            '_AniBaka_t': DateTime.now().millisecondsSinceEpoch.toString(),
          },
        )
        .toString();
  }

  /// Moves the old official Raw subscription to the accelerated default while
  /// leaving user-added repositories untouched.
  static String? _migrateLegacySubscription(String url) {
    if (url == directSubscription || url == jsDelivrSubscription) {
      return acceleratedSubscription;
    }
    return null;
  }

  static String? _toRawGitHubUrl(String url) {
    if (url.startsWith(githubAcceleratorPrefix)) {
      return _toRawGitHubUrl(url.substring(githubAcceleratorPrefix.length));
    }

    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.host.toLowerCase() == 'raw.githubusercontent.com') {
      return url;
    }
    if (!uri.host.toLowerCase().contains('jsdelivr.net')) return null;

    final segments = uri.pathSegments;
    if (segments.length < 4 || segments.first != 'gh') return null;

    final user = segments[1];
    final repoAndRef = segments[2];
    final separator = repoAndRef.indexOf('@');
    final repo = separator < 0
        ? repoAndRef
        : repoAndRef.substring(0, separator);
    final ref = separator < 0 ? 'main' : repoAndRef.substring(separator + 1);
    final path = segments.skip(3).join('/');
    if (user.isEmpty || repo.isEmpty || ref.isEmpty || path.isEmpty) {
      return null;
    }

    return Uri.https(
      'raw.githubusercontent.com',
      '/$user/$repo/$ref/$path',
    ).toString();
  }

  static String? _toJsDelivrUrl(String url) {
    final raw = _toRawGitHubUrl(url);
    final uri = Uri.tryParse(raw ?? url);
    if (uri == null || uri.host.toLowerCase() != 'raw.githubusercontent.com') {
      return null;
    }

    final segments = uri.pathSegments;
    if (segments.length < 4) return null;
    final owner = segments[0];
    final repository = segments[1];
    final ref = segments[2];
    final path = segments.skip(3).join('/');
    if (owner.isEmpty || repository.isEmpty || ref.isEmpty || path.isEmpty) {
      return null;
    }
    return Uri.https(
      'cdn.jsdelivr.net',
      '/gh/$owner/$repository@$ref/$path',
    ).toString();
  }

  static String? _toGitHubRepositoryUrl(String url) {
    final raw = _toRawGitHubUrl(url);
    final uri = Uri.tryParse(raw ?? url);
    if (uri == null || uri.host.toLowerCase() != 'raw.githubusercontent.com') {
      return null;
    }

    final segments = uri.pathSegments;
    if (segments.length < 4) return null;
    final owner = segments[0];
    final repository = segments[1];
    final ref = segments[2];
    final path = segments.skip(3).join('/');
    if (owner.isEmpty || repository.isEmpty || ref.isEmpty || path.isEmpty) {
      return null;
    }
    return Uri.https(
      'github.com',
      '/$owner/$repository/raw/$ref/$path',
    ).toString();
  }

  static String resolveRuleUrl(String indexUrl, String relative) {
    if (_isHttpUrl(relative)) return relative;
    final canonicalIndex = _canonicalUrl(indexUrl);
    if (canonicalIndex.startsWith(githubAcceleratorPrefix)) {
      final directIndex = canonicalIndex.substring(
        githubAcceleratorPrefix.length,
      );
      return '$githubAcceleratorPrefix${Uri.parse(directIndex).resolve(relative)}';
    }
    return Uri.parse(canonicalIndex).resolve(relative).toString();
  }

  static List<String> _storedSubscriptions() {
    final stored = Instances.sp.getStringList(_subscriptionsKey);
    final subscriptions = stored == null || stored.isEmpty
        ? const <String>[remoteSubscription]
        : stored;
    return subscriptions.map(_canonicalUrl).toSet().toList(growable: false);
  }

  static String _canonicalUrl(String url) =>
      _migrateLegacySubscription(url) ?? url;

  static bool _isHttpUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  static bool _isLocalUrl(String url) => url.startsWith(assetScheme);

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}

class _InstalledSourceIndex {
  _InstalledSourceIndex(Iterable<CustomSourceConfig> sources) {
    for (final source in sources) {
      byId[source.id] = source;
      byName.putIfAbsent(source.name, () => source);
      final url = source.baseUrl.trim();
      if (url.isNotEmpty) byUrl.putIfAbsent(url, () => source);
    }
  }

  final Map<String, CustomSourceConfig> byId = {};
  final Map<String, CustomSourceConfig> byName = {};
  final Map<String, CustomSourceConfig> byUrl = {};

  CustomSourceConfig? find(RuleHubItem item, {String? mappedId}) {
    CustomSourceConfig? source;

    if (mappedId != null && mappedId.isNotEmpty) {
      source = byId[mappedId];
      if (source != null) return source;
    }

    final itemId = item.id.trim();
    if (itemId.isNotEmpty) {
      source = byId[itemId];
      if (source != null) return source;
    }

    final itemName = item.name.trim();
    if (itemName.isNotEmpty) {
      source = byName[itemName];
      if (source != null) return source;
    }

    final itemUrl = item.baseUrl?.trim();
    return itemUrl?.isNotEmpty == true ? byUrl[itemUrl] : null;
  }
}
