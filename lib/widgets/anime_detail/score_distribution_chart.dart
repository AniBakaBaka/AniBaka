import 'package:flutter/material.dart';
import 'package:baka/widgets/common/platform_tooltip.dart';

/// Bangumi 1–10 分人数分布，下标 0 = 1 分。
class ScoreDistributionChart extends StatelessWidget {
  const ScoreDistributionChart({required this.counts, super.key});

  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    assert(counts.length == 10);
    var maxCount = 0;
    for (final count in counts) {
      if (count > maxCount) maxCount = count;
    }
    if (maxCount == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final muted = isDark
        ? Colors.white.withValues(alpha: 0.18)
        : const Color(0xFFD1D1D6);
    final labelStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: isDark ? Colors.white54 : const Color(0xFF8E8E93),
      height: 1,
    );

    return Semantics(
      label: '评分分布柱形图',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 10; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 72,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: PlatformTooltip(
                      message: '${i + 1} 分 · ${counts[i]} 人',
                      child: Container(
                        width: 14,
                        height: (counts[i] * 72 / maxCount).clamp(
                          counts[i] > 0 ? 4.0 : 2.0,
                          72.0,
                        ),
                        decoration: BoxDecoration(
                          color: i >= 7 ? theme.colorScheme.primary : muted,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: 14,
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.center,
                    style: labelStyle,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
