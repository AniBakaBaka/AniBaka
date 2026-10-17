import 'package:baka/core/network_service.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' show min;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:baka/services/torrent/torrent_model.dart';
import 'package:baka/services/torrent/tracker_client.dart';
import 'package:baka/services/torrent/peer_protocol.dart';
import 'package:baka/services/torrent/piece_manager.dart';
import 'package:baka/services/torrent/stream_server.dart';

/// Torrent 下载状态
enum TorrentState { idle, resolving, connecting, downloading, seeding, error }

/// 强类型下载统计
class TorrentStats {
  final TorrentState state;
  final int peers;
  final double progress;
  final int downloadedBytes;
  final int uploadedBytes;
  final int totalBytes;
  final int contiguousBytes;
  final int bufferRequiredBytes;
  final bool readyToPlay;
  final double downloadSpeed;
  final double uploadSpeed;
  final String? errorMessage;

  const TorrentStats({
    this.state = TorrentState.idle,
    this.peers = 0,
    this.progress = 0.0,
    this.downloadedBytes = 0,
    this.uploadedBytes = 0,
    this.totalBytes = 0,
    this.contiguousBytes = 0,
    this.bufferRequiredBytes = 0,
    this.readyToPlay = false,
    this.downloadSpeed = 0.0,
    this.uploadSpeed = 0.0,
    this.errorMessage,
  });
}

/// Owns one download session. PieceManager is the source of download state.
class TorrentEngine {
  bool _disposed = false;
  Future<void>? _disposing;
  final _stopped = Completer<void>();
  final _buffered = Completer<void>();
  final _cancelToken = CancelToken();
  final _tracker = TrackerClient();
  final Set<MetadataPeerConnection> _metadataPeers = {};
  final Map<PeerAddress, PeerConnection> _peers = {};
  TorrentMetadata? _metadata;
  PieceManager? _pieceManager;
  final _streamServer = TorrentStreamServer();
  final _dio = NetworkService.createDio(
    BaseOptions(
      headers: {'User-Agent': 'Baka/1.0', 'Accept': 'application/x-bittorrent'},
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.bytes,
    ),
  );

  Timer? _announceTimer;
  ServerSocket? _peerServer;
  bool _isConnectingPeers = false;
  int _listenPort = TrackerClient.defaultListenPort;
  TorrentState _state = TorrentState.idle;
  String? _errorMessage;
  static const int _maxPeers = 30;

  int _lastSpeedBytes = 0;
  int _lastUploadBytes = 0;
  int _uploadedBytes = 0;
  final Stopwatch _speedClock = Stopwatch()..start();
  int _lastSpeedAtMs = 0;
  double _downloadSpeed = 0;
  double _uploadSpeed = 0;

  /// Completes when verified data is playable, or when the session stops.
  Future<String?> start(String url) async {
    _setState(TorrentState.resolving);
    try {
      _metadata = Uri.parse(url).scheme == 'magnet'
          ? await _resolveMagnetMetadata(MagnetLink.parse(url))
          : await _fetchTorrent(url);
      if (_disposed) return null;
      final meta = _metadata;
      if (meta == null) throw const FormatException('无法获取种子元数据');
      if (meta.trackers.isEmpty) {
        throw const FormatException('种子未提供 tracker，当前未实现 DHT');
      }
      final videoIndex = meta.findVideoFileIndex();
      if (videoIndex == null) throw const FormatException('种子中未找到视频文件');
      final pm = _pieceManager = PieceManager(
        metadata: meta,
        targetFileIndex: videoIndex,
      );
      pm.onPieceCompleted = (piece) {
        if (!_buffered.isCompleted && pm.isReadyToPlay) _buffered.complete();
        // A failed send can synchronously remove a disconnected peer.
        for (final peer in _peers.values.toList(growable: false)) {
          peer.announcePiece(piece);
        }
        if (pm.isComplete) _setState(TorrentState.seeding);
      };
      await _streamServer.start(pm);
      if (_disposed) {
        await _streamServer.stop();
        return null;
      }
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      if (_disposed) {
        await server.close();
        return null;
      }
      _peerServer = server;
      _listenPort = server.port;
      server.listen(
        (socket) {
          final address = PeerAddress(
            socket.remoteAddress.address,
            socket.remotePort,
          );
          if (_disposed ||
              _peers.length >= _maxPeers ||
              _peers.containsKey(address)) {
            socket.destroy();
            return;
          }
          final peer = _addPeer(address, pm);
          unawaited(
            peer.accept(socket).then((ok) {
              if (ok) _peerConnected();
            }),
          );
        },
        onError: (Object e) => debugPrint('[TorrentEngine] Peer listener: $e'),
      );
      _setState(TorrentState.connecting);
      unawaited(_connectToPeers(event: 'started'));
      await Future.any([_buffered.future, _stopped.future]);
      return _disposed ? null : _streamServer.streamUrl;
    } catch (e) {
      if (!_disposed) {
        _errorMessage = e.toString();
        _setState(TorrentState.error);
      }
      rethrow;
    }
  }

