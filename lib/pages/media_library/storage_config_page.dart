import 'package:baka/storage/storage_config.dart';
import 'package:baka/storage/storage_provider.dart';
import 'package:baka/storage/webdav_storage_provider.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:flutter/material.dart';

/// WebDAV 连接配置页面（新增/编辑）
class StorageConfigPage extends StatefulWidget {
  final StorageConfig? existingConfig;

  const StorageConfigPage({super.key, this.existingConfig});

  @override
  State<StorageConfigPage> createState() => _StorageConfigPageState();
}

class _StorageConfigPageState extends State<StorageConfigPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _rootPathController;

  bool _isTesting = false;
  bool _obscurePassword = true;
  bool? _testSuccess;
  String? _testMessage;

  bool get _isEditing => widget.existingConfig != null;

  @override
  void initState() {
    super.initState();
    final c = widget.existingConfig;
    _nameController = TextEditingController(text: c?.name ?? '');
    _urlController = TextEditingController(text: c?.path ?? '');
    _usernameController = TextEditingController(text: c?.username ?? '');
    _passwordController = TextEditingController(text: c?.password ?? '');
    _rootPathController = TextEditingController(text: c?.rootPath ?? '/');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _rootPathController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isTesting = true;
      _testSuccess = null;
      _testMessage = null;
    });

    try {
      final provider = WebDavStorageProvider(
        baseUrl: _urlController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        rootPath: _rootPathController.text.trim(),
      );

      final success = await provider.testConnection();
      provider.dispose();

      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _testSuccess = success;
        _testMessage = success ? '连接成功' : '连接失败，请检查配置';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _testSuccess = false;
        _testMessage = '连接错误: $e';
      });
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final config = StorageConfig(
      id:
          widget.existingConfig?.id ??
          'webdav_${DateTime.now().millisecondsSinceEpoch}',
      name: _nameController.text.trim(),
      type: StorageProviderType.webdav,
      path: _urlController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      rootPath: _rootPathController.text.trim(),
    );

    Navigator.pop(context, config);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑 WebDAV' : '添加 WebDAV'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildField(
                controller: _nameController,
                label: '显示名称',
                hint: '例如：NAS 动漫',
                validator: (v) =>
                    v == null || v.trim().isEmpty ? '请输入名称' : null,
              ),
              const SizedBox(height: 16),
              _buildField(
                controller: _urlController,
                label: '服务器地址',
                hint: 'https://your-server.com/dav',
                keyboardType: TextInputType.url,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return '请输入服务器地址';
                  final uri = Uri.tryParse(v.trim());
                  if (uri == null || !uri.hasScheme) return '请输入有效的 URL';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              _buildField(
                controller: _usernameController,
                label: '用户名',
                hint: '可选',
              ),
              const SizedBox(height: 16),
              _buildField(
                controller: _passwordController,
                label: '密码',
                hint: '可选',
                obscureText: _obscurePassword,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              const SizedBox(height: 16),
              _buildField(
                controller: _rootPathController,
                label: '根目录路径',
                hint: '/',
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _isTesting ? null : _testConnection,
                icon: _isTesting
                    ? const ShimmerCircle(size: 18)
                    : const Icon(Icons.wifi_tethering_rounded, size: 20),
                label: Text(_isTesting ? '测试中...' : '测试连接'),
              ),
              if (_testSuccess != null) ...[
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _testSuccess!
                          ? Icons.check_circle_rounded
                          : Icons.error_rounded,
                      color: _testSuccess!
                          ? Colors.green
                          : theme.colorScheme.error,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _testMessage!,
                        style: TextStyle(
                          fontSize: 13,
                          color: _testSuccess!
                              ? Colors.green
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    String? hint,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    bool obscureText = false,
    Widget? suffixIcon,
  }) {
    return TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      obscureText: obscureText,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
