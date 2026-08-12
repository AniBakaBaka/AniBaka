import 'package:baka/widgets/platform/tv/tv_theme_util.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/widgets/player_dialogs.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/services/danmaku_service.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/widgets/platform/tv/tv_focusable.dart';

class TvSettingsPanel extends StatefulWidget {
  final PlaybackController controller;
  final DanmakuController danmakuController;
  final VoidCallback onClose;

  const TvSettingsPanel({
    required this.controller,
    required this.danmakuController,
    required this.onClose,
    super.key,
  });

  @override
  State<TvSettingsPanel> createState() => _TvSettingsPanelState();
}

class _TvSettingsPanelState extends State<TvSettingsPanel> {
  static final _fontOptions = AppFonts.fontOptions.entries.toList(
    growable: false,
  );

  PlaybackController get _ctrl => widget.controller;
  DanmakuController get _danmaku => widget.danmakuController;

  late double _speed;
  bool _optionChanged = false;

  @override
  void initState() {
    super.initState();
    _speed = _ctrl.core.value.playbackRate;
  }

  @override
  void dispose() {
    if (_optionChanged) DanmakuService.saveSettings(_danmaku);
    super.dispose();
  }

  void _setDanmakuOption(DanmakuOption option) {
    setState(() => _danmaku.updateOption(option));
    _optionChanged = true;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.arrowRight) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final option = _danmaku.option;
    return FocusScope(
      autofocus: true,
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _handleKeyEvent,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 380,
            height: double.infinity,
            decoration: BoxDecoration(
              color: context.tvShadowColor(0.88),
              border: Border(
                right: BorderSide(color: context.tvHighlightColor(0.08)),
              ),
            ),
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 32,
                ),
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.settings,
                        color: context.tvTextSecondaryColor,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '播放设置',
                        style: TextStyle(
                          color: context.tvTextColor,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),

                  _buildSectionTitle('弹幕'),
                  const SizedBox(height: 12),

                  ValueListenableBuilder<PlayerOverlayState>(
                    valueListenable: _ctrl.overlay,
                    builder: (context, overlay, _) => _buildToggleItem(
                      icon: Icons.subtitles,
                      title: '显示弹幕',
                      value: overlay.showDanmaku,
                      autofocus: true,
                      onToggle: () {
                        _ctrl.setDanmakuVisible(!overlay.showDanmaku);
                      },
                    ),
                  ),
                  const SizedBox(height: 8),

                  _TvSelectItem(
                    icon: Icons.font_download_outlined,
                    title: '弹幕字体',
                    value: option.fontFamily,
                    options: _fontOptions,
                    onChanged: (fontFamily) => _setDanmakuOption(
                      option.copyWith(fontFamily: fontFamily),
                    ),
                  ),
                  const SizedBox(height: 8),

                  _TvSliderItem(
                    icon: Icons.format_size,
                    title: '弹幕字号',
                    value: option.fontSize,
                    min: 10,
                    max: 36,
                    step: 2,
                    displayValue: '${option.fontSize.toInt()}',
                    onChanged: (value) =>
                        _setDanmakuOption(option.copyWith(fontSize: value)),
                  ),
                  const SizedBox(height: 8),

