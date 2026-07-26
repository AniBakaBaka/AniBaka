import 'package:flutter/foundation.dart';
import 'dart:async';

import 'package:baka/services/torrent/torrent_engine.dart';

/// Global BT download and streaming service.
class TorrentService {
  TorrentService._();
  static final TorrentService instance = TorrentService._();

  static const Duration defaultBufferTimeout = Duration(seconds: 30);
  static const Duration _bufferPollInterval = Duration(milliseconds: 200);
  static const Duration _statsPublishInterval = Duration(milliseconds: 500);
  static final RegExp _torrentUrlPattern = RegExp(
    r'\.torrent(?:[?#&]|$)',
    caseSensitive: false,
  );

  TorrentEngine? _engine;
  Timer? _statsTimer;
  DateTime? _lastStatsPublishedAt;

  final ValueNotifier<TorrentStats?> statsNotifier = ValueNotifier(null);

  /// Current torrent engine.
  TorrentEngine? get engine => _engine;

  /// Current state.
  TorrentState get state => _engine?.state ?? TorrentState.idle;

  /// Download progress callback.
  void Function(double progress, int downloadedBytes, int totalBytes)?
  onProgress;

  /// State change callback.
  void Function(TorrentState state)? onStateChanged;

  /// Buffer-ready callback.
  void Function(String streamUrl)? onReadyToPlay;

  /// Whether the URL or episode id points to a BT source.
  static bool isBtLink(String value) {
    final lower = value.toLowerCase().trim();
    return lower.startsWith('magnet:') || _torrentUrlPattern.hasMatch(lower);
  }

  static bool isMagnetLink(String value) =>
      value.toLowerCase().trim().startsWith('magnet:');

  /// Start streaming from a magnet or torrent URL.
  Future<String?> startStream(String url) async {
    await stopStream();

    final target = url.trim();
    if (!isBtLink(target)) {
      debugPrint('[TorrentService] Unsupported BT link: $target');
      return null;
    }

    final engine = TorrentEngine();
    _engine = engine;
    _bindCallbacks(engine);

    final streamUrl = isMagnetLink(target)
        ? await engine.startFromMagnet(target)
        : await engine.startFromTorrentUrl(target);

    return _finalizeStart(engine, streamUrl);
  }

  /// Resolve a regular media URL unchanged, or turn a magnet/torrent URL into
  /// the loopback HTTP stream consumed by the player.
  ///
  /// Failed starts, terminal engine errors, cancellations, and buffer timeouts
  /// clean up the engine before surfacing [TorrentPlaybackException].
  Future<String> resolvePlaybackUrl(
    String url, {
    Duration bufferTimeout = defaultBufferTimeout,
  }) async {
    final target = url.trim();
    if (target.isEmpty || !isBtLink(target)) return target;

    final streamUrl = await startStream(target);
    final activeEngine = _engine;
    if (streamUrl == null || activeEngine == null) {
      final message = activeEngine?.errorMessage ?? 'BT stream failed to start';
      if (activeEngine != null && identical(_engine, activeEngine)) {
        await stopStream();
      }
      throw TorrentPlaybackException(message);
    }

    try {
      await _waitUntilBuffered(activeEngine, bufferTimeout);
      return streamUrl;
    } catch (_) {
      if (identical(_engine, activeEngine)) await stopStream();
      rethrow;
    }
  }

  /// Stop the current streaming/download engine.
  Future<void> stopStream() async {
    final engine = _engine;
    if (engine == null) return;

    _engine = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _lastStatsPublishedAt = null;
    statsNotifier.value = null;
    await engine.stop();
  }

  /// Current download stats.
  TorrentStats? getStats() => _engine?.getStats();

  /// Current target-file download progress.
  double get progress => _engine?.pieceManager?.progress ?? 0.0;

  Future<void> _waitUntilBuffered(
    TorrentEngine activeEngine,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (!identical(_engine, activeEngine)) {
        throw const TorrentPlaybackException('BT stream was stopped');
      }
      if (activeEngine.state == TorrentState.error) {
        throw TorrentPlaybackException(
          activeEngine.errorMessage ?? 'BT stream entered an error state',
        );
      }
      if (activeEngine.pieceManager?.isReadyToPlay == true) return;

      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative || remaining == Duration.zero) {
        throw TorrentPlaybackException(
          'BT buffer timed out after ${timeout.inSeconds}s',
        );
      }
      await Future.delayed(
        remaining < _bufferPollInterval ? remaining : _bufferPollInterval,
      );
    }
  }

  void _bindCallbacks(TorrentEngine engine) {
    engine.onProgress = (progress, downloaded, total) {
      if (_engine != engine) return;
      onProgress?.call(progress, downloaded, total);
      _scheduleStatsPublish(engine);
    };
    engine.onStateChanged = (state) {
      if (_engine != engine) return;
      onStateChanged?.call(state);
      _publishStats(engine);
    };
    engine.onReadyToPlay = (streamUrl) {
      if (_engine != engine) return;
      onReadyToPlay?.call(streamUrl);
      _publishStats(engine);
    };
    _publishStats(engine);
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

  String? _finalizeStart(TorrentEngine engine, String? streamUrl) {
    if (_engine != engine) {
      engine.stop();
      return null;
    }
    if (streamUrl == null) {
      debugPrint(
        '[TorrentService] Failed to start stream: ${engine.errorMessage}',
      );
    }
    return streamUrl;
  }
}

class TorrentPlaybackException implements Exception {
  const TorrentPlaybackException(this.message);

  final String message;

  @override
  String toString() => 'TorrentPlaybackException: $message';
}
