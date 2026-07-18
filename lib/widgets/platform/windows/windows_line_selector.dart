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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: theme.cardColor.withValues(alpha: 0.5),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: theme.hintColor, size: 18),
            const SizedBox(width: 8),
            Text(
              '此剧集暂无其他线路',
              style: TextStyle(color: theme.hintColor, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null && !isInline) ...[
          Text(
            title!,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
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
    final names = sourceNames;
    final lineName =
        (names != null && lineIndex > 0 && lineIndex <= names.length)
        ? names[lineIndex - 1]
        : '线路 $lineIndex';

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onTap(lineIndex),
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: isSelected
                  ? primaryColor.withValues(alpha: 0.15)
                  : theme.scaffoldBackgroundColor.withValues(alpha: 0.8),
              border: Border.all(
                color: isSelected
                    ? primaryColor.withValues(alpha: 0.5)
                    : theme.dividerColor.withValues(alpha: 0.1),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isSelected) ...[
                  Icon(Icons.stream, color: primaryColor, size: 12),
                  const SizedBox(width: 4),
                ],
                Text(
                  lineName,
                  style: TextStyle(
                    color: isSelected
                        ? primaryColor
                        : theme.textTheme.bodyMedium?.color,
                    fontSize: 12.0,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
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
