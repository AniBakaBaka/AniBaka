import 'dart:collection';
import 'dart:convert';

import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/pages/setting/ai_rule_settings_page.dart';
import 'package:baka/services/source/ai_rule_settings.dart';
import 'package:baka/services/source/ai_rule_authoring_service.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/source_adapter.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';
import 'package:baka/widgets/common/platform_tooltip.dart';
import 'package:flutter/services.dart';

enum _TestStage { search, episodes, playback }

class AiRuleAuthoringPage extends StatefulWidget {
  const AiRuleAuthoringPage({super.key, this.seed, this.source});

  final RuleAuthoringSeed? seed;
  final CustomSourceConfig? source;

  @override
  State<AiRuleAuthoringPage> createState() => _AiRuleAuthoringPageState();
}

class _AiRuleAuthoringPageState extends State<AiRuleAuthoringPage> {
  static const _quickKeywords = ['孤独摇滚', '葬送的芙莉莲', '迷宫饭', '鬼灭之刃'];
  static const _emptyPipeline = <String, dynamic>{
    'search': <dynamic>[],
    'detail': <dynamic>[],
    'play': <dynamic>[],
  };

  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _siteController;
  late final TextEditingController _keywordController;
  late final TextEditingController _instructionsController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _pipelineController;
  late final String _sourceId;

  AiProviderConfig? _provider;
  AiRuleAuthoringService? _service;
  RuleAuthoringResult? _result;
  final _activity = _AuthoringActivity();
  String? _error;

  bool _loading = true;
  bool _running = false;
  bool _saving = false;
  final _enabled = ValueNotifier(true);
  bool _showAdvanced = false;
  int _maxRounds = 35;

  _TestStage? _runningTest;
  String? _testSeriesUrl;
  String? _testEpisodeUrl;
  final _testResults = <_TestStage, ({bool passed, String log})>{};
  SourceAdapter? _testAdapter;
  late (String, String, String) _testInput;

  bool get _busy => _running || _runningTest != null || _saving;

  bool get _isBuiltinSource {
    final key = widget.source?.id ?? widget.seed?.sourceKey;
    return key != null && AdapterRegistry.isBuiltinSource(key);
  }

  bool get _isRepairing =>
      widget.seed?.mode == RuleAuthoringMode.repair ||
      widget.seed?.failureMessage != null;

  RuleAuthoringMode get _mode => widget.seed?.mode ?? RuleAuthoringMode.create;

  bool get _isEditingExisting =>
      widget.source != null || widget.seed?.currentConfig != null;

  @override
  void initState() {
    super.initState();
    final source = widget.source ?? widget.seed?.currentConfig;
    final seed = widget.seed;

    _sourceId = source?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    _maxRounds = seed?.maxRounds ?? 35;
    _enabled.value = source?.enabled ?? true;

    _nameController = TextEditingController(text: source?.name ?? '');
    _siteController = TextEditingController(
      text: seed?.siteUrl ?? source?.baseUrl ?? '',
    );
    _keywordController = TextEditingController(
      text: seed?.keyword.trim().isNotEmpty == true ? seed!.keyword : '孤独摇滚',
    );
    _instructionsController = TextEditingController(
      text: seed?.instructions ?? '',
    );
    _descriptionController = TextEditingController(
      text: source?.description ?? '',
    );
    _pipelineController = TextEditingController(
      text: _encodePipeline(source?.pipelineJson() ?? _emptyPipeline),
    );

    if (seed?.instructions.isNotEmpty == true) _showAdvanced = true;
    _testInput = (
      _pipelineController.text,
      _siteController.text,
      _keywordController.text,
    );
    for (final controller in [
      _pipelineController,
      _siteController,
      _keywordController,
    ]) {
      controller.addListener(_invalidateTests);
    }
    _loadProvider();
  }

