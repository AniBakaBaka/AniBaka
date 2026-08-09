import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:baka/services/torrent/torrent_engine.dart';
import 'package:baka/services/torrent/torrent_model.dart';

/// Owns the single active BT session and exposes one shared UI snapshot.
class TorrentService {
  TorrentService._();

  static final TorrentService instance = TorrentService._();
  static const Duration defaultBufferTimeout = Duration(seconds: 30);
  static const Duration _statsPublishInterval = Duration(milliseconds: 500);

  TorrentEngine? _engine;
  Timer? _statsTimer;
  DateTime? _lastStatsPublishedAt;
  Completer<void> _nextUpdate = Completer<void>();

  final ValueNotifier<TorrentStats?> statsNotifier = ValueNotifier(null);

  static bool isBtLink(String value) => isTorrentLink(value);

  Future<String?> _startStream(String url) async {
    await stopStream();
    final target = url.trim();
    if (!isTorrentLink(target)) return null;

    final engine = TorrentEngine();
    _engine = engine;
    engine.onChanged = () {
      if (!identical(_engine, engine)) return;
      _signalUpdate();
      _scheduleStatsPublish(engine);
    };
    _publishStats(engine);

    final streamUrl = target.toLowerCase().startsWith('magnet:')
        ? await engine.startFromMagnet(target)
        : await engine.startFromTorrentUrl(target);
    if (!identical(_engine, engine)) {
      unawaited(engine.stop());
      return null;
    }
    return streamUrl;
  }

  Future<String> resolvePlaybackUrl(
    String url, {
    Duration bufferTimeout = defaultBufferTimeout,
  }) async {
    final target = url.trim();
    if (!isTorrentLink(target)) return target;

    final streamUrl = await _startStream(target);
    final engine = _engine;
    if (streamUrl == null || engine == null) {
      final message = engine?.errorMessage ?? 'BT stream failed to start';
      if (engine != null && identical(_engine, engine)) await stopStream();
      throw TorrentPlaybackException(message);
    }

    try {
      await _waitUntilBuffered(engine, bufferTimeout);
      return streamUrl;
    } catch (_) {
      if (identical(_engine, engine)) await stopStream();
      rethrow;
    }
  }

  Future<void> stopStream() async {
    final engine = _engine;
    if (engine == null) return;
    _engine = null;
    engine.onChanged = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastStatsPublishedAt = null;
    statsNotifier.value = null;
    _signalUpdate();
    await engine.stop();
  }

  Future<void> _waitUntilBuffered(
    TorrentEngine engine,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (!identical(_engine, engine)) {
        throw const TorrentPlaybackException('BT stream was stopped');
      }
      if (engine.state == TorrentState.error) {
        throw TorrentPlaybackException(
          engine.errorMessage ?? 'BT stream entered an error state',
        );
      }
      if (engine.isReadyToPlay) return;

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TorrentPlaybackException(
          'BT buffer timed out after ${timeout.inSeconds}s',
        );
      }
      try {
        await _nextUpdate.future.timeout(remaining);
      } on TimeoutException {
        throw TorrentPlaybackException(
          'BT buffer timed out after ${timeout.inSeconds}s',
        );
      }
    }
  }

  void _signalUpdate() {
    final update = _nextUpdate;
    _nextUpdate = Completer<void>();
    if (!update.isCompleted) update.complete();
  }

  void _scheduleStatsPublish(TorrentEngine engine) {
    if (_statsTimer != null) return;
    final now = DateTime.now();
    final elapsed = _lastStatsPublishedAt == null
        ? _statsPublishInterval
        : now.difference(_lastStatsPublishedAt!);
    if (elapsed >= _statsPublishInterval) {
      _publishStats(engine);
      return;
    }
    _statsTimer = Timer(_statsPublishInterval - elapsed, () {
      _statsTimer = null;
      _publishStats(engine);
    });
  }

  void _publishStats(TorrentEngine engine) {
    if (!identical(_engine, engine)) return;
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastStatsPublishedAt = DateTime.now();
    statsNotifier.value = engine.getStats();
  }
}

class TorrentPlaybackException implements Exception {
  const TorrentPlaybackException(this.message);

  final String message;

  @override
  String toString() => 'TorrentPlaybackException: $message';
}
