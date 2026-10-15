import 'dart:io';

import 'package:baka/app/navigation.dart';
import 'package:baka/app_state.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/instance.dart';
import 'package:baka/pages/mine/mine_profile.dart';
import 'package:baka/widgets/common/platform_tooltip.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart' hide ContextExtensionss;

const double _expandedWidth = 240;
const double _collapsedWidth = 72;

// 图标左侧留白 = 条目外边距 + 图标内边距，折叠与展开时图标位置一致。
const double _itemMargin = 12;
const double _iconInset = 14;
const double _itemHeight = 40;

const _themeIcons = <IconData>[
  Icons.brightness_auto_rounded,
  Icons.light_mode_rounded,
  Icons.dark_mode_rounded,
];

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
  late bool _collapsed = Instances.sp.getBool('sidebarCollapsed') ?? false;
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  // 主界面不在最上层时不响应搜索快捷键。
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyK ||
        !mounted ||
        _route?.isCurrent == false) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifier = Platform.isMacOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (!modifier) return false;
    NavigationService.toSearch(context);
    return true;
  }

  void _toggleCollapsed() {
    setState(() => _collapsed = !_collapsed);
    Instances.sp.setBool('sidebarCollapsed', _collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final showLabels = !_collapsed;
    return Container(
      width: _collapsed ? _collapsedWidth : _expandedWidth,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          right: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          _Brand(collapsed: _collapsed, onToggle: _toggleCollapsed),
          const SizedBox(height: 12),
          _SearchEntry(
            showLabels: showLabels,
            onTap: () => NavigationService.toSearch(context),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 12),
              children: _buildNavigation(showLabels),
            ),
          ),
          Obx(() {
            // Bangumi 登录也通过同一个账号通知刷新，无需另存一份展示状态。
            Get.find<AccountSession>().user.value;
            return _AccountCard(showLabels: showLabels);
          }),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  List<Widget> _buildNavigation(bool showLabels) {
    final current = widget.currentPageIndex;
    _NavItem page(
      int index,
      IconData icon,
      IconData selectedIcon,
      String label,
    ) => _NavItem(
      icon: icon,
      selectedIcon: selectedIcon,
      label: label,
      selected: current == index,
      showLabel: showLabels,
      onTap: () => widget.onPageChange(index),
    );
    return [
      _SectionLabel('浏览', showLabel: showLabels),
      page(0, Icons.explore_outlined, Icons.explore_rounded, '番组'),
      page(1, Icons.forum_outlined, Icons.forum_rounded, 'C 岛'),
      _SectionLabel('我的', showLabel: showLabels),
      page(2, Icons.person_outline_rounded, Icons.person_rounded, '个人中心'),
      page(3, Icons.favorite_border_rounded, Icons.favorite_rounded, '我的追番'),
      page(4, Icons.history_rounded, Icons.history_rounded, '观看历史'),
      page(5, Icons.download_outlined, Icons.download_rounded, '下载管理'),
    ];
  }
}

WidgetStateProperty<Color?> _itemOverlay(ColorScheme colors) =>
    WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return colors.onSurface.withValues(alpha: 0.08);
      }
      if (states.contains(WidgetState.hovered)) {
        return colors.onSurface.withValues(alpha: 0.05);
      }
      return null;
    });

class _Brand extends StatelessWidget {
  final bool collapsed;
  final VoidCallback onToggle;

