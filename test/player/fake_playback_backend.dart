import 'dart:async';

import 'package:baka/widgets/baka_player/playback_backend.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class FakePlaybackBackend implements PlaybackBackend {
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _position = StreamController<Duration>.broadcast(sync: true);
  final _duration = StreamController<Duration>.broadcast(sync: true);
  final _buffer = StreamController<Duration>.broadcast(sync: true);
  final _buffering = StreamController<bool>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);
  final _completed = StreamController<bool>.broadcast(sync: true);
  final _tracks = StreamController<Tracks>.broadcast(sync: true);

  bool initialized = false;
  bool disposed = false;
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  String? _currentMediaUri;
  Duration? lastSeek;
  double? lastRate;
  SubtitleTrack? lastSubtitleTrack;
  int playCount = 0;
  int openCount = 0;
  int pauseCount = 0;
  int stopCount = 0;
  final nativeProperties = <String, String>{};

  @override
  VideoController? get videoController => null;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<Duration> get buffered => _buffer.stream;
  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Stream<String> get errors => _errors.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<Tracks> get tracks => _tracks.stream;
  @override
  bool get isPlaying => _isPlaying;
  @override
  Duration get currentPosition => _currentPosition;
  @override
  List<SubtitleTrack> get subtitleTracks => const [];
  @override
  SubtitleTrack get currentSubtitleTrack => SubtitleTrack.no();
  @override
  String? get currentMediaUri => _currentMediaUri;

  @override
  Future<void> initialize() async => initialized = true;

  @override
  Future<void> open(
    String uri, {
    required bool autoplay,
    Map<String, String>? httpHeaders,
  }) async {
    openCount++;
    _currentMediaUri = uri;
    _isPlaying = autoplay;
    _playing.add(autoplay);
  }

  @override
  Future<void> play() async {
    playCount++;
    _isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _currentMediaUri = null;
    _isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    _currentPosition = position;
    _position.add(position);
  }

  @override
  Future<void> setRate(double rate) async => lastRate = rate;
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    lastSubtitleTrack = track;
  }

  @override
  Future<void> setNativeProperty(String name, String value) async {
    nativeProperties[name] = value;
  }

  void emitPosition(Duration value) {
    _currentPosition = value;
    _position.add(value);
  }

  void emitDuration(Duration value) {
    _duration.add(value);
  }

  void emitPlaying(bool value) {
    _isPlaying = value;
    _playing.add(value);
  }

  void emitBuffering(bool value) => _buffering.add(value);
  void emitError(String value) => _errors.add(value);
  void emitCompleted() => _completed.add(true);
  void emitTracks(Tracks value) => _tracks.add(value);

  @override
  Future<void> dispose() async {
    disposed = true;
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _buffer.close();
    await _buffering.close();
    await _errors.close();
    await _completed.close();
    await _tracks.close();
  }
}
