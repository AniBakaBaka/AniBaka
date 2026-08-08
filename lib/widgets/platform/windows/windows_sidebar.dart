import 'package:cached_network_image/cached_network_image.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/mine_service.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/services/settings_service.dart';
import 'package:flutter/material.dart';

class WindowsSidebar extends StatefulWidget {
  final int currentPageIndex;
  final Function(int) onPageChange;

  const WindowsSidebar({
    required this.currentPageIndex,
    required this.onPageChange,
    super.key,
  });

  @override
  State<WindowsSidebar> createState() => _WindowsSidebarState();
}

class _WindowsSidebarState extends State<WindowsSidebar> {
  late final MineService _mine = MineService();
  late bool _isSidebarCollapsed = ThemeService.getSidebarCollapsed();
  int? _hoveredIndex;

  void _setHoveredIndex(int? index) {
    if (_hoveredIndex != index) {
      setState(() => _hoveredIndex = index);
    }
  }

  void _toggleSidebar() {
    setState(() => _isSidebarCollapsed = !_isSidebarCollapsed);
    ThemeService.setSidebarCollapsed(_isSidebarCollapsed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final reduceVisualEffects = context.reduceMotion;

    final width = _isSidebarCollapsed ? 72.0 : 240.0;

    final backgroundColor = theme.scaffoldBackgroundColor;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.fastOutSlowIn, // 更优雅的动画曲线
      width: width,
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border(
          right: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.05),
            width: 1,
          ),
        ),
        boxShadow: [
          if (!_isSidebarCollapsed && !reduceVisualEffects)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 20,
              offset: const Offset(4, 0),
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 32),

          _buildUserInfo(theme),

          const SizedBox(height: 32),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(children: _buildNavItems(theme)),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(12),
            child: _buildCollapseButton(theme),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildAvatar(double size) {
    final avatarUrl = _mine.avatarUrl;
    return Hero(
      tag: 'sidebar_avatar',
      child: ClipOval(
        child: avatarUrl.isEmpty
            ? _buildAvatarFallback(size)
            : CachedNetworkImage(
                memCacheWidth: (size * 2).toInt(),
                imageUrl: avatarUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _buildAvatarFallback(size),
              ),
      ),
    );
  }

  Widget _buildAvatarFallback(double size) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      color: colors.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.person_outline_rounded,
        size: size * 0.56,
        color: colors.onSurfaceVariant,
      ),
    );
  }

  void _openLoginPage() {
    Navigator.pushNamed(context, 'Baka://login');
  }

  Widget _buildUserButton(Widget child) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openLoginPage,
        child: child,
      ),
    );
  }

  Widget _buildUserInfo(ThemeData theme) {
    if (_isSidebarCollapsed) {
      return _buildUserButton(
        Center(
          child: Tooltip(
            message: _mine.isLogin ? '账号与 Bangumi' : '登录',
            child: SizedBox(width: 40, height: 40, child: _buildAvatar(40)),
          ),
        ),
      );
    }

    return _buildUserButton(
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            SizedBox(width: 48, height: 48, child: _buildAvatar(48)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _mine.hasIdentity ? _mine.displayName : '点击登录',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _mine.isBangumiLogin && !_mine.isLogin
                        ? 'Bangumi 登录 · 历史仅本机'
                        : _mine.isLogin
                        ? '欢迎回来'
                        : '打开登录页面',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.textTheme.bodyMedium?.color?.withValues(
                        alpha: 0.5,
                      ),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildNavItems(ThemeData theme) {
    final currentIndex = widget.currentPageIndex;
    final entries = <_NavEntry>[
      _NavEntry(
        index: 0,
        icon: Icons.explore_rounded,
        label: '番组',
        isSelected: currentIndex == 0,
        onTap: () => widget.onPageChange(0),
      ),
      _NavEntry(
        index: 1,
        icon: Icons.forum_rounded,
        label: 'C 岛',
        isSelected: currentIndex == 1,
        onTap: () => widget.onPageChange(1),
      ),
      _NavEntry(
        index: 2,
        icon: Icons.person_rounded,
        label: '我的',
        isSelected: currentIndex == 2,
        onTap: () => widget.onPageChange(2),
      ),
      const _NavEntry.divider(),
      _NavEntry(
        index: 10,
        icon: Icons.search_rounded,
        label: '搜索',
        isSelected: false,
        onTap: () => NavigationService.toSearch(context),
      ),
      _NavEntry(
        index: 11,
        icon: Icons.public_rounded,
        label: '里世界',
        isSelected: false,
        onTap: () => NavigationService.toWebView(
          context,
          url: 'https://www.acgzone.cc',
          title: '里世界',
        ),
      ),
    ];

    final widgets = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.isDivider) {
        widgets.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(height: 1, indent: 8, endIndent: 8),
          ),
        );
        continue;
      }
      if (i > 0 && !entries[i - 1].isDivider) {
        widgets.add(const SizedBox(height: 8));
      }
      widgets.add(_buildNavItem(theme, entry));
    }
    return widgets;
  }

  Widget _buildNavItem(ThemeData theme, _NavEntry entry) {
    final isSelected = entry.isSelected;
    final isHovered = _hoveredIndex == entry.index;
    final primaryColor = theme.colorScheme.primary;
    final baseTextColor = theme.textTheme.bodyMedium?.color;

    final Color? foreground;
    if (isSelected) {
      foreground = primaryColor;
    } else if (isHovered) {
      foreground = baseTextColor;
    } else {
      foreground = null;
    }
    final iconColor = foreground ?? baseTextColor?.withValues(alpha: 0.5);
    final textColor = foreground ?? baseTextColor?.withValues(alpha: 0.7);
    final backgroundColor = isSelected
        ? primaryColor.withValues(alpha: 0.1)
        : (isHovered ? theme.hoverColor : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => _setHoveredIndex(entry.index),
      onExit: (_) => _setHoveredIndex(null),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: entry.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          height: 48,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: EdgeInsets.symmetric(
            horizontal: _isSidebarCollapsed ? 0 : 16,
          ),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: _isSidebarCollapsed
              ? Center(child: Icon(entry.icon, color: iconColor, size: 24))
              : Row(
                  children: [
                    Icon(entry.icon, color: iconColor, size: 22),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        entry.label,
                        style: TextStyle(
                          color: textColor,
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isSelected)
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: primaryColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildCollapseButton(ThemeData theme) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _toggleSidebar,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _isSidebarCollapsed
                    ? Icons.keyboard_double_arrow_right_rounded
                    : Icons.keyboard_double_arrow_left_rounded,
                size: 20,
                color: theme.disabledColor,
              ),
              if (!_isSidebarCollapsed) ...[
                const SizedBox(width: 8),
                Text(
                  '收起侧边栏',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.disabledColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NavEntry {
  const _NavEntry({
    required this.index,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  }) : isDivider = false;

  const _NavEntry.divider()
    : index = -1,
      icon = Icons.remove,
      label = '',
      isSelected = false,
      onTap = _noop,
      isDivider = true;

  final int index;
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isDivider;

  static void _noop() {}
}
