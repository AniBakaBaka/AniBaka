import 'dart:async';
import 'dart:ui';

import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter/material.dart';

/// 播放器极简重要数据悬浮窗 (Player Info HUD)
class PlayerInfoHud extends StatefulWidget {
  const PlayerInfoHud({
    required this.controller,
    required this.onClose,
    super.key,
  });

  final PlaybackController controller;
  final VoidCallback onClose;

  @override
  State<PlayerInfoHud> createState() => _PlayerInfoHudState();
}

class _PlayerInfoHudState extends State<PlayerInfoHud> {
  PlaybackTechnicalInfo? _info;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fetchInfo();
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _fetchInfo();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchInfo() async {
    try {
      final info = await widget.controller.loadTechnicalInfo();
      if (mounted) {
        setState(() => _info = info);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {}, // 阻止手势穿透到底层播放器
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: 230,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 0.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 极简顶部标题与关闭按钮
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '播放数据',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: widget.onClose,
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                if (info == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  )
                else ...[
                  _buildItem('分辨率', _formatResolution(info)),
                  _buildItem('视频编码', _formatVideoCodec(info)),
                  _buildItem('视频码率', _formatBitrate(info.videoBitrate)),
                  _buildItem('渲染输出', _formatRenderer(info)),
                  _buildItem('渲染掉帧', _formatFrameDrops(info)),
                  _buildItem('画质增强', _formatEnhancement(info)),
                  _buildItem('音频规格', _formatAudio(info)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 11.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _formatResolution(PlaybackTechnicalInfo info) {
    final res = info.resolution ?? '未知';
    if (info.framesPerSecond != null && info.framesPerSecond! > 0) {
      final fps = info.framesPerSecond!.toStringAsFixed(
        info.framesPerSecond! % 1 == 0 ? 0 : 2,
      );
      return '$res @ ${fps}fps';
    }
    return res;
  }

  String _formatVideoCodec(PlaybackTechnicalInfo info) {
    final codec = (info.videoCodec ?? '').toUpperCase();
    final hw = info.hardwareDecoder?.trim();
    if (hw != null && hw.isNotEmpty && hw != 'no') {
      return codec.isNotEmpty ? '$codec · 硬解' : '硬解 ($hw)';
    }
    return codec.isNotEmpty ? '$codec · 软解' : '软解';
  }

  String _formatRenderer(PlaybackTechnicalInfo info) {
    final profile =
        PlaybackSettingsService.videoRendererLabels[info.rendererProfile] ??
        info.rendererProfile;
    if (info.videoOutput != null && info.videoOutput!.isNotEmpty) {
      return '${info.videoOutput} ($profile)';
    }
    return profile;
  }

  String _formatFrameDrops(PlaybackTechnicalInfo info) {
    if (info.frameDropCount == 0 && info.delayedFrameCount == 0) {
      return '0';
    }
    return '${info.frameDropCount} (延迟 ${info.delayedFrameCount})';
  }

  String _formatEnhancement(PlaybackTechnicalInfo info) {
    if (info.appliedEnhancementPipeline == VideoEnhancementPipeline.off) {
      return '关闭';
    }
    return 'Anime4K · ${info.appliedEnhancementPipeline.label}';
  }

  String _formatAudio(PlaybackTechnicalInfo info) {
    final parts = <String>[];
    if (info.audioCodec != null && info.audioCodec!.isNotEmpty) {
      parts.add(info.audioCodec!.toUpperCase());
    }
    if (info.audioChannels != null && info.audioChannels! > 0) {
      parts.add('${info.audioChannels}ch');
    }
    final bitrate = _formatBitrate(info.audioBitrate);
    if (bitrate != '暂不可用') {
      parts.add(bitrate);
    }
    return parts.isEmpty ? '暂不可用' : parts.join(' · ');
  }

  String _formatBitrate(int? bitsPerSecond) {
    if (bitsPerSecond == null || bitsPerSecond <= 0) return '暂不可用';
    if (bitsPerSecond >= 1000000) {
      return '${(bitsPerSecond / 1000000).toStringAsFixed(2)} Mbps';
    }
    return '${(bitsPerSecond / 1000).toStringAsFixed(0)} Kbps';
  }
}

/// 以独立 Dialog 形式弹出极简 HUD（方便 TV 等特定场景使用）
Future<void> showPlayerInfoDialog(
  BuildContext context,
  PlaybackController controller,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Center(
      child: Material(
        color: Colors.transparent,
        child: PlayerInfoHud(
          controller: controller,
          onClose: () => Navigator.pop(ctx),
        ),
      ),
    ),
  );
}