  Future<void> _loadProvider() async {
    try {
      final provider = await AiRuleSettingsService.instance.load();
      if (mounted) setState(() => _provider = provider);
    } catch (error) {
      if (mounted) setState(() => _error = '模型配置读取失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _service?.dispose();
    _testAdapter?.dispose();
    _activity.dispose();
    _enabled.dispose();
    _nameController.dispose();
    _siteController.dispose();
    _keywordController.dispose();
    _instructionsController.dispose();
    _descriptionController.dispose();
    _pipelineController.dispose();
    super.dispose();
  }

  static String _encodePipeline(Map<String, dynamic> pipeline) =>
      const JsonEncoder.withIndent('  ').convert(pipeline);

  Map<String, dynamic>? _parsePipeline() {
    try {
      final decoded = jsonDecode(_pipelineController.text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  String? _validateSite(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return '请输入有效的 HTTP(S) 站点主页';
    }
    return null;
  }

  CustomSourceConfig _buildConfig(Map<String, dynamic> pipeline) {
    final original = widget.source ?? widget.seed?.currentConfig;
    final name = _nameController.text.trim();
    return CustomSourceConfig(
      id: _sourceId,
      name: name.isNotEmpty ? name : '未命名图源',
      baseUrl: _siteController.text.trim(),
      iconUrl: original?.iconUrl,
      description: _descriptionController.text.trim(),
      pipeline: pipeline,
      enabled: _enabled.value,
      createdAt: original?.createdAt,
    );
  }

  ({CustomSourceConfig config, SourceRule rule})? _validateCurrentRule() {
    FocusManager.instance.primaryFocus?.unfocus();
    final pipeline = _parsePipeline();
    if (pipeline == null || pipeline.isEmpty) {
      showSnackBar('请先生成或填入规则 JSON', isError: true);
      return null;
    }
    try {
      final config = _buildConfig(pipeline);
      final rule = config.rule;
      final validation = RuleValidator.validate(rule);
      if (!validation.isValid) {
        showSnackBar('规则校验未通过：${validation.errors.join('；')}', isError: true);
        return null;
      }
      return (config: config, rule: rule);
    } catch (error) {
      showSnackBar('规则格式无效：$error', isError: true);
      return null;
    }
  }

  Future<void> _openSettings() async {
    HapticFeedback.lightImpact();
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AiRuleSettingsPage()),
    );
    if (mounted) await _loadProvider();
  }

  Future<void> _start() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    final provider = _provider;
    if (provider == null || !provider.isConfigured) {
      await _openSettings();
      return;
    }

    HapticFeedback.mediumImpact();
    final original = widget.seed;
    final seed = RuleAuthoringSeed(
      mode: _mode,
      siteUrl: _siteController.text.trim(),
      keyword: _keywordController.text.trim(),
      instructions: _instructionsController.text.trim(),
      sourceKey: original?.sourceKey ?? widget.source?.id,
      currentConfig: widget.source ?? original?.currentConfig,
      seriesId: original?.seriesId,
      episodeId: original?.episodeId,
      failureMessage: original?.failureMessage,
      maxRounds: _maxRounds,
    );

    final service = AiRuleAuthoringService();
    setState(() {
      _service = service;
      _running = true;
      _result = null;
      _error = null;
      _activity.clear();
    });

    try {
      final result = await service.run(
        provider: provider,
        seed: seed,
        onProgress: (progress) {
          if (mounted) _activity.add(progress);
        },
      );
      if (mounted) {
        setState(() {
          _result = result;
          if (_nameController.text.trim().isEmpty) {
            _nameController.text = result.config.name;
          }
          if (result.config.baseUrl.isNotEmpty) {
            _siteController.text = result.config.baseUrl;
          }
          if (result.config.hasPipeline) {
            _pipelineController.text = _encodePipeline(
              result.config.pipelineJson()!,
            );
          }
        });
        HapticFeedback.heavyImpact();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
        HapticFeedback.heavyImpact();
      }
    } finally {
      service.dispose();
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    HapticFeedback.mediumImpact();

    final rule = _validateCurrentRule();
    if (rule == null) return;

    setState(() => _saving = true);
    try {
      final config = rule.config;
      final sourceKey = widget.seed?.sourceKey ?? widget.source?.id;
      final catalog = sourceCatalog;

      bool saved;
      if (sourceKey != null && AdapterRegistry.isBuiltinSource(sourceKey)) {
        saved = await catalog.updateBuiltinSource(sourceKey, config);
      } else if (sourceKey != null &&
          (widget.source != null ||
              AdapterRegistry.isCustomSource(sourceKey))) {
        saved = await catalog.updateCustomSource(config);
      } else {
        saved = await catalog.addCustomSource(config);
      }

      if (!mounted) return;
      if (!saved) {
        showSnackBar('规则保存失败：来源已变更或 ID 冲突', isError: true);
        return;
      }
      showSnackBar(
        _isRepairing
            ? '规则已保存'
            : (_isBuiltinSource
                  ? '内置源本地规则已保存'
                  : (_enabled.value ? '图源已保存并启用' : '图源已保存，当前已停用')),
      );
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) showSnackBar('保存失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _formatPipeline() {
    final pipeline = _parsePipeline();
    if (pipeline == null) {
      showSnackBar('规则 JSON 格式无效', isError: true);
      return;
    }
    _pipelineController.value = TextEditingValue(
      text: _encodePipeline(pipeline),
      selection: const TextSelection.collapsed(offset: 0),
    );
    showSnackBar('规则已格式化');
  }

  Future<void> _pastePipeline() async {
    if (_busy) return;
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || _busy) return;
    final text = clipboard?.text?.trim();
    if (text == null || text.isEmpty) {
      showSnackBar('剪贴板中没有文本', isError: true);
      return;
    }

    try {
      final decoded = SourceCodec.decode(text);
      if (decoded is! Map) throw const FormatException();
      final json = Map<String, dynamic>.from(decoded);
      final pipeline = CustomSourceConfig.fromJson({
        ...json,
        'format': kSourceRuleFormatV2,
      }).pipelineJson();
      if (pipeline == null || pipeline.isEmpty) throw const FormatException();

      setState(() {
        _pipelineController.text = _encodePipeline(pipeline);
        if (json['name'] != null && _nameController.text.trim().isEmpty) {
          _nameController.text = json['name'].toString();
        }
        if (json['baseUrl'] != null && _siteController.text.trim().isEmpty) {
          _siteController.text = json['baseUrl'].toString();
        }
      });
      showSnackBar('已成功导入规则');
    } catch (_) {
      showSnackBar('剪贴板内容不是合法的规则或分享链接', isError: true);
    }
  }

  void _copyRule({bool share = false}) {
    final validated = _validateCurrentRule();
    if (validated == null) return;
    final json = validated.config.toJson();
    Clipboard.setData(
      ClipboardData(
        text: share ? SourceCodec.encode(json) : _encodePipeline(json),
      ),
    );
    showSnackBar(share ? 'baka:// 分享链接已复制' : '配置 JSON 已复制');
  }

  void _invalidateTests() {
    final input = (
      _pipelineController.text,
      _siteController.text,
      _keywordController.text,
    );
    if (input == _testInput) return; // 光标、选区变化不影响规则。
    _testInput = input;
    _testAdapter?.dispose();
    _testAdapter = null;
    if (_runningTest == null && _testResults.isEmpty) return;
    setState(() {
      _runningTest = null;
      _testSeriesUrl = null;
      _testEpisodeUrl = null;
      _testResults.clear();
    });
  }

  Future<void> _runTest(_TestStage stage) async {
    if (_busy) return;
    final validated = _validateCurrentRule();
    if (validated == null) return;
    if (stage == _TestStage.episodes && _testSeriesUrl == null ||
        stage == _TestStage.playback && _testEpisodeUrl == null) {
      return;
    }
    final adapter = _testAdapter ??= SourceAdapter(validated.rule);
    setState(() {
      _runningTest = stage;
      _testResults.removeWhere((key, _) => key.index >= stage.index);
      if (stage == _TestStage.search) _testSeriesUrl = null;
      if (stage != _TestStage.playback) _testEpisodeUrl = null;
    });
    try {
      final String log;
      final bool passed;
      switch (stage) {
        case _TestStage.search:
          final keyword = _keywordController.text.trim();
          if (keyword.isEmpty) throw const FormatException('请输入测试关键词');
          final results = await adapter.search(keyword, enhanceWithBgm: false);
          if (!mounted || !identical(adapter, _testAdapter)) return;
          passed = results.isNotEmpty;
          _testSeriesUrl = passed ? results.first.seriesId : null;
          final preview = results
              .take(3)
              .map((e) => '• ${e.name} (${e.seriesId})')
              .join('\n');
          log = passed ? '成功命中 ${results.length} 部番剧：\n$preview' : '未找到搜索结果';
        case _TestStage.episodes:
          final catalog = await adapter.getPlaybackCatalog(_testSeriesUrl!);
          if (!mounted || !identical(adapter, _testAdapter)) return;
          passed = !catalog.isEmpty && catalog.episodes.first.lines.isNotEmpty;
          final firstEpisode = passed ? catalog.episodes.first : null;
          _testEpisodeUrl = firstEpisode?.lineAt(
            firstEpisode.availableLineIndexes.firstOrNull ?? 1,
          );
          log = passed
              ? '解析成功：${catalog.sourceNames.length} 条线路，共 ${catalog.episodes.length} 集\n线路：${catalog.sourceNames.join('、')}'
              : '未提取到播放线路';
        case _TestStage.playback:
          final url = await adapter.resolveDownloadUrl(
            _testEpisodeUrl!,
            forceRefresh: true,
          );
          if (!mounted || !identical(adapter, _testAdapter)) return;
          passed = url.isNotEmpty;
          log = passed ? '播放直链解析成功：\n$url' : '未提取到播放直链';
      }
      setState(() => _testResults[stage] = (passed: passed, log: log));
    } catch (error) {
      if (mounted && identical(adapter, _testAdapter)) {
        setState(() => _testResults[stage] = (passed: false, log: '失败：$error'));
      }
    } finally {
      if (mounted && identical(adapter, _testAdapter)) {
        setState(() => _runningTest = null);
      }
    }
  }

  Widget _buildSetup(BuildContext context, {required bool wide}) {
    final colors = Theme.of(context).colorScheme;
    return _Section(
      title: '图源配置',
      subtitle: '填写站点，开始创建你的规则',
      icon: Icons.language_rounded,
      children: [
        OutlinedButton(
          onPressed: _busy ? null : _openSettings,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(12)),
          child: Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 18, color: colors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _provider?.isConfigured == true
                          ? _provider!.model
                          : '选择 AI 模型',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _provider?.isConfigured == true ? '模型已配置' : '配置后即可生成规则',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
        if (widget.seed?.failureMessage case final String failure)
          Text('异常诊断：$failure', style: TextStyle(color: colors.error)),
        TextFormField(
          controller: _siteController,
          validator: _validateSite,
          readOnly: _busy,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '站点主页',
            hintText: 'https://example.com',
            prefixIcon: Icon(Icons.public_rounded, size: 18),
          ),
        ),
        TextFormField(
          controller: _keywordController,
          readOnly: _busy,
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入测试关键词' : null,
          decoration: const InputDecoration(
            labelText: '测试关键词',
            prefixIcon: Icon(Icons.search_rounded, size: 19),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: _keywordController,
          builder: (context, value, _) => Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final keyword in _quickKeywords)
                _Option(
                  label: keyword,
                  selected: value.text.trim() == keyword,
                  onTap: _busy ? null : () => _keywordController.text = keyword,
                ),
            ],
          ),
        ),
        Row(
          children: [
            const Expanded(
              child: Text(
                '探索轮数',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            PlatformTooltip(
              message: '达到轮数后停止；不限制时可手动中止',
              child: Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final rounds in {35, 50, 60, 0, _maxRounds})
              _Option(
                label: rounds == 0 ? '不限制' : '$rounds 轮',
                selected: _maxRounds == rounds,
                onTap: _busy ? null : () => setState(() => _maxRounds = rounds),
              ),
          ],
        ),
        Divider(height: 8, color: colors.outlineVariant),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _nameController,
                readOnly: _busy,
                decoration: const InputDecoration(
                  labelText: '图源名称',
                  hintText: 'AI 自动提取',
                ),
              ),
            ),
            const SizedBox(width: 12),
            ValueListenableBuilder(
              valueListenable: _enabled,
              builder: (context, enabled, _) => PlatformTooltip(
                message: enabled ? '图源已启用' : '图源已停用',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '启用',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    Switch(
                      value: enabled,
                      onChanged: _busy
                          ? null
                          : (value) => _enabled.value = value,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        TextFormField(
          controller: _descriptionController,
          readOnly: _busy,
          decoration: const InputDecoration(labelText: '备注说明（可选）'),
        ),
        if (_showAdvanced)
          TextFormField(
            controller: _instructionsController,
            readOnly: _busy,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: '补充线索 / 自定义 Prompt'),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showAdvanced = true),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('补充线索 / 自定义 Prompt'),
            ),
          ),
        if (wide)
          FilledButton.icon(
            onPressed: _running ? _service?.dispose : (_busy ? null : _start),
            icon: Icon(
              _running ? Icons.stop_rounded : Icons.auto_awesome_rounded,
              size: 18,
            ),
            label: Text(_running ? '中止任务' : (_isRepairing ? '开始修复' : '开始生成')),
          ),
      ],
    );
  }

  Widget _buildProgress(BuildContext context) {
    return ListenableBuilder(
      listenable: _activity,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final progress = _activity.progress;
        final report = _result?.validation;
        final currentStep = report?.success == true
            ? 4
            : switch (progress?.stage) {
                'probe' => 0,
                'validation' => 2,
                'success' => 3,
                _ => _running ? 1 : -1,
              };
        return _Section(
          title: '生成进度',
          icon: Icons.route_rounded,
          trailing: _StatusLabel(
            label: _running
                ? '生成中'
                : _error != null
                ? '需处理'
                : report?.success == true
                ? '已完成'
                : '待开始',
            color: _error != null
                ? colors.error
                : _running
                ? colors.primary
                : colors.onSurfaceVariant,
          ),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, label) in [
                  '站点探测',
                  '规则推导',
                  '规则验证',
                  '交付就绪',
                ].indexed)
                  Expanded(
                    child: Column(
                      children: [
                        Container(
                          height: 32,
                          width: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: currentStep >= index
                                ? colors.primary
                                : colors.surfaceContainer,
                            border: Border.all(
                              color: currentStep >= index
                                  ? colors.primary
                                  : colors.outlineVariant,
                            ),
                          ),
                          child: currentStep > index
                              ? Icon(
                                  Icons.check_rounded,
                                  size: 17,
                                  color: colors.onPrimary,
                                )
                              : Text(
                                  '0${index + 1}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: currentStep == index
                                        ? colors.onPrimary
                                        : colors.onSurfaceVariant,
                                  ),
                                ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: currentStep >= index
                                ? colors.onSurface
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (_running) ...[
              LinearProgressIndicator(
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
              Text(
                '第 ${progress?.round ?? 0} / ${_maxRounds == 0 ? '不限' : _maxRounds} 轮',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ] else if (progress == null && report == null && _error == null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_outlined,
                      color: colors.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '准备好，创建下一个图源',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '填写站点与关键词，或导入已有规则开始编辑。',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.6,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (progress != null)
              Text(progress.message, style: const TextStyle(height: 1.6)),
            if (_activity.summary case final String summary)
              Text(summary, style: TextStyle(color: colors.onSurfaceVariant)),
            if (_error case final String error)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.errorContainer.withValues(alpha: .35),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  error,
                  style: TextStyle(color: colors.error, height: 1.6),
                ),
              ),
            if (report != null) ...[
              Text(
                report.success ? '规则验证通过（${_result!.rounds} 轮）' : '规则未通过验证',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(report.message),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final metric in [
                    '搜索 ${report.seriesCount} 部',
                    '线路 ${report.lineCount} 条',
                    '剧集 ${report.episodeCount} 集',
                    '媒体 ${report.mediaKind ?? '未识别'}',
                  ])
                    _StatusLabel(label: metric, color: colors.primary),
                ],
              ),
            ],
            if (_activity.logs.isNotEmpty)
              Container(
                height: 120,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ListView.builder(
                  reverse: true,
                  itemCount: _activity.logs.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      _activity.logs.elementAt(
                        _activity.logs.length - 1 - index,
                      ),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildEditor(BuildContext context) {
    return _Section(
      title: '规则 JSON',
      subtitle: '支持手动编辑，也可由 AI 生成',
      icon: Icons.data_object_rounded,
      inverse: true,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'pipeline.json',
                style: TextStyle(fontSize: 12, color: Color(0xFF93A4BB)),
              ),
            ),
            for (final (tooltip, icon, action)
                in <(String, IconData, VoidCallback?)>[
                  (
                    '格式化',
                    Icons.format_align_left_rounded,
                    _busy ? null : _formatPipeline,
                  ),
                  (
                    '剪贴板粘贴',
                    Icons.content_paste_rounded,
                    _busy ? null : _pastePipeline,
                  ),
                  ('复制 JSON', Icons.copy_rounded, _copyRule),
                  (
                    '分享链接',
                    Icons.ios_share_rounded,
                    () => _copyRule(share: true),
                  ),
                ])
              IconButton(
                onPressed: action,
                tooltip: tooltip,
                icon: Icon(icon, size: 17),
                color: const Color(0xFFBCC9DA),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
              ),
          ],
        ),
        TextFormField(
          controller: _pipelineController,
          readOnly: _busy,
          minLines: 10,
          maxLines: 16,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          cursorColor: const Color(0xFF7DB9F3),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.8,
            color: Color(0xFFBED8F4),
          ),
          decoration: const InputDecoration(
            filled: true,
            fillColor: Color(0xFF131A25),
            contentPadding: EdgeInsets.all(16),
            border: OutlineInputBorder(borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF668BB7)),
            ),
          ),
        ),
        const Text(
          '生成或编辑后，可用单步测试检查规则。',
          style: TextStyle(fontSize: 11, color: Color(0xFF93A4BB)),
        ),
      ],
    );
  }

  Widget _buildTests(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const labels = ['检索番剧', '剧集与线路', '播放直链'];
    final passed = _testResults.values.where((result) => result.passed).length;
    return _Section(
      title: '单步测试',
      subtitle: '按顺序检查规则的每个环节',
      icon: Icons.science_outlined,
      trailing: _StatusLabel(label: '$passed / 3', color: colors.primary),
      children: [
        for (final stage in _TestStage.values) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              children: [
                _runningTest == stage
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        switch (_testResults[stage]?.passed) {
                          true => Icons.check_circle_rounded,
                          false => Icons.error_outline_rounded,
                          null => Icons.radio_button_unchecked_rounded,
                        },
                        size: 20,
                        color: switch (_testResults[stage]?.passed) {
                          true => const Color(0xFF26977A),
                          false => colors.error,
                          null => colors.onSurfaceVariant,
                        },
                      ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        labels[stage.index],
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        switch (stage) {
                          _TestStage.search => _testSeriesUrl ?? '从搜索结果提取番剧 ID',
                          _TestStage.episodes =>
                            _testSeriesUrl == null ? '请先完成检索' : '解析线路与分集列表',
                          _TestStage.playback =>
                            _testEpisodeUrl == null ? '请先解析剧集' : '解析首集媒体地址',
                        },
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed:
                      _busy ||
                          (stage == _TestStage.episodes &&
                              _testSeriesUrl == null) ||
                          (stage == _TestStage.playback &&
                              _testEpisodeUrl == null)
                      ? null
                      : () => _runTest(stage),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    _testResults.containsKey(stage) ? '重测' : '测试',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (_testResults[stage] case final result?)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: SelectableText(
                  result.log,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
        Text(
          '测试仅用于检查当前规则，保存后才会生效。',
          style: TextStyle(
            fontSize: 11,
            height: 1.6,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final colors = theme.colorScheme.copyWith(
      surface: dark ? const Color(0xFF1B1E24) : Colors.white,
      surfaceContainer: dark
          ? const Color(0xFF22262E)
          : const Color(0xFFF5F7FA),
      outlineVariant: dark ? const Color(0xFF323741) : const Color(0xFFE5E9EF),
    );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: colors.outlineVariant),
    );
    return Theme(
      data: theme.copyWith(
        colorScheme: colors,
        scaffoldBackgroundColor: dark
            ? const Color(0xFF111318)
            : const Color(0xFFF5F7FA),
        textTheme: theme.textTheme
            .apply(bodyColor: colors.onSurface, displayColor: colors.onSurface)
            .copyWith(
              bodyLarge: theme.textTheme.bodyLarge?.copyWith(
                fontSize: 13,
                height: 1.5,
              ),
              bodyMedium: theme.textTheme.bodyMedium?.copyWith(
                fontSize: 13,
                height: 1.5,
              ),
            ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colors.surfaceContainer,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 16,
          ),
          labelStyle: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          floatingLabelStyle: TextStyle(fontSize: 13, color: colors.primary),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(color: colors.primary, width: 1.5),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 46),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            textStyle: theme.textTheme.labelLarge?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(11),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: colors.outlineVariant),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(11),
            ),
          ),
        ),
      ),
      child: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            backgroundColor: colors.surface,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            title: Text(
              _isRepairing
                  ? 'AI 修复图源'
                  : _isBuiltinSource
                  ? '编辑内置源'
                  : _isEditingExisting
                  ? '编辑图源'
                  : 'AI 规则工坊',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            actions: [
              IconButton(
                onPressed: _busy ? null : _pastePipeline,
                tooltip: '粘贴导入规则',
                icon: const Icon(Icons.content_paste_rounded, size: 20),
              ),
              IconButton(
                onPressed: _busy ? null : _openSettings,
                tooltip: '模型参数设置',
                icon: const Icon(Icons.tune_rounded, size: 20),
              ),
              const SizedBox(width: 12),
            ],
          ),
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 840;
                  final save = FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(_saving ? '保存中…' : '保存图源'),
                  );
                  return Row(
                    children: [
                      if (compact)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _running
                                ? _service?.dispose
                                : (_busy ? null : _start),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 46),
                            ),
                            icon: Icon(
                              _running
                                  ? Icons.stop_rounded
                                  : Icons.auto_awesome_rounded,
                              size: 18,
                            ),
                            label: Text(
                              _running
                                  ? '中止任务'
                                  : _isRepairing
                                  ? '开始修复'
                                  : '开始生成',
                            ),
                          ),
                        )
                      else ...[
                        Icon(
                          Icons.info_outline_rounded,
                          size: 16,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _isBuiltinSource ? '保存为内置源的本地规则' : '更改将在保存后生效',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 12),
                      if (compact) Expanded(child: save) else save,
                    ],
                  );
                },
              ),
            ),
          ),
          body: Form(
            key: _formKey,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 880;
                final setup = _buildSetup(context, wide: wide);
                final editor = _buildEditor(context);
                final tests = _buildTests(context);
                final workspace = ListView(
                  padding: EdgeInsets.all(wide ? 24 : 16),
                  children: [
                    if (!wide) setup,
                    _buildProgress(context),
                    if (constraints.maxWidth >= 1200)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 6, child: editor),
                          const SizedBox(width: 16),
                          Expanded(flex: 5, child: tests),
                        ],
                      )
                    else ...[
                      editor,
                      tests,
                    ],
                  ],
                );
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1560),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: 360,
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    24,
                                    0,
                                    8,
                                  ),
                                  child: setup,
                                ),
                              ),
                              Expanded(child: workspace),
                            ],
                          )
                        : workspace,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 高频进度通知仅刷新进度区域；环形队列保留最近 50 条，淘汰时不搬移数组。
