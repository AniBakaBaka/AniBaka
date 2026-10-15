import 'dart:async';

import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback/playback_settings.dart';
import '../controller.dart';
import 'package:flutter/material.dart';

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
  ({
    String resolution,
    String codec,
    String bitrate,
    String renderer,
    String drops,
    String enhancement,
    String audio,
  })?
  _rows;
  bool _fetching = false;
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
    if (_fetching) return;
    _fetching = true;
    final controller = widget.controller;
    try {
      final info = await controller.loadTechnicalInfo();
      if (!mounted || !identical(controller, widget.controller)) return;
      final rows = (
        resolution: _formatResolution(info),
        codec: _formatVideoCodec(info),
        bitrate: _formatBitrate(info.videoBitrate),
        renderer: _formatRenderer(info),
        drops: _formatFrameDrops(info),
        enhancement: _formatEnhancement(info),
        audio: _formatAudio(info),
      );
      if (_rows != rows) setState(() => _rows = rows);
    } catch (_) {
    } finally {
      _fetching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;

    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // 阻止手势穿透到底层播放器
        child: Container(
          width: 230,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xF0181818),
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

              if (rows == null)
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
                _buildItem('分辨率', rows.resolution),
                _buildItem('视频编码', rows.codec),
                _buildItem('视频码率', rows.bitrate),
                _buildItem('渲染输出', rows.renderer),
                _buildItem('渲染掉帧', rows.drops),
                _buildItem('画质增强', rows.enhancement),
                _buildItem('音频规格', rows.audio),
              ],
            ],
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
    final decoder = switch (info.hardwareDecoder) {
      null => '暂不可用',
      'no' => '软解',
      _ => '硬解',
    };
    return codec.isEmpty ? decoder : '$codec · $decoder';
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
    final drops = info.frameDropCount?.toString() ?? '暂不可用';
    final delayed = info.delayedFrameCount;
    return delayed == null || delayed == 0 ? drops : '$drops (延迟 $delayed)';
  }

  String _formatEnhancement(PlaybackTechnicalInfo info) {
    if (info.appliedEnhancementPipeline == VideoEnhancementMode.off) {
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