  const _Brand({required this.collapsed, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 16),
          PlatformTooltip(
            message: collapsed ? '展开侧边栏' : '收起侧边栏',
            child: IconButton(
              onPressed: onToggle,
              style: ButtonStyle(
                overlayColor: _itemOverlay(colors),
                shape: const WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ),
                fixedSize: const WidgetStatePropertyAll(Size(40, 36)),
              ),
              icon: Icon(
                Icons.menu_rounded,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          if (!collapsed) ...[
            const SizedBox(width: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Image.asset(
                'assets/ic_launcher.png',
                width: 26,
                height: 26,
                cacheWidth: 78,
                filterQuality: FilterQuality.medium,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Baka',
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  color: colors.onSurface,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SearchEntry extends StatelessWidget {
  final bool showLabels;
  final VoidCallback onTap;

  const _SearchEntry({required this.showLabels, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shortcut = Platform.isMacOS ? '⌘ K' : 'Ctrl K';
    final entry = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _itemMargin),
      child: Material(
        color: colors.onSurface.withValues(alpha: 0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashFactory: NoSplash.splashFactory,
          overlayColor: _itemOverlay(colors),
          child: SizedBox(
            height: 38,
            child: Row(
              children: [
                const SizedBox(width: _iconInset),
                Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                if (showLabels) ...[
                  Expanded(
                    child: Text(
                      '搜索番剧',
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _KeyHint(shortcut),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (showLabels) return entry;
    return PlatformTooltip(message: '搜索（$shortcut）', child: entry);
  }
}

class _KeyHint extends StatelessWidget {
  final String text;

  const _KeyHint(this.text);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          height: 1.2,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final bool showLabel;

  const _SectionLabel(this.text, {required this.showLabel});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (!showLabel) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
        child: Divider(
          height: 1,
          thickness: 1,
          color: colors.outlineVariant.withValues(alpha: 0.5),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _itemMargin + _iconInset,
        18,
        _itemMargin,
        6,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: colors.onSurfaceVariant.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool showLabel;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.showLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final duration = context.reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);

    final item = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _itemMargin, vertical: 2),
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: isDark ? 0.18 : 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashFactory: NoSplash.splashFactory,
          overlayColor: _itemOverlay(colors),
          child: SizedBox(
            height: _itemHeight,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedContainer(
                      duration: duration,
                      curve: Curves.easeOutCubic,
                      width: 3,
                      height: selected ? 16 : 0,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const SizedBox(width: _iconInset),
                    Icon(
                      selected ? selectedIcon : icon,
                      size: 20,
                      color: selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    if (showLabel)
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: selected
                                ? colors.onSurface
                                : colors.onSurface.withValues(alpha: 0.82),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (showLabel) return item;
    return PlatformTooltip(message: label, child: item);
  }
}

/// 底部账号卡片：头像进入登录与账号管理，右侧按钮循环切换主题模式。
class _AccountCard extends StatelessWidget {
  final bool showLabels;

  const _AccountCard({required this.showLabels});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final session = Get.find<AccountSession>();
    final appState = Get.find<AppState>();
    final status = session.isLoggedIn
        ? '已登录'
        : session.isBangumiLogin
        ? 'Bangumi 登录'
        : '登录后同步追番与历史';

    final avatar = _Avatar(url: session.avatarUrl, size: 32);
    if (!showLabels) {
      return Center(
        child: PlatformTooltip(
          message: session.isLoggedIn ? '账号与 Bangumi' : '登录',
          child: InkResponse(
            onTap: () => Navigator.pushNamed(context, 'Baka://login'),
            radius: 22,
            child: avatar,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _itemMargin),
      child: Material(
        color: colors.onSurface.withValues(alpha: 0.04),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.pushNamed(context, 'Baka://login'),
          splashFactory: NoSplash.splashFactory,
          overlayColor: _itemOverlay(colors),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
            child: Row(
              children: [
                avatar,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        session.hasIdentity ? session.displayName : '点击登录',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // “跟随系统”与当前系统主题相同时 Theme 不会变化，需要单独订阅。
                Obx(
                  () => PlatformTooltip(
                    message: '主题：${appState.themeModeLabel}',
                    child: IconButton(
                      onPressed: () =>
                          appState.setThemeMode((appState.themeMode + 1) % 3),
                      style: ButtonStyle(overlayColor: _itemOverlay(colors)),
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        _themeIcons[appState.themeMode.clamp(0, 2)],
                        color: colors.onSurfaceVariant,
                      ),
                    ),
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

class _Avatar extends StatelessWidget {
  final String url;
  final double size;

  const _Avatar({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final fallback = _fallback(context);
    if (url.isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        memCacheWidth: 96,
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 150),
        fadeOutDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }

  Widget _fallback(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.person_outline_rounded,
        size: size * 0.55,
        color: colors.primary,
      ),
    );
  }
}
