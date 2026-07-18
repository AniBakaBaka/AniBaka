import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final bool autofocus;
  final FocusNode? focusNode;
  final BorderRadius borderRadius;
  final double focusScale;
  final Color? focusBorderColor;
  final double focusBorderWidth;
  final EdgeInsets focusPadding;
  final bool enableScale;
  final bool enableBorder;
  final bool enableGlow;
  final KeyEventResult Function(KeyEvent event)? customKeyHandler;

  const TvFocusable({
    required this.child,
    this.onPressed,
    this.onLongPress,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.focusScale = 1.05,
    this.focusBorderColor,
    this.focusBorderWidth = 3.0,
    this.focusPadding = EdgeInsets.zero,
    this.enableScale = true,
    this.enableBorder = true,
    this.enableGlow = true,
    this.customKeyHandler,
    super.key,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  static const Duration _focusAnimDuration = Duration(milliseconds: 150);

  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  bool _isFocused = false;

  @override
  void dispose() {
    if (widget.focusNode == null) _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged(bool hasFocus) {
    if (_isFocused == hasFocus) return;
    setState(() => _isFocused = hasFocus);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final custom = widget.customKeyHandler;
    if (custom != null) {
      final result = custom(event);
      if (result == KeyEventResult.handled) return result;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter)) {
      widget.onPressed?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final focusColor =
        widget.focusBorderColor ?? Theme.of(context).colorScheme.primary;
    final scale = widget.enableScale && _isFocused ? widget.focusScale : 1.0;

    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onFocusChange: _onFocusChanged,
      onKeyEvent: _onKeyEvent,
      child: GestureDetector(
        onTap: widget.onPressed,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: _focusAnimDuration,
          curve: Curves.easeOutCubic,
          padding: widget.focusPadding,
          transform: Matrix4.diagonal3Values(scale, scale, 1),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: widget.enableBorder
                ? Border.all(
                    color: _isFocused ? focusColor : Colors.transparent,
                    width: widget.focusBorderWidth,
                  )
                : null,
            boxShadow: widget.enableGlow && _isFocused
                ? [
                    BoxShadow(
                      color: focusColor.withValues(alpha: 0.4),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class TvFocusableChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback? onPressed;
  final bool autofocus;
  final FocusNode? focusNode;
  final IconData? icon;
  final double fontSize;

  const TvFocusableChip({
    required this.label,
    this.isSelected = false,
    this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.icon,
    this.fontSize = 18,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return TvFocusable(
      onPressed: onPressed,
      autofocus: autofocus,
      focusNode: focusNode,
      borderRadius: BorderRadius.circular(24),
      focusScale: 1.08,
      enableGlow: false,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? primaryColor
              : theme.cardColor.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: fontSize + 2,
                color: isSelected
                    ? context.tvTextColor
                    : context.tvTextSecondaryColor,
              ),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? context.tvTextColor
                    : context.tvTextSecondaryColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
