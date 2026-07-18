import 'dart:convert';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/store/rule_migrator.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CustomSourceEditPage extends StatefulWidget {
  final CustomSourceConfig? source;

  const CustomSourceEditPage({super.key, this.source});

  @override
  State<CustomSourceEditPage> createState() => _CustomSourceEditPageState();
}

enum _TestStage { search, episodes, playback }

class _CustomSourceEditPageState extends State<CustomSourceEditPage> {
  static const _emptyPipeline = <String, dynamic>{
    'search': <dynamic>[],
    'detail': <dynamic>[],
    'play': <dynamic>[],
  };

  final _formKey = GlobalKey<FormState>();
  final _manager = SourceAdapterService.instance;

  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _pipelineController;
  late final TextEditingController _testKeywordController;
  late final String _sourceId;

  bool _enabled = true;
  bool _isSaving = false;
  _TestStage? _runningTest;
  String? _testSeriesUrl;
  String? _testEpisodeUrl;
  final Map<_TestStage, String> _testLogs = {
    for (final stage in _TestStage.values) stage: '',
  };

  bool get _isEditing => widget.source != null;

  @override
  void initState() {
    super.initState();
    final source = widget.source;
    _sourceId = source?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    _nameController = TextEditingController(text: source?.name ?? '');
    _baseUrlController = TextEditingController(text: source?.baseUrl ?? '');
    _descriptionController = TextEditingController(
      text: source?.description ?? '',
    );
    _pipelineController = TextEditingController(
      text: _encodePipeline(source?.pipeline ?? _emptyPipeline),
    );
    _testKeywordController = TextEditingController(text: '孤独摇滚');
    _enabled = source?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _descriptionController.dispose();
    _pipelineController.dispose();
    _testKeywordController.dispose();
    super.dispose();
  }

  String _encodePipeline(Map<String, dynamic> pipeline) {
    return const JsonEncoder.withIndent('  ').convert(pipeline);
  }

  Map<String, dynamic>? _parsePipeline([String? input]) {
    try {
      final decoded = jsonDecode(input ?? _pipelineController.text);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) return '请输入图源名称';
    return null;
  }

