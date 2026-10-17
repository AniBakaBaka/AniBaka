import 'package:flutter/material.dart';
import 'package:baka/widgets/common/expressive_slider_theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: CustomScrollView(
      slivers: [
        SliverAppBar.large(
          title: Text(title),
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        ),
        SliverSafeArea(
          top: false,
          sliver: SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverList.list(children: children),
          ),
        ),
      ],
    ),
  );
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({required this.children, this.title, super.key});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title case final title?)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                title,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              ),
            ),
          Material(
            color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.04),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListTileTheme(
              data: ListTileThemeData(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                minLeadingWidth: 20,
                horizontalTitleGap: 12,
                minTileHeight: 48,
                minVerticalPadding: 12,
                iconColor: isDark ? Colors.white70 : Colors.black87,
                titleTextStyle: theme.textTheme.bodyLarge?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.white : Colors.black87,
                ),
                subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  height: 1.5,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
              child: IconTheme.merge(
                data: const IconThemeData(size: 20),
                child: Column(
                  children: [
                    for (var index = 0; index < children.length; index++) ...[
                      if (index > 0)
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 48,
                          color: isDark
                              ? Colors.white10
                              : Colors.black.withValues(alpha: 0.05),
                        ),
                      children[index],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.trailingIcon,
    this.busy = false,
    this.enabled = true,
    this.color,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;
  final IconData? trailingIcon;
  final bool busy;
  final bool enabled;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = this.value;
    final isDark = theme.brightness == Brightness.dark;
    final trailingIcon =
        this.trailingIcon ??
        (onTap != null && value == null ? Icons.chevron_right_rounded : null);
    return LayoutBuilder(
      builder: (context, constraints) => ListTile(
        enabled: enabled,
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        iconColor: color,
        textColor: color,
        onTap: busy || !enabled ? null : onTap,
        trailing: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : value == null && trailingIcon == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  if (value != null)
                    _SettingsValue(
                      value,
                      maxWidth: (constraints.maxWidth * 0.4).clamp(0, 180),
                      enabled: enabled,
                    ),
                  if (trailingIcon != null)
                    Icon(
                      trailingIcon,
                      size: 18,
                      color:
                          color ?? (isDark ? Colors.white24 : Colors.black26),
                    ),
                ],
              ),
      ),
    );
  }
}

class SettingsSelectTile<T> extends StatelessWidget {
  const SettingsSelectTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    super.key,
  });

  final IconData icon;
  final String title;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T>? onChanged;

  Future<void> _pick(BuildContext context) async {
    final selected = await showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (context) => RadioGroup<T>(
        groupValue: value,
        onChanged: (next) => Navigator.pop(context, next),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final MapEntry(:key, value: label) in options.entries)
              RadioListTile<T>(value: key, title: Text(label)),
          ],
        ),
      ),
    );
    if (selected != null && selected != value) onChanged?.call(selected);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      enabled: onChanged != null,
      icon: icon,
      title: title,
      value: options[value] ?? '$value',
      onTap: onChanged == null ? null : () => _pick(context),
    );
  }
}

class SettingsSliderTile extends StatelessWidget {
  const SettingsSliderTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.label,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    super.key,
  });

  final IconData icon;
  final String title;
  final double value;
  final String label;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tileTheme = ListTileTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: tileTheme.iconColor),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: tileTheme.titleTextStyle)),
              const SizedBox(width: 12),
              _SettingsValue(label, maxWidth: 100, enabled: onChanged != null),
            ],
          ),
          SliderTheme(
            data: ExpressiveSliderTheme.from(theme.colorScheme),
            child: Semantics(
              label: title,
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                label: label,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsValue extends StatelessWidget {
  const _SettingsValue(this.text, {this.maxWidth = 180, this.enabled = true});

  final String text;
  final double maxWidth;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: enabled
              ? (isDark ? Colors.white70 : Colors.black54)
              : theme.disabledColor,
        ),
      ),
    );
  }
}
