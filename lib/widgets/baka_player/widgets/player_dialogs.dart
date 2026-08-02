import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/dialog/input_dialog.dart';
import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';

Future<void> showPlaybackDetailsSheet(
  BuildContext context,
  PlaybackController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    elevation: 0,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => _PlaybackDetailsSheet(controller: controller),
  );
}

class _PlaybackDetailsSheet extends StatefulWidget {
  const _PlaybackDetailsSheet({required this.controller});

  final PlaybackController controller;

  @override
  State<_PlaybackDetailsSheet> createState() => _PlaybackDetailsSheetState();
}

class _PlaybackDetailsSheetState extends State<_PlaybackDetailsSheet> {
  late Future<PlaybackTechnicalInfo> _details;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _details = widget.controller.loadTechnicalInfo();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FractionallySizedBox(
      heightFactor: 0.82,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.onSurfaceVariant.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '播放器详情',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新',
                      onPressed: () => setState(_reload),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Divider(height: 1, color: colors.outlineVariant),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: FutureBuilder<PlaybackTechnicalInfo>(
                  future: _details,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            '暂时无法读取播放器详情\n${snapshot.error}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    return _PlaybackDetailsContent(info: snapshot.requireData);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaybackDetailsContent extends StatelessWidget {
  const _PlaybackDetailsContent({required this.info});

  final PlaybackTechnicalInfo info;

  @override
  Widget build(BuildContext context) {
    final rendererProfile =
        PlaybackSettingsService.videoRendererLabels[info.rendererProfile] ??
        info.rendererProfile;
    final hardwareMode =
        PlaybackSettingsService.hwdecModeLabels[info.hardwareDecodeMode] ??
        info.hardwareDecodeMode;
    final fallback = info.enhancementFallbackReason?.trim();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DetailSection(
            title: '视频',
            entries: [
              (label: '清晰度', value: _orUnavailable(info.qualityLabel)),
              (label: '片源分辨率', value: _orUnavailable(info.resolution)),
              (label: '帧率', value: _formatFps(info.framesPerSecond)),
              (label: '视频编码', value: _orUnavailable(info.videoCodec)),
              (label: '视频解码器', value: _orUnavailable(info.videoDecoder)),
              (
                label: '硬件解码',
                value: _hardwareDecoder(info.hardwareDecoder, hardwareMode),
              ),
              (label: '视频码率', value: _formatBitrate(info.videoBitrate)),
              (label: '像素格式', value: _orUnavailable(info.pixelFormat)),
              (label: '色彩空间', value: _orUnavailable(info.colorSpace)),
            ],
          ),
          const SizedBox(height: 24),
          _DetailSection(
            title: '渲染',
            entries: [
              (label: '视频渲染器', value: _orUnavailable(info.videoOutput)),
              (label: '渲染配置', value: rendererProfile),
              (label: '图形 API 配置', value: _orUnavailable(info.graphicsApi)),
              (
                label: '当前 GPU 上下文',
                value: _orUnavailable(info.graphicsContext),
              ),
              (label: '输出纹理', value: _orUnavailable(info.outputResolution)),
              (label: '请求增强', value: info.requestedEnhancementMode.label),
              (label: '实际管线', value: info.appliedEnhancementPipeline.label),
              (
                label: '降级原因',
                value: fallback == null || fallback.isEmpty ? '无' : fallback,
              ),
              (
                label: '渲染掉帧',
                value: '${info.frameDropCount}（延迟 ${info.delayedFrameCount}）',
              ),
              (label: '封装格式', value: _orUnavailable(info.containerFormat)),
            ],
          ),
          const SizedBox(height: 24),
          _DetailSection(
            title: '音频',
            entries: [
              (label: '音频编码', value: _orUnavailable(info.audioCodec)),
              (label: '音频解码器', value: _orUnavailable(info.audioDecoder)),
              (label: '音频码率', value: _formatBitrate(info.audioBitrate)),
              (
                label: '采样率',
                value: info.audioSampleRate == null
                    ? '暂不可用'
                    : '${info.audioSampleRate} Hz',
              ),
              (
                label: '声道',
                value: _audioChannels(
                  info.audioChannels,
                  info.audioChannelLayout,
                ),
              ),
              (label: '采样格式', value: _orUnavailable(info.audioFormat)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.entries});

  final String title;
  final List<({String label, String value})> entries;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (var index = 0; index < entries.length; index++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 112,
                  child: Text(
                    entries[index].label,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SelectableText(
                    entries[index].value,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
          if (index != entries.length - 1)
            Divider(height: 1, color: colors.outlineVariant),
        ],
      ],
    );
  }
}

String _orUnavailable(String? value) =>
    value == null || value.trim().isEmpty ? '暂不可用' : value;

String _formatFps(double? value) {
  if (value == null || value <= 0) return '暂不可用';
  final fixed = value.toStringAsFixed(2);
  return '${fixed.replaceFirst(RegExp(r'\.?0+$'), '')} FPS';
}

String _formatBitrate(int? bitsPerSecond) {
  if (bitsPerSecond == null || bitsPerSecond <= 0) return '暂不可用';
  if (bitsPerSecond >= 1000000) {
    return '${(bitsPerSecond / 1000000).toStringAsFixed(2)} Mbps';
  }
  return '${(bitsPerSecond / 1000).toStringAsFixed(0)} Kbps';
}

String _hardwareDecoder(String? actual, String configured) {
  final value = actual?.trim();
  if (value == null || value.isEmpty) {
    return '实际状态不可用 · 配置：$configured';
  }
  final label = value == 'no' ? '软件解码' : value;
  return '$label · 配置：$configured';
}

String _audioChannels(int? count, String? layout) {
  final values = <String>[];
  if (count != null && count > 0) values.add('$count 声道');
  if (layout != null && layout.trim().isNotEmpty) values.add(layout.trim());
  return values.isEmpty ? '暂不可用' : values.join(' · ');
}

void showSpeedDialog(BuildContext context, PlaybackController controller) {
  const speeds = [0.5, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0];
  _showSelectionDialog<double>(
    context: context,
    title: '\u500d\u901f',
    items: speeds
        .map(
          (speed) => (
            value: speed,
            label: speed.toString(),
            selected: speed == controller.core.value.playbackRate,
          ),
        )
        .toList(),
    onSelect: controller.setRate,
    actions: [
      TextButton(
        onPressed: () {
          controller.setRate(1.0);
          Navigator.pop(context);
        },
        child: const Text('\u9ed8\u8ba4\u901f\u5ea6'),
      ),
    ],
  );
}

void showVideoFitDialog(BuildContext context, PlaybackController controller) {
  _showSelectionDialog<({BoxFit fit, String description})>(
    context: context,
    title: '\u753b\u9762\u6bd4\u4f8b',
    items: PlaybackController.videoFitTypes
        .map(
          (type) => (
            value: type,
            label: type.description,
            selected: type.fit == controller.preferences.value.videoFit,
          ),
        )
        .toList(),
    onSelect: (type) {
      controller.setVideoFit(type.fit, type.description);
    },
  );
}

Future<void> showVideoEnhancementModeDialog(
  BuildContext context,
  PlaybackController controller,
) async {
  final options = <SelectionOption<VideoEnhancementMode>>[
    const SelectionOption(
      value: VideoEnhancementMode.low,
      label: '低',
      subtitle: '轻度锐化，画面更通透，性能开销小',
    ),
    const SelectionOption(
      value: VideoEnhancementMode.medium,
      label: '中',
      subtitle: '线条更锐利，画面更干净，效果明显',
    ),
    const SelectionOption(
      value: VideoEnhancementMode.high,
      label: '高',
      subtitle: '大幅提升清晰度，改善显著',
    ),
    const SelectionOption(
      value: VideoEnhancementMode.ultra,
      label: '超高',
      subtitle: '负载高，线条与细节还原最佳',
    ),
  ];
  final result = await showAppSelectionDialog<VideoEnhancementMode>(
    context,
    title: 'Anime4K 增强档位',
    options: options,
    currentValue: controller.preferences.value.videoEnhancementMode,
  );
  if (result != null) {
    try {
      await controller.setVideoEnhancementMode(result);
      showSnackBar('视频增强：${result.label}');
    } catch (error) {
      showSnackBar('视频增强切换失败：$error');
    }
  }
}

void _showSelectionDialog<T>({
  required BuildContext context,
  required String title,
  required List<({T value, String label, bool selected})> items,
  required void Function(T) onSelect,
  List<Widget>? actions,
}) {
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Wrap(
        spacing: 8,
        children: items
            .map(
              (item) => InkWell(
                onTap: () {
                  onSelect(item.value);
                  Navigator.pop(ctx);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: Theme.of(ctx).colorScheme.primary.withValues(
                      alpha: item.selected ? 0.3 : 0.1,
                    ),
                  ),
                  child: Text(item.label),
                ),
              ),
            )
            .toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(
            '\u53d6\u6d88',
            style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
          ),
        ),
        ...?actions,
      ],
    ),
  );
}
