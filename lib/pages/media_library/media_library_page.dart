import 'dart:io';

import 'package:baka/pages/media_library/storage_browser_page.dart';
import 'package:baka/pages/media_library/storage_config_page.dart';
import 'package:baka/storage/local_storage_provider.dart';
import 'package:baka/storage/storage_config.dart';
import 'package:baka/storage/storage_provider.dart';
import 'package:baka/storage/webdav_storage_provider.dart';
import 'package:baka/widgets/common/shimmer.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// 媒体库主页：展示所有存储源
class MediaLibraryPage extends StatefulWidget {
  const MediaLibraryPage({super.key});

  @override
  State<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends State<MediaLibraryPage> {
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _initFuture = StorageConfigService.init();
  }

  StorageProvider _createProvider(StorageConfig config) {
    switch (config.type) {
      case StorageProviderType.local:
        return LocalStorageProvider(rootPath: config.path, name: config.name);
      case StorageProviderType.webdav:
        return WebDavStorageProvider(
          baseUrl: config.path,
          username: config.username ?? '',
          password: config.password ?? '',
          rootPath: config.rootPath,
          name: config.name,
        );
      case StorageProviderType.smb:
        throw UnimplementedError('SMB 暂不支持');
    }
  }

  Future<void> _openStorage(StorageConfig config) async {
    try {
      if (config.type == StorageProviderType.local &&
          !await _ensureLocalVideoPermission()) {
        _showLocalPermissionDeniedMessage();
        return;
      }

      final provider = _createProvider(config);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => StorageBrowserPage(
            provider: provider,
            initialPath: config.type == StorageProviderType.local
                ? config.path
                : config.rootPath,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开失败: $e')));
      }
    }
  }

  Future<void> _addLocalFolder() async {
    if (!await _ensureLocalVideoPermission()) {
      _showLocalPermissionDeniedMessage();
      return;
    }

    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;

    final config = StorageConfig(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      name: result.split(Platform.pathSeparator).last,
      type: StorageProviderType.local,
      path: result,
    );
    await StorageConfigService.save(config);
  }

  Future<bool> _ensureLocalVideoPermission() async {
    if (!Platform.isAndroid) return true;

    final sdkInt = await _androidSdkInt();
    final permission = sdkInt >= 33 ? Permission.videos : Permission.storage;
    var status = await permission.status;
    if (status.isGranted) return true;

    status = await permission.request();
    return status.isGranted;
  }

  Future<int> _androidSdkInt() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt;
    } catch (_) {
      return 33;
    }
  }

  void _showLocalPermissionDeniedMessage() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('需要视频访问权限才能读取本地媒体文件'),
        action: SnackBarAction(
          label: '去开启',
          onPressed: () => openAppSettings(),
        ),
      ),
    );
  }

  Future<void> _addWebDav() async {
    final result = await Navigator.push<StorageConfig>(
      context,
      MaterialPageRoute(builder: (_) => const StorageConfigPage()),
    );
    if (result != null) {
      await StorageConfigService.save(result);
    }
  }

  Future<void> _editConfig(StorageConfig config) async {
    final result = await Navigator.push<StorageConfig>(
      context,
      MaterialPageRoute(
        builder: (_) => StorageConfigPage(existingConfig: config),
      ),
    );
    if (result != null) {
      await StorageConfigService.save(result);
    }
  }

  Future<void> _deleteConfig(StorageConfig config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除存储源'),
        content: Text('确定删除「${config.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await StorageConfigService.delete(config.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('媒体库'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add_rounded),
            tooltip: '添加存储源',
            onSelected: (value) {
              if (value == 'local') _addLocalFolder();
              if (value == 'webdav') _addWebDav();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'local', child: Text('本地文件夹')),
              PopupMenuItem(value: 'webdav', child: Text('WebDAV 服务器')),
            ],
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _buildStorageListSkeleton();
          }
          return ValueListenableBuilder<List<StorageConfig>>(
            valueListenable: StorageConfigService.configsListenable,
            builder: (context, configs, _) {
              if (configs.isEmpty) return _buildEmptyState(theme);
              return ListView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                itemCount: configs.length,
                itemBuilder: (context, index) => _StorageTile(
                  config: configs[index],
                  onTap: () => _openStorage(configs[index]),
                  onEdit: () => _editConfig(configs[index]),
                  onDelete: () => _deleteConfig(configs[index]),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildStorageListSkeleton() {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: 4,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (_, _) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            ShimmerBox(
              width: 28,
              height: 28,
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShimmerTextLine(height: 16, widthFactor: 0.42),
                  SizedBox(height: 8),
                  ShimmerTextLine(height: 12, widthFactor: 0.78),
                ],
              ),
            ),
            SizedBox(width: 16),
            ShimmerBox(
              width: 20,
              height: 20,
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_open_rounded,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            '还没有添加存储源',
            style: TextStyle(
              fontSize: 15,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '点击右上角 + 添加本地文件夹或 WebDAV 服务器',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageTile extends StatelessWidget {
  final StorageConfig config;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _StorageTile({
    required this.config,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  IconData get _icon {
    switch (config.type) {
      case StorageProviderType.local:
        return Icons.folder_rounded;
      case StorageProviderType.webdav:
        return Icons.cloud_rounded;
      case StorageProviderType.smb:
        return Icons.lan_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: Icon(_icon, color: theme.colorScheme.primary, size: 28),
      title: Text(
        config.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        config.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: PopupMenuButton<String>(
        icon: Icon(
          Icons.more_vert_rounded,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        onSelected: (value) {
          if (value == 'edit') onEdit();
          if (value == 'delete') onDelete();
        },
        itemBuilder: (_) => [
          if (config.type == StorageProviderType.webdav)
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
          PopupMenuItem(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: theme.colorScheme.error)),
          ),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}
