import 'package:cached_network_image/cached_network_image.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/home/miniapp_page.dart';
import 'package:baka/pages/mine/mine_profile.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class WindowsSidebar extends StatefulWidget {
  final int currentPageIndex;
  final ValueChanged<int> onPageChange;

  const WindowsSidebar({
    required this.currentPageIndex,
    required this.onPageChange,
    super.key,
  });

  @override
  State<WindowsSidebar> createState() => _WindowsSidebarState();
}

class _WindowsSidebarState extends State<WindowsSidebar> {
  late final AppState _app = Get.find<AppState>();
  late bool _isSidebarCollapsed =
      Instances.sp.getBool('sidebarCollapsed') ?? false;

  void _toggleSidebar() {
    setState(() => _isSidebarCollapsed = !_isSidebarCollapsed);
    Instances.sp.setBool('sidebarCollapsed', _isSidebarCollapsed);
  }

  void _openLoginPage() {
    Navigator.pushNamed(context, 'Baka://login');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final width = _isSidebarCollapsed ? 68.0 : 220.0;
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.06);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      width: width,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(right: BorderSide(color: dividerColor, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          _buildUserInfo(theme),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: _buildNavItems(theme),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: _buildCollapseButton(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(double size) {
    final avatarUrl = _app.avatarUrl;
    if (avatarUrl.isEmpty) {
      return _buildAvatarFallback(size);
    }
    return ClipOval(
      child: CachedNetworkImage(
        memCacheWidth: 80,
        imageUrl: avatarUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 150),
        fadeOutDuration: const Duration(milliseconds: 150),
        errorWidget: (_, _, _) => _buildAvatarFallback(size),
      ),
    );
  }

  Widget _buildAvatarFallback(double size) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.person_outline_rounded,
        size: size * 0.55,
        color: colors.onSurfaceVariant,
      ),
    );
  }

  Widget _buildUserInfo(ThemeData theme) {
    if (_isSidebarCollapsed) {
      return Center(
        child: Tooltip(
          message: _app.isLoggedIn ? '账号与 Bangumi' : '登录',
          child: InkResponse(
            onTap: _openLoginPage,
            radius: 24,
            child: SizedBox(width: 38, height: 38, child: _buildAvatar(38)),
          ),
        ),
      );
    }

    return InkWell(
      onTap: _openLoginPage,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            SizedBox(width: 40, height: 40, child: _buildAvatar(40)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _app.hasIdentity ? _app.displayName : '点击登录',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _app.isBangumiLogin && !_app.isLoggedIn
                        ? 'Bangumi 登录'
                        : _app.isLoggedIn
                        ? '已登录'
                        : '打开登录',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.textTheme.bodySmall?.color?.withValues(
                        alpha: 0.6,
                      ),
                    ),
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

  List<Widget> _buildNavItems(ThemeData theme) {
    final currentIndex = widget.currentPageIndex;
    return [
      _NavItem(
        icon: Icons.explore_rounded,
        label: '番组',
        isSelected: currentIndex == 0,
        isCollapsed: _isSidebarCollapsed,
        onTap: () => widget.onPageChange(0),
      ),
      const SizedBox(height: 4),
      _NavItem(
        icon: Icons.forum_rounded,
        label: 'C 岛',
        isSelected: currentIndex == 1,
        isCollapsed: _isSidebarCollapsed,
        onTap: () => widget.onPageChange(1),
      ),
      const SizedBox(height: 4),
      _NavItem(
        icon: Icons.person_rounded,
        label: '我的',
        isSelected: currentIndex == 2,
        isCollapsed: _isSidebarCollapsed,
        onTap: () => widget.onPageChange(2),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Divider(height: 1, thickness: 0.8),
      ),
      _NavItem(
        icon: Icons.search_rounded,
        label: '搜索',
        isSelected: false,
        isCollapsed: _isSidebarCollapsed,
        onTap: () => NavigationService.toSearch(context),
      ),
      const SizedBox(height: 4),
      _NavItem(
        icon: Icons.public_rounded,
        label: '里世界',
        isSelected: false,
        isCollapsed: _isSidebarCollapsed,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                const WebViewPage(url: 'https://www.acgzone.cc', title: '里世界'),
          ),
        ),
      ),
    ];
  }

  Widget _buildCollapseButton(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _toggleSidebar,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isDark ? Colors.white12 : Colors.black12,
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _isSidebarCollapsed
                    ? Icons.keyboard_double_arrow_right_rounded
                    : Icons.keyboard_double_arrow_left_rounded,
                size: 18,
                color: theme.hintColor,
              ),
              if (!_isSidebarCollapsed) ...[
                const SizedBox(width: 8),
                Text(
                  '收起侧边栏',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.hintColor,
                    fontWeight: FontWeight.w500,
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

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final bool isCollapsed;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.isCollapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final baseTextColor = theme.textTheme.bodyMedium?.color;

    final fgColor = isSelected
        ? primary
        : baseTextColor?.withValues(alpha: 0.75);
    final bgColor = isSelected
        ? primary.withValues(alpha: 0.12)
        : Colors.transparent;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: isSelected ? null : theme.hoverColor,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          height: 42,
          padding: EdgeInsets.symmetric(horizontal: isCollapsed ? 0 : 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: isCollapsed
              ? Icon(icon, color: fgColor, size: 22)
              : Row(
                  children: [
                    Icon(icon, color: fgColor, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: fgColor,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          fontSize: 13.5,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isSelected)
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