class _AuthoringActivity extends ChangeNotifier {
  final logs = ListQueue<String>(50);
  RuleAuthoringProgress? progress;
  String? summary;

  void clear() {
    logs.clear();
    progress = null;
    summary = null;
    notifyListeners();
  }

  void add(RuleAuthoringProgress value) {
    if (value.stage == 'summary') {
      if (summary == value.message) return;
      summary = value.message;
    } else {
      final message = value.message.trim();
      if (progress?.round == value.round &&
          progress?.stage == value.stage &&
          progress?.message.trim() == message) {
        return;
      }
      progress = value;
      if (message.isNotEmpty) {
        if (logs.length == 50) logs.removeFirst();
        logs.addLast('R${value.round} [${value.stage.toUpperCase()}] $message');
      }
    }
    notifyListeners();
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    required this.icon,
    this.subtitle,
    this.trailing,
    this.inverse = false,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  final Widget? trailing;
  final List<Widget> children;
  final bool inverse;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: inverse ? const Color(0xFF1B2432) : colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: inverse ? const Color(0xFF2E3A4B) : colors.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: inverse
                      ? const Color(0xFF2A394C)
                      : colors.primary.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: inverse ? const Color(0xFF96C6F6) : colors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: inverse
                            ? const Color(0xFFECF2FA)
                            : colors.onSurface,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: inverse
                              ? const Color(0xFF93A4BB)
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
          ...children,
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      enabled: onTap != null,
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: .10)
            : colors.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: onTap == null
                    ? colors.onSurfaceVariant.withValues(alpha: .5)
                    : selected
                    ? colors.primary
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color),
    ),
  );
}
