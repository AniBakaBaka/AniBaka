import 'dart:io';

import 'package:baka/models/subtitle_config.dart';
import 'package:flutter/material.dart';

typedef MpvPropertySetter = Future<void> Function(String name, String value);

const mediacodecEmbedRenderer = 'mediacodec_embed';

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

const localDemuxerLavfOptions =
    'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
    'protocol_whitelist=[file,http,https,tcp,udp,tls,data,crypto,ftp,rtp,rtsp,rtmp,srt]';

const networkDemuxerLavfOptions =
    'reconnect=1,multiple_requests=1,retry_open=3,hls_wrap=0,hls_allow_cache=1,'
    'fflags=+igndts+ignidx,tls_verify=0';

const lowMemoryPlayerProperties = <String, String>{
  'cache-secs': '5',
  'demuxer-max-bytes': '8388608',
  'demuxer-max-back-bytes': '2097152',
  'demuxer-hysteresis-secs': '2',
};

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
  return <String, String>{
    ...playerProperties,
    if (lowMemoryMode) ...lowMemoryPlayerProperties,
    'hwdec': effectiveHwdec(hwdecMode, videoRenderer, android: android),
    ...buildVideoRendererProperties(videoRenderer, android: android),
    'demuxer-lavf-o': isNetwork
        ? networkDemuxerLavfOptions
        : localDemuxerLavfOptions,
  };
}

/// 实际生效的 hwdec：硬解直通强制 mediacodec 解码，否则沿用用户选择。
String effectiveHwdec(String hwdecMode, String videoRenderer, {bool? android}) {
  final isAndroid = android ?? Platform.isAndroid;
  if (!isAndroid) return hwdecMode;
  if (videoRenderer == mediacodecEmbedRenderer) return 'mediacodec';
  return hwdecMode == 'auto' ? 'auto-safe' : hwdecMode;
}

bool isFatalPlaybackError(String error) {
  final message = error.toLowerCase();
  return message.contains('could not open codec') ||
      message.contains('failed to open codec');
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
