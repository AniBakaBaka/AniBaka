import 'package:baka/models/skip_segment.dart';
import 'package:baka/utils/format_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

abstract final class SkipSegmentColors {
  static const opening = Color(0xFF65D1C5);
  static const ending = Color(0xFFF2BA72);
  static Color forType(String type) => type == 'op' ? opening : ending;
}

/// Paint on the existing seek control without replacing its drag or semantics.
class SkipSegmentTrack extends StatelessWidget {
  const SkipSegmentTrack({
    required this.data,
    required this.duration,
    required this.position,
    required this.barHeight,
    required this.child,
    this.thumbRadius = 0,
    this.trackInset = 0,
    super.key,
  });

  final ValueListenable<SkipData> data;
  final Duration duration;
  final Duration position;
  final double barHeight;
  final double thumbRadius;
  final double trackInset;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SkipData>(
    valueListenable: data,
    child: child,
    builder: (context, value, child) {
      if (value.segments.isEmpty) return child!;
      return CustomPaint(
        foregroundPainter: _SkipSegmentPainter(
          segments: value.segments,
          duration: duration.inMilliseconds,
          position: position.inMilliseconds,
          barHeight: barHeight,
          thumbRadius: thumbRadius,
          trackInset: trackInset,
          textDirection: Directionality.of(context),
        ),
        child: child,
      );
    },
  );
}

class _SkipSegmentPainter extends CustomPainter {
  const _SkipSegmentPainter({
    required this.segments,
    required this.duration,
    required this.position,
    required this.barHeight,
    required this.thumbRadius,
    required this.trackInset,
    required this.textDirection,
  });

  final List<SkipSegment> segments;
  final int duration, position;
  final double barHeight, thumbRadius, trackInset;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0 || size.width <= trackInset * 2) return;
    final width = size.width - trackInset * 2;
    final y = size.height / 2;
    double x(int ms) => trackInset + width * (ms / duration).clamp(0.0, 1.0);
    canvas.save();
    // Leave the seek thumb visible over marked regions, including while dragging.
    if (thumbRadius > 0) {
      canvas.clipPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Offset.zero & size)
          ..addOval(
            Rect.fromCircle(
              center: Offset(x(position), y),
              radius: thumbRadius + 1,
            ),
          ),
      );
    }
    final paint = Paint();
    for (final segment in segments) {
      if (!segment.fits(duration)) continue;
      final rect = Rect.fromLTRB(
        x(segment.startMs),
        y - barHeight / 2,
        x(segment.endMs),
        y + barHeight / 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(barHeight / 2)),
        paint..color = SkipSegmentColors.forType(segment.type),
      );
    }
    canvas.restore();
  }

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (size) => [
        for (final segment in segments)
          if (segment.fits(duration))
            CustomPainterSemantics(
              rect: Offset.zero & size,
              properties: SemanticsProperties(
                textDirection: textDirection,
                label:
                    '${segment.label} '
                    '${Duration(milliseconds: segment.startMs).toTimeString()} 至 '
                    '${Duration(milliseconds: segment.endMs).toTimeString()}',
              ),
            ),
      ];

  @override
  bool shouldRebuildSemantics(_SkipSegmentPainter oldDelegate) =>
      oldDelegate.segments != segments ||
      oldDelegate.duration != duration ||
      oldDelegate.textDirection != textDirection;

  @override
  bool shouldRepaint(_SkipSegmentPainter oldDelegate) =>
      oldDelegate.segments != segments ||
      oldDelegate.duration != duration ||
      (thumbRadius > 0 && oldDelegate.position != position) ||
      oldDelegate.barHeight != barHeight ||
      oldDelegate.thumbRadius != thumbRadius ||
      oldDelegate.trackInset != trackInset;
}
