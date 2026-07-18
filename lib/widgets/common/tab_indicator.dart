import 'dart:math' as math;

import 'package:flutter/material.dart';

class ArcTabIndicator extends Decoration {
  final double height;
  final Color color;

  const ArcTabIndicator({this.height = 3, this.color = Colors.white});

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    return _ArcIndicatorPainter(onChanged, height, color);
  }
}

class _ArcIndicatorPainter extends BoxPainter {
  final double height;
  final Color color;

  _ArcIndicatorPainter(super.onChanged, this.height, this.color);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final radius = math.min(size.width, size.height) / 3;
    final center = Offset(
      offset.dx + size.width / 2,
      offset.dy + size.height - height,
    );

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3.3;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius / 1.5),
      (math.pi / 180) * 30,
      120 * (math.pi / 180),
      false,
      paint,
    );
  }
}
