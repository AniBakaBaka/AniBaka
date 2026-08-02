import 'dart:async';

import 'package:baka/services/tv_log_export_service.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';
import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

Future<void> showTvLogExportDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const TvLogExportDialog(),
  );
}

class TvLogExportDialog extends StatefulWidget {
  const TvLogExportDialog({super.key});

  @override
  State<TvLogExportDialog> createState() => _TvLogExportDialogState();
}

class _TvLogExportDialogState extends State<TvLogExportDialog> {
  TvLogExportSession? _session;
  TvLogExportInfo? _info;
  StreamSubscription<int>? _downloadSubscription;
  Object? _error;
  int _downloads = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    unawaited(_downloadSubscription?.cancel());
    unawaited(_session?.stop());
    super.dispose();
  }

  Future<void> _prepare() async {
    final oldSession = _session;
    _session = null;
    await _downloadSubscription?.cancel();
    await oldSession?.stop();

    if (mounted) {
      setState(() {
        _info = null;
        _error = null;
        _downloads = 0;
      });
    }

    final session = TvLogExportSession();
    _session = session;
    try {
      AppLogger.instance.info('TV log export requested', tag: 'TvLogExport');
      final info = await session.start();
      _downloadSubscription = session.downloadCount.listen((count) {
        if (mounted) setState(() => _downloads = count);
      });
      if (mounted) setState(() => _info = info);
    } catch (error, stackTrace) {
      AppLogger.instance.error(
        'TV log export failed',
        tag: 'TvLogExport',
        error: error,
        stackTrace: stackTrace,
      );
      await session.stop();
      if (mounted) setState(() => _error = error);
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.goBack)) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Dialog(
        backgroundColor: context.tvPanelBgColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: SizedBox(
          width: 720,
          child: Padding(
            padding: const EdgeInsets.all(36),
            child: _buildContent(),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final info = _info;
    final error = _error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              Icons.qr_code_2_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: 30,
            ),
            const SizedBox(width: 14),
            Text(
              '导出日志',
              style: TextStyle(
                color: context.tvTextColor,
                fontSize: 26,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        if (info != null)
          _buildReady(info)
        else if (error != null)
          _buildError(error)
        else
          _buildLoading(),
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (error != null) ...[
              _buildButton(
                icon: Icons.refresh_rounded,
                label: '重试',
                onPressed: _prepare,
              ),
              const SizedBox(width: 14),
            ],
            _buildButton(
              autofocus: info != null,
              icon: Icons.close_rounded,
              label: '关闭',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildReady(TvLogExportInfo info) {
    final size = (info.archive.sizeBytes / 1024).clamp(0, double.infinity);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 236,
          height: 236,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(
            data: info.url,
            backgroundColor: Colors.white,
            eyeStyle: const QrEyeStyle(color: Colors.black),
            dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
          ),
        ),
        const SizedBox(width: 32),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _downloads > 0 ? '日志已下载' : '使用手机扫码下载',
                style: TextStyle(
                  color: _downloads > 0
                      ? Colors.greenAccent
                      : context.tvTextColor,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '请让手机与电视连接同一局域网。二维码仅在此窗口打开期间有效。',
                style: TextStyle(
                  color: context.tvTextSecondaryColor,
                  fontSize: 15,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '${info.archive.logFileCount} 个日志文件 · ${size.toStringAsFixed(size < 10 ? 1 : 0)} KB',
                style: TextStyle(color: context.tvTextHintColor, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                info.url,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.tvTextHintColor,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLoading() {
    return SizedBox(
      height: 236,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          Text(
            '正在打包日志…',
            style: TextStyle(color: context.tvTextSecondaryColor, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildError(Object error) {
    return SizedBox(
      height: 236,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.wifi_off_rounded,
            color: Colors.orangeAccent,
            size: 52,
          ),
          const SizedBox(height: 18),
          Text(
            '无法启动扫码导出',
            style: TextStyle(
              color: context.tvTextColor,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            error.toString().replaceFirst('Bad state: ', ''),
            textAlign: TextAlign.center,
            style: TextStyle(color: context.tvTextSecondaryColor, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool autofocus = false,
  }) {
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(12),
      enableScale: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        decoration: BoxDecoration(
          color: context.tvHighlightColor(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.tvHighlightColor(0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: context.tvTextColor, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: context.tvTextColor,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
