import 'package:flutter/material.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';

class MacOSTitleBar extends StatelessWidget {
  final Color? backgroundColor;
  final String? title;

  const MacOSTitleBar({super.key, this.backgroundColor, this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bgColor =
        backgroundColor ??
        theme.appBarTheme.backgroundColor ??
        (isDark ? const Color(0xFF2D2D2D) : const Color(0xFFF5F5F5));

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.black.withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
      ),
      child: WindowTitleBarBox(
        child: MoveWindow(
          child: Center(
            child: title != null
                ? Text(
                    title!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
