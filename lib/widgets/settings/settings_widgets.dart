import 'package:flutter/material.dart';
import 'package:baka/instance.dart';
import 'package:flutter/services.dart';

class SettingsSliverAppBar extends StatelessWidget {
  final String title;
  final Color? backgroundColor;
  final double expandedHeight;

  const SettingsSliverAppBar({
    required this.title,
    this.backgroundColor,
    this.expandedHeight = 120,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background =
        backgroundColor ?? (isDark ? Colors.black : const Color(0xFFF2F2F7));

    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      backgroundColor: background,
      elevation: 0,
      scrolledUnderElevation: 0,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsetsDirectional.only(
          start: 72,
          bottom: 16,
          end: 20,
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black,
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        centerTitle: false,
      ),
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back,
          color: isDark ? Colors.white : Colors.black,
        ),
        onPressed: () => Navigator.pop(context),
      ),
    );
  }
}

class SettingsSectionHeader extends StatelessWidget {
  final String title;
  final double bottomPadding;

  const SettingsSectionHeader(this.title, {this.bottomPadding = 8, super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.55);
    return Padding(
      padding: EdgeInsets.only(left: 16, bottom: bottomPadding),
      child: Text(
        title,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class SettingsGroup extends StatelessWidget {
  final List<Widget> children;

  const SettingsGroup({required this.children, super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reduceVisualEffects = context.reduceMotion;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: reduceVisualEffects
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Column(children: children),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.title,
    required this.icon,
    required this.trailing,
    this.iconWidget,
    this.subtitle,
    this.onTap,
    this.showDivider = true,
    this.verticalPadding = 16,
  });

  final String title;
  final IconData icon;
  final Widget? iconWidget;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;
  final bool showDivider;
  final double verticalPadding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : Colors.black;

    return InkWell(
      onTap: onTap == null
          ? null
          : () {
              HapticFeedback.lightImpact();
              onTap!();
            },
      highlightColor: foreground.withValues(alpha: isDark ? 0.05 : 0.03),
      splashColor: Colors.transparent,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: verticalPadding,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: foreground.withValues(alpha: isDark ? 0.05 : 0.03),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child:
                      iconWidget ??
                      Icon(
                        icon,
                        size: 18,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: foreground,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: foreground.withValues(alpha: 0.54),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                trailing,
              ],
            ),
          ),
          if (showDivider)
            Divider(
              height: 1,
              thickness: 0.5,
              indent: 56,
              color: colors.onSurface.withValues(alpha: isDark ? 0.1 : 0.05),
            ),
        ],
      ),
    );
  }
}

class SettingsTile extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Widget? iconWidget;
  final VoidCallback? onTap;
  final bool showDivider;

  const SettingsTile({
    required this.title,
    required this.value,
    required this.icon,
    super.key,
    this.iconWidget,
    this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtitleColor = isDark ? Colors.white54 : Colors.black54;
    return _SettingsRow(
      title: title,
      icon: icon,
      iconWidget: iconWidget,
      onTap: onTap,
      showDivider: showDivider,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              value,
              style: TextStyle(fontSize: 14, color: subtitleColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: isDark ? Colors.white24 : Colors.black26,
          ),
        ],
      ),
    );
  }
}

class SettingsSwitchTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final IconData icon;
  final ValueChanged<bool> onChanged;
  final bool showDivider;

  const SettingsSwitchTile({
    required this.title,
    required this.value,
    required this.icon,
    required this.onChanged,
    this.subtitle,
    super.key,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = Theme.of(context).colorScheme.primary;

    void handleChanged(bool next) {
      HapticFeedback.lightImpact();
      onChanged(next);
    }

    return _SettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      onTap: () => onChanged(!value),
      showDivider: showDivider,
      verticalPadding: 12,
      trailing: Switch.adaptive(
        value: value,
        onChanged: handleChanged,
        activeTrackColor: activeColor,
      ),
    );
  }
}
