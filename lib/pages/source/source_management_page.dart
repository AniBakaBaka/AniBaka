import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/pages/source/custom_source_edit_page.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/common/skeletonizer.dart';
import 'package:baka/widgets/source/source_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SourceManagementPage extends StatefulWidget {
  const SourceManagementPage({super.key});

  @override
  State<SourceManagementPage> createState() => _SourceManagementPageState();
}

class _SourceManagementPageState extends State<SourceManagementPage> {
  final _sources = SourceAdapterService.instance;
  final _catalog = SourceCatalog.instance;
  final _repo = RuleRepositoryService.instance;
  final Set<String> _installing = <String>{};

  List<CustomSourceConfig> _customSources = const [];
  List<RuleHubIndex> _indices = const [];
  _HubCatalog _hubCatalog = const _HubCatalog.empty();

  bool _editing = false;
  bool _loadingSources = true;
  bool _loadingHub = true;
  bool _batchInstalling = false;
  String? _hubError;
  int _hubRequest = 0;

  @override
  void initState() {
    super.initState();
    _catalog.addListener(_onSourcesChanged);
    _loadData();
  }

  @override
  void dispose() {
    _catalog.removeListener(_onSourcesChanged);
    super.dispose();
  }

  void _onSourcesChanged() {
    if (!mounted) return;

    final sources = _catalog.customSources;
    if (_batchInstalling || _installing.isNotEmpty) {
      _customSources = sources;
      return;
    }

    setState(() {
      _customSources = sources;
      _hubCatalog = _HubCatalog.build(_indices, _repo);
    });
  }

  Future<void> _loadData() async {
    await Future.wait<void>([_loadSources(), _loadHub()]);
  }

  Future<void> _loadSources() async {
    await _sources.init();
    if (!mounted) return;

    setState(() {
      _customSources = _catalog.customSources;
      _hubCatalog = _HubCatalog.build(_indices, _repo);
      _loadingSources = false;
    });
  }

  Future<void> _loadHub({bool forceRefresh = false}) async {
    final request = ++_hubRequest;
    if (mounted) {
      setState(() {
        _loadingHub = true;
        _hubError = null;
      });
    }

    try {
      final indices = await _repo.fetchAll(forceRefresh: forceRefresh);
      if (!mounted || request != _hubRequest) return;

      setState(() {
        _indices = indices;
        _hubCatalog = _HubCatalog.build(indices, _repo);
        _loadingHub = false;
        _hubError = indices.isEmpty ? '没有可用的规则库，请检查订阅地址或网络。' : null;
      });
    } catch (error) {
      if (!mounted || request != _hubRequest) return;
      setState(() {
        _loadingHub = false;
        _hubError = '加载失败：$error';
      });
    }
  }

