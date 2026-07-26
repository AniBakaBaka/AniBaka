import 'dart:ui' as ui;
import 'package:flutter/material.dart';

Future<void> showPlayerSettingsPanel(BuildContext context, Widget child) {
  return showDialog(
    context: context,
    barrierColor: Colors.transparent,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.only(
        left: MediaQuery.sizeOf(context).width * 0.55,
        right: 0,
      ),
      alignment: Alignment.centerRight,
      elevation: 0,
      child: child,
    ),
  );
}

class PanelResetButton extends StatelessWidget {
  final VoidCallback onPressed;
  const PanelResetButton({required this.onPressed, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: theme.cardColor.withValues(alpha: 0.5),
          foregroundColor: theme.colorScheme.error,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: const Text(
          '恢复默认设置',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class PanelExpandToggle extends StatelessWidget {
  final bool isExpanded;
  final VoidCallback onTap;
  const PanelExpandToggle({
    required this.isExpanded,
    required this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        alignment: Alignment.center,
        child: Text(
          isExpanded ? '收起更多设置' : '展开更多设置',
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class PanelSectionTitle extends StatelessWidget {
  final String title;
  const PanelSectionTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.6),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class PanelSettingsGroup extends StatelessWidget {
  final Color backgroundColor;
  final List<Widget> children;

  const PanelSettingsGroup({
    required this.backgroundColor,
    required this.children,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(children: children),
    );
  }
}

class PanelContainer extends StatelessWidget {
  final Widget child;
  const PanelContainer({required this.child, super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerRight,
          end: Alignment.centerLeft,
          colors: [
            Colors.black.withValues(alpha: 0.85),
            Colors.black.withValues(alpha: 0.25),
          ],
          stops: const [0.2, 1.0],
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          bottomLeft: Radius.circular(24),
        ),
        border: Border(
          left: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.1),
            width: 0.5,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 20,
            offset: const Offset(-5, 0),
          ),
        ],
      ),
      child: child,
    );
  }
}

class PanelDivider extends StatelessWidget {
  const PanelDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 0.5,
      thickness: 0.5,
      indent: 16,
      color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
    );
  }
}

class PanelSliderTile extends StatelessWidget {
  final String title;
  final double value;
  final String valueLabel;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  const PanelSliderTile({
    required this.title,
    required this.value,
    required this.valueLabel,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.onChangeEnd,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                valueLabel,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            activeColor: activeColor,
            inactiveColor: Colors.white.withValues(alpha: 0.12),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}

/// 面板里的下拉选择行。
///
/// [options] 为候选值到显示文案的有序映射（Dart 的 Map 保持插入序）。
class PanelSelectTile extends StatelessWidget {
  final String title;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  const PanelSelectTile({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                dropdownColor: const Color(0xFF2C2C2E),
                icon: const Icon(
                  Icons.unfold_more,
                  color: Colors.white60,
                  size: 16,
                ),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                isDense: true,
                items: [
                  for (final option in options.entries)
                    DropdownMenuItem(
                      value: option.key,
                      child: Text(option.value),
                    ),
                ],
                onChanged: (next) {
                  if (next != null) onChanged(next);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PanelSwitchTile extends StatelessWidget {
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? subtitle;

  const PanelSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Transform.scale(
              scale: 0.8,
              child: Switch.adaptive(
                value: value,
                onChanged: onChanged,
                activeThumbColor: activeColor,
                activeTrackColor: activeColor.withValues(alpha: 0.4),
                inactiveThumbColor: Colors.white,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.2),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
