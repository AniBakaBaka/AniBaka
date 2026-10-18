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
              title: const Text('DNS over HTTPS（DoH）'),
              subtitle: const Text(
                '通过 HTTPS 加密“域名转 IP 地址”的 DNS 查询，减少查询途中被窃听或篡改的风险。'
                '所选 DoH 服务商仍可看到查询域名；仅开启 DoH 无法隐藏 HTTPS 握手中的域名。',
              ),
              value: _doh,
              onChanged: (v) => setState(() => _doh = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.enhanced_encryption_outlined),
              title: const Text('Encrypted Client Hello（ECH）'),
              subtitle: const Text(
                '加密 HTTPS 握手中的真实域名（SNI），进一步减少访问目标的泄露。'
                '需要目标站点支持并发布 ECH 配置，无法隐藏目标 IP 地址。'
                '可单独开启；仅开启 ECH 时，通过下方服务查询 ECH 配置，IP 地址仍使用系统 DNS 解析。',
              ),
              value: _ech,
              onChanged: (v) => setState(() => _ech = v),
            ),
          ],
        ),
        SettingsSection(
          title: 'DoH / ECH 配置查询服务',
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
                  helperText: '填写完整的 HTTPS 地址，服务需支持标准 DoH 查询（RFC 8484）。',
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
              title: '默认服务与首次连接',
              subtitle:
                  '默认使用 Cloudflare（1.1.1.1）的 IP 地址端点，避免首次连接时解析 DoH 服务域名。'
                  '自定义域名端点及代理服务器地址仍可能通过系统 DNS 解析。',
            ),
          ],
        ),
        const SettingsSection(
          title: '使用说明',
          children: [
            SettingsTile(
              icon: Icons.sync_problem_outlined,
              title: '连接失败时的行为',
              subtitle:
                  '开启 DoH 后，普通公网域名查询失败时，请求会报错，不会回退到系统 DNS；本机及局域网名称仍使用本地解析。'
                  '未发布 ECH 配置的站点使用普通 HTTPS；已获取配置但 ECH 握手失败时，请求会报错。',
            ),
            SettingsTile(
              icon: Icons.restart_alt_rounded,
              title: '保存并重启后生效',
              subtitle:
                  '适用于应用接口、搜索源、图片及下载等内置网络请求。'
                  'WebView、播放器原生直连及 BT 的 UDP / Peer 连接不受此设置控制。',
            ),
          ],
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    ),
  );
}
