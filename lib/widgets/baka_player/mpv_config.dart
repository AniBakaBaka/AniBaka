import 'package:baka/models/subtitle_config.dart';
import 'package:flutter/material.dart';

typedef MpvPropertySetter = Future<void> Function(String name, String value);

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

/// Build player properties with configurable decode and render profiles.
///
/// [hwdecMode] accepts 'auto', 'auto-safe', or 'no'.
/// [videoRenderer] deliberately changes libmpv's scaling profile instead of
/// `vo`: media_kit's external texture requires `vo=libmpv` on Windows.
Map<String, String> buildPlayerProperties({
  String hwdecMode = 'auto',
  String videoRenderer = 'auto',
}) {
  return <String, String>{
    ...playerProperties,
    'hwdec': hwdecMode,
    ...buildVideoRendererProperties(videoRenderer),
  };
}

Map<String, String> buildVideoRendererProperties(String renderer) {
  if (renderer == 'quality') {
    return const <String, String>{
      'scale': 'ewa_lanczossharp',
      'cscale': 'ewa_lanczossharp',
      'dscale': 'mitchell',
      'correct-downscaling': 'yes',
      'linear-downscaling': 'yes',
      'sigmoid-upscaling': 'yes',
    };
  }

  // Keep auto and compatibility conservative. These values also reset every
  // quality override when the selection is changed while playback is active.
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
