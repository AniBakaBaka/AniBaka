import 'package:baka/models/custom_source_config.dart';
import 'package:baka/pages/source/ai_rule_authoring_page.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/source/source_repository.dart';
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
  final _sources = sourceRepository;
  final _catalog = sourceCatalog;
  final _repo = ruleRepository;
  final Set<String> _installing = <String>{};

  List<CustomSourceConfig> _customSources = const [];
  RuleHubCatalog get _hubCatalog => _repo.hubCatalog;

  bool _editing = false;
  bool _loadingSources = true;
  bool _loadingHub = true;
  bool _batchInstalling = false;
  bool _batchUpdating = false;
  int _batchCompleted = 0;
  int _batchTotal = 0;
  String? _hubError;
  int _hubRequest = 0;

  @override
  void initState() {
    super.initState();
    _catalog.addListener(_onSourcesChanged);
    _repo.addListener(_onSourcesChanged);
    _loadData();
  }

  @override
  void dispose() {
    _catalog.removeListener(_onSourcesChanged);
    _repo.removeListener(_onSourcesChanged);
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
    final modified = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AiRuleAuthoringPage(source: source)),
    );
    if (modified == true && mounted) {
      setState(() {
        _customSources = _catalog.customSources;
      });
    }
  }

  Future<void> _resetBuiltinOverride(String key, String name) async {
    final confirmed = await showSourceConfirmDialog(
      context: context,
      title: '恢复官方规则',
      content: '将移除“$name”的本地覆盖并恢复 App 内置规则。',
      confirmText: '恢复',
    );
    if (!confirmed) return;
    final restored = await _catalog.resetBuiltinSource(key);
    if (mounted) {
      showSnackBar(restored ? '已恢复官方规则' : '当前没有本地覆盖', isError: !restored);
    }
  }

  Future<void> _toggleCustomSource(CustomSourceConfig source) async {
    HapticFeedback.lightImpact();
    await _catalog.updateCustomSource(
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

    final deleted = await _catalog.deleteCustomSource(source.id);
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

    await _catalog.clearCustomSources();
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

  Future<void> _installRule(RuleHubEntry rule) async {
    final key = rule.operationKey;
    if (_batchInstalling || _installing.contains(key)) return;

    HapticFeedback.mediumImpact();
    setState(() => _installing.add(key));
    final result = await _repo.install(rule.item, indexUrl: rule.indexUrl);
    if (!mounted) return;

    setState(() {
      _installing.remove(key);
      _customSources = _catalog.customSources;
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

  Future<void> _installAllRules() =>
      _installBatch(_hubCatalog.installable, updating: false);

  Future<void> _updateAllRules() =>
      _installBatch(_hubCatalog.updates, updating: true);

  Future<void> _installBatch(
    List<RuleHubEntry> rules, {
    required bool updating,
  }) async {
    if (_batchInstalling || _installing.isNotEmpty || rules.isEmpty) return;

    HapticFeedback.mediumImpact();
    setState(() {
      _batchInstalling = true;
      _batchUpdating = updating;
      _batchCompleted = 0;
      _batchTotal = rules.length;
    });

    var success = 0;
    var failed = 0;
    var next = 0;
    Future<void> installNext() async {
      while (mounted && next < rules.length) {
        final rule = rules[next++];
        setState(() => _installing.add(rule.operationKey));
        try {
          final result = await _repo.install(
            rule.item,
            indexUrl: rule.indexUrl,
          );
          if (result == RuleInstallResult.failed) {
            failed++;
          } else {
            success++;
          }
        } catch (error) {
          failed++;
          debugPrint('[RuleHub] Failed to install ${rule.item.name}: $error');
        } finally {
          if (mounted) {
            setState(() {
              _installing.remove(rule.operationKey);
              _customSources = _catalog.customSources;
              _batchCompleted++;
            });
          }
        }
      }
    }

    // Keep slow downloads from holding up the entire batch without flooding
    // the subscription server. The repository serializes catalog writes.
    await Future.wait([
      for (var i = 0; i < 4 && i < rules.length; i++) installNext(),
    ]);
    if (!mounted) return;

    setState(() {
      _batchInstalling = false;
      _customSources = _catalog.customSources;
    });
    showSnackBar(
      failed == 0
          ? '${updating ? '更新' : '安装'}完成，共 $success 个源'
          : '${updating ? '更新' : '安装'}完成：成功 $success 个，失败 $failed 个，可重试',
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
      final count = await _catalog.importCustomSource(text);
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
    final busy = _batchInstalling || _installing.isNotEmpty;
    final canInstallAll =
        !_batchInstalling &&
        _installing.isEmpty &&
        _hubCatalog.installable.isNotEmpty;

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
                  onPressed: busy
                      ? null
                      : () {
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
                    onPressed: busy ? null : _openEditor,
                    tooltip: '新建图源',
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.rss_feed_rounded,
                      color: context.primaryColor,
                    ),
                    onPressed: busy ? null : _manageSubscriptions,
                    tooltip: '订阅管理',
                  ),
                  PopupMenuButton<String>(
                    enabled: !busy,
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
                          title: Text('检查源更新'),
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
                            enabled: _catalog.isBuiltinEnabled(source.key),
                            size: 26,
                            radius: 6,
                          );
                        },
                        titleOf: (source) => source.displayName,
                        subtitleOf: (_) => '第三方源',
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
              SliverToBoxAdapter(child: _buildUpdateSummary()),
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
                          onPressed: busy || _customSources.isEmpty
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

  Widget _buildUpdateSummary() {
    final updates = _hubCatalog.updates;
    final busy = _batchInstalling || _installing.isNotEmpty;
    final title = _batchInstalling
        ? '正在${_batchUpdating ? '更新' : '安装'}源 · $_batchCompleted / $_batchTotal'
        : updates.isNotEmpty
        ? '${updates.length} 个源有更新'
        : _loadingHub
        ? '正在检查源更新…'
        : _hubError != null || _repo.usingCachedIndices
        ? '暂时无法确认最新版本'
        : '已安装的源均为最新版本';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Material(
        color: context.colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (updates.isNotEmpty ||
                      (_batchInstalling && _batchUpdating))
                    FilledButton.icon(
                      onPressed: busy ? null : _updateAllRules,
                      icon: const Icon(
                        Icons.system_update_alt_rounded,
                        size: 18,
                      ),
                      label: const Text('全部更新'),
                    )
                  else
                    TextButton.icon(
                      onPressed: busy || _loadingHub
                          ? null
                          : () => _loadHub(forceRefresh: true),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('检查更新'),
                    ),
                ],
              ),
              if (updates.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  updates.map((rule) => rule.item.name).join('、'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.theme.hintColor,
                  ),
                ),
              ],
              if (_repo.usingCachedIndices) ...[
                const SizedBox(height: 8),
                const Text(
                  '部分规则库连接失败，当前显示上次检查结果。可下拉重试。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
              if (_loadingHub || _batchInstalling) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _batchInstalling
                      ? _batchCompleted / _batchTotal
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSourceGrid(List<AdapterDescriptor> builtinSources) {
    final gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 180,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      mainAxisExtent: 180 + MediaQuery.textScalerOf(context).scale(32),
    );
    if (_loadingSources) {
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        sliver: SliverGrid(
          gridDelegate: gridDelegate,
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
        gridDelegate: gridDelegate,
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index < customStart) {
              final source = builtinSources[index];
              final config = _catalog.builtinSourceById(source.key);
              final rule = _hubCatalog.installedBySourceId[source.key];
              final enabled = _catalog.isBuiltinEnabled(source.key);
              final hasUpdate = rule?.status == InstallStatus.updateAvailable;
              final hasLocalOverride =
                  _catalog.builtinOverrideById(source.key) != null;
              final busy =
                  rule != null && _installing.contains(rule.operationKey);
              final actionsBlocked = _batchInstalling || busy;
              final version = _catalog.installedVersionFor(source.key);
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
                    '第三方源',
                badge: hasLocalOverride ? (version > 0 ? '规则库' : '本地') : '内置',
                versionLabel: hasUpdate
                    ? '${version > 0 ? 'v$version' : '本地版本'} → v${rule!.item.version}'
                    : version > 0
                    ? '当前 v$version'
                    : null,
                installed: true,
                enabled: enabled,
                hasUpdate: hasUpdate,
                busy: busy,
                buttonLabel: hasUpdate ? '更新' : (enabled ? '已启用' : '已停用'),
                onTap: actionsBlocked
                    ? null
                    : () async {
                        HapticFeedback.lightImpact();
                        await _catalog.toggleBuiltinSource(source.key);
                        if (mounted) setState(() {});
                      },
                onButtonPressed: !actionsBlocked && hasUpdate && rule != null
                    ? () => _installRule(rule)
                    : null,
                onEdit: actionsBlocked
                    ? null
                    : () {
                        final targetConfig =
                            config ??
                            CustomSourceConfig(
                              id: source.key,
                              name: source.displayName,
                              baseUrl: '',
                              pipeline: const <String, dynamic>{
                                'search': <dynamic>[],
                                'detail': <dynamic>[],
                                'play': <dynamic>[],
                              },
                            );
                        _openEditor(targetConfig);
                      },
                onDelete: hasLocalOverride && !actionsBlocked
                    ? () => _resetBuiltinOverride(
                        source.key,
                        config?.name ?? source.displayName,
                      )
                    : null,
                deleteLabel: '恢复官方规则',
                deleteDestructive: false,
              );
            }

            if (index < remoteStart) {
              final source = _customSources[index - customStart];
              final rule = _hubCatalog.installedBySourceId[source.id];
              final hasUpdate = rule?.status == InstallStatus.updateAvailable;
              final busy =
                  rule != null && _installing.contains(rule.operationKey);
              final actionsBlocked = _batchInstalling || busy;
              final version = _catalog.installedVersionFor(source.id);
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
                badge: '自定义',
                versionLabel: hasUpdate
                    ? '${version > 0 ? 'v$version' : '本地版本'} → v${rule!.item.version}'
                    : version > 0
                    ? '当前 v$version'
                    : null,
                installed: true,
                enabled: source.enabled,
                hasUpdate: hasUpdate,
                busy: busy,
                buttonLabel: hasUpdate
                    ? '更新'
                    : (source.enabled ? '已启用' : '已停用'),
                onTap: actionsBlocked
                    ? null
                    : () => _toggleCustomSource(source),
                onButtonPressed: !actionsBlocked && hasUpdate && rule != null
                    ? () => _installRule(rule)
                    : null,
                onEdit: actionsBlocked ? null : () => _openEditor(source),
                onDelete: actionsBlocked ? null : () => _deleteSource(source),
              );
            }

            final rule = _hubCatalog.available[index - remoteStart];
            final item = rule.item;
            final busy = _installing.contains(rule.operationKey);
            final canInstall =
                item.hasResolvableConfig && !_batchInstalling && !busy;
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
              badge: 'v${item.version}',
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
