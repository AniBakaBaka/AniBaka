import 'package:flutter/material.dart';

/// Shrinks slightly while pressed.
///
/// The press animation is created on the first press, so lists of buttons
/// do not each hold an animation controller and ticker.
class ScaleButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const ScaleButton({required this.child, this.onTap, super.key});

  @override
  State<ScaleButton> createState() => _ScaleButtonState();
}

class _ScaleButtonState extends State<ScaleButton>
    with SingleTickerProviderStateMixin {
  static final _pressedScale = Tween<double>(
    begin: 1,
    end: 0.95,
  ).chain(CurveTween(curve: Curves.easeOut));

  AnimationController? _press;
  Animation<double> _scale = kAlwaysCompleteAnimation;

  void _setPressed(bool pressed) {
    final press = _press;
    if (press != null) {
      pressed ? press.forward() : press.reverse();
    } else if (pressed) {
      final created = _press = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 100),
      )..forward();
      setState(() => _scale = created.drive(_pressedScale));
    }
  }

  @override
  void didUpdateWidget(covariant ScaleButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onTap == null) _press?.value = 0;
  }

  @override
  void dispose() {
    _press?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      onTap: widget.onTap,
      behavior: HitTestBehavior.translucent,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}