  String? _validateBaseUrl(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '请输入站点主页';
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '请输入有效的 HTTP(S) 地址';
    }
    return null;
  }

  String? _validatePipeline(String? value) {
    if (value == null || value.trim().isEmpty) return '请输入规则 JSON';
    final pipeline = _parsePipeline(value);
    if (pipeline == null) return '规则必须是合法的 JSON 对象';
    if (pipeline.isEmpty) return '规则内容不能为空';

    const listKeys = ['recipes', 'search', 'detail', 'play'];
    for (final key in listKeys) {
      if (pipeline[key] != null && pipeline[key] is! List) {
        return '$key 必须是数组';
      }
    }
    if (pipeline['headers'] != null && pipeline['headers'] is! Map) {
      return 'headers 必须是对象';
    }
    if (!pipeline.containsKey('recipes') &&
        !pipeline.containsKey('search') &&
        !pipeline.containsKey('detail') &&
        !pipeline.containsKey('play')) {
      return '至少填写 recipes、search、detail 或 play';
    }
    return null;
  }

  CustomSourceConfig _buildConfig(Map<String, dynamic> pipeline) {
    return CustomSourceConfig(
      id: _sourceId,
      name: _nameController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
      iconUrl: widget.source?.iconUrl,
      description: _descriptionController.text.trim(),
      pipeline: pipeline,
      enabled: _enabled,
      createdAt: widget.source?.createdAt,
    );
  }

  SourceRule? _validateCurrentRule({bool showMessage = true}) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return null;

    final pipeline = _parsePipeline();
    if (pipeline == null) return null;
    final rule = RuleMigrator.ruleForConfig(_buildConfig(pipeline));
    final validation = RuleValidator.validate(rule);
    if (!validation.isValid) {
      if (showMessage) {
        showSnackBar('规则校验失败：${validation.errors.join('；')}', isError: true);
      }
      return null;
    }
    return rule;
  }

  Future<void> _save() async {
    if (_isSaving) return;
    HapticFeedback.mediumImpact();

    final rule = _validateCurrentRule();
    if (rule == null) return;

    setState(() => _isSaving = true);
    try {
      final config = _buildConfig(_parsePipeline()!);
      final saved = _isEditing
          ? await _manager.updateCustomSource(config)
          : await _manager.addCustomSource(config);
      if (!mounted) return;
      if (!saved) {
        showSnackBar(_isEditing ? '图源不存在，无法更新' : '图源 ID 已存在', isError: true);
        return;
      }
      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) showSnackBar('保存失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _formatPipeline() {
    final pipeline = _parsePipeline();
    if (pipeline == null) {
      _formKey.currentState?.validate();
      showSnackBar('规则 JSON 格式无效', isError: true);
      return;
    }
    _pipelineController.value = TextEditingValue(
      text: _encodePipeline(pipeline),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _formKey.currentState?.validate();
    showSnackBar('规则已格式化');
  }

  Future<void> _pastePipeline() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboard?.text?.trim();
    if (text == null || text.isEmpty) {
      showSnackBar('剪贴板中没有文本', isError: true);
      return;
    }

    try {
      final decoded = SourceCodec.decode(text);
      if (decoded is! Map) throw const FormatException();
      final json = Map<String, dynamic>.from(decoded);
      final pipeline = json['pipeline'] is Map
          ? Map<String, dynamic>.from(json['pipeline'] as Map)
          : <String, dynamic>{
              if (json['recipes'] != null) 'recipes': json['recipes'],
              if (json['headers'] != null) 'headers': json['headers'],
              if (json['search'] != null) 'search': json['search'],
              if (json['detail'] != null) 'detail': json['detail'],
              if (json['play'] != null) 'play': json['play'],
              if (json['useWebview'] != null) 'useWebview': json['useWebview'],
              if (json['directConnection'] != null)
                'directConnection': json['directConnection'],
            };
      if (pipeline.isEmpty) throw const FormatException();

      setState(() {
        _pipelineController.text = _encodePipeline(pipeline);
        _testSeriesUrl = null;
        _testEpisodeUrl = null;
        for (final stage in _TestStage.values) {
          _testLogs[stage] = '';
        }
      });
      _formKey.currentState?.validate();
      showSnackBar('已粘贴规则');
    } catch (_) {
      showSnackBar('剪贴板内容不是有效的规则', isError: true);
    }
  }

  void _copyJson() {
    final rule = _validateCurrentRule();
    if (rule == null) return;
    final config = _buildConfig(_parsePipeline()!);
    final json = const JsonEncoder.withIndent('  ').convert(config.toJson());
    Clipboard.setData(ClipboardData(text: json));
    showSnackBar('配置 JSON 已复制');
  }

  void _copyShareLink() {
    final rule = _validateCurrentRule();
    if (rule == null) return;
    final config = _buildConfig(_parsePipeline()!);
    final link = SourceCodec.encode(config.toJson());
    Clipboard.setData(ClipboardData(text: link));
    showSnackBar('baka:// 分享链接已复制');
  }

  Future<void> _runTest(
    _TestStage stage,
    Future<String> Function(PipelineSourceAdapter adapter) action,
  ) async {
    if (_runningTest != null) return;
    final rule = _validateCurrentRule();
    if (rule == null) return;

    HapticFeedback.mediumImpact();
    setState(() {
      _runningTest = stage;
      switch (stage) {
        case _TestStage.search:
          _testSeriesUrl = null;
          _testEpisodeUrl = null;
          _testLogs[stage] = '[搜索] ${_testKeywordController.text.trim()}\n';
          _testLogs[_TestStage.episodes] = '';
          _testLogs[_TestStage.playback] = '';
          break;
        case _TestStage.episodes:
          _testEpisodeUrl = null;
          _testLogs[stage] = '[剧集] $_testSeriesUrl\n';
          _testLogs[_TestStage.playback] = '';
          break;
        case _TestStage.playback:
          _testLogs[stage] = '[播放] $_testEpisodeUrl\n';
          break;
      }
    });

    try {
      final adapter = PipelineSourceAdapter(rule);
      final log = await action(adapter);
      if (mounted) setState(() => _testLogs[stage] = log);
    } catch (error, stackTrace) {
      if (!mounted) return;
      final stack = stackTrace.toString().split('\n').take(3).join('\n');
      setState(() {
        _testLogs[stage] = '${_testLogs[stage]}❌ 测试失败：$error\n$stack';
      });
    } finally {
      if (mounted) setState(() => _runningTest = null);
    }
  }

  void _testSearch() {
    _runTest(_TestStage.search, (adapter) async {
      final keyword = _testKeywordController.text.trim();
      if (keyword.isEmpty) throw const FormatException('请输入测试关键词');
      final results = await adapter.search('', keyword);
      if (results.isEmpty) return '⚠️ 未找到搜索结果';

      _testSeriesUrl = results.first.seriesId;
      final preview = results
          .take(5)
          .map((item) => '${item.name}\n${item.seriesId}')
          .join('\n\n');
      return '✅ 找到 ${results.length} 条结果\n\n$preview';
    });
  }

  void _testEpisodes() {
    final seriesUrl = _testSeriesUrl;
    if (seriesUrl == null) return;
    _runTest(_TestStage.episodes, (adapter) async {
      final sources = await adapter.getSources(seriesUrl);
      if (sources.isEmpty) return '⚠️ 未提取到播放线路';

      for (final source in sources) {
        if (source.episodes.isNotEmpty) {
          _testEpisodeUrl = source.episodes.first.episodeId;
          break;
        }
      }
      final preview = sources
          .map(
            (source) =>
                '${source.sourceName ?? '默认线路'}：${source.episodes.length} 集',
          )
          .join('\n');
      return '✅ 找到 ${sources.length} 条播放线路\n\n$preview';
    });
  }

  void _testPlayback() {
    final episodeUrl = _testEpisodeUrl;
    if (episodeUrl == null) return;
    _runTest(_TestStage.playback, (adapter) async {
      final url = await adapter.resolveDownloadUrl(
        episodeUrl,
        forceRefresh: true,
      );
      return url.isEmpty ? '⚠️ 未提取到播放链接' : '✅ 播放链接\n\n$url';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑自定义源' : '新建自定义源'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const ShimmerCircle(size: 18)
                : const Text(
                    '保存',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            _buildIntroCard(),
            const SizedBox(height: 24),
            _buildSectionTitle('基础信息'),
            _buildSection(
              children: [
                _buildTextField(
                  controller: _nameController,
                  label: '名称',
                  hint: '例如：示例动漫',
                  prefixIcon: Icons.badge_outlined,
                  validator: _validateName,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                _buildTextField(
                  controller: _baseUrlController,
                  label: '站点主页',
                  hint: 'https://example.com',
                  prefixIcon: Icons.language_rounded,
                  validator: _validateBaseUrl,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                _buildTextField(
                  controller: _descriptionController,
                  label: '描述',
                  hint: '可选，用于说明规则用途或注意事项',
                  prefixIcon: Icons.notes_rounded,
                  minLines: 2,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用图源'),
                  subtitle: const Text('保存后立即参与搜索和播放'),
                  secondary: const Icon(Icons.power_settings_new_rounded),
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildSectionTitle('规则 JSON'),
            _buildSection(
              children: [
                Text(
                  '手动填写 anx-rule/2 的规则主体，支持 recipes、headers、search、detail、play、useWebview 和 directConnection。',
                  style: TextStyle(
                    color: context.theme.hintColor,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _pipelineController,
                  validator: _validatePipeline,
                  minLines: 14,
                  maxLines: 24,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.45,
                  ),
                  decoration: InputDecoration(
                    labelText: '规则主体',
                    alignLabelWithHint: true,
                    hintText:
                        '{\n  "search": [],\n  "detail": [],\n  "play": []\n}',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                  ),
                  onChanged: (_) {
                    _testSeriesUrl = null;
                    _testEpisodeUrl = null;
                  },
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _formatPipeline,
                      icon: const Icon(
                        Icons.format_align_left_rounded,
                        size: 18,
                      ),
                      label: const Text('格式化'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _pastePipeline,
                      icon: const Icon(Icons.content_paste_rounded, size: 18),
                      label: const Text('粘贴规则'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _copyJson,
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('复制 JSON'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _copyShareLink,
                      icon: const Icon(Icons.link_rounded, size: 18),
                      label: const Text('复制分享链接'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildSectionTitle('规则测试'),
            _buildSection(
              children: [
                _buildTextField(
                  controller: _testKeywordController,
                  label: '测试关键词',
                  hint: '输入一个站内能搜到的标题',
                  prefixIcon: Icons.search_rounded,
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: 16),
                _buildTestStep(
                  number: 1,
                  title: '测试搜索',
                  description: '验证 search 管线并取得第一条详情地址',
                  stage: _TestStage.search,
                  onPressed: _testSearch,
                ),
                const Divider(height: 32),
                _buildTestStep(
                  number: 2,
                  title: '测试剧集',
                  description: _testSeriesUrl ?? '请先完成搜索测试',
                  stage: _TestStage.episodes,
                  onPressed: _testSeriesUrl == null ? null : _testEpisodes,
                ),
                const Divider(height: 32),
                _buildTestStep(
                  number: 3,
                  title: '测试播放',
                  description: _testEpisodeUrl ?? '请先完成剧集测试',
                  stage: _TestStage.playback,
                  onPressed: _testEpisodeUrl == null ? null : _testPlayback,
                ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: _isSaving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded),
              label: Text(_isSaving ? '保存中...' : '保存图源'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroCard() {
    return Material(
      color: context.primaryColor.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.code_rounded, color: context.primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '手动配置图源',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '填写站点信息和规则 JSON，保存前可依次测试搜索、剧集与播放链接。',
                    style: TextStyle(
                      color: context.theme.hintColor,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: TextStyle(
          color: context.theme.hintColor,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildSection({required List<Widget> children}) {
    return Material(
      color: context.cardColor,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData prefixIcon,
    String? hint,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    int minLines = 1,
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      minLines: minLines,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(prefixIcon),
        alignLabelWithHint: maxLines > 1,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
      ),
    );
  }

  Widget _buildTestStep({
    required int number,
    required String title,
    required String description,
    required _TestStage stage,
    required VoidCallback? onPressed,
  }) {
    final isRunning = _runningTest == stage;
    final log = _testLogs[stage] ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.primaryColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Text(
                '$number',
                style: TextStyle(
                  color: context.primaryColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.theme.hintColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(
              onPressed: _runningTest == null ? onPressed : null,
              child: isRunning
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('运行'),
            ),
          ],
        ),
        if (log.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.theme.scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                log,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.45,
                  color: log.contains('❌')
                      ? context.colorScheme.error
                      : context.theme.textTheme.bodyMedium?.color,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
