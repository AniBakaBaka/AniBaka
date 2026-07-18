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
  Stream<String> get errors => _requiredPlayer.stream.error;
  @override
  Stream<bool> get completed => _requiredPlayer.stream.completed;
  @override
  Stream<Tracks> get tracks => _requiredPlayer.stream.tracks;

  @override
  bool get isPlaying => _player?.state.playing ?? false;
  @override
  Duration get currentPosition => _player?.state.position ?? Duration.zero;
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
      Media(
        uri,
        httpHeaders: httpHeaders ?? const <String, String>{},
      ),
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
  Future<void> dispose() async {
    final player = _player;
    _player = null;
    _videoController = null;
    await player?.dispose();
  }
}
