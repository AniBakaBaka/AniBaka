import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/services/playback/animejanai_playback.dart';
import 'package:baka/services/playback/dlss_global_playback.dart';
import 'settings_widgets.dart';

Future<void> showPlaybackEffects(
  BuildContext context,
  AnimeJaNaiPlayback playback, {
  required Future<Uint8List?> Function() captureFrame,
}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('画质设置'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: VideoEnhancementSettings(
          playback: playback,
          captureFrame: captureFrame,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  ),
);

class VideoEnhancementSettings extends StatefulWidget {
  const VideoEnhancementSettings({super.key, this.playback, this.captureFrame});
  final AnimeJaNaiPlayback? playback;
  final Future<Uint8List?> Function()? captureFrame;

  @override
  State<VideoEnhancementSettings> createState() =>
      _VideoEnhancementSettingsState();
}

class _VideoEnhancementSettingsState extends State<VideoEnhancementSettings> {
  final _dlss = DlssGlobalPlayback.instance;
  final _anime = AnimeJaNaiService.instance;
  late final _changes = Listenable.merge([_dlss, _anime, ?widget.playback]);

  Widget _toggle(String title, bool value, ValueChanged<bool>? changed) =>
      SwitchListTile(title: Text(title), value: value, onChanged: changed);

  Widget _dlssSlider(
    String title,
    double value,
    ValueChanged<double> change, {
    double min = 0,
    double max = 1,
  }) => SettingsSliderTile(
    icon: Icons.tune_rounded,
    title: title,
    value: value,
    min: min,
    max: max,
    divisions: 40,
    label: value.toStringAsFixed(2),
    onChanged: _dlss.busy ? null : (value) => setState(() => change(value)),
    onChangeEnd: (_) => _dlss.saveEffects(),
  );

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _changes,
      builder: (context, _) {
        final effects = _dlss.effects;
        final playback = widget.playback;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: 'AnimeJaNai',
              children: [
                _toggle(
                  '启用',
                  _anime.enabled,
                  _anime.busy ? null : _anime.setEnabled,
                ),
                SettingsSelectTile<AnimeJaNaiProfile>(
                  icon: Icons.high_quality_outlined,
                  title: '档位',
                  value: _anime.profile,
                  options: {
                    for (final p in AnimeJaNaiProfile.values) p: p.label,
                  },
                  onChanged: _anime.busy ? null : _anime.setProfile,
                ),
                SettingsSelectTile<AnimeJaNaiBackend>(
                  icon: Icons.memory_outlined,
                  title: '后端',
                  value: _anime.backend,
                  options: {
                    for (final b in AnimeJaNaiBackend.values) b: b.label,
                  },
                  onChanged: _anime.busy ? null : _anime.setBackend,
                ),
                SettingsSelectTile<AnimeJaNaiLook>(
                  icon: Icons.auto_awesome_outlined,
                  title: '模型',
                  value: _anime.look,
                  options: {
                    for (final look in AnimeJaNaiLook.values) look: look.label,
                  },
                  onChanged: _anime.busy ? null : _anime.setLook,
                ),
                _toggle(
                  'RIFE 补帧',
                  _anime.interpolation,
                  _anime.busy ? null : _anime.setInterpolation,
                ),
                SettingsSelectTile<AnimeJaNaiFrameMultiplier>(
                  icon: Icons.slow_motion_video_rounded,
                  title: '补帧倍率',
                  value: _anime.frameMultiplier,
                  options: {
                    for (final factor in AnimeJaNaiFrameMultiplier.values)
                      factor: factor.label,
                  },
                  onChanged: _anime.busy ? null : _anime.setFrameMultiplier,
                ),
                SettingsSelectTile<AnimeJaNaiInterpolationMode>(
                  icon: Icons.speed_rounded,
                  title: '补帧方案',
                  value: _anime.interpolationMode,
                  options: {
                    for (final mode in AnimeJaNaiInterpolationMode.values)
                      mode: mode.label,
                  },
                  onChanged: _anime.busy ? null : _anime.setInterpolationMode,
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    '快速方案使用轻量 RIFE，在最高 540p 下处理后超分至最高 1080p，'
                    '细节会比完整方案少；倍率不变，仅在你手动选择时启用。',
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    '随 AnimeJaNai 启用。24 fps × 2 → 48 fps，30 fps × 2 → 60 fps。'
                    '首次开启下载约 441 MiB；TensorRT 首次使用需编译引擎。',
                  ),
                ),
                for (final adjustment in AnimeJaNaiAdjustment.values)
                  SettingsSliderTile(
                    icon: Icons.tune_rounded,
                    title: adjustment.label,
                    value: _anime.picture[adjustment],
                    min: adjustment.min,
                    max: adjustment.max,
                    divisions: 60,
                    label: _anime.picture[adjustment].toStringAsFixed(2),
                    onChanged: _anime.busy
                        ? null
                        : (value) => _anime.adjustPicture(adjustment, value),
                    onChangeEnd: (_) => _anime.savePicture(),
                  ),
                if (playback != null && widget.captureFrame != null)
                  ListTile(
                    leading: const Icon(Icons.compare_rounded),
                    title: const Text('同帧对比'),
                    enabled: playback.status.active,
                    onTap: playback.status.active ? _compare : null,
                  ),
                ListTile(
                  title: Text(
                    _anime.busy
                        ? _anime.status
                        : playback?.status.message ?? _anime.status,
                  ),
                  subtitle: _anime.error == null ? null : Text(_anime.error!),
                  trailing: _anime.busy
                      ? TextButton(
                          onPressed: _anime.cancelSetup,
                          child: const Text('取消'),
                        )
                      : playback?.status.failed == true
                      ? TextButton(
                          onPressed: playback!.retry,
                          child: const Text('重试'),
                        )
                      : null,
                ),
                if (_anime.busy)
                  LinearProgressIndicator(value: _anime.installer.progress),
              ],
            ),
            SettingsSection(
              title: 'DLSS',
              children: [
                _toggle(
                  '启用',
                  _dlss.enabled,
                  _dlss.busy ? null : _dlss.setEnabled,
                ),
                _toggle(
                  '神经改绘',
                  effects.neuralRendering,
                  _dlss.busy
                      ? null
                      : (v) {
                          effects.neuralRendering = v;
                          _dlss.saveEffects();
                        },
                ),
                _dlssSlider(
                  '改绘强度',
                  effects.intensity,
                  (v) => effects.intensity = v,
                  min: .1,
                  max: 2,
                ),
                SettingsSelectTile<int>(
                  icon: Icons.aspect_ratio_rounded,
                  title: '处理分辨率',
                  value: effects.maxHeight,
                  options: const {720: '720p', 1080: '1080p'},
                  onChanged: _dlss.busy
                      ? null
                      : (value) {
                          effects.maxHeight = value;
                          _dlss.saveEffects();
                        },
                ),
                _toggle(
                  '超分辨率',
                  effects.superResolution,
                  _dlss.busy
                      ? null
                      : (v) {
                          effects.superResolution = v;
                          _dlss.saveEffects();
                        },
                ),
                _dlssSlider(
                  '输出锐化',
                  effects.sharpness,
                  (v) => effects.sharpness = v,
                ),
                _toggle(
                  '帧生成',
                  effects.frameGeneration,
                  _dlss.busy
                      ? null
                      : (v) {
                          effects.frameGeneration = v;
                          _dlss.saveEffects();
                        },
                ),
                _toggle(
                  '画质对比',
                  effects.comparison,
                  _dlss.busy
                      ? null
                      : (v) {
                          effects.comparison = v;
                          _dlss.saveEffects();
                        },
                ),
                ListTile(
                  title: Text(_dlss.error ?? _dlss.status),
                  trailing: _dlss.busy
                      ? TextButton(
                          onPressed: _dlss.cancelSetup,
                          child: const Text('取消'),
                        )
                      : null,
                ),
              ],
            ),
            OutlinedButton(
              onPressed: _anime.busy || _dlss.busy
                  ? null
                  : () async {
                      for (final adjustment in AnimeJaNaiAdjustment.values) {
                        _anime.adjustPicture(adjustment, 0);
                      }
                      _dlss.effects = DlssPlaybackEffects();
                      await Future.wait([
                        _anime.savePicture(),
                        _dlss.saveEffects(),
                      ]);
                    },
              child: const Text('重置自定义效果'),
            ),
            if (playback?.status.details case final String details
                when details.isNotEmpty)
              ExpansionTile(
                title: const Text('诊断'),
                children: [
                  SelectableText(details),
                  TextButton(
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: details)),
                    child: const Text('复制'),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }

  Future<void> _compare() async {
    AnimeJaNaiComparison? comparison;
    try {
      comparison = await widget.playback!.captureComparison(
        captureFrame: widget.captureFrame!,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(child: _Comparison(comparison!)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      await comparison?.close();
    }
  }
}

class _Comparison extends StatefulWidget {
  const _Comparison(this.images);
  final AnimeJaNaiComparison images;
  @override
  State<_Comparison> createState() => _ComparisonState();
}

class _ComparisonState extends State<_Comparison> {
  double _split = .5;
  late final _original = MemoryImage(widget.images.original);
  late final _enhanced = MemoryImage(widget.images.enhanced);

  @override
  void dispose() {
    _original.evict();
    _enhanced.evict();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 900,
    height: MediaQuery.sizeOf(context).height * .7,
    child: Column(
      children: [
        Expanded(
          child: InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: Stack(
                children: [
                  Image(image: _enhanced, gaplessPlayback: true),
                  Positioned.fill(
                    child: ClipRect(
                      clipper: _SplitClipper(_split),
                      child: Image(
                        image: _original,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Slider(value: _split, onChanged: (v) => setState(() => _split = v)),
        const Text('原画 / 超分'),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _SplitClipper extends CustomClipper<Rect> {
  const _SplitClipper(this.split);
  final double split;
  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * split, size.height);
  @override
  bool shouldReclip(_SplitClipper oldClipper) => split != oldClipper.split;
}
