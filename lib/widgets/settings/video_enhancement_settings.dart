import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:baka/services/playback/animejanai_playback.dart';
import 'package:baka/services/playback/dlss_global_playback.dart';
import 'package:baka/widgets/player/settings_panel.dart';
import 'settings_widgets.dart';

/// 播放器里的画质增强入口：和弹幕/播放器设置共用同一块侧边浮层。
Future<void> showPlaybackEffects(
  BuildContext context,
  AnimeJaNaiPlayback playback, {
  required Future<Uint8List?> Function() captureFrame,
}) => showPlayerSettingsPanel(
  context,
  PanelContainer(
    title: '画质增强',
    child: Builder(
      builder: (context) => ListView(
        padding: playerPanelContentPadding(context),
        children: [
          VideoEnhancementSettings(
            playback: playback,
            captureFrame: captureFrame,
            inPanel: true,
          ),
        ],
      ),
    ),
  ),
);

/// 画质增强设置。
///
/// 同一套逻辑用在两个地方：播放器的半透明面板（[inPanel]）和「实验室」设置页。
/// 面板里用 Panel 系控件（白字、无卡片底），设置页里沿用 Settings 系卡片。
class VideoEnhancementSettings extends StatefulWidget {
  const VideoEnhancementSettings({
    super.key,
    this.playback,
    this.captureFrame,
    this.inPanel = false,
  });
  final AnimeJaNaiPlayback? playback;
  final Future<Uint8List?> Function()? captureFrame;
  final bool inPanel;

  @override
  State<VideoEnhancementSettings> createState() =>
      _VideoEnhancementSettingsState();
}

class _VideoEnhancementSettingsState extends State<VideoEnhancementSettings> {
  final _dlss = DlssGlobalPlayback.instance;
  final _anime = AnimeJaNaiService.instance;
  late final _changes = Listenable.merge([_dlss, _anime, ?widget.playback]);

  bool get _panel => widget.inPanel;

