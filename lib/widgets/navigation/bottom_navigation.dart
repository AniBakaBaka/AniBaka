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
  }) : assert(items.length > 1),
       assert(currentIndex >= 0 && currentIndex < items.length);

  @override
  State<AppBottomNavigation> createState() => _AppBottomNavigationState();
}

class _AppBottomNavigationState extends State<AppBottomNavigation> {
  static const _padding = 8.0;
  final _dragIndex = ValueNotifier<double?>(null);

  @override
  void dispose() {
    _dragIndex.dispose();
    super.dispose();
  }

  void _onDragUpdate(Offset pos, double width) {
    final count = widget.items.length;
    final dx = Directionality.of(context) == TextDirection.rtl
        ? width - pos.dx - _padding
        : pos.dx - _padding;
    final itemWidth = (width - _padding * 2) / count;
    final index = ((dx - itemWidth / 2) / itemWidth).clamp(0.0, count - 1.0);
    if (_dragIndex.value?.round() != index.round()) {
      HapticFeedback.selectionClick();
    }
    _dragIndex.value = index;
  }

  void _onDragEnd() {
    final target = _dragIndex.value?.round();
    _dragIndex.value = null;
    if (target != null) _select(target);
  }

  void _select(int index) {
    if (index == widget.currentIndex) return;
    HapticFeedback.lightImpact();
    widget.onTap(index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = context.reduceMotion;
    final isDark = colors.brightness == Brightness.dark;
    final count = widget.items.length;

    final selectedColor = isDark
        ? Color.lerp(colors.primary, Colors.white, 0.25)!
        : colors.primary;
    final unselectedColor = isDark
        ? colors.onSurface.withValues(alpha: 0.45)
        : colors.onSurfaceVariant.withValues(alpha: 0.65);

    final indicator = FractionallySizedBox(
      widthFactor: 1 / count,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(26)),
            color: colors.primary.withValues(alpha: isDark ? 0.28 : 0.12),
          ),
          child: const SizedBox(height: 52),
        ),
      ),
    );

    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color:
            (isDark
                    ? (colors.surface.computeLuminance() < 0.05
                          ? const Color(0xFF1C1C1E)
                          : colors.surfaceContainer)
                    : colors.surface)
                .withValues(alpha: 0.85),
        borderRadius: const BorderRadius.all(Radius.circular(32)),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : colors.onSurface.withValues(alpha: 0.08),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Listener(
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
                horizontal: _padding,
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
                      alignment: AlignmentDirectional(
                        -1.0 +
                            2 *
                                (dragIndex ?? widget.currentIndex) /
                                (count - 1),
                        0,
                      ),
                      child: child,
                    ),
                    child: indicator,
                  ),
                  ValueSelector<double?, int>(
                    valueListenable: _dragIndex,
                    select: (index) => index?.round() ?? widget.currentIndex,
                    builder: (_, highlighted) => Row(
                      children: [
                        for (var i = 0; i < count; i++)
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _select(i),
                              child: _NavItem(
                                item: widget.items[i],
                                selected: highlighted == i,
                                color: highlighted == i
                                    ? selectedColor
                                    : unselectedColor,
                                reduceMotion: reduceMotion,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final safe = MediaQuery.paddingOf(context);
    // The bar keeps its layout height while hidden and only slides in paint:
    // with Scaffold.extendBody its height is the body's bottom inset, and an
    // animated height would rebuild and relayout every tab page per frame.
    return AnimatedSlide(
      offset: widget.visible ? Offset.zero : const Offset(0, 1),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: ExcludeSemantics(
          excluding: !widget.visible,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              safe.left < 16 ? 16 : safe.left,
              0,
              safe.right < 16 ? 16 : safe.right,
              safe.bottom < 10 ? 10 : safe.bottom,
            ),
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 500,
                  minHeight: 64,
                  maxHeight: 64,
                ),
                child: bar,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.item,
    required this.selected,
    required this.color,
    required this.reduceMotion,
  });

  final AppNavItem item;
  final bool selected;
  final Color color;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    const size = 22.0;
    final icon = item.iconData != null
        ? Icon(item.iconData, color: color, size: size)
        : SvgPicture.asset(
            selected ? '${item.iconPath}.svg' : '${item.iconPath}-outline.svg',
            width: size,
            height: size,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          );
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        icon,
        const SizedBox(height: 2),
        AnimatedDefaultTextStyle(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 180),
          style: TextStyle(
            fontSize: 11,
            height: 1.2,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: color,
          ),
          child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
