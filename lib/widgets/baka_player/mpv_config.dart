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
  'demuxer-lavf-o':
      'reconnect=1,multiple_requests=1,retry_open=3,hls_wrap=0,hls_allow_cache=1,fflags=+igndts+ignidx,tls_verify=0',
};

const lowMemoryPlayerProperties = <String, String>{
  'cache-secs': '5',
  'demuxer-max-bytes': '8388608',
  'demuxer-max-back-bytes': '2097152',
  'demuxer-hysteresis-secs': '2',
};

/// Build player properties with configurable decode and render profiles.
///
/// [hwdecMode] accepts 'auto', 'auto-safe', or 'no'.
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
}) {
  return <String, String>{
    ...playerProperties,
    if (lowMemoryMode) ...lowMemoryPlayerProperties,
    'hwdec': effectiveHwdec(hwdecMode, videoRenderer, android: android),
    ...buildVideoRendererProperties(videoRenderer),
  };
}

/// 实际生效的 hwdec：硬解直通强制 mediacodec 解码，否则沿用用户选择。
String effectiveHwdec(
  String hwdecMode,
  String videoRenderer, {
  bool? android,
}) {
  final isAndroid = android ?? Platform.isAndroid;
  return isAndroid && videoRenderer == mediacodecEmbedRenderer
      ? 'mediacodec'
      : hwdecMode;
}

/// 渲染器选择变化时按顺序应用的 mpv 属性。
///
/// Android 上每个选项都对应真实的 vo：gpu / gpu-next / mediacodec_embed。
/// 切到 mediacodec_embed 时先固定 hwdec 再切换 vo（vo 重初始化会按当时的
/// hwdec 重建解码链），并重设 vid 避免出现 "Could not open codec"。
/// 非 Android 平台不动 vo 与 hwdec（media_kit 需要 vo=libmpv 纹理输出）。
Map<String, String> buildRendererSwitchProperties({
  required String renderer,
  required String hwdecMode,
  bool? android,
}) {
  final isAndroid = android ?? Platform.isAndroid;
  const knownRenderers = {'gpu', 'gpu-next', mediacodecEmbedRenderer};
  final props = <String, String>{};
  if (isAndroid && knownRenderers.contains(renderer)) {
    final direct = renderer == mediacodecEmbedRenderer;
    // hwdec 必须先于 vo 应用：vo 重初始化会按当时的 hwdec 重建解码链。
    props['hwdec'] = direct ? 'mediacodec' : hwdecMode;
    props['vo'] = renderer;
    if (direct) props['vid'] = 'auto';
  }
  props.addAll(buildVideoRendererProperties(renderer));
  return props;
}

Map<String, String> buildVideoRendererProperties(String renderer) {
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

  // gpu 与 mediacodec_embed 使用保守缩放。这些值也会在播放中切换渲染器时
  // 重置 gpu-next 的高质量覆盖。
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
