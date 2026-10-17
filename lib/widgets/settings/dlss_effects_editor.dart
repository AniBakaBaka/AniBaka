import 'package:flutter/material.dart';

import 'package:baka/services/playback/dlss_global_playback.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:baka/widgets/settings/settings_widgets.dart';

class DlssSettings extends StatefulWidget {
  const DlssSettings({super.key});

  @override
  State<DlssSettings> createState() => _DlssSettingsState();
}

class _DlssSettingsState extends State<DlssSettings> {
  final _service = DlssGlobalPlayback.instance;
  late var _draft = _service.effects;

  Future<void> _apply() async {
    if (await _service.applyEffects(_draft)) showSnackBar('效果已保存');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) {
      final s = _service;
      final d = _draft;
      final colors = Theme.of(context).colorScheme;
      ValueChanged<T>? edit<T>(DlssPlaybackEffects Function(T value) change) =>
          s.busy ? null : (value) => setState(() => _draft = change(value));
      final (IconData icon, Color? color) = s.error != null
          ? (Icons.error_outline_rounded, colors.error)
          : s.hasEnhancedOutput
          ? (Icons.check_circle_outline_rounded, Colors.green)
          : s.hasFallback
          ? (Icons.warning_amber_rounded, Colors.orange)
          : (Icons.info_outline_rounded, null);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSection(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.auto_awesome_motion_outlined),
                title: const Text('DLSS 5 视频增强'),
                subtitle: s.enabled ? null : const Text('首次开启需下载约 236 MiB 运行库'),
                value: s.enabled,
                onChanged: s.busy ? null : s.setEnabled,
              ),
              if (s.enabled)
                SwitchListTile(
                  secondary: const Icon(Icons.play_circle_outline_rounded),
                  title: const Text('播放时启用'),
                  value: s.playbackEnabled,
                  onChanged: s.busy ? null : s.setPlaybackEnabled,
                ),
              ListTile(
                leading: s.busy
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon, color: color),
                title: const Text('运行状态'),
                subtitle: SelectableText([s.status, ?s.error].join('\n')),
                trailing: s.busy
                    ? TextButton(
                        onPressed: s.cancelSetup,
                        child: const Text('取消'),
                      )
                    : null,
              ),
            ],
          ),
          SettingsSection(
            title: '效果',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.auto_fix_high_rounded),
                title: const Text('NR 神经改绘'),
                value: d.neuralRendering,
                onChanged: edit((v) => d.copyWith(neuralRendering: v)),
              ),
              SettingsSliderTile(
                icon: Icons.tune_rounded,
                title: '改绘强度',
                value: d.intensity,
                min: .1,
                max: 2,
                divisions: 38,
                label: d.intensity.toStringAsFixed(2),
                onChanged: d.neuralRendering
                    ? edit((v) => d.copyWith(intensity: v))
                    : null,
              ),
              SettingsSelectTile<int>(
                icon: Icons.aspect_ratio_rounded,
                title: '处理分辨率上限',
                value: d.maxHeight,
                options: const {720: '1280 × 720', 1080: '1920 × 1080'},
                onChanged: edit((v) => d.copyWith(maxHeight: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.hd_outlined),
                title: const Text('2 倍超分辨率'),
                value: d.superResolution,
                onChanged: edit((v) => d.copyWith(superResolution: v)),
              ),
              SettingsSliderTile(
                icon: Icons.deblur_rounded,
                title: '输出锐化',
                value: d.sharpness,
                divisions: 20,
                label: '${(d.sharpness * 100).round()}%',
                onChanged: edit((v) => d.copyWith(sharpness: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.animation_rounded),
                title: const Text('帧生成'),
                value: d.frameGeneration,
                onChanged: edit((v) => d.copyWith(frameGeneration: v)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.compare_rounded),
                title: const Text('左右画质对比'),
                value: d.comparison,
                onChanged: edit((v) => d.copyWith(comparison: v)),
              ),
            ],
          ),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: s.busy
                      ? null
                      : () => setState(
                          () => _draft = const DlssPlaybackEffects(),
                        ),
                  child: const Text('恢复默认'),
                ),
              ),
              Expanded(
                child: FilledButton(
                  onPressed: s.busy || d == s.effects ? null : _apply,
                  child: const Text('应用'),
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}