  Future<void> _openEditor([CustomSourceConfig? source]) async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CustomSourceEditPage(source: source)),
    );
  }

  Future<void> _toggleCustomSource(CustomSourceConfig source) async {
    HapticFeedback.lightImpact();
    await _sources.updateCustomSource(
      source.copyWith(enabled: !source.enabled),
    );
  }

  Future<void> _deleteSource(CustomSourceConfig source) async {
    HapticFeedback.heavyImpact();
    final confirmed = await showSourceConfirmDialog(
      context: context,
      title: '删除图源',
      content: '确定要删除“${source.name}”吗？\n此操作不可恢复。',
      confirmText: '删除',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    final deleted = await _sources.deleteCustomSource(source.id);
    if (!mounted) return;
    showSnackBar(deleted ? '已删除“${source.name}”' : '删除失败', isError: !deleted);
  }

  Future<void> _deleteAllCustomSources() async {
    final confirmed = await showSourceConfirmDialog(
      context: context,
      title: '删除全部自定义源',
      content: '这将清空所有已安装的自定义源，此操作不可恢复。',
      confirmText: '全部删除',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    await _sources.clearAllCustomSources();
    if (!mounted) return;
    setState(() => _editing = false);
    showSnackBar('已清空全部自定义源');
  }

  Future<void> _enableAllSources() async {
    HapticFeedback.mediumImpact();
    await _catalog.enableAllBuiltins();
    await _catalog.setAllCustomSourcesEnabled(true);
    if (mounted) setState(() {});
  }

  Future<void> _installRule(_HubRule rule) async {
    final key = rule.operationKey;
    if (_installing.contains(key)) return;

    HapticFeedback.mediumImpact();
    setState(() => _installing.add(key));
    final result = await _repo.install(rule.item, indexUrl: rule.indexUrl);
    if (!mounted) return;

    setState(() {
      _installing.remove(key);
      _customSources = _catalog.customSources;
      _hubCatalog = _HubCatalog.build(_indices, _repo);
    });

    switch (result) {
      case RuleInstallResult.added:
        showSnackBar('已安装“${rule.item.name}”');
        break;
      case RuleInstallResult.updated:
        showSnackBar('已更新“${rule.item.name}”');
        break;
      case RuleInstallResult.failed:
        showSnackBar('安装失败，配置可能无效', isError: true);
        break;
    }
  }

  Future<void> _installAllRules() async {
    if (_batchInstalling) return;
    final rules = _hubCatalog.installable;
    if (rules.isEmpty) {
      showSnackBar('所有可用图源均已安装');
      return;
    }

    HapticFeedback.mediumImpact();
    setState(() => _batchInstalling = true);

    var success = 0;
    var failed = 0;
    for (final rule in rules) {
      final result = await _repo.install(rule.item, indexUrl: rule.indexUrl);
      if (result == RuleInstallResult.failed) {
        failed++;
      } else {
        success++;
      }
    }
    if (!mounted) return;

    setState(() {
      _batchInstalling = false;
      _customSources = _catalog.customSources;
      _hubCatalog = _HubCatalog.build(_indices, _repo);
    });
    showSnackBar(
      failed == 0 ? '一键安装完成，共 $success 个规则' : '安装完成：成功 $success 个，失败 $failed 个',
      isError: failed > 0,
    );
  }

  Future<void> _importSource() async {
    HapticFeedback.mediumImpact();
    final controller = TextEditingController();
    final confirmed = await showSourceDialog<bool>(
      context: context,
      title: '导入配置',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '支持 baka:// 链接或 JSON 源码。',
            style: TextStyle(fontSize: 13, color: context.theme.hintColor),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              hintText: '在此粘贴配置...',
              border: OutlineInputBorder(),
              fillColor: Colors.transparent,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('导入'),
        ),
      ],
    );

    final text = controller.text.trim();
    controller.dispose();
    if (confirmed != true || text.isEmpty) return;

    try {
      final count = await _sources.importCustomSource(text);
      if (mounted) {
        showSnackBar(count > 0 ? '导入成功' : '配置格式无效', isError: count == 0);
      }
    } catch (_) {
      if (mounted) showSnackBar('导入失败，请检查格式', isError: true);
    }
  }

  Future<void> _manageSubscriptions() async {
    HapticFeedback.lightImpact();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SourceSubscriptionSheet(repo: _repo),
    );
    if (mounted) await _loadHub(forceRefresh: true);
  }

  @override
  Widget build(BuildContext context) {
    final builtinSources = _catalog.builtinSources;
    final canInstallAll =
        !_batchInstalling && _hubCatalog.installable.isNotEmpty;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => _loadHub(forceRefresh: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverAppBar.large(
              surfaceTintColor: Colors.transparent,
              stretch: true,
              title: const Text(
                '图源管理',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
              actions: [
                IconButton(
                  icon: Icon(
                    _editing ? Icons.done_rounded : Icons.sort_rounded,
                    color: context.primaryColor,
                  ),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    setState(() => _editing = !_editing);
                  },
                  tooltip: _editing ? '完成排序' : '编辑排序',
                ),
                if (!_editing) ...[
                  IconButton(
                    icon: Icon(
                      Icons.add_circle_rounded,
                      color: context.primaryColor,
                    ),
                    onPressed: _openEditor,
                    tooltip: '新建图源',
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.rss_feed_rounded,
                      color: context.primaryColor,
                    ),
                    onPressed: _manageSubscriptions,
                    tooltip: '订阅管理',
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      color: context.theme.hintColor,
                    ),
                    color: context.cardColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onSelected: (value) {
                      switch (value) {
                        case 'import':
                          _importSource();
                          break;
                        case 'refresh':
                          _loadHub(forceRefresh: true);
                          break;
                        case 'enable':
                          _enableAllSources();
                          break;
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'import',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.download_rounded, size: 18),
                          title: Text('导入配置'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'refresh',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.refresh_rounded, size: 18),
                          title: Text('刷新发现页'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'enable',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.check_circle_outline_rounded,
                            size: 18,
                          ),
                          title: Text('全部启用'),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(width: 4),
              ],
            ),
            if (_editing)
              SliverToBoxAdapter(
                child: Column(
                  children: [
                    if (builtinSources.isNotEmpty)
                      SourceReorderSection<AdapterDescriptor>(
                        title: '拖动排序内置源',
                        items: builtinSources,
                        keyOf: (source) => source.key,
                        iconBuilder: (source) {
                          final config = _catalog.builtinSourceById(source.key);
                          final hub =
                              _hubCatalog.installedBySourceId[source.key];
                          return SourceIcon(
                            name: config?.name ?? source.displayName,
                            iconUrl: config?.iconUrl.isNotEmpty == true
                                ? config!.iconUrl
                                : hub?.item.iconUrl,
                            baseUrl: config?.baseUrl,
                            enabled: _catalog.isBuiltinEnabled(
                              source.key,
                            ),
                            size: 26,
                            radius: 6,
                          );
                        },
                        titleOf: (source) => source.displayName,
                        subtitleOf: (source) => source.statusLabel ?? '',
                        onReorder: (oldIndex, newIndex) async {
                          await _catalog.reorderBuiltinSource(
                            oldIndex,
                            newIndex,
                          );
                          if (mounted) setState(() {});
                        },
                      ),
                    if (_customSources.isNotEmpty)
                      SourceReorderSection<CustomSourceConfig>(
                        title: '拖动排序自定义源',
                        items: _customSources,
                        keyOf: (source) => source.id,
                        iconBuilder: (source) => SourceIcon(
                          name: source.name,
                          iconUrl: source.iconUrl.isNotEmpty
                              ? source.iconUrl
                              : _hubCatalog
                                    .installedBySourceId[source.id]
                                    ?.item
                                    .iconUrl,
                          baseUrl: source.baseUrl,
                          enabled: source.enabled,
                          size: 26,
                          radius: 6,
                        ),
                        titleOf: (source) => source.name,
                        subtitleOf: (source) =>
                            Uri.tryParse(source.baseUrl)?.host ??
                            source.baseUrl,
                        onReorder: (oldIndex, newIndex) async {
                          await _catalog.reorderCustomSource(
                            oldIndex,
                            newIndex,
                          );
                        },
                      ),
                  ],
                ),
              )
            else ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: canInstallAll ? _installAllRules : null,
                          icon: _batchInstalling
                              ? const SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download_rounded, size: 18),
                          label: const Text('一键安装'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _customSources.isEmpty
                              ? null
                              : _deleteAllCustomSources,
                          icon: const Icon(
                            Icons.delete_sweep_rounded,
                            size: 18,
                          ),
                          label: const Text('一键删除'),
                          style: FilledButton.styleFrom(
                            foregroundColor: context.colorScheme.error,
                            backgroundColor: context.colorScheme.error
                                .withValues(alpha: 0.1),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_hubError != null && !_loadingHub)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Material(
                      color: context.colorScheme.errorContainer.withValues(
                        alpha: 0.45,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.cloud_off_rounded,
                          color: context.colorScheme.error,
                        ),
                        title: Text(
                          _hubError!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: TextButton(
                          onPressed: () => _loadHub(forceRefresh: true),
                          child: const Text('重试'),
                        ),
                      ),
                    ),
                  ),
                ),
              _buildSourceGrid(builtinSources),
            ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceGrid(List<AdapterDescriptor> builtinSources) {
    if (_loadingSources) {
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.85,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, _) => AppSkeletonizer(
              enabled: true,
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                ),
              ),
            ),
            childCount: 6,
          ),
        ),
      );
    }

    final customStart = builtinSources.length;
    final remoteStart = customStart + _customSources.length;
    final itemCount = remoteStart + _hubCatalog.available.length;
    if (itemCount == 0) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Text(
            '没有任何图源',
            style: TextStyle(color: context.theme.hintColor),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.85,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index < customStart) {
              final source = builtinSources[index];
              final config = _catalog.builtinSourceById(source.key);
              final rule = _hubCatalog.installedBySourceId[source.key];
              final enabled = _catalog.isBuiltinEnabled(source.key);
              final hasUpdate = rule?.status == InstallStatus.updateAvailable;
              final busy =
                  rule != null && _installing.contains(rule.operationKey);
              return SourceGridCard(
                key: ValueKey('builtin-${source.key}'),
                icon: SourceIcon(
                  name: config?.name ?? source.displayName,
                  iconUrl: config?.iconUrl.isNotEmpty == true
                      ? config!.iconUrl
                      : rule?.item.iconUrl,
                  baseUrl: config?.baseUrl,
                  enabled: enabled,
                  size: 38,
                  radius: 10,
                ),
                title: config?.name ?? source.displayName,
                subtitle:
                    Uri.tryParse(config?.baseUrl ?? '')?.host ??
                    config?.baseUrl ??
                    source.statusLabel ??
                    '',
                badge: rule == null
                    ? '内置'
                    : '内置 · v${rule.item.displayVersion}',
                installed: true,
                enabled: enabled,
                hasUpdate: hasUpdate,
                busy: busy,
                buttonLabel: hasUpdate ? '更新' : (enabled ? '已启用' : '已停用'),
                onTap: busy
                    ? null
                    : () async {
                        HapticFeedback.lightImpact();
                        await _catalog.toggleBuiltinSource(source.key);
                        if (mounted) setState(() {});
                      },
                onButtonPressed: hasUpdate && rule != null
                    ? () => _installRule(rule)
                    : null,
              );
            }

            if (index < remoteStart) {
              final source = _customSources[index - customStart];
              final rule = _hubCatalog.installedBySourceId[source.id];
              final hasUpdate = rule?.status == InstallStatus.updateAvailable;
              final busy =
                  rule != null && _installing.contains(rule.operationKey);
              return SourceGridCard(
                key: ValueKey('custom-${source.id}'),
                icon: SourceIcon(
                  name: source.name,
                  iconUrl: source.iconUrl.isNotEmpty
                      ? source.iconUrl
                      : rule?.item.iconUrl,
                  baseUrl: source.baseUrl,
                  enabled: source.enabled,
                  size: 38,
                  radius: 10,
                ),
                title: source.name,
                subtitle: Uri.tryParse(source.baseUrl)?.host ?? source.baseUrl,
                badge: rule == null ? '管线' : 'v${rule.item.displayVersion}',
                installed: true,
                enabled: source.enabled,
                hasUpdate: hasUpdate,
                busy: busy,
                buttonLabel: hasUpdate
                    ? '更新'
                    : (source.enabled ? '已启用' : '已停用'),
                onTap: busy ? null : () => _toggleCustomSource(source),
                onButtonPressed: hasUpdate && rule != null
                    ? () => _installRule(rule)
                    : null,
                onEdit: () => _openEditor(source),
                onDelete: () => _deleteSource(source),
              );
            }

            final rule = _hubCatalog.available[index - remoteStart];
            final item = rule.item;
            final busy = _installing.contains(rule.operationKey);
            final canInstall = item.hasResolvableConfig && !busy;
            final baseUrl = item.baseUrl;
            return SourceGridCard(
              key: ValueKey('remote-${rule.operationKey}'),
              icon: SourceIcon(
                name: item.name,
                iconUrl: item.iconUrl,
                baseUrl: item.baseUrl,
                enabled: false,
                size: 38,
                radius: 10,
              ),
              title: item.name,
              subtitle: baseUrl == null || baseUrl.isEmpty
                  ? '未知'
                  : (Uri.tryParse(baseUrl)?.host ?? baseUrl),
              badge: 'v${item.displayVersion}',
              installed: false,
              enabled: false,
              busy: busy,
              buttonLabel: item.hasResolvableConfig ? '获取' : '不可用',
              onTap: canInstall ? () => _installRule(rule) : null,
            );
          },
          childCount: itemCount,
          addAutomaticKeepAlives: false,
        ),
      ),
    );
  }
}

