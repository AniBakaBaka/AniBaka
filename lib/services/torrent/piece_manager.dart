import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:baka/services/torrent/torrent_model.dart';

/// 待请求的 block 描述
class BlockRequest {
  final int pieceIndex;
  final int begin;
  final int length;
  const BlockRequest(this.pieceIndex, this.begin, this.length);
}

/// 分片状态
enum PieceState { pending, downloading, completed }

/// 分片管理器 — 顺序下载优先，管理已下载数据
class PieceManager {
  final TorrentMetadata metadata;
  final int targetFileIndex;

  static const int blockSize = 16384; // 16 KB
  static const int maxPeerRequestSize = 128 * 1024;
  static const Duration _requestTimeout = Duration(seconds: 8);
  static const int _bufferTarget = 2 * 1024 * 1024; // 2 MB

  /// 每个分片的状态
  late final List<PieceState> _pieceStates;

  /// 每个分片中已下载的 block 数据 (begin offset → data)
  late final List<Map<int, Uint8List>> _pieceBlocks;

  /// 每个分片中已发出的 block 请求，避免多个 peer 重复请求同一段。
  late final List<Map<int, DateTime>> _requestedBlocks;

  /// 已完成且校验通过的分片数据
  final Map<int, Uint8List> _completedPieces = {};

  /// 目标文件覆盖的分片范围
  late final int _firstPiece;
  late final int _lastPiece;
  late final int _firstPieceOffset;

  int _downloadedBytes = 0;
  int _torrentDownloadedBytes = 0;

  /// 进度信号：每收到一个 block 后触发，stream_server 用于事件驱动等待。
  Completer<void> _nextEvent = Completer<void>();

  /// 进度回调
  void Function(int downloadedBytes, int totalBytes)? onProgress;

  /// 分片完成且校验通过时触发，用于向 peer 发送 have。
  void Function(int pieceIndex, Uint8List data)? onPieceCompleted;

  PieceManager({required this.metadata, required this.targetFileIndex}) {
    final file = metadata.files[targetFileIndex];
    _firstPiece = file.offset ~/ metadata.pieceLength;
    _lastPiece = (file.end - 1) ~/ metadata.pieceLength;
    _firstPieceOffset = file.offset % metadata.pieceLength;

    final totalPieces = metadata.pieceCount;
    _pieceStates = List.filled(totalPieces, PieceState.pending);
    _pieceBlocks = List.generate(totalPieces, (_) => <int, Uint8List>{});
    _requestedBlocks = List.generate(totalPieces, (_) => <int, DateTime>{});
  }

  TorrentFile get targetFile => metadata.files[targetFileIndex];

  /// 暴露分片范围和状态（供 UI 方格图使用）
  int get firstPiece => _firstPiece;
  int get lastPiece => _lastPiece;
  List<PieceState> get pieceStates => _pieceStates;

  int get downloadedBytes => _downloadedBytes;
  int get torrentDownloadedBytes => _torrentDownloadedBytes;

  int get bufferRequiredBytes => math.min(_bufferTarget, targetFile.length);

  bool get isReadyToPlay => contiguousBytes >= bufferRequiredBytes;

  /// 下载进度（0.0 ~ 1.0）— 基于已收字节数。
  double get progress => targetFile.length == 0
      ? 1.0
      : (_downloadedBytes / targetFile.length).clamp(0.0, 1.0);

  /// 目标视频是否已全部完成。
  bool get isTargetComplete {
    for (var i = _firstPiece; i <= _lastPiece; i++) {
      if (_pieceStates[i] != PieceState.completed) return false;
    }
    return true;
  }

  /// 整个 torrent 是否已全部完成，完成后才算真正进入做种。
  bool get isComplete {
    for (final state in _pieceStates) {
      if (state != PieceState.completed) return false;
    }
    return true;
  }

  Iterable<int> get completedPieceIndices => _completedPieces.keys;

  bool hasPiece(int pieceIndex) => _completedPieces.containsKey(pieceIndex);

  /// 文件开头连续已下载字节数（用于判断是否可以开始播放）
  int get contiguousBytes {
    var bytes = 0;
    for (var i = _firstPiece; i <= _lastPiece; i++) {
      if (_pieceStates[i] != PieceState.completed) break;
      bytes +=
          metadata.pieceSize(i) - (i == _firstPiece ? _firstPieceOffset : 0);
    }
    return math.min(bytes, targetFile.length);
  }

  /// 下一次进度事件（每收到一个 block 后完成并旋转为新 Completer）。
  Future<void> get nextProgress => _nextEvent.future;

  /// 顺序优先策略选取下一个待请求 block。
  BlockRequest? nextBlock({required Set<int> availablePieces}) {
    final now = DateTime.now();
    final startPiece = isTargetComplete ? 0 : _firstPiece;
    final endPiece = isTargetComplete ? metadata.pieceCount - 1 : _lastPiece;

    for (var i = startPiece; i <= endPiece; i++) {
      if (_pieceStates[i] == PieceState.completed) continue;
      if (!availablePieces.contains(i)) continue;

      final pieceSize = metadata.pieceSize(i);
      final blocks = _pieceBlocks[i];
      final requested = _requestedBlocks[i];

      for (var offset = 0; offset < pieceSize; offset += blockSize) {
        if (blocks.containsKey(offset)) continue;
        final at = requested[offset];
        if (at != null && now.difference(at) < _requestTimeout) continue;

        final len = math.min(blockSize, pieceSize - offset);
        _pieceStates[i] = PieceState.downloading;
        requested[offset] = now;
        return BlockRequest(i, offset, len);
      }
    }
    return null;
  }