  Widget _section(String title, List<Widget> rows) {
    if (!_panel) return SettingsSection(title: title, children: rows);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelSectionTitle(title),
          PanelSettingsGroup(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const PanelDivider(),
                rows[i],
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _toggle(String title, bool value, ValueChanged<bool>? changed) =>
      _panel
      ? PanelSwitchTile(title: title, value: value, onChanged: changed)
      : SwitchListTile(title: Text(title), value: value, onChanged: changed);

  Widget _select<T>({
    required IconData icon,
    required String title,
    required T value,
    required Map<T, String> options,
    required ValueChanged<T>? onChanged,
  }) => _panel
      ? PanelSelectTile<T>(
          title: title,
          value: value,
          options: options,
          onChanged: onChanged,
        )
      : SettingsSelectTile<T>(
          icon: icon,
          title: title,
          value: value,
          options: options,
          onChanged: onChanged,
        );

  Widget _slider({
    required IconData icon,
    required String title,
    required double value,
    required ValueChanged<double>? onChanged,
    ValueChanged<double>? onChangeEnd,
    double min = 0,
    double max = 1,
    int? divisions,
  }) => _panel
      ? PanelSliderTile(
          title: title,
          value: value,
          valueLabel: value.toStringAsFixed(2),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        )
      : SettingsSliderTile(
          icon: icon,
          title: title,
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: value.toStringAsFixed(2),
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        );

  Widget _hint(String text) => Padding(
    padding: EdgeInsets.fromLTRB(4, _panel ? 8 : 4, 4, _panel ? 0 : 8),
    child: Text(
      text,
      style: _panel
          ? TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
              height: 1.45,
            )
          : const TextStyle(fontSize: 12, height: 1.45),
    ),
  );

  Widget _statusRow({
    required String text,
    String? error,
    VoidCallback? onCancel,
    VoidCallback? onRetry,
  }) {
    if (!_panel) {
      return ListTile(
        title: Text(text),
        subtitle: error == null ? null : Text(error),
        trailing: onCancel != null
            ? TextButton(onPressed: onCancel, child: const Text('取消'))
            : onRetry != null
            ? TextButton(onPressed: onRetry, child: const Text('重试'))
            : null,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onCancel != null)
            TextButton(onPressed: onCancel, child: const Text('取消'))
          else if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _compareRow(AnimeJaNaiPlayback playback) {
    final enabled = playback.status.active;
    if (!_panel) {
      return ListTile(
        leading: const Icon(Icons.compare_rounded),
        title: const Text('同帧对比'),
        enabled: enabled,
        onTap: enabled ? _compare : null,
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonalIcon(
        onPressed: enabled ? _compare : null,
        icon: const Icon(Icons.compare_rounded, size: 18),
        label: const Text('同帧对比'),
      ),
    );
  }

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
            _section('AnimeJaNai', [
              _toggle(
                '启用',
                _anime.enabled,
                _anime.busy ? null : _anime.setEnabled,
              ),
              _select<AnimeJaNaiProfile>(
                icon: Icons.high_quality_outlined,
                title: '档位',
                value: _anime.profile,
                options: {
                  for (final p in AnimeJaNaiProfile.values) p: p.label,
                },
                onChanged: _anime.busy ? null : _anime.setProfile,
              ),
              _select<AnimeJaNaiBackend>(
                icon: Icons.memory_outlined,
                title: '后端',
                value: _anime.backend,
                options: {
                  for (final b in AnimeJaNaiBackend.values) b: b.label,
                },
                onChanged: _anime.busy ? null : _anime.setBackend,
              ),
              _select<AnimeJaNaiLook>(
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
              _select<AnimeJaNaiFrameMultiplier>(
                icon: Icons.slow_motion_video_rounded,
                title: '补帧倍率',
                value: _anime.frameMultiplier,
                options: {
                  for (final factor in AnimeJaNaiFrameMultiplier.values)
                    factor: factor.label,
                },
                onChanged: _anime.busy ? null : _anime.setFrameMultiplier,
              ),
              _select<AnimeJaNaiInterpolationMode>(
                icon: Icons.speed_rounded,
                title: '补帧方案',
                value: _anime.interpolationMode,
                options: {
                  for (final mode in AnimeJaNaiInterpolationMode.values)
                    mode: mode.label,
                },
                onChanged: _anime.busy ? null : _anime.setInterpolationMode,
              ),
              _hint(
                '快速方案使用轻量 RIFE，在最高 540p 下处理后超分至最高 1080p，'
                '细节会比完整方案少；倍率不变，仅在你手动选择时启用。',
              ),
              _hint(
                '随 AnimeJaNai 启用。24 fps × 2 → 48 fps，30 fps × 2 → 60 fps。'
                '首次开启下载约 441 MiB；TensorRT 首次使用需编译引擎。',
              ),
              for (final adjustment in AnimeJaNaiAdjustment.values)
                _slider(
                  icon: Icons.tune_rounded,
                  title: adjustment.label,
                  value: _anime.picture[adjustment],
                  min: adjustment.min,
                  max: adjustment.max,
                  divisions: 60,
                  onChanged: _anime.busy
                      ? null
                      : (value) => _anime.adjustPicture(adjustment, value),
                  onChangeEnd: (_) => _anime.savePicture(),
                ),
              if (playback != null && widget.captureFrame != null)
                _compareRow(playback),
              if (_anime.status.isNotEmpty)
                _statusRow(
                  text: _anime.busy
                      ? _anime.status
                      : playback?.status.message ?? _anime.status,
                  error: _anime.error,
                  onCancel: _anime.busy ? _anime.cancelSetup : null,
                  onRetry: playback?.status.failed == true
                      ? playback!.retry
                      : null,
                ),
              if (_anime.busy)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: LinearProgressIndicator(
                    value: _anime.installer.progress,
                  ),
                ),
            ]),
            _section('DLSS', [
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
              _slider(
                icon: Icons.tune_rounded,
                title: '改绘强度',
                value: effects.intensity,
                min: .1,
                max: 2,
                divisions: 40,
                onChanged: _dlss.busy
                    ? null
                    : (v) => setState(() => effects.intensity = v),
                onChangeEnd: (_) => _dlss.saveEffects(),
              ),
              _select<int>(
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
              _slider(
                icon: Icons.tune_rounded,
                title: '输出锐化',
                value: effects.sharpness,
                divisions: 40,
                onChanged: _dlss.busy
                    ? null
                    : (v) => setState(() => effects.sharpness = v),
                onChangeEnd: (_) => _dlss.saveEffects(),
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
              if ((_dlss.error ?? _dlss.status).isNotEmpty)
                _statusRow(
                  text: _dlss.error ?? _dlss.status,
                  onCancel: _dlss.busy ? _dlss.cancelSetup : null,
                ),
            ]),
            _panel
                ? PanelResetButton(
                    onPressed: () {
                      if (_anime.busy || _dlss.busy) return;
                      _resetEffects();
                    },
                  )
                : OutlinedButton(
                    onPressed: _anime.busy || _dlss.busy
                        ? null
                        : _resetEffects,
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

  Future<void> _resetEffects() async {
    for (final adjustment in AnimeJaNaiAdjustment.values) {
      _anime.adjustPicture(adjustment, 0);
    }
    _dlss.effects = DlssPlaybackEffects();
    await Future.wait([_anime.savePicture(), _dlss.saveEffects()]);
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
