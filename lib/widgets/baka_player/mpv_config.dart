import 'dart:io';

import 'package:baka/models/subtitle_config.dart';
import 'package:flutter/material.dart';

typedef MpvPropertySetter = Future<void> Function(String name, String value);

/// 硬解直通渲染器（仅 Android 可用）。
///
/// 对应 mpv 的 `vo=mediacodec_embed`：解码帧由 MediaCodec 直接写入 Surface，
/// 完全绕过 GPU 合成。部分电视（尤其低端 Android TV）的 `vo=gpu` 会出现
/// 有声黑屏，此模式是这类设备的可靠退路。
const mediacodecEmbedRenderer = 'mediacodec_embed';

/// A bounded packet cache shared by every platform.
///
/// media_kit already configures mpv's demuxer cache. Keep one explicit memory
/// budget here instead of stacking several 32 MiB stream/network buffers.
const playerProperties = <String, String>{
  'volume-max': '100',
  'hwdec': 'auto',
  'hwdec-codecs': 'all',
  'cache': 'auto',
  'cache-secs': '12',
  'demuxer-max-bytes': '16777216',
  'demuxer-max-back-bytes': '4194304',
  'demuxer-hysteresis-secs': '3',
  'network-timeout': '30',
  'tls-verify': 'no',
  'user-agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
};

/// 本地文件的 lavf 参数：保持 media_kit 默认的协议白名单与宽松解析。
///
/// 刻意不使用 `igndts+ignidx`：本地 MP4/MKV 的精确 seek 依赖样本索引与
/// DTS（B 帧流的包排序），忽略后 seek 会定位到错误关键帧，甚至直接落到
/// 文件末尾导致视频立即播完。
const localDemuxerLavfOptions =
    'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
    'protocol_whitelist=[file,http,https,tcp,udp,tls,data,crypto,ftp,rtp,rtsp,rtmp,srt]';

const lowMemoryPlayerProperties = <String, String>{
  'cache-secs': '5',
  'demuxer-max-bytes': '8388608',
  'demuxer-max-back-bytes': '2097152',
  'demuxer-hysteresis-secs': '2',
};

/// Build player properties with configurable decode and render profiles.
///
/// [hwdecMode] accepts 'auto', 'auto-safe', 'mediacodec-copy', or 'no'.
/// [videoRenderer] usually changes libmpv's scaling profile instead of `vo`:
/// media_kit's external texture requires `vo=libmpv` on Windows. The Android
/// 硬解直通 profile is the exception — it pins `hwdec=mediacodec` here and
/// leaves `vo=mediacodec_embed` to the VideoController configuration.
///
/// 初始加载路径刻意不设置 `vo`：Flutter 视频 Surface 尚未就绪（wid=0）时
/// 初始化 VO 可能导致崩溃，初始 vo 由 VideoController 的 configuration 在
/// Surface 就绪后统一应用。
Map<String, String> buildPlayerProperties({
  String hwdecMode = 'auto',
  String videoRenderer = 'gpu',
  bool lowMemoryMode = false,
  bool? android,
  String? mediaUri,
}) {
  final isNetwork =
      mediaUri != null &&
      (mediaUri.startsWith('http://') || mediaUri.startsWith('https://'));
  final isHls = isNetwork && mediaUri.toLowerCase().contains('.m3u8');
  return <String, String>{
    ...playerProperties,
    if (lowMemoryMode) ...lowMemoryPlayerProperties,
    'hwdec': effectiveHwdec(hwdecMode, videoRenderer, android: android),
    ...buildVideoRendererProperties(videoRenderer, android: android),
    // 网络流交还给 mpv/FFmpeg 默认解复用策略；自定义 reconnect、持久连接
    // 与 HLS 缓存选项会干扰部分签名分片在 seek 后重新建连。
    'demuxer-lavf-o': isNetwork ? '' : localDemuxerLavfOptions,
    // A seek-recovery manifest temporarily disables rebasing so its original
    // fMP4 timestamps remain on the episode timeline. Every normal open must
    // restore mpv's default before loading the next media.
    'rebase-start-time': 'yes',
    // Android 当前打包的 FFmpeg 6.0 在 fMP4 HLS seek 时可能把目标分片开头
    // 略早于 EXTINF 时间线的关键帧全部丢掉，最终误判 EOF。让 demuxer 从前一
    // 个常见 HLS 分片开始读取，再由 mpv 精确解码到目标时间。
    'hr-seek': 'yes',
    'hr-seek-demuxer-offset': isHls ? '12' : '0',
  };
}

