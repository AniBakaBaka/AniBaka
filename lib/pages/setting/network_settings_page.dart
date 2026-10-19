import 'package:flutter/material.dart';

import 'package:baka/core/network_settings.dart';
import 'package:baka/instance.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class NetworkSettingsPage extends StatefulWidget {
  const NetworkSettingsPage({super.key});

  @override
  State<NetworkSettingsPage> createState() => _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends State<NetworkSettingsPage> {
  final _form = GlobalKey<FormState>();
  late final _saved = NetworkSettings.load(Instances.sp);
  late bool _doh = _saved.dohEnabled;
  late bool _ech = _saved.echEnabled;
  late final _endpoint = TextEditingController(text: _saved.dohEndpoint);

  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    await NetworkSettings(
      dohEnabled: _doh,
      echEnabled: _ech,
      dohEndpoint: _endpoint.text.trim(),
    ).save(Instances.sp);
    showSnackBar('已保存，重启应用后生效');
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: SettingsPage(
      title: '网络设置',
      children: [
        SettingsSection(
          title: '隐私保护',
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.dns_outlined),
              title: const Text('加密 DNS（DoH）'),
              subtitle: const Text('加密 DNS 查询，减少被监听和篡改的风险。'),
              value: _doh,
              onChanged: (v) => setState(() => _doh = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.enhanced_encryption_outlined),
              title: const Text('加密客户端问候（ECH）'),
              subtitle: const Text(
                '加密连接时发送的域名信息，保护访问隐私。'
                '需要网站支持，可单独开启，搭配 DoH 使用效果更好。',
              ),
              value: _ech,
              onChanged: (v) => setState(() => _ech = v),
            ),
          ],
        ),
        SettingsSection(
          title: 'DNS 服务',
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextFormField(
                controller: _endpoint,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'DoH 服务地址',
                  hintText: NetworkSettings.defaultEndpoint,
                  helperText: '填写支持 DoH 的 HTTPS 地址，DoH 和 ECH 均使用此服务。',
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  try {
                    NetworkSettings.validateEndpoint(value!);
                    return null;
                  } on FormatException catch (e) {
                    return e.message;
                  }
                },
              ),
            ),
            const SettingsTile(
              icon: Icons.info_outline_rounded,
              title: '默认 DNS 服务',
              subtitle: '默认使用 Cloudflare（1.1.1.1），也可填写其他 DoH 服务地址。',
            ),
          ],
        ),
        const SettingsSection(
          title: '使用说明',
          children: [
            SettingsTile(
              icon: Icons.sync_problem_outlined,
              title: '无法联网时',
              subtitle:
                  '如果开启后无法联网，可尝试更换 DNS 服务，或关闭相关选项后保存并重启。'
                  '不支持 ECH 的网站仍使用普通 HTTPS 连接。',
            ),
            SettingsTile(
              icon: Icons.restart_alt_rounded,
              title: '保存并重启后生效',
              subtitle:
                  '适用于应用内的数据加载、搜索、图片及下载。'
                  '内置网页、部分视频播放和 BT 连接不受此设置影响。',
            ),
          ],
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    ),
  );
}
