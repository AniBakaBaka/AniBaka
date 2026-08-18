import 'package:flutter/material.dart';

class WindowsLineSelector extends StatelessWidget {
  const WindowsLineSelector({
    required this.lineCount,
    required this.currUrl,
    required this.onUrlChanged,
    super.key,
    this.title,
    this.sourceNames,
    this.isInline = false,
  });

  final int lineCount;
  final int currUrl;
  final ValueChanged<int> onUrlChanged;
  final String? title;
  final List<String>? sourceNames;
  final bool isInline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (lineCount <= 1) {
      if (isInline) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: theme.cardColor.withValues(alpha: 0.4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, color: theme.hintColor, size: 16),
            const SizedBox(width: 6),
            Text(
              '此剧集暂无其他线路',
              style: TextStyle(color: theme.hintColor, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null && !isInline) ...[
          Text(
            title!,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
        ],
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(
              lineCount,
              (index) => _WindowsLineSelectorItem(
                lineIndex: index + 1,
                currUrl: currUrl,
                onTap: onUrlChanged,
                sourceNames: sourceNames,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WindowsLineSelectorItem extends StatelessWidget {
  const _WindowsLineSelectorItem({
    required this.lineIndex,
    required this.currUrl,
    required this.onTap,
    this.sourceNames,
  });

  final int lineIndex;
  final int currUrl;
  final ValueChanged<int> onTap;
  final List<String>? sourceNames;

  @override
  Widget build(BuildContext context) {
    final isSelected = lineIndex == currUrl;
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;
    final names = sourceNames;
    final lineName =
        (names != null && lineIndex > 0 && lineIndex <= names.length)
            ? names[lineIndex - 1]
            : '线路 $lineIndex';

    final bgColor = isSelected
        ? primaryColor
        : (isDark ? const Color(0xFF2C2C33) : Colors.black.withValues(alpha: 0.08));

    final borderColor = isSelected
        ? primaryColor
        : (isDark ? Colors.white.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.15));

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: () => onTap(lineIndex),
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
                  const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 14),
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
