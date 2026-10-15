import 'package:baka/instance.dart';
import 'package:baka/widgets/common/value_selector.dart';
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
  final bool visible;

  const AppBottomNavigation({
    required this.currentIndex,
    required this.onTap,
    required this.items,
    this.visible = true,
    super.key,
  }) : assert(items.length > 0),
       assert(currentIndex >= 0 && currentIndex < items.length);

  @override
  State<AppBottomNavigation> createState() => _AppBottomNavigationState();
}

class _AppBottomNavigationState extends State<AppBottomNavigation> {
  final _dragIndex = ValueNotifier<double?>(null);

  @override
  void dispose() {
    _dragIndex.dispose();
    super.dispose();
  }

  void _onDragUpdate(Offset pos, double width) {
    const padding = 8.0;
    final usableWidth = width - padding * 2;
    final dx = Directionality.of(context) == TextDirection.rtl
        ? width - pos.dx - padding
        : pos.dx - padding;
    final itemWidth = usableWidth / widget.items.length;
    final clampedIndex = ((dx - itemWidth / 2) / itemWidth).clamp(
      0.0,
      (widget.items.length - 1).toDouble(),
    );

    final hover = clampedIndex.round();
    if (_dragIndex.value?.round() != hover) {
      HapticFeedback.selectionClick();
    }
    _dragIndex.value = clampedIndex;
  }

  void _onDragEnd() {
    final target = _dragIndex.value?.round();
    _dragIndex.value = null;
    if (target != null && target != widget.currentIndex) {
      HapticFeedback.lightImpact();
      widget.onTap(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = context.reduceMotion;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final isDark = colors.brightness == Brightness.dark;

    final primaryColor = isDark
        ? Color.lerp(colors.primary, Colors.white, 0.25)!
        : colors.primary;
    final unselectedColor = isDark
        ? colors.onSurface.withValues(alpha: 0.45)
        : colors.onSurfaceVariant.withValues(alpha: 0.65);

    final bgDecoration = BoxDecoration(
      color: isDark
          ? (colors.surface.computeLuminance() < 0.05
                ? const Color(0xFF1C1C1E).withValues(alpha: 0.85)
                : colors.surfaceContainer.withValues(alpha: 0.85))
          : colors.surface.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(32),
      border: Border.all(
        color: isDark
            ? Colors.white.withValues(alpha: 0.12)
            : colors.onSurface.withValues(alpha: 0.08),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.08),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ],
    );

    final navigation = SafeArea(
      top: false,
      bottom: false,
      minimum: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        safeBottom < 10 ? 10 - safeBottom : 0,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 500,
            minHeight: 64,
            maxHeight: 64,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: DecoratedBox(
              decoration: bgDecoration,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Listener(
                    // Accepted drags report PointerCancel as drag end too.
                    onPointerCancel: (_) => _dragIndex.value = null,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragStart: (d) =>
                          _onDragUpdate(d.localPosition, constraints.maxWidth),
                      onHorizontalDragUpdate: (d) =>
                          _onDragUpdate(d.localPosition, constraints.maxWidth),
                      onHorizontalDragEnd: (_) => _onDragEnd(),
                      onHorizontalDragCancel: () => _dragIndex.value = null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Stack(
                          children: [
                            ValueListenableBuilder<double?>(
                              valueListenable: _dragIndex,
                              builder: (_, dragIndex, child) => AnimatedAlign(
                                duration: reduceMotion || dragIndex != null
                                    ? Duration.zero
                                    : const Duration(milliseconds: 250),
                                curve: Curves.easeOutCubic,
                                alignment: widget.items.length > 1
                                    ? AlignmentDirectional(
                                        -1 +
                                            2 *
                                                (dragIndex ??
                                                    widget.currentIndex
                                                        .toDouble()) /
                                                (widget.items.length - 1),
                                        0,
                                      )
                                    : Alignment.center,
                                child: child,
                              ),
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
                                      color: isDark
                                          ? colors.primary.withValues(
                                              alpha: 0.28,
                                            )
                                          : colors.primary.withValues(
                                              alpha: 0.12,
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            ValueSelector<double?, int>(
                              valueListenable: _dragIndex,
                              select: (index) =>
                                  index?.round() ?? widget.currentIndex,
                              builder: (_, highlightedIndex) => Row(
                                children: List.generate(widget.items.length, (
                                  i,
                                ) {
                                  final selected = highlightedIndex == i;
                                  final item = widget.items[i];
                                  final itemColor = selected
                                      ? primaryColor
                                      : unselectedColor;

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
                                            duration: reduceMotion
                                                ? Duration.zero
                                                : const Duration(
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
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    // Scaffold includes this layout height in the body's bottom inset. A paint
    // translation alone leaves an empty navigation-sized strip after hiding.
    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: widget.visible ? 1.0 : 0.0),
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        builder: (context, height, child) => ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: height,
            child: child,
          ),
        ),
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: ExcludeSemantics(
            excluding: !widget.visible,
            child: navigation,
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
