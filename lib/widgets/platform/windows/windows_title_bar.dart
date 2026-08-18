import 'package:flutter/material.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/playback_settings_service.dart';

class WindowsTitleBar extends StatelessWidget {
  final Color? backgroundColor;
  final Color? foregroundColor;

  const WindowsTitleBar({
    super.key,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        backgroundColor ??
        theme.appBarTheme.backgroundColor ??
        (isDark ? const Color(0xFF202020) : const Color(0xFFF5F5F5));
    final fgColor =
        foregroundColor ??
        theme.appBarTheme.foregroundColor ??
        (isDark ? Colors.white70 : Colors.black87);

    return Container(
      height: 32,
      color: bgColor,
      child: WindowTitleBarBox(
        child: Row(
          children: [
            Expanded(child: MoveWindow()),
            _WindowButton(
              icon: Icons.remove,
              onPressed: () => appWindow.minimize(),
              color: fgColor,
            ),
            _WindowButton(
              icon: appWindow.isMaximized
                  ? Icons.filter_none
                  : Icons.crop_square,
              onPressed: () => appWindow.maximizeOrRestore(),
              color: fgColor,
            ),
            _WindowButton(
              icon: Icons.close,
              onPressed: () async {
                if (PlaybackSettingsService.getClearCacheOnExit()) {
                  await AppStorage.clearAllCache();
                }
                appWindow.close();
              },
              color: fgColor,
              isCloseButton: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;
  final bool isCloseButton;

  const _WindowButton({
    required this.icon,
    required this.onPressed,
    required this.color,
    this.isCloseButton = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        hoverColor: isCloseButton
            ? Colors.redAccent
            : (Theme.of(context).brightness == Brightness.dark
                ? Colors.white10
                : Colors.black12),
        onTap: onPressed,
        child: SizedBox(
          width: 46,
          height: 32,
          child: Icon(
            icon,
            size: 15,
            color: color,
          ),
        ),
      ),
    );
  }
}