  /// 取消一个尚未收到的 block 请求，使其他 peer 可以立即接手。
  void cancelBlockRequest(int pieceIndex, int begin) {
    if (pieceIndex < 0 || pieceIndex >= metadata.pieceCount || begin < 0) {
      return;
    }
    _requestedBlocks[pieceIndex].remove(begin);
  }

  /// 收到一个 block 数据
  void onBlockReceived(int pieceIndex, int begin, Uint8List data) {
    if (pieceIndex < 0 || pieceIndex >= metadata.pieceCount) return;
    if (begin < 0) return;
    if (_pieceStates[pieceIndex] == PieceState.completed) return;

    final pieceSize = metadata.pieceSize(pieceIndex);
    if (data.isEmpty || begin + data.length > pieceSize) return;

    final blocks = _pieceBlocks[pieceIndex];
    _requestedBlocks[pieceIndex].remove(begin);
    if (blocks.containsKey(begin)) return; // 已有同一 block，丢弃重复包

    blocks[begin] = data;
    _downloadedBytes += _targetOverlapBytes(pieceIndex, begin, data.length);
    _torrentDownloadedBytes += data.length;

    if (_blockBytes(blocks) >= pieceSize) {
      final assembled = _assemblePiece(pieceIndex, pieceSize);
      if (_verifyPiece(pieceIndex, assembled)) {
        _pieceStates[pieceIndex] = PieceState.completed;
        _completedPieces[pieceIndex] = assembled;
        blocks.clear();
        _requestedBlocks[pieceIndex].clear();
        onPieceCompleted?.call(pieceIndex, assembled);
      } else {
        for (final entry in blocks.entries) {
          _downloadedBytes -= _targetOverlapBytes(
            pieceIndex,
            entry.key,
            entry.value.length,
          );
          _torrentDownloadedBytes -= entry.value.length;
        }
        blocks.clear();
        _requestedBlocks[pieceIndex].clear();
        _pieceStates[pieceIndex] = PieceState.pending;
      }
    }

    onProgress?.call(_downloadedBytes, metadata.totalSize);
    _signalProgress();
  }

  void _signalProgress() {
    final c = _nextEvent;
    _nextEvent = Completer<void>();
    if (!c.isCompleted) c.complete();
  }

  static int _blockBytes(Map<int, Uint8List> blocks) {
    var total = 0;
    for (final v in blocks.values) {
      total += v.length;
    }
    return total;
  }

  int _targetOverlapBytes(int pieceIndex, int begin, int length) {
    final blockStart = pieceIndex * metadata.pieceLength + begin;
    final blockEnd = blockStart + length;
    final overlapStart = math.max(blockStart, targetFile.offset);
    final overlapEnd = math.min(blockEnd, targetFile.end);
    return math.max(0, overlapEnd - overlapStart);
  }

  Uint8List _assemblePiece(int pieceIndex, int pieceSize) {
    final result = Uint8List(pieceSize);
    final blocks = _pieceBlocks[pieceIndex];
    for (final entry in blocks.entries) {
      result.setRange(entry.key, entry.key + entry.value.length, entry.value);
    }
    return result;
  }

  bool _verifyPiece(int pieceIndex, Uint8List data) {
    final expected = metadata.pieceHash(pieceIndex);
    final actual = sha1.convert(data).bytes;
    for (var i = 0; i < 20; i++) {
      if (expected[i] != actual[i]) return false;
    }
    return true;
  }

  /// 从指定文件偏移量读取数据（用于流媒体服务器）。
  /// 当请求范围内任一分片尚未就绪时返回 null。
  Uint8List? readFileData(int fileOffset, int length) {
    final globalStart = targetFile.offset + fileOffset;
    final globalEnd = globalStart + length;

    final result = Uint8List(length);
    var pos = globalStart;
    var written = 0;
    while (pos < globalEnd) {
      final pieceData = _completedPieces[pos ~/ metadata.pieceLength];
      if (pieceData == null) return null;

      final pieceOffset = pos % metadata.pieceLength;
      final copyLen = math.min(pieceData.length - pieceOffset, globalEnd - pos);
      result.setRange(written, written + copyLen, pieceData, pieceOffset);
      written += copyLen;
      pos += copyLen;
    }
    return result;
  }

  /// 读取完整分片中的一段数据，用于响应 peer 的 request 消息。
  Uint8List? readPieceBlock(int pieceIndex, int begin, int length) {
    if (pieceIndex < 0 || pieceIndex >= metadata.pieceCount) return null;
    if (begin < 0 || length <= 0 || length > maxPeerRequestSize) return null;

    final pieceData = _completedPieces[pieceIndex];
    if (pieceData == null || begin + length > pieceData.length) return null;

    return Uint8List.sublistView(pieceData, begin, begin + length);
  }
}
