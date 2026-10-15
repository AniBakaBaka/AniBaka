import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:baka/services/torrent/torrent_engine.dart';
import 'package:baka/services/torrent/torrent_model.dart';

/// Owns the active BT session and publishes the shared UI statistics.
class TorrentService {
  static const defaultBufferTimeout = Duration(seconds: 30);
  static const _statsPublishInterval = Duration(milliseconds: 500);

  TorrentEngine? _engine;
  Timer? _statsTimer;
  bool _disposed = false;
  int _generation = 0;
  Future<void>? _disposing;
  Future<void>? _stopping;
  final ValueNotifier<TorrentStats?> statsNotifier = ValueNotifier(null);

  Future<String> resolvePlaybackUrl(
    String url, {
    Duration bufferTimeout = defaultBufferTimeout,
  }) async {
    final target = url.trim();
    if (!isTorrentLink(target)) return target;
    if (_disposed) throw StateError('TorrentService is disposed');
    final generation = ++_generation;
    await _stopEngine();
    if (_disposed || generation != _generation) {
      throw const TorrentPlaybackException('BT stream was stopped');
    }
    final engine = _engine = TorrentEngine();
    // Sampling bounds UI work and updates speeds even when traffic stops.
    _statsTimer = Timer.periodic(_statsPublishInterval, (_) {
      statsNotifier.value = engine.getStats();
    });
    statsNotifier.value = engine.getStats();
    try {
      final streamUrl = await engine.start(target).timeout(bufferTimeout);
      if (generation != _generation || streamUrl == null) {
        throw const TorrentPlaybackException('BT stream was stopped');
      }
      statsNotifier.value = engine.getStats();
      return streamUrl;
    } on TimeoutException {
      if (generation == _generation) await stopStream();
      throw TorrentPlaybackException(
        'BT buffer timed out after ${bufferTimeout.inSeconds}s',
      );
    } catch (_) {
      if (generation == _generation) await stopStream();
      rethrow;
    }
  }

  Future<void> stopStream() {
    _generation++;
    return _stopEngine();
  }

  Future<void> _stopEngine() async {
    final engine = _engine;
    _engine = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    if (!_disposed) statsNotifier.value = null;
    if (engine != null) _stopping = engine.dispose();
    await _stopping;
  }

  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    await stopStream();
    statsNotifier.dispose();
  }
}

class TorrentPlaybackException implements Exception {
  const TorrentPlaybackException(this.message);
  final String message;
  @override
  String toString() => 'TorrentPlaybackException: $message';
}
