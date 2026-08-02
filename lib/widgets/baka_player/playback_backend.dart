import 'package:baka/models/playback_state.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

abstract interface class PlaybackBackend {
  VideoController? get videoController;

  Stream<bool> get playing;
  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<Duration> get buffered;
  Stream<bool> get buffering;
  Stream<String> get errors;
  Stream<bool> get completed;
  Stream<Tracks> get tracks;

  bool get isPlaying;
  Duration get currentPosition;
  List<SubtitleTrack> get subtitleTracks;
  SubtitleTrack get currentSubtitleTrack;
  String? get currentMediaUri;

  Future<void> initialize();
  Future<void> open(
    String uri, {
    required bool autoplay,
    Map<String, String>? httpHeaders,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setSubtitleTrack(SubtitleTrack track);
  Future<void> setNativeProperty(String name, String value);
  Future<PlaybackTechnicalInfo> getTechnicalInfo();
  Future<void> dispose();
}

class MediaKitPlaybackBackend implements PlaybackBackend {
  Player? _player;
  VideoController? _videoController;

  @override
  VideoController? get videoController => _videoController;

  Player get _requiredPlayer =>
      _player ?? (throw StateError('Playback backend is not initialized'));

  @override
  Stream<bool> get playing => _requiredPlayer.stream.playing;
  @override
  Stream<Duration> get position => _requiredPlayer.stream.position;
  @override
  Stream<Duration> get duration => _requiredPlayer.stream.duration;
  @override
  Stream<Duration> get buffered => _requiredPlayer.stream.buffer;
  @override
  Stream<bool> get buffering => _requiredPlayer.stream.buffering;
  @override
  Stream<String> get errors => _requiredPlayer.stream.error;
  @override
  Stream<bool> get completed => _requiredPlayer.stream.completed;
  @override
  Stream<Tracks> get tracks => _requiredPlayer.stream.tracks;

  @override
  bool get isPlaying => _player?.state.playing ?? false;
  @override
  Duration get currentPosition => _player?.state.position ?? Duration.zero;
  @override
  List<SubtitleTrack> get subtitleTracks =>
      _player?.state.tracks.subtitle ?? const <SubtitleTrack>[];
  @override
  SubtitleTrack get currentSubtitleTrack =>
      _requiredPlayer.state.track.subtitle;
  @override
  String? get currentMediaUri =>
      _player?.state.playlist.medias.firstOrNull?.uri;

  @override
  Future<void> initialize() async {
    if (_player != null) return;
    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 8 * 1024 * 1024,
        title: 'BAKA Player',
      ),
    );
    _player = player;
    _videoController = VideoController(player);
  }

  @override
  Future<void> open(
    String uri, {
    required bool autoplay,
    Map<String, String>? httpHeaders,
  }) {
    return _requiredPlayer.open(
      Media(uri, httpHeaders: httpHeaders ?? const <String, String>{}),
      play: autoplay,
    );
  }

  @override
  Future<void> play() => _requiredPlayer.play();
  @override
  Future<void> pause() => _requiredPlayer.pause();
  @override
  Future<void> stop() => _requiredPlayer.stop();
  @override
  Future<void> seek(Duration position) => _requiredPlayer.seek(position);
  @override
  Future<void> setRate(double rate) => _requiredPlayer.setRate(rate);
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _requiredPlayer.setSubtitleTrack(track);

