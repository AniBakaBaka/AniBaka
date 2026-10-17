import 'package:baka/core/network_service.dart';
import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:baka/models/update_info.dart';

final _imagePattern = RegExp(r'!\[.*?\]\((.*?)\)');

Widget _buildRichText(BuildContext context, String text) {
  final textStyle = TextStyle(
    fontSize: 14,
    height: 1.6,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  final List<Widget> children = [];
  int lastEnd = 0;

  for (final match in _imagePattern.allMatches(text)) {
    if (match.start > lastEnd) {
      children.add(
        Text(text.substring(lastEnd, match.start), style: textStyle),
      );
    }

    final url = match.group(1)!;
    if (url.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(
                width: double.infinity,
                height: 160,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              errorWidget: (context, url, error) =>
                  const Icon(Icons.broken_image),
            ),
          ),
        ),
      );
    }
    lastEnd = match.end;
  }

  if (lastEnd == 0) return Text(text, style: textStyle);
  if (lastEnd < text.length) {
    children.add(Text(text.substring(lastEnd), style: textStyle));
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: children,
  );
}

Future<void> _downloadAndInstall(
  BuildContext context,
  String downloadUrl,
) async {
  if (Platform.isIOS) {
    await launchUrlString(downloadUrl, mode: LaunchMode.externalApplication);
    return;
  }
  if (Platform.isAndroid) {
    final status = await Permission.requestInstallPackages.request();
    if (!status.isGranted) return;
  }
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DownloadDialog(downloadUrl),
  );
}

class _DownloadDialog extends StatefulWidget {
  final String downloadUrl;
  const _DownloadDialog(this.downloadUrl);

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  final _client = NetworkService.createDio();
  final _cancelToken = CancelToken();
  int? _percent;
  String _status = '正在下载...';
  String? _error;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    super.dispose();
  }

  Future<void> _startDownload() async {
    try {
      final dir = Platform.isAndroid
          ? await getTemporaryDirectory()
          : await Instances.desktopDataDirectory('updates');
      if (!mounted) return;
      final fileName = switch (Platform.operatingSystem) {
        'android' => 'app_update.apk',
        'windows' => 'anibaka-setup.exe',
        'macos' => 'anibaka-setup.dmg',
        _ => throw UnsupportedError('当前平台不支持应用内更新'),
      };
      final filePath = '${dir.path}/$fileName';

      await _client.download(
        widget.downloadUrl,
        filePath,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          if (!mounted || total <= 0) return;
          final percent = received * 100 ~/ total;
          if (percent == _percent) return;
          setState(() {
            _percent = percent;
            final receivedMB = (received / 1048576).toStringAsFixed(2);
            final totalMB = (total / 1048576).toStringAsFixed(2);
            _status = '已下载 $receivedMB MB / $totalMB MB';
          });
        },
      );

      if (!mounted) return;
      final result = await OpenFilex.open(filePath);
      if (!mounted) return;
      if (result.type == ResultType.done) {
        Navigator.pop(context);
      } else {
        setState(() => _error = '无法打开安装包: ${result.message}');
      }
    } catch (e) {
      if (mounted && !_cancelToken.isCancelled) {
        setState(() => _error = '更新失败: $e');
      }
    } finally {
      _client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _error != null,
      child: AppDialog(
        title: '下载更新',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error == null) ...[
              LinearProgressIndicator(
                value: _percent == null ? null : _percent! / 100,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 12),
              if (_percent != null)
                Text(
                  '$_percent%',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              const SizedBox(height: 16),
            ],
            Text(
              _error ?? _status,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: _error == null
            ? null
            : AppDialogActions(
                confirmText: '关闭',
                onConfirm: () => Navigator.pop(context),
              ),
      ),
    );
  }
}

void showAnnouncementDialog({
  required String content,
  required UpdateInfo updateInfo,
}) {
  final context = Instances.currentContext;
  if (context == null) return;
  final hasUpdate = updateInfo.hasUpdate;
  final forceUpdate = updateInfo.forceUpdate;
  var installing = false;

  showDialog(
    barrierDismissible: !forceUpdate,
    context: context,
    builder: (BuildContext dialogContext) {
      final colorScheme = Theme.of(dialogContext).colorScheme;
      return PopScope(
        canPop: !forceUpdate,
        child: AppDialog(
          title: forceUpdate ? '强制更新' : (hasUpdate ? '版本更新' : '公告'),
          content: hasUpdate
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          Instances.appVersion,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Icon(
                            Icons.arrow_forward,
                            size: 20,
                            color: colorScheme.primary,
                          ),
                        ),
                        Text(
                          updateInfo.latestVersion,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    if (updateInfo.changelog.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _buildRichText(
                          dialogContext,
                          updateInfo.changelog,
                        ),
                      ),
                    ],
                    if (content.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 8),
                      _buildRichText(dialogContext, content),
                    ],
                  ],
                )
              : (content.isNotEmpty
                    ? _buildRichText(dialogContext, content)
                    : null),
          actions: AppDialogActions(
            confirmText: hasUpdate ? (forceUpdate ? '立即更新' : '有新版本') : '知道了',
            cancelText: hasUpdate && !forceUpdate ? '知道了' : null,
            isDestructive: forceUpdate,
            onConfirm: () async {
              if (!hasUpdate) {
                Navigator.pop(dialogContext);
                return;
              }
              if (installing) return;
              installing = true;
              try {
                if (!forceUpdate) Navigator.pop(dialogContext);
                await _downloadAndInstall(context, updateInfo.downloadUrl);
              } finally {
                installing = false;
              }
            },
          ),
        ),
      );
    },
  );
}
