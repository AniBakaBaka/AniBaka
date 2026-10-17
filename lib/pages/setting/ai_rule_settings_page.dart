import 'package:flutter/material.dart';

import 'package:baka/models/ai_rule_authoring.dart';
import 'package:baka/services/source/ai_rule_authoring_service.dart';
import 'package:baka/services/source/ai_rule_settings.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class AiRuleSettingsPage extends StatefulWidget {
  const AiRuleSettingsPage({super.key});

  @override
  State<AiRuleSettingsPage> createState() => _AiRuleSettingsPageState();
}

class _AiRuleSettingsPageState extends State<AiRuleSettingsPage> {
  static const _presets = [
    (name: 'DeepSeek', url: 'https://api.deepseek.com/v1', model: 'deepseek-chat'),
    (
      name: 'SiliconFlow',
      url: 'https://api.siliconflow.cn/v1',
      model: 'deepseek-ai/DeepSeek-V3',
    ),
    (name: 'OpenAI', url: 'https://api.openai.com/v1', model: 'gpt-4o-mini'),
    (name: 'Ollama', url: 'http://localhost:11434/v1', model: 'qwen2.5:7b'),
  ];

  final _form = GlobalKey<FormState>();
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _apiKey = TextEditingController();
  bool _obscureKey = true;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await AiRuleSettingsService.instance.load();
    if (!mounted) return;
    _baseUrl.text = config.baseUrl;
    _model.text = config.model;
    _apiKey.text = config.apiKey;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  AiProviderConfig get _config => AiProviderConfig(
    baseUrl: _baseUrl.text.trim(),
    model: _model.text.trim(),
    apiKey: _apiKey.text.trim(),
  );

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    await AiRuleSettingsService.instance.save(_config);
    showSnackBar('已保存');
    if (mounted) Navigator.pop(context);
  }

  Future<void> _test() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _testing = true);
    final service = AiRuleAuthoringService();
    try {
      await service.testConnection(_config);
      showSnackBar('连接成功');
    } catch (e) {
      showSnackBar('连接失败：$e', isError: true);
    } finally {
      service.dispose();
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: SettingsPage(
      title: 'AI 规则编写',
      children: [
        SettingsSection(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                spacing: 16,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in _presets)
                        ActionChip(
                          label: Text(preset.name),
                          onPressed: () {
                            _baseUrl.text = preset.url;
                            _model.text = preset.model;
                          },
                        ),
                    ],
                  ),
                  TextFormField(
                    controller: _baseUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'https://api.openai.com/v1',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final uri = Uri.tryParse(value!.trim());
                      return uri != null &&
                              (uri.scheme == 'http' || uri.scheme == 'https') &&
                              uri.host.isNotEmpty
                          ? null
                          : '请输入有效的 HTTP(S) 地址';
                    },
                  ),
                  TextFormField(
                    controller: _model,
                    decoration: const InputDecoration(
                      labelText: '模型',
                      hintText: 'deepseek-chat',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        value!.trim().isEmpty ? '请输入模型名称' : null,
                  ),
                  TextFormField(
                    controller: _apiKey,
                    obscureText: _obscureKey,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: 'sk-...',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                        icon: Icon(
                          _obscureKey
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Row(
          spacing: 12,
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _testing ? null : _test,
                child: Text(_testing ? '测试中…' : '测试连接'),
              ),
            ),
            Expanded(
              child: FilledButton(onPressed: _save, child: const Text('保存')),
            ),
          ],
        ),
      ],
    ),
  );
}
