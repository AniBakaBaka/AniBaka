import 'package:flutter/material.dart';

class ScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const ScaleButton({required this.child, this.onTap, super.key});

  @override
  State<ScaleButton> createState() => _ScaleButtonState();
}

class _ScaleButtonState extends State<ScaleButton> {
  static const Duration _pressDuration = Duration(milliseconds: 100);
  static const double _pressedScale = 0.95;

  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final bool isEnabled = widget.onTap != null;
    return GestureDetector(
      onTapDown: isEnabled ? (_) => _setPressed(true) : null,
      onTapUp: isEnabled ? (_) => _setPressed(false) : null,
      onTapCancel: isEnabled ? () => _setPressed(false) : null,
      onTap: widget.onTap,
      behavior: HitTestBehavior.translucent,
      child: AnimatedScale(
        scale: _pressed ? _pressedScale : 1,
        duration: _pressDuration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