/// 实际生效的 hwdec：硬解直通强制 mediacodec 解码，否则沿用用户选择。
String effectiveHwdec(String hwdecMode, String videoRenderer, {bool? android}) {
  final isAndroid = android ?? Platform.isAndroid;
  return isAndroid && videoRenderer == mediacodecEmbedRenderer
      ? 'mediacodec'
      : hwdecMode;
}

Map<String, String> buildRendererSwitchProperties({
  required String renderer,
  required String hwdecMode,
  bool? android,
}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (isAndroid) return const <String, String>{};
  return buildVideoRendererProperties(renderer, android: false);
}

/// 渲染器对应的 mpv 渲染属性。
///
/// Android 的 vo 只能是 `gpu`（media_kit 默认）或 `mediacodec_embed`，
/// 两者都使用保守缩放；额外固定 rgba8 帧缓冲并关闭去色带 / 补帧等高显存
/// 处理，避免 Mali-G52 这类低显存 GPU 在 rgba16f 中间纹理上 OOM。
/// `gpu-next` 仅存在于桌面端（libmpv 的缩放档位），Android 传入时按 gpu
/// 处理。
Map<String, String> buildVideoRendererProperties(
  String renderer, {
  bool? android,
}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (isAndroid) {
    return const <String, String>{
      'gpu-context': 'android',
      'profile': 'fast',
      'fbo-format': 'rgba8',
      'deband': 'no',
      'interpolation': 'no',
      'scale': 'bilinear',
      'cscale': 'bilinear',
      'dscale': 'bilinear',
      'correct-downscaling': 'no',
      'linear-downscaling': 'no',
      'sigmoid-upscaling': 'no',
    };
  }

  if (renderer == 'gpu-next') {
    return const <String, String>{
      'scale': 'ewa_lanczossharp',
      'cscale': 'ewa_lanczossharp',
      'dscale': 'mitchell',
      'correct-downscaling': 'yes',
      'linear-downscaling': 'yes',
      'sigmoid-upscaling': 'yes',
    };
  }

  // gpu 使用保守缩放。这些值也会在播放中切换渲染器时重置 gpu-next 的
  // 高质量覆盖。
  return const <String, String>{
    'scale': 'bilinear',
    'cscale': 'bilinear',
    'dscale': 'bilinear',
    'correct-downscaling': 'no',
    'linear-downscaling': 'no',
    'sigmoid-upscaling': 'no',
  };
}

String sanitizePlaybackError(Object error) {
  var message = error.toString();
  message = message.replaceAllMapped(
    RegExp(r'(https?:\/\/)([^\/\s?#@]+@)', caseSensitive: false),
    (match) => match.group(1)!,
  );
  message = message.replaceAll(
    RegExp(r'Authorization:\s*Basic\s+[A-Za-z0-9+/=]+', caseSensitive: false),
    'Authorization: Basic ***',
  );
  message = message.replaceAllMapped(
    RegExp(
      r'([?&](?:password|passwd|token|access_token|auth|authorization)=)[^&\s]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}***',
  );
  return message;
}

Map<String, String> buildSubtitleProperties(SubtitleConfig config) {
  final subPos = config.position.round().clamp(0, 150);
  final subFontSize = config.fontSize.round().clamp(10, 100);

  return {
    'sub-pos': '$subPos',
    'sub-font-size': '$subFontSize',
    'sub-color': colorToMpv(
      config.fontColor.withValues(alpha: config.opacity * config.fontColor.a),
    ),
    'sub-border-size': config.borderWidth.toStringAsFixed(1),
    'sub-border-color': colorToMpv(config.borderColor),
    'sub-back-color': colorToMpv(config.backgroundColor),
    'sub-bold': config.bold ? 'yes' : 'no',
    'sub-visibility': 'no',
    if (config.fontFamily.isNotEmpty) 'sub-font': config.fontFamily,
    'sub-ass-override': 'force',
  };
}

String colorToMpv(Color color) {
  String byte(double value) {
    return (value * 255.0)
        .round()
        .clamp(0, 255)
        .toRadixString(16)
        .padLeft(2, '0');
  }

  return '#${byte(color.a)}${byte(color.r)}${byte(color.g)}${byte(color.b)}';
}

Future<void> syncMpvProperties(
  MpvPropertySetter setProperty,
  Map<String, String> properties, {
  required String debugLabel,
}) async {
  for (final entry in properties.entries) {
    try {
      await setProperty(entry.key, entry.value);
    } catch (e) {
      debugPrint('Failed to set $debugLabel property ${entry.key}: $e');
    }
  }
}
