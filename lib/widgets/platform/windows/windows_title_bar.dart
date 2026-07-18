import 'package:flutter/material.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:baka/services/cache_manager.dart';
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
        (isDark ? const Color(0xFF2D2D2D) : const Color(0xFFF3F3F3));
    final fgColor =
        foregroundColor ??
        theme.appBarTheme.foregroundColor ??
        (isDark ? Colors.white : Colors.black);

    return Container(
      height: 32,
      color: bgColor,
      child: WindowTitleBarBox(
        child: Row(
          children: [
            Expanded(child: MoveWindow()),
            Row(
              children: [
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
                      await CacheManagerService.instance.clearAllCache();
                    }
                    appWindow.close();
                  },
                  color: fgColor,
                  isCloseButton: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
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
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Color hoverColor;
    if (widget.isCloseButton) {
      hoverColor = Colors.red;
    } else {
      hoverColor = isDark
          ? Colors.white.withValues(alpha: 0.1)
          : Colors.black.withValues(alpha: 0.1);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: 32,
          color: _isHovered ? hoverColor : Colors.transparent,
          child: Icon(
            widget.icon,
            size: 16,
            color: _isHovered && widget.isCloseButton
                ? Colors.white
                : widget.color,
          ),
        ),
      ),
    );
  }
}