  Future<TorrentMetadata> _fetchTorrent(
    String url, {
    Iterable<String> trackers = const [],
  }) async {
    final response = await _dio.get<Uint8List>(url, cancelToken: _cancelToken);
    return TorrentMetadata.fromBytes(response.data!, trackers: trackers);
  }

  PeerConnection _addPeer(PeerAddress address, PieceManager pm) {
    final peer = PeerConnection(
      address: address,
      peerId: TrackerClient.peerId,
      pieceManager: pm,
      onUploaded: (bytes) => _uploadedBytes += bytes,
      onDisconnected: () {
        _peers.remove(address);
      },
    );
    _peers[address] = peer;
    return peer;
  }

  void _peerConnected() {
    if (_state == TorrentState.connecting) _setState(TorrentState.downloading);
  }

  Future<void> _connectToPeers({String? event}) async {
    if (_disposed || _isConnectingPeers) return;
    _isConnectingPeers = true;
    final meta = _metadata!;
    final pm = _pieceManager!;
    try {
      final announce = await _tracker.announce(
        infoHash: meta.infoHash,
        trackers: meta.trackers,
        downloaded: pm.torrentDownloadedBytes,
        left: meta.totalSize - pm.verifiedBytes,
        uploaded: _uploadedBytes,
        port: _listenPort,
        event: event,
      );
      if (_disposed) return;
      final candidates = announce.peers.iterator;
      Future<void> worker() async {
        while (!_disposed &&
            _peers.length < _maxPeers &&
            candidates.moveNext()) {
          final address = candidates.current;
          if (_peers.containsKey(address)) continue;
          final peer = _addPeer(address, pm);
          if (await peer.connect()) _peerConnected();
        }
      }

      await Future.wait([
        for (var i = 0; i < min(8, announce.peers.length); i++) worker(),
      ]);
      // Reannounce according to the tracker, without a second polling loop.
      final interval = announce.interval;
      if (!_disposed && interval != null) {
        _announceTimer = Timer(interval, () => unawaited(_connectToPeers()));
      }
    } finally {
      _isConnectingPeers = false;
    }
  }

  Future<TorrentMetadata?> _resolveMagnetMetadata(MagnetLink magnet) async {
    if (magnet.trackers.isEmpty && magnet.exactSources.isEmpty) {
      throw const FormatException('磁链未提供 tracker 或 xs，当前未实现 DHT');
    }
    final tracker = TrackerClient();
    final found = Completer<TorrentMetadata?>();
    Future<void> resolve(Future<TorrentMetadata?> task) async {
      final metadata = await task;
      if (metadata != null && !found.isCompleted) found.complete(metadata);
    }

    final tasks = [
      resolve(_fetchMetadataViaPeers(magnet, tracker)),
      if (magnet.exactSources.isNotEmpty)
        resolve(_fetchMetadataFromExactSources(magnet)),
    ];
    try {
      return await Future.any([
        found.future,
        // A last-finishing candidate may have already completed found.
        Future.wait(tasks).then((_) => found.isCompleted ? found.future : null),
        _stopped.future.then((_) => null),
      ]);
    } finally {
      _cancelToken.cancel();
      tracker.dispose();
      for (final peer in _metadataPeers) {
        peer.disconnect();
      }
    }
  }

