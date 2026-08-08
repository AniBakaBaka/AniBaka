import 'package:baka/pages/player/player_page.dart';
import 'package:baka/storage/storage_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/widgets/common/skeletonizer.dart';

/// 文件浏览器页面：浏览目录和文件，点击视频播放
class StorageBrowserPage extends StatefulWidget {
  final StorageProvider provider;
  final String initialPath;

  const StorageBrowserPage({
    required this.provider,
    required this.initialPath,
    super.key,
  });

  @override
  State<StorageBrowserPage> createState() => _StorageBrowserPageState();
}

class _StorageBrowserPageState extends State<StorageBrowserPage> {
  late String _currentPath;
  List<StorageItem> _visibleItems = [];
  bool _dirIsEmpty = true;
  bool _isLoading = true;
  String? _error;
  int _loadGeneration = 0;

  final List<String> _pathStack = [];

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _loadDirectory(_currentPath);
  }

  @override
  void dispose() {
    widget.provider.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory(String path) async {
    final loadGeneration = ++_loadGeneration;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final items = await widget.provider.listDirectory(path);
      if (!mounted || loadGeneration != _loadGeneration) return;
      setState(() {
        _dirIsEmpty = items.isEmpty;
        _visibleItems = items
            .where((item) => item.isDirectory || item.isVideo)
            .toList(growable: false);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || loadGeneration != _loadGeneration) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _navigateToDirectory(StorageItem item) {
    _pathStack.add(_currentPath);
    _currentPath = item.path;
    _loadDirectory(_currentPath);
  }

  bool _navigateBack() {
    if (_pathStack.isEmpty) return false;
    _currentPath = _pathStack.removeLast();
    _loadDirectory(_currentPath);
    return true;
  }

  Future<void> _playVideo(StorageItem item) async {
    try {
      final url = widget.provider.playableUrl(item.path);
      final headers = widget.provider.httpHeaders;
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            data: {
              'source': '_local',
              'title': widget.provider.displayName,
              'episodeTitle': item.name,
              'localFilePath': url,
              'id': 0,
              'httpHeaders': ?headers,
            },
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('播放失败: $e')));
      }
    }
  }

  void _onItemTap(StorageItem item) {
    HapticFeedback.lightImpact();
    if (item.isDirectory) {
      _navigateToDirectory(item);
    } else {
      _playVideo(item);
    }
  }

  String get _currentDirName {
    final name = StoragePath.name(_currentPath);
    return name.isEmpty ? widget.provider.displayName : name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: _pathStack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _navigateBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _currentDirName,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          scrolledUnderElevation: 0.5,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () {
              if (!_navigateBack()) Navigator.pop(context);
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => _loadDirectory(_currentPath),
              tooltip: '刷新',
            ),
          ],
        ),
        body: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return AppSkeletonizer(
        enabled: true,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: 6,
          itemBuilder: (context, index) => _ListItemTile(
            item: StorageItem(
              name: '媒体文件名称占位符.mp4',
              path: '/dummy.mp4',
              type: StorageItemType.file,
              size: 1024000,
            ),
            onTap: () {},
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => _loadDirectory(_currentPath),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_visibleItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _dirIsEmpty
                  ? Icons.folder_open_rounded
                  : Icons.videocam_off_rounded,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              _dirIsEmpty ? '此目录为空' : '没有可播放的媒体文件',
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _visibleItems.length,
      itemBuilder: (context, index) {
        final item = _visibleItems[index];
        return _ListItemTile(item: item, onTap: () => _onItemTap(item));
      },
    );
  }


}

class _ListItemTile extends StatelessWidget {
  final StorageItem item;
  final VoidCallback onTap;

  const _ListItemTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: _FileIcon(item: item, size: 32),
      title: Text(
        item.name,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: item.isFile
          ? Text(
              [
                if (item.displaySize.isNotEmpty) item.displaySize,
                if (item.modified != null) _formatDate(item.modified!),
              ].join(' · '),
              style: TextStyle(
                fontSize: 12,
                color: theme.textTheme.bodyMedium?.color?.withValues(
                  alpha: 0.4,
                ),
              ),
            )
          : null,
      trailing: item.isDirectory
          ? Icon(
              Icons.chevron_right_rounded,
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.3),
            )
          : null,
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class _FileIcon extends StatelessWidget {
  final StorageItem item;
  final double size;

  const _FileIcon({required this.item, required this.size});

  @override
  Widget build(BuildContext context) {
    if (item.isDirectory) {
      return Icon(
        Icons.folder_rounded,
        size: size,
        color: const Color(0xFFFFA726),
      );
    }
    return Icon(
      Icons.movie_rounded,
      size: size,
      color: const Color(0xFF42A5F5),
    );
  }
}