  @override
  Future<void> setNativeProperty(String name, String value) async {
    final platform = _requiredPlayer.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(name, value);
    }
  }

  @override
  Future<PlaybackTechnicalInfo> getTechnicalInfo() async {
    final player = _requiredPlayer;
    final state = player.state;
    // mpv 的属性读取会阻塞调用线程直到核心空闲。媒体尚未加载完成时
    // （duration 未知）跳过原生属性读取，避免在 loadfile/网络卡顿时
    // 冻结 UI 线程。
    final properties = state.duration > Duration.zero
        ? await _readNativeProperties(player)
        : const <String, String>{};
    final video = _activeVideoTrack(state);
    final audio = _activeAudioTrack(state);
    final params = state.videoParams;
    final audioParams = state.audioParams;
    final outputRect = _videoController?.rect.value;

    return PlaybackTechnicalInfo(
      width: params.w ?? state.width ?? video?.w,
      height: params.h ?? state.height ?? video?.h,
      framesPerSecond:
          _parseDouble(properties['estimated-vf-fps']) ??
          _parseDouble(properties['container-fps']) ??
          video?.fps,
      videoBitrate: _parseInt(properties['video-bitrate']) ?? video?.bitrate,
      videoCodec: _firstValue([
        properties['video-codec-name'],
        video?.codec,
        properties['video-codec'],
      ]),
      videoDecoder: _firstValue([video?.decoder, properties['video-codec']]),
      hardwareDecoder: properties['hwdec-current'],
      videoOutput: properties['current-vo'],
      graphicsApi: properties['gpu-api'],
      graphicsContext: properties['current-gpu-context'],
      pixelFormat: _firstValue([params.pixelformat, params.hwPixelformat]),
      colorSpace: _joinedValues([
        params.primaries,
        params.gamma,
        params.colormatrix,
      ]),
      containerFormat: properties['file-format'],
      audioBitrate:
          _parseInt(properties['audio-bitrate']) ??
          state.audioBitrate?.round() ??
          audio?.bitrate,
      audioSampleRate: audioParams.sampleRate ?? audio?.samplerate,
      audioChannels: audioParams.channelCount ?? audio?.channelscount,
      audioCodec: _firstValue([
        properties['audio-codec-name'],
        audio?.codec,
        properties['audio-codec'],
      ]),
      audioDecoder: _firstValue([audio?.decoder, properties['audio-codec']]),
      audioFormat: audioParams.format,
      audioChannelLayout: _firstValue([
        audioParams.hrChannels,
        audioParams.channels,
        audio?.channels,
      ]),
      outputWidth: outputRect?.width.round(),
      outputHeight: outputRect?.height.round(),
      frameDropCount: _parseInt(properties['frame-drop-count']) ?? 0,
      delayedFrameCount: _parseInt(properties['vo-delayed-frame-count']) ?? 0,
    );
  }

  @override
  Future<void> dispose() async {
    final player = _player;
    _player = null;
    _videoController = null;
    await player?.dispose();
  }
}

const _technicalPropertyNames = <String>[
  'current-vo',
  'gpu-api',
  'current-gpu-context',
  'hwdec-current',
  'video-codec',
  'video-codec-name',
  'file-format',
  'estimated-vf-fps',
  'container-fps',
  'video-bitrate',
  'audio-codec',
  'audio-codec-name',
  'audio-bitrate',
  'frame-drop-count',
  'vo-delayed-frame-count',
];

Future<Map<String, String>> _readNativeProperties(Player player) async {
  final platform = player.platform;
  if (platform is! NativePlayer) return const <String, String>{};

  final result = <String, String>{};
  for (final name in _technicalPropertyNames) {
    try {
      final value = (await platform.getProperty(name)).trim();
      if (value.isNotEmpty && value.toLowerCase() != 'n/a') {
        result[name] = value;
      }
    } catch (_) {
      // Not every libmpv build or platform exposes every diagnostic property.
    }
  }
  return result;
}

VideoTrack? _activeVideoTrack(PlayerState state) {
  final selected = state.track.video;
  if (selected.id != 'auto' && selected.id != 'no') {
    for (final track in state.tracks.video) {
      if (track.id == selected.id) return track;
    }
    return selected;
  }
  VideoTrack? fallback;
  for (final track in state.tracks.video) {
    if (track.id == 'auto' || track.id == 'no') continue;
    if (track.isDefault == true) return track;
    fallback ??= track;
  }
  return fallback;
}

AudioTrack? _activeAudioTrack(PlayerState state) {
  final selected = state.track.audio;
  if (selected.id != 'auto' && selected.id != 'no') {
    for (final track in state.tracks.audio) {
      if (track.id == selected.id) return track;
    }
    return selected;
  }
  AudioTrack? fallback;
  for (final track in state.tracks.audio) {
    if (track.id == 'auto' || track.id == 'no') continue;
    if (track.isDefault == true) return track;
    fallback ??= track;
  }
  return fallback;
}

String? _firstValue(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

String? _joinedValues(Iterable<String?> values) {
  final result = <String>[];
  for (final value in values) {
    final normalized = value?.trim();
    if (normalized != null &&
        normalized.isNotEmpty &&
        !result.contains(normalized)) {
      result.add(normalized);
    }
  }
  return result.isEmpty ? null : result.join(' / ');
}

double? _parseDouble(String? value) =>
    value == null ? null : double.tryParse(value);

int? _parseInt(String? value) => _parseDouble(value)?.round();
