import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'package:baka/models/playback_state.dart';
import 'package:baka/models/subtitle_config.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/player/settings_panel.dart';

const _palette = <Color>[
  Colors.white,
  Colors.black,
  Color(0xFFFFFF00),
  Color(0xFF00FF00),
  Color(0xFF00FFFF),
  Color(0xFFFF0000),
  Color(0xFFFF69B4),
  Color(0xFFFFA500),
  Color(0xFF8B5CF6),
  Color(0xFF3B82F6),
];

class SubtitleSettingsPage extends StatefulWidget {
  const SubtitleSettingsPage({required this.controller, super.key});

  final PlaybackController controller;

  static Future<void> show(
    BuildContext context,
    PlaybackController controller,
  ) => showPlayerSettingsPanel(
    context,
    SubtitleSettingsPage(controller: controller),
  );

  @override
  State<SubtitleSettingsPage> createState() => _SubtitleSettingsPageState();
}

class _SubtitleSettingsPageState extends State<SubtitleSettingsPage> {
  late SubtitleTrack _track = widget.controller.currentSubtitleTrack;

  void _selectTrack(SubtitleTrack? track) {
    setState(() => _track = track!);
    widget.controller.setSubtitleTrack(track!);
  }

  static String _label(SubtitleTrack track) {
    if (track.id == 'no') return '关闭';
    final name = [?track.title, ?track.language].join(' · ');
    return name.isEmpty ? '轨道 ${track.id}' : name;
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final gap = SizedBox(height: isCompactPlayerPanel(context) ? 12 : 24);
    return PanelContainer(
      title: '字幕设置',
      child: ValueListenableBuilder<PlaybackPreferences>(
        valueListenable: controller.preferences,
        builder: (context, preferences, _) {
          final c = preferences.subtitleConfig;
          void update(SubtitleConfig next, {bool persist = true}) =>
              controller.updateSubtitleConfig(next, persist: persist);
          Widget slider(
            String title,
            double value,
            String label,
            double min,
            double max,
            int divisions,
            SubtitleConfig Function(double value) change,
          ) => PanelSliderTile(
            title: title,
            value: value,
            valueLabel: label,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (v) => update(change(v), persist: false),
            onChangeEnd: (v) => update(change(v)),
          );

          return ListView(
            padding: playerPanelContentPadding(context),
            children: [
              const PanelSectionTitle('字幕轨道'),
              RadioGroup<SubtitleTrack>(
                groupValue: _track,
                onChanged: _selectTrack,
                child: PanelSettingsGroup(
                  children: [
                    for (final track in [
                      SubtitleTrack.no(),
                      ...controller.subtitleTracks.where(
                        (t) => t.id != 'auto' && t.id != 'no',
                      ),
                    ])
                      RadioListTile<SubtitleTrack>(
                        contentPadding: EdgeInsets.zero,
                        value: track,
                        title: Text(_label(track)),
                      ),
                  ],
                ),
              ),
              gap,
              const PanelSectionTitle('字幕外观'),
              PanelSettingsGroup(
                children: [
                  PanelSelectTile(
                    title: '字体',
                    value: c.fontFamily,
                    options: SubtitleConfig.fonts,
                    onChanged: (v) => update(c.copyWith(fontFamily: v)),
                  ),
                  const PanelDivider(),
                  slider(
                    '字体大小',
                    c.fontSize,
                    '${c.fontSize.round()}',
                    12,
                    60,
                    24,
                    (v) => c.copyWith(fontSize: v),
                  ),
                  const PanelDivider(),
                  slider(
                    '字幕位置',
                    c.position,
                    '${c.position.round()}%',
                    0,
                    100,
                    20,
                    (v) => c.copyWith(position: v),
                  ),
                  const PanelDivider(),
                  slider(
                    '透明度',
                    c.opacity,
                    '${(c.opacity * 100).round()}%',
                    .1,
                    1,
                    9,
                    (v) => c.copyWith(opacity: v),
                  ),
                  const PanelDivider(),
                  slider(
                    '描边宽度',
                    c.borderWidth,
                    c.borderWidth.toStringAsFixed(1),
                    0,
                    6,
                    12,
                    (v) => c.copyWith(borderWidth: v),
                  ),
                  const PanelDivider(),
                  PanelSwitchTile(
                    title: '粗体',
                    value: c.bold,
                    onChanged: (v) => update(c.copyWith(bold: v)),
                  ),
                  const PanelDivider(),
                  _ColorRow(
                    title: '字体颜色',
                    value: c.fontColor,
                    onChanged: (v) => update(c.copyWith(fontColor: v)),
                  ),
                  const PanelDivider(),
                  _ColorRow(
                    title: '描边颜色',
                    value: c.borderColor,
                    onChanged: (v) => update(c.copyWith(borderColor: v)),
                  ),
                  const PanelDivider(),
                  _ColorRow(
                    title: '背景颜色',
                    value: c.backgroundColor,
                    transparent: true,
                    onChanged: (v) => update(c.copyWith(backgroundColor: v)),
                  ),
                ],
              ),
              gap,
              PanelResetButton(
                onPressed: () {
                  update(const SubtitleConfig());
                  showSnackBar('已恢复默认字幕设置');
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.transparent = false,
  });

  final String title;
  final Color value;
  final ValueChanged<Color> onChanged;
  final bool transparent;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        spacing: 10,
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final color in [
                if (transparent) Colors.transparent,
                ..._palette,
              ])
                GestureDetector(
                  onTap: () => onChanged(color),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: color == value ? primary : Colors.white30,
                        width: color == value ? 3 : 1,
                      ),
                    ),
                    child: color == Colors.transparent
                        ? const Icon(
                            Icons.block_rounded,
                            size: 16,
                            color: Colors.white54,
                          )
                        : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
