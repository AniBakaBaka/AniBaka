import 'package:flutter/material.dart';

/// Bangumi 1–10 分人数分布柱形图（桌面详情页）。
class ScoreDistributionChart extends StatelessWidget {
  const ScoreDistributionChart({
    required this.counts,
    this.maxBarHeight = 72,
    this.barWidth = 16,
    this.barGap = 6,
    this.showLabels = true,
    this.showValues = false,
    this.compact = false,
    super.key,
  });

  /// 长度 10，下标 0 = 1 分。
  final List<int> counts;
  final double maxBarHeight;
  final double barWidth;
  final double barGap;
  final bool showLabels;
  final bool showValues;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;

    final safe = counts.length >= 10
        ? counts.sublist(0, 10)
        : [...counts, ...List.filled(10 - counts.length, 0)];
    var maxCount = 0;
    for (final c in safe) {
      if (c > maxCount) maxCount = c;
    }
    if (maxCount <= 0) {
      return const SizedBox.shrink();
    }

    final muteBar = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : const Color(0xFFD1D1D6);
    final highBar = scheme.primary;
    final labelColor = isDark ? Colors.white54 : const Color(0xFF8E8E93);

    return Semantics(
      label: '评分分布柱形图',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact) ...[
            Text(
              '评分分布',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white70 : const Color(0xFF3A3A3C),
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            height: maxBarHeight + (showValues ? 16 : 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 10; i++) ...[
                  if (i > 0) SizedBox(width: barGap),
                  _Bar(
                    count: safe[i],
                    maxCount: maxCount,
                    maxHeight: maxBarHeight,
                    width: barWidth,
                    color: i >= 7 ? highBar : muteBar,
                    showValue: showValues,
                    valueColor: labelColor,
                  ),
                ],
              ],
            ),
          ),
          if (showLabels) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 10; i++) ...[
                  if (i > 0) SizedBox(width: barGap),
                  SizedBox(
                    width: barWidth,
                    child: Text(
                      '${i + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                        height: 1,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.count,
    required this.maxCount,
    required this.maxHeight,
    required this.width,
    required this.color,
    required this.showValue,
    required this.valueColor,
  });

  final int count;
  final int maxCount;
  final double maxHeight;
  final double width;
  final Color color;
  final bool showValue;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final ratio = maxCount <= 0 ? 0.0 : count / maxCount;
    final h = (ratio * maxHeight).clamp(count > 0 ? 4.0 : 2.0, maxHeight);

    return SizedBox(
      width: width,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (showValue && count > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                _shortCount(count),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: valueColor,
                  height: 1,
                ),
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
          Tooltip(
            message: '$count 人',
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              width: width,
              height: h,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _shortCount(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}w';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
