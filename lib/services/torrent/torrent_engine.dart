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
  final int torrentTotalBytes;
  final int contiguousBytes;
  final int bufferRequiredBytes;
  final bool readyToPlay;
  final String? targetFileName;
  final String? streamUrl;
  final double downloadSpeed;
  final double uploadSpeed;

  const TorrentStats({
    this.state = TorrentState.idle,
    this.peers = 0,
    this.progress = 0.0,
    this.downloadedBytes = 0,
    this.uploadedBytes = 0,
    this.totalBytes = 0,
    this.torrentTotalBytes = 0,
    this.contiguousBytes = 0,
    this.bufferRequiredBytes = 0,
    this.readyToPlay = false,
    this.targetFileName,
    this.streamUrl,
    this.downloadSpeed = 0.0,
    this.uploadSpeed = 0.0,
  });
}

/// Torrent 引擎 — 编排 tracker、peer、piece 管理和流媒体服务器
class TorrentEngine {
  TorrentMetadata? _metadata;
  PieceManager? _pieceManager;
  final TorrentStreamServer _streamServer = TorrentStreamServer();
  final List<PeerConnection> _peers = [];
  final Dio _dio = Dio(
    BaseOptions(
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/122.0 Safari/537.36',
        'Accept': 'application/x-bittorrent,*/*',
      },
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.bytes,
    ),
  );

  Timer? _announceTimer;
  Timer? _peerCheckTimer;
  ServerSocket? _peerServer;
  bool _isConnectingPeers = false;
  bool _completedAnnounced = false;
  int _listenPort = TrackerClient.defaultListenPort;

  TorrentState _state = TorrentState.idle;
  TorrentState get state => _state;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  TorrentMetadata? get metadata => _metadata;
  PieceManager? get pieceManager => _pieceManager;
  TorrentStreamServer get streamServer => _streamServer;

  /// 进度回调
  void Function(double progress, int downloadedBytes, int totalBytes)?
  onProgress;

  /// 状态变化回调
  void Function(TorrentState state)? onStateChanged;

  /// 缓冲就绪回调（可以开始播放）
  void Function(String streamUrl)? onReadyToPlay;

  bool _readyNotified = false;
  static const int _minBufferBytes = 2 * 1024 * 1024; // 2MB 最小缓冲
  static const int _maxPeers = 30;

  // 速度追踪
  int _lastSpeedBytes = 0;
  int _lastUploadBytes = 0;
  int _uploadedBytes = 0;
  DateTime _lastSpeedTime = DateTime.now();
  double _downloadSpeed = 0;
  double _uploadSpeed = 0;

  /// 从 .torrent 文件 URL 开始下载
  Future<String?> startFromTorrentUrl(String torrentUrl) async {
    _setState(TorrentState.resolving);
    try {
      final response = await _dio.get<List<int>>(torrentUrl);
      if (response.data == null) {
        _setError('下载 .torrent 文件失败');
        return null;
      }
      final bytes = Uint8List.fromList(response.data!);
      _metadata = TorrentMetadata.fromBytes(bytes);
      return await _startDownload();
    } catch (e) {
      _setError('解析 torrent 失败: $e');
      return null;
    }
  }

  /// 从 magnet 链接开始下载
  Future<String?> startFromMagnet(String magnetUri) async {
    _setState(TorrentState.resolving);
    try {
      final magnet = MagnetLink.parse(magnetUri);

      _metadata = await _resolveMagnetMetadata(magnet);
      if (_metadata == null) {
        _setError('无法通过 BEP 9 或公开缓存获取种子元数据');
        return null;
      }

      return await _startDownload();
    } catch (e) {
      _setError('Magnet 解析失败: $e');
      return null;
    }
  }

  Future<TorrentMetadata?> _resolveMagnetMetadata(MagnetLink magnet) async {
    final completer = Completer<TorrentMetadata?>();
    final tasks = <Future<TorrentMetadata?>>[
      _fetchMetadataViaPeers(magnet),
      _fetchMetadataFromCache(magnet),
      if (magnet.exactSources.isNotEmpty)
        _fetchMetadataFromExactSources(magnet),
    ];
    var remaining = tasks.length;

    void complete(TorrentMetadata? metadata) {
      if (metadata != null && !completer.isCompleted) {
        completer.complete(metadata);
        return;
      }
      remaining--;
      if (remaining == 0 && !completer.isCompleted) {
        completer.complete(null);
      }
    }

    for (final task in tasks) {
      unawaited(
        task.then(complete).catchError((_) {
          complete(null);
        }),
      );
    }

    return completer.future;
  }

  Future<String?> _startDownload() async {
    final meta = _metadata!;
    debugPrint('[TorrentEngine] 开始下载: ${meta.name}');
    debugPrint(
      '[TorrentEngine] 文件数: ${meta.files.length}, '
      '总大小: ${(meta.totalSize / 1024 / 1024).toStringAsFixed(1)}MB',
    );

    // 找到视频文件
    final videoIndex = meta.findVideoFileIndex();
    if (videoIndex == null) {
      _setError('种子中未找到视频文件');
      return null;
    }

    debugPrint('[TorrentEngine] 目标视频: ${meta.files[videoIndex]}');

    // 初始化 piece 管理器
    _pieceManager = PieceManager(metadata: meta, targetFileIndex: videoIndex);

    _pieceManager!.onProgress = (downloaded, total) {
      final targetSize = _pieceManager!.targetFile.length;
      final progress = targetSize > 0 ? downloaded / targetSize : 0.0;
      onProgress?.call(progress, downloaded, targetSize);

      // 检查是否可以开始播放
      if (!_readyNotified && _pieceManager!.isReadyToPlay) {
        _readyNotified = true;
        onReadyToPlay?.call(_streamServer.streamUrl);
      }
    };
    _pieceManager!.onPieceCompleted = (pieceIndex, _) {
      for (final peer in _peers) {
        peer.announcePiece(pieceIndex);
      }
      if (_pieceManager?.isComplete == true) {
        _setState(TorrentState.seeding);
        _announceCompleted();
      }
    };

    // 启动流媒体服务器
    await _streamServer.start(_pieceManager!);
    await _startPeerListener(meta, _pieceManager!);

    // 开始连接 peer 下载
    _setState(TorrentState.connecting);
    final peerCount = await _connectToPeers();
    if (peerCount == 0) {
      await _streamServer.stop();
      await _peerServer?.close();
      _peerServer = null;
      _setError('无法找到可用的 peer');
      return null;
    }

    // 定期重新 announce
    _announceTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _connectToPeers(),
    );

    // 定期检查 peer 连接状态
    _peerCheckTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkPeers(),
    );

    _setState(
      _pieceManager?.isComplete == true
          ? TorrentState.seeding
          : TorrentState.downloading,
    );
    return _streamServer.streamUrl;
  }

  Future<int> _connectToPeers({String? event}) async {
    final meta = _metadata;
    if (meta == null) return 0;
    final pm = _pieceManager;
    if (pm == null || _isConnectingPeers) return 0;

    _isConnectingPeers = true;
    try {
      final peers = await TrackerClient.announceMetadata(
        metadata: meta,
        downloaded: pm.torrentDownloadedBytes,
        uploaded: _totalUploadedBytes(),
        port: _listenPort,
        event: event,
      );
      debugPrint('[TorrentEngine] 从 tracker 获取到 ${peers.length} 个 peer');

      final freeSlots = _maxPeers - _peers.length;
      if (freeSlots <= 0) return 0;

      final candidates = peers
          .where((addr) => !_peers.any((peer) => peer.address == addr))
          .take(freeSlots)
          .toList(growable: false);
      if (candidates.isEmpty) return 0;

      final results = await Future.wait(
        candidates.map((addr) async {
          final peer = PeerConnection(
            address: addr,
            infoHash: meta.infoHash,
            peerId: TrackerClient.peerId,
            pieceManager: pm,
            onUploaded: _recordUploaded,
          );

          final connected = await peer.connect();
          if (!connected ||
              _metadata != meta ||
              _pieceManager != pm ||
              _peers.length >= _maxPeers ||
              _peers.any((item) => item.address == addr)) {
            peer.disconnect();
            return false;
          }

          _peers.add(peer);
          peer.fillRequestPipeline();
          return true;
        }),
      );
      return results.where((connected) => connected).length;
    } catch (e) {
      debugPrint('[TorrentEngine] Tracker announce 失败: $e');
      return 0;
    } finally {
      _isConnectingPeers = false;
    }
  }

  Future<void> _startPeerListener(
    TorrentMetadata metadata,
    PieceManager pieceManager,
  ) async {
    await _peerServer?.close();
    _peerServer = null;
    _listenPort = TrackerClient.defaultListenPort;

    for (final port in const [TrackerClient.defaultListenPort, 0]) {
      try {
        final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        _peerServer = server;
        _listenPort = server.port;
        server.listen(
          (socket) =>
              unawaited(_acceptIncomingPeer(socket, metadata, pieceManager)),
          onError: (e) => debugPrint('[TorrentEngine] Peer 监听错误: $e'),
        );
        debugPrint('[TorrentEngine] Peer 监听端口: $_listenPort');
        return;
      } catch (e) {
        if (port != 0) {
          debugPrint('[TorrentEngine] 监听 $port 失败，尝试随机端口: $e');
        }
      }
    }
  }

  Future<void> _acceptIncomingPeer(
    Socket socket,
    TorrentMetadata metadata,
    PieceManager pieceManager,
  ) async {
    if (_peers.length >= _maxPeers || _metadata != metadata) {
      socket.destroy();
      return;
    }

    final addr = PeerAddress(socket.remoteAddress.address, socket.remotePort);
    final peer = PeerConnection(
      address: addr,
      infoHash: metadata.infoHash,
      peerId: TrackerClient.peerId,
      pieceManager: pieceManager,
      onUploaded: _recordUploaded,
    );
    final accepted = await peer.accept(socket);
    if (!accepted ||
        _metadata != metadata ||
        _pieceManager != pieceManager ||
        _peers.length >= _maxPeers) {
      peer.disconnect();
      return;
    }
    _peers.add(peer);
    peer.fillRequestPipeline();
  }

  void _checkPeers() {
    _peers.removeWhere((peer) {
      if (!peer.isConnected) {
        peer.disconnect();
        return true;
      }
      if (!peer.isChoked) peer.fillRequestPipeline();
      return false;
    });

    if (kDebugMode) {
      final pm = _pieceManager;
      if (pm != null) {
        final chokedCount = _peers.where((p) => p.isChoked).length;
        debugPrint(
          '[TorrentEngine] Peers: ${_peers.length} (已解锁:${_peers.length - chokedCount}, 被锁:$chokedCount), '
          '已下载: ${(pm.downloadedBytes / 1024).toStringAsFixed(0)}KB, '
          '进度: ${(pm.progress * 100).toStringAsFixed(1)}%, '
          '连续: ${(pm.contiguousBytes / 1024).toStringAsFixed(0)}KB',
        );
      }
    }

    if (_peers.length < 5) unawaited(_connectToPeers());
    if (_pieceManager?.isComplete == true) {
      _setState(TorrentState.seeding);
      _announceCompleted();
    }
  }

  void _announceCompleted() {
    if (_completedAnnounced) return;
    if (_isConnectingPeers) {
      Future.delayed(const Duration(seconds: 2), _announceCompleted);
      return;
    }
    _completedAnnounced = true;
    unawaited(_connectToPeers(event: 'completed'));
  }

  Future<void> _announceStopped() async {
    final meta = _metadata;
    final pm = _pieceManager;
    if (meta == null || pm == null) return;
    try {
      await TrackerClient.announceMetadata(
        metadata: meta,
        downloaded: pm.torrentDownloadedBytes,
        uploaded: _totalUploadedBytes(),
        port: _listenPort,
        event: 'stopped',
      );
    } catch (_) {}
  }

  Future<TorrentMetadata?> _fetchMetadataViaPeers(MagnetLink magnet) async {
    _setState(TorrentState.connecting);
    final peers = await TrackerClient.announceFromMagnet(
      magnet: magnet,
      port: _listenPort,
    );
    debugPrint('[TorrentEngine] BEP 9 metadata 候选 peer: ${peers.length}');
    if (peers.isEmpty) return null;

    final completer = Completer<TorrentMetadata?>();
    var remaining = 0;
    for (final addr in peers.take(24)) {
      remaining++;
      unawaited(() async {
        try {
          final infoBytes = await MetadataPeerConnection(
            address: addr,
            infoHash: magnet.infoHashBytes,
            peerId: TrackerClient.peerId,
          ).fetch();
          if (infoBytes != null && !completer.isCompleted) {
            final metadata = TorrentMetadata.fromInfoBytes(
              infoBytes,
              trackers: magnet.trackers,
            );
            if (metadata.infoHashHex == magnet.infoHash) {
              completer.complete(metadata);
              return;
            }
          }
        } catch (_) {
          // 单个 peer 失败时继续等待其他候选。
        }
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }());
    }

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => null,
    );
  }

  /// 尝试从公开缓存获取 metadata。
  Future<TorrentMetadata?> _fetchMetadataFromCache(MagnetLink magnet) async {
    final cacheUrls = [
      'https://itorrents.org/torrent/${magnet.infoHash.toUpperCase()}.torrent',
      'https://torrage.info/torrent.php?h=${magnet.infoHash.toUpperCase()}',
      'https://btcache.me/torrent/${magnet.infoHash.toUpperCase()}',
    ];

    for (final url in cacheUrls) {
      try {
        final response = await _dio.get<List<int>>(url);
        if (response.statusCode == 200 && response.data != null) {
          final metadata = TorrentMetadata.fromBytes(
            Uint8List.fromList(response.data!),
          );
          if (metadata.infoHashHex == magnet.infoHash) return metadata;
        }
      } catch (_) {
        continue;
      }
    }

    return null;
  }

  Future<TorrentMetadata?> _fetchMetadataFromExactSources(
    MagnetLink magnet,
  ) async {
    for (final url in magnet.exactSources) {
      try {
        final response = await _dio.get<List<int>>(url);
        if (response.statusCode != 200 || response.data == null) continue;
        final metadata = TorrentMetadata.fromBytes(
          Uint8List.fromList(response.data!),
        );
        if (metadata.infoHashHex == magnet.infoHash) return metadata;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  void _setState(TorrentState newState) {
    if (_state == newState) return;
    _state = newState;
    onStateChanged?.call(newState);
  }

  void _setError(String message) {
    _errorMessage = message;
    _setState(TorrentState.error);
    debugPrint('[TorrentEngine] 错误: $message');
  }

  /// 停止下载并清理资源
  Future<void> stop() async {
    final stoppedAnnounce = _announceStopped();
    _announceTimer?.cancel();
    _peerCheckTimer?.cancel();
    _announceTimer = null;
    _peerCheckTimer = null;
    await _peerServer?.close();
    _peerServer = null;
    _listenPort = TrackerClient.defaultListenPort;
    _isConnectingPeers = false;
    _completedAnnounced = false;

    for (final peer in _peers) {
      peer.disconnect();
    }
    _peers.clear();

    await _streamServer.stop();
    _pieceManager = null;
    _metadata = null;
    _readyNotified = false;
    _uploadedBytes = 0;
    _setState(TorrentState.idle);
    await stoppedAnnounce.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  /// 更新速度统计（从 getStats 中分离，消除 getter 副作用）
  void _updateSpeed() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastSpeedTime).inMilliseconds;
    if (elapsed < 1000) return;

    final currentBytes = _pieceManager?.torrentDownloadedBytes ?? 0;
    final totalUploaded = _totalUploadedBytes();
    final seconds = elapsed / 1000;
    _downloadSpeed = ((currentBytes - _lastSpeedBytes) / seconds).clamp(
      0.0,
      double.infinity,
    );
    _uploadSpeed = ((totalUploaded - _lastUploadBytes) / seconds).clamp(
      0.0,
      double.infinity,
    );
    _lastSpeedBytes = currentBytes;
    _lastUploadBytes = totalUploaded;
    _lastSpeedTime = now;
  }

  /// 获取当前下载统计（强类型）
  TorrentStats getStats() {
    _updateSpeed();

    final pm = _pieceManager;
    final targetFile = pm?.targetFile;

    return TorrentStats(
      state: _state,
      peers: _peers.length,
      progress: pm?.progress ?? 0.0,
      downloadedBytes: pm?.downloadedBytes ?? 0,
      uploadedBytes: _totalUploadedBytes(),
      totalBytes: targetFile?.length ?? 0,
      torrentTotalBytes: _metadata?.totalSize ?? 0,
      contiguousBytes: pm?.contiguousBytes ?? 0,
      bufferRequiredBytes:
          pm?.bufferRequiredBytes ??
          min(_minBufferBytes, targetFile?.length ?? _minBufferBytes),
      readyToPlay: pm?.isReadyToPlay ?? false,
      targetFileName: targetFile?.path,
      streamUrl: _streamServer.isRunning ? _streamServer.streamUrl : null,
      downloadSpeed: _downloadSpeed,
      uploadSpeed: _uploadSpeed,
    );
  }

  int _totalUploadedBytes() {
    return _uploadedBytes;
  }

  void _recordUploaded(int bytes) {
    if (bytes <= 0) return;
    _uploadedBytes += bytes;
  }
}