  Future<TorrentMetadata?> _fetchMetadataViaPeers(
    MagnetLink magnet,
    TrackerClient tracker,
  ) async {
    final hash = magnet.infoHashBytes;
    final announce = await tracker.announce(
      infoHash: hash,
      trackers: magnet.trackers,
      left: 1,
      event: 'started',
    );
    if (_disposed || _cancelToken.isCancelled) return null;
    final peers = announce.peers;
    final found = Completer<TorrentMetadata?>();
    var next = 0;
    Future<void> worker() async {
      while (!_disposed &&
          !_cancelToken.isCancelled &&
          !found.isCompleted &&
          next < min(peers.length, 24)) {
        final peer = MetadataPeerConnection(
          address: peers[next++],
          infoHash: hash,
          peerId: TrackerClient.peerId,
        );
        _metadataPeers.add(peer);
        try {
          final bytes = await peer.fetch();
          if (bytes == null || found.isCompleted) continue;
          final metadata = TorrentMetadata.fromInfoBytes(
            bytes,
            trackers: magnet.trackers,
          );
          if (metadata.infoHashHex == magnet.infoHash) found.complete(metadata);
        } catch (e) {
          // Try the next peer when this peer's metadata is invalid.
          debugPrint('[TorrentEngine] Metadata: $e');
        } finally {
          _metadataPeers.remove(peer);
          peer.disconnect();
        }
      }
    }

    return Future.any([
      found.future,
      Future.wait([
        for (var i = 0; i < min(peers.length, 6); i++) worker(),
      ]).then((_) => found.isCompleted ? found.future : null),
      _stopped.future.then((_) => null),
    ]);
  }

  Future<TorrentMetadata?> _fetchMetadataFromExactSources(
    MagnetLink magnet,
  ) async {
    for (final url in magnet.exactSources) {
      if (_disposed || _cancelToken.isCancelled) break;
      try {
        final metadata = await _fetchTorrent(url, trackers: magnet.trackers);
        if (metadata.infoHashHex == magnet.infoHash) return metadata;
      } catch (e) {
        if (!_cancelToken.isCancelled) debugPrint('[TorrentEngine] $url: $e');
      }
    }
    return null;
  }

  void _setState(TorrentState state) {
    if (_disposed || _state == state) return;
    _state = state;
  }

  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _stopped.complete();
    _cancelToken.cancel();
    _dio.close(force: true);
    _announceTimer?.cancel();
    for (final peer in _metadataPeers) {
      peer.disconnect();
    }
    while (_peers.isNotEmpty) {
      _peers.values.first.disconnect();
    }
    final meta = _metadata;
    final pm = _pieceManager;
    if (meta == null || pm == null) {
      _tracker.dispose();
    } else {
      // Bound this network cleanup; playback switches wait only for local resources.
      final deadline = Timer(const Duration(seconds: 2), _tracker.dispose);
      unawaited(
        _tracker
            .announce(
              infoHash: meta.infoHash,
              trackers: meta.trackers,
              left: meta.totalSize - pm.verifiedBytes,
              downloaded: pm.torrentDownloadedBytes,
              uploaded: _uploadedBytes,
              port: _listenPort,
              event: 'stopped',
            )
            .whenComplete(() {
              deadline.cancel();
              _tracker.dispose();
            }),
      );
    }
    await _peerServer?.close();
    await _streamServer.stop();
    pm?.dispose();
    _pieceManager = null;
    _metadata = null;
  }

  TorrentStats getStats() {
    final pm = _pieceManager;
    final now = _speedClock.elapsedMilliseconds;
    final elapsed = now - _lastSpeedAtMs;
    if (elapsed >= 1000) {
      final downloaded = pm?.torrentDownloadedBytes ?? 0;
      _downloadSpeed = (downloaded - _lastSpeedBytes) * 1000 / elapsed;
      _uploadSpeed = (_uploadedBytes - _lastUploadBytes) * 1000 / elapsed;
      _lastSpeedBytes = downloaded;
      _lastUploadBytes = _uploadedBytes;
      _lastSpeedAtMs = now;
    }
    return TorrentStats(
      state: _state,
      peers: _peers.values.where((p) => p.isConnected).length,
      progress: pm?.progress ?? 0,
      downloadedBytes: pm?.downloadedBytes ?? 0,
      uploadedBytes: _uploadedBytes,
      totalBytes: pm?.targetFile.length ?? 0,
      contiguousBytes: pm?.contiguousBytes ?? 0,
      bufferRequiredBytes: pm?.bufferRequiredBytes ?? 0,
      readyToPlay: pm?.isReadyToPlay ?? false,
      downloadSpeed: _downloadSpeed,
      uploadSpeed: _uploadSpeed,
      errorMessage: _errorMessage,
    );
  }
}
