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

import 'package:baka/utils/version_util.dart';

Widget _buildRichText(BuildContext context, String text) {
  if (text.isEmpty) return const SizedBox.shrink();

  final RegExp exp = RegExp(r'!\[.*?\]\((.*?)\)');
  final matches = exp.allMatches(text);
  final textStyle = TextStyle(
    fontSize: 14,
    height: 1.6,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  if (matches.isEmpty) {
    return Text(text, style: textStyle);
  }

  final List<Widget> children = [];
  int lastEnd = 0;

  for (final match in matches) {
    if (match.start > lastEnd) {
      children.add(
        Text(text.substring(lastEnd, match.start), style: textStyle),
      );
    }

    final url = match.group(1);
    if (url != null && url.isNotEmpty) {
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

  showDialog(
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
  double _progress = 0.0;
  String _status = '准备下载...';
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    try {
      final dir = Platform.isAndroid
          ? await getTemporaryDirectory()
          : Instances.isDesktopPlatform
          ? await Instances.desktopDataDirectory('updates')
          : await getDownloadsDirectory() ?? await getTemporaryDirectory();

      final fileName = Platform.isAndroid
          ? 'app_update.apk'
          : Platform.isWindows
          ? 'anibaka-setup.exe'
          : 'anibaka-setup.dmg';
      final filePath = '${dir.path}/$fileName';

      final file = File(filePath);
      if (await file.exists()) await file.delete();

      if (mounted) setState(() => _status = '正在下载...');

      await Dio().download(
        widget.downloadUrl,
        filePath,
        onReceiveProgress: (received, total) {
          if (total != -1 && mounted) {
            setState(() {
              _progress = received / total;
              final receivedMB = (received / 1048576).toStringAsFixed(2);
              final totalMB = (total / 1048576).toStringAsFixed(2);
              _status = '已下载 $receivedMB MB / $totalMB MB';
            });
          }
        },
      );

      if (mounted) Navigator.of(context).pop();
      await OpenFilex.open(filePath);
    } catch (e) {
      debugPrint('下载错误: $e');
      if (mounted) {
        setState(() {
          _failed = true;
          _status = '下载失败: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _failed,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '下载更新',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              LinearProgressIndicator(
                value: _progress,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 12),
              Text(
                '${(_progress * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _status,
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
              if (_failed) ...[
                const SizedBox(height: 20),
                FilledButton.tonal(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            ],
          ),
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
  final hasUpdate = updateInfo.hasUpdate;
  final forceUpdate = updateInfo.forceUpdate;
  final colorScheme = Theme.of(context).colorScheme;

  showDialog(
    barrierDismissible: !forceUpdate,
    context: context,
    builder: (BuildContext dialogContext) {
      return PopScope(
        canPop: !forceUpdate,
        child: AppDialog(
          title: forceUpdate ? '强制更新' : (hasUpdate ? '版本更新' : '公告'),
          contentWidget: hasUpdate
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
          actions: [
            if (hasUpdate)
              Row(
                children: [
                  if (!forceUpdate)
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => Navigator.pop(dialogContext),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('知道了'),
                      ),
                    ),
                  if (!forceUpdate) const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        if (!forceUpdate) Navigator.pop(dialogContext);
                        _downloadAndInstall(context, updateInfo.downloadUrl);
                      },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: forceUpdate ? colorScheme.error : null,
                        foregroundColor: forceUpdate
                            ? colorScheme.onError
                            : null,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(forceUpdate ? '立即更新' : '有新版本'),
                    ),
                  ),
                ],
              )
            else
              FilledButton.tonal(
                onPressed: () => Navigator.pop(dialogContext),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  minimumSize: const Size(double.infinity, 0),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('知道了'),
              ),
          ],
        ),
      );
    },
  );
}