                  _TvSliderItem(
                    icon: Icons.opacity,
                    title: '弹幕透明度',
                    value: option.opacity,
                    min: 0.1,
                    max: 1.0,
                    step: 0.1,
                    displayValue: '${(option.opacity * 100).toInt()}%',
                    onChanged: (value) => _setDanmakuOption(
                      option.copyWith(
                        opacity: double.parse(value.toStringAsFixed(1)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  _TvSliderItem(
                    icon: Icons.crop_free,
                    title: '弹幕区域',
                    value: option.area,
                    min: 0.25,
                    max: 1.0,
                    step: 0.25,
                    displayValue: '${(option.area * 100).toInt()}%',
                    onChanged: (value) => _setDanmakuOption(
                      option.copyWith(
                        area: double.parse(value.toStringAsFixed(2)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  _buildToggleItem(
                    icon: Icons.vertical_align_top,
                    title: '隐藏顶部弹幕',
                    value: option.hideTop,
                    onToggle: () => _setDanmakuOption(
                      option.copyWith(hideTop: !option.hideTop),
                    ),
                  ),
                  const SizedBox(height: 8),

                  _buildToggleItem(
                    icon: Icons.vertical_align_bottom,
                    title: '隐藏底部弹幕',
                    value: option.hideBottom,
                    onToggle: () => _setDanmakuOption(
                      option.copyWith(hideBottom: !option.hideBottom),
                    ),
                  ),
                  const SizedBox(height: 8),

                  _buildToggleItem(
                    icon: Icons.swap_horiz,
                    title: '隐藏滚动弹幕',
                    value: option.hideScroll,
                    onToggle: () => _setDanmakuOption(
                      option.copyWith(hideScroll: !option.hideScroll),
                    ),
                  ),

                  const SizedBox(height: 28),

                  _buildSectionTitle('播放'),
                  const SizedBox(height: 12),

                  _TvSliderItem(
                    icon: Icons.speed,
                    title: '播放速度',
                    value: _speed,
                    min: 0.5,
                    max: 3.0,
                    step: 0.25,
                    displayValue: '${_speed}x',
                    onChanged: (v) {
                      final speed = double.parse(v.toStringAsFixed(2));
                      setState(() => _speed = speed);
                      _ctrl.setRate(speed);
                    },
                  ),
                  const SizedBox(height: 8),

                  ValueListenableBuilder<PlaybackPreferences>(
                    valueListenable: _ctrl.preferences,
                    builder: (context, preferences, _) => _buildToggleItem(
                      icon: Icons.skip_next,
                      title: '智能跳过片头片尾',
                      value: preferences.enableSkipOpEd,
                      onToggle: () {
                        _ctrl.updatePreferences(
                          preferences.copyWith(
                            enableSkipOpEd: !preferences.enableSkipOpEd,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),

                  ValueListenableBuilder<PlaybackPreferences>(
                    valueListenable: _ctrl.preferences,
                    builder: (context, preferences, _) {
                      final hwdecOptions =
                          PlaybackSettingsService.hwdecModeOptionsForPlatform;
                      final hwdecIndex = hwdecOptions
                          .indexOf(preferences.hwdecMode)
                          .clamp(0, hwdecOptions.length - 1);
                      return _TvSliderItem(
                        icon: Icons.memory_rounded,
                        title: '硬件解码',
                        value: hwdecIndex.toDouble(),
                        min: 0,
                        max: (hwdecOptions.length - 1).toDouble(),
                        step: 1,
                        displayValue:
                            preferences.videoRenderer == 'mediacodec_embed'
                            ? 'mediacodec_embed'
                            : (PlaybackSettingsService
                                      .hwdecModeLabelsForPlatform[preferences
                                      .hwdecMode] ??
                                  preferences.hwdecMode),
                        onChanged: (v) {
                          final index = v.toInt();
                          if (index >= 0 && index < hwdecOptions.length) {
                            _ctrl.updatePreferences(
                              preferences.copyWith(
                                hwdecMode: hwdecOptions[index],
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 8),

                  ValueListenableBuilder<PlaybackPreferences>(
                    valueListenable: _ctrl.preferences,
                    builder: (context, preferences, _) => _TvSliderItem(
                      icon: Icons.monitor_rounded,
                      title: '视频渲染器',
                      value: PlaybackSettingsService
                          .videoRendererOptionsForPlatform
                          .indexOf(preferences.videoRenderer)
                          .toDouble(),
                      min: 0,
                      max:
                          (PlaybackSettingsService
                                      .videoRendererOptionsForPlatform
                                      .length -
                                  1)
                              .toDouble(),
                      step: 1,
                      displayValue:
                          PlaybackSettingsService
                              .videoRendererLabels[preferences.videoRenderer] ??
                          preferences.videoRenderer,
                      onChanged: (value) {
                        final index = value.toInt();
                        if (index >= 0 &&
                            index <
                                PlaybackSettingsService
                                    .videoRendererOptionsForPlatform
                                    .length) {
                          _ctrl.updatePreferences(
                            preferences.copyWith(
                              videoRenderer: PlaybackSettingsService
                                  .videoRendererOptionsForPlatform[index],
                            ),
                          );
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 8),

                  _buildActionItem(
                    icon: Icons.info_outline_rounded,
                    title: '播放器详情',
                    subtitle: '清晰度、解码与渲染信息',
                    onPressed: () => showPlaybackDetailsSheet(context, _ctrl),
                  ),
                  const SizedBox(height: 8),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: context.tvHighlightColor(0.4),
        letterSpacing: 1.5,
      ),
    );
  }

  Widget _buildToggleItem({
    required IconData icon,
    required String title,
    required bool value,
    required VoidCallback onToggle,
    bool autofocus = false,
  }) {
    return TvFocusable(
      autofocus: autofocus,
      onPressed: onToggle,
      borderRadius: BorderRadius.circular(12),
      enableScale: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: context.tvHighlightColor(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: context.tvTextSecondaryColor, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: context.tvTextColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Container(
              width: 44,
              height: 26,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                color: value
                    ? Theme.of(context).colorScheme.primary
                    : context.tvHighlightColor(0.15),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: context.tvTextColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onPressed,
  }) {
    return TvFocusable(
      onPressed: onPressed,
      borderRadius: BorderRadius.circular(12),
      enableScale: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: context.tvHighlightColor(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: context.tvTextSecondaryColor, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: context.tvTextColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: context.tvTextSecondaryColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: context.tvTextSecondaryColor,
            ),
          ],
        ),
      ),
    );
  }
}

class _TvSelectItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final List<MapEntry<String, String>> options;
  final ValueChanged<String> onChanged;

  const _TvSelectItem({
    required this.icon,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final index = options.indexWhere((option) => option.key == value);
    final selectedIndex = index < 0 ? 0 : index;

    void select(int nextIndex) {
      if (nextIndex >= 0 && nextIndex < options.length) {
        onChanged(options[nextIndex].key);
      }
    }

    return TvFocusable(
      onPressed: () => select((selectedIndex + 1) % options.length),
      borderRadius: BorderRadius.circular(12),
      enableScale: false,
      customKeyHandler: (event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          select(selectedIndex - 1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          select(selectedIndex + 1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: context.tvHighlightColor(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: context.tvTextSecondaryColor, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: context.tvTextColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(
              Icons.chevron_left,
              color: selectedIndex > 0
                  ? context.tvTextSecondaryColor
                  : context.tvHighlightColor(0.15),
              size: 20,
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 104,
              child: Text(
                options[selectedIndex].value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              color: selectedIndex < options.length - 1
                  ? context.tvTextSecondaryColor
                  : context.tvHighlightColor(0.15),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _TvSliderItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final double step;
  final String displayValue;
  final ValueChanged<double> onChanged;

  const _TvSliderItem({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.displayValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onPressed: () {
        final next = value + step;
        onChanged(next > max ? min : next);
      },
      borderRadius: BorderRadius.circular(12),
      enableScale: false,
      customKeyHandler: (event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowLeft) {
          final next = value - step;
          if (next >= min) onChanged(next);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          final next = value + step;
          if (next <= max + 0.001) onChanged(next.clamp(min, max));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: context.tvHighlightColor(0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: context.tvTextSecondaryColor, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: context.tvTextColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(
              Icons.chevron_left,
              color: value > min
                  ? context.tvTextSecondaryColor
                  : context.tvHighlightColor(0.15),
              size: 20,
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 60,
              child: Text(
                displayValue,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              color: value < max
                  ? context.tvTextSecondaryColor
                  : context.tvHighlightColor(0.15),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