class _HubCatalog {
  final Map<String, _HubRule> installedBySourceId;
  final List<_HubRule> available;
  final List<_HubRule> installable;

  const _HubCatalog.empty()
    : installedBySourceId = const {},
      available = const [],
      installable = const [];

  _HubCatalog({
    required this.installedBySourceId,
    required this.available,
    required this.installable,
  });

  factory _HubCatalog.build(
    List<RuleHubIndex> indices,
    RuleRepositoryService repo,
  ) {
    final rawRules = <({RuleHubItem item, String indexUrl})>[
      for (final index in indices)
        for (final item in index.rules) (item: item, indexUrl: index.sourceUrl),
    ];
    if (rawRules.isEmpty) return const _HubCatalog.empty();

    final inspected = repo.inspectItems(rawRules.map((rule) => rule.item));
    final installed = <String, _HubRule>{};
    final available = <String, _HubRule>{};

    for (final raw in rawRules) {
      final info = inspected[raw.item]!;
      final rule = _HubRule(
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

    final availableRules = List<_HubRule>.unmodifiable(available.values);
    return _HubCatalog(
      installedBySourceId: Map<String, _HubRule>.unmodifiable(installed),
      available: availableRules,
      installable: List<_HubRule>.unmodifiable(
        availableRules.where((rule) => rule.item.hasResolvableConfig),
      ),
    );
  }
}

class _HubRule {
  final RuleHubItem item;
  final String indexUrl;
  final InstallStatus status;

  const _HubRule({
    required this.item,
    required this.indexUrl,
    required this.status,
  });

  String get catalogKey =>
      '${item.id}\n${item.name}\n${item.baseUrl ?? ''}\n${item.file ?? ''}';

  String get operationKey => '$indexUrl\n${item.installKey}';
}
