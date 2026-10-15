import 'package:flutter/material.dart';

class WindowsLineSelector extends StatelessWidget {
  const WindowsLineSelector({
    required this.availableLineIndexes,
    required this.currUrl,
    required this.onUrlChanged,
    super.key,
    this.sourceNames,
  });

  final int currUrl;
  final ValueChanged<int> onUrlChanged;
  final List<String>? sourceNames;
  final Iterable<int> availableLineIndexes;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final index in availableLineIndexes) _buildLine(context, index),
        ],
      ),
    );
  }

  Widget _buildLine(BuildContext context, int lineIndex) {
    final isSelected = lineIndex == currUrl;
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;
    final names = sourceNames;
    final lineName = (names != null && lineIndex <= names.length)
        ? names[lineIndex - 1]
        : '线路 $lineIndex';

    final bgColor = isSelected
        ? primaryColor
        : (isDark
              ? const Color(0xFF2C2C33)
              : Colors.black.withValues(alpha: 0.08));

    final borderColor = isSelected
        ? primaryColor
        : (isDark
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.black.withValues(alpha: 0.15));

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: () => onUrlChanged(lineIndex),
          borderRadius: BorderRadius.circular(6),
          hoverColor: isSelected ? null : Colors.white.withValues(alpha: 0.08),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: borderColor, width: 1.0),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSelected) ...[
                  const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                  const SizedBox(width: 3),
                ],
                Text(
                  lineName,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12.0,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
