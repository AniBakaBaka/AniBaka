import 'dart:ui' show ImageFilter;

import 'package:baka/instance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

class AppNavItem {
  final String iconPath;
  final String label;
  final IconData? iconData;

  const AppNavItem({
    required this.iconPath,
    required this.label,
    this.iconData,
  });
}

class AppBottomNavigation extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<AppNavItem> items;

  const AppBottomNavigation({
    required this.currentIndex,
    required this.onTap,
    required this.items,
    super.key,
  });

  @override
  State<AppBottomNavigation> createState() => _AppBottomNavigationState();
}

class _AppBottomNavigationState extends State<AppBottomNavigation> {
  double? _dragIndex;
  int? _lastHapticIndex;

  void _onDragUpdate(Offset pos, double width) {
    if (widget.items.isEmpty || width <= 0) return;
    const padding = 8.0;
    final usableWidth = width - padding * 2;
    final dx = (pos.dx - padding).clamp(0.0, usableWidth);
    final itemWidth = usableWidth / widget.items.length;
    final clampedIndex = ((dx - itemWidth / 2) / itemWidth)
        .clamp(0.0, (widget.items.length - 1).toDouble());

    final hover = clampedIndex.round();
    if (_lastHapticIndex != hover) {
      _lastHapticIndex = hover;
      HapticFeedback.selectionClick();
    }
    setState(() => _dragIndex = clampedIndex);
  }

  void _onDragEnd() {
    if (_dragIndex != null) {
      final target = _dragIndex!.round().clamp(0, widget.items.length - 1);
      if (target != widget.currentIndex) {
        HapticFeedback.lightImpact();
        widget.onTap(target);
      }
    }
    setState(() {
      _dragIndex = null;
      _lastHapticIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = context.reduceMotion;
    final isDark = colors.brightness == Brightness.dark;

    final activeIndex = _dragIndex ?? widget.currentIndex.toDouble();
    final highlightedIndex =
        activeIndex.round().clamp(0, widget.items.length - 1);

    final bgDecoration = BoxDecoration(
      color: isDark
          ? colors.surfaceContainerHighest.withValues(alpha: 0.75)
          : colors.surface.withValues(alpha: 0.75),
      borderRadius: BorderRadius.circular(32),
      border: Border.all(
        color: colors.onSurface.withValues(alpha: isDark ? 0.10 : 0.06),
      ),
    );

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: SizedBox(
            height: 64,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (reduceMotion)
                    DecoratedBox(decoration: bgDecoration)
                  else
                    BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: DecoratedBox(decoration: bgDecoration),
                    ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragStart: (d) =>
                            _onDragUpdate(d.localPosition, constraints.maxWidth),
                        onHorizontalDragUpdate: (d) =>
                            _onDragUpdate(d.localPosition, constraints.maxWidth),
                        onHorizontalDragEnd: (_) => _onDragEnd(),
                        onHorizontalDragCancel: _onDragEnd,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Stack(
                            children: [
                              // 滑块指示器
                              AnimatedAlign(
                                duration: reduceMotion || _dragIndex != null
                                    ? Duration.zero
                                    : const Duration(milliseconds: 250),
                                curve: Curves.easeOutCubic,
                                alignment: widget.items.length > 1
                                    ? AlignmentDirectional(
                                        -1 +
                                            2 *
                                                activeIndex /
                                                (widget.items.length - 1),
                                        0,
                                      )
                                    : Alignment.center,
                                child: FractionallySizedBox(
                                  widthFactor: 1 / widget.items.length,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: Container(
                                      height: 52,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(26),
                                        color: colors.primary.withValues(
                                          alpha: isDark ? 0.22 : 0.12,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // Item 列表
                              Row(
                                children: List.generate(widget.items.length, (i) {
                                  final selected = highlightedIndex == i;
                                  final item = widget.items[i];
                                  final itemColor = selected
                                      ? colors.primary
                                      : colors.onSurfaceVariant;

                                  return Expanded(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        if (widget.currentIndex == i) return;
                                        HapticFeedback.lightImpact();
                                        widget.onTap(i);
                                      },
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          _NavItemIcon(
                                            item: item,
                                            selected: selected,
                                            color: itemColor,
                                          ),
                                          const SizedBox(height: 2),
                                          AnimatedDefaultTextStyle(
                                            duration: const Duration(
                                              milliseconds: 180,
                                            ),
                                            style: TextStyle(
                                              fontSize: 11,
                                              height: 1.2,
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : FontWeight.w500,
                                              color: itemColor,
                                            ),
                                            child: Text(
                                              item.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItemIcon extends StatelessWidget {
  final AppNavItem item;
  final bool selected;
  final Color color;

  const _NavItemIcon({
    required this.item,
    required this.selected,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    const size = 22.0;
    if (item.iconData != null) {
      return Icon(item.iconData, color: color, size: size);
    }
    final path = selected
        ? '${item.iconPath}.svg'
        : '${item.iconPath}-outline.svg';
    return SvgPicture.asset(
      path,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
