import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/models/collection.dart';

const _statusData = <CollectionStatus, (Color, IconData, String)>{
  CollectionStatus.doing: (Color(0xFF007AFF), Icons.play_arrow_rounded, '正在追番中'),
  CollectionStatus.wish: (Color(0xFF34C759), Icons.bookmark_rounded, '标记为想看'),
  CollectionStatus.collect: (Color(0xFFAF52DE), Icons.done_all_rounded, '已经看完了'),
  CollectionStatus.onHold: (Color(0xFFFF9500), Icons.pause_rounded, '暂时搁置中'),
  CollectionStatus.dropped: (Color(0xFFFF3B30), Icons.close_rounded, '不再追了'),
};

(Color, IconData, String) statusVisual(CollectionStatus status) => _statusData[status]!;

class CollectionStatusSheet extends StatelessWidget {
  final CollectionStatus? currentStatus;
  final ValueChanged<CollectionStatus> onSelect;
  final VoidCallback? onRemove;

  const CollectionStatusSheet({
    required this.currentStatus,
    required this.onSelect,
    this.onRemove,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _DragHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Row(
                  children: [
                    Text(
                      '收藏状态',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),
                    const Spacer(),
                    if (currentStatus != null) _CurrentBadge(status: currentStatus!),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final status in CollectionStatus.values)
                      _StatusChip(
                        status: status,
                        isSelected: currentStatus == status,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onSelect(status);
                        },
                      ),
                  ],
                ),
              ),
              if (onRemove != null) ...[
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _RemoveButton(onTap: onRemove!),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        width: 36,
        height: 5,
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.15) : Colors.black.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(2.5),
        ),
      ),
    );
  }
}

class _CurrentBadge extends StatelessWidget {
  final CollectionStatus status;
  const _CurrentBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, _, _) = _statusData[status]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(status.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final CollectionStatus status;
  final bool isSelected;
  final VoidCallback onTap;

  const _StatusChip({required this.status, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (color, icon, desc) = _statusData[status]!;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: (MediaQuery.sizeOf(context).width - 42) / 2,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: isDark ? 0.22 : 0.10)
              : (isDark ? const Color(0xFF2C2C2E) : Colors.white),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? color.withValues(alpha: 0.6) : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: isSelected ? color : color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 18, color: isSelected ? Colors.white : color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    status.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : const Color(0xFF8E8E93),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoveButton extends StatelessWidget {
  final VoidCallback onTap;
  const _RemoveButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.heavyImpact();
        onTap();
        Navigator.of(context).pop();
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF2C2C2E)
              : Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFFFF3B30)),
            SizedBox(width: 8),
            Text('取消收藏', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFFF3B30))),
          ],
        ),
      ),
    );
  }
}
