import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:baka/services/torrent/torrent_model.dart';

class BlockRequest {
  const BlockRequest(this.pieceIndex, this.begin, this.length);

  final int pieceIndex;
  final int begin;
  final int length;
}

enum PieceState { pending, downloading, completed }

/// Downloads only the selected media file and stores verified pieces on disk.
/// In-flight block maps are sparse, so idle torrent pieces allocate no maps.
class PieceManager {
  PieceManager({required this.metadata, required this.targetFileIndex}) {
    final file = metadata.files[targetFileIndex];
    _firstPiece = file.offset ~/ metadata.pieceLength;
    _lastPiece = (file.end - 1) ~/ metadata.pieceLength;
    _firstPieceOffset = file.offset % metadata.pieceLength;
    _pieceStates = List<PieceState>.filled(
      _lastPiece - _firstPiece + 1,
      PieceState.pending,
    );
    _pieceStatesView = UnmodifiableListView(_pieceStates);
    _remainingPieces = _pieceStates.length;
    _firstIncompletePiece = _firstPiece;
    _cacheFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'anibaka-${metadata.infoHashHex}-$targetFileIndex.part',
    );
    _cache = _cacheFile.openSync(mode: FileMode.write);
  }

  static const int blockSize = 16 * 1024;
  static const int maxPeerRequestSize = 128 * 1024;
  static const int _requestTimeoutMs = 8000;
  static const int _bufferTarget = 2 * 1024 * 1024;

  final TorrentMetadata metadata;
  final int targetFileIndex;
  late final int _firstPiece;
  late final int _lastPiece;
  late final int _firstPieceOffset;
  late final List<PieceState> _pieceStates;
  late final List<PieceState> _pieceStatesView;
  late final File _cacheFile;
  late final RandomAccessFile _cache;

  final Map<int, Map<int, Uint8List>> _pieceBlocks = {};
  final Map<int, Map<int, int>> _requestedBlocks = {};
  final Stopwatch _requestClock = Stopwatch()..start();
  late int _remainingPieces;
  late int _firstIncompletePiece;
  int _contiguousBytes = 0;
  int _downloadedBytes = 0;
  int _torrentDownloadedBytes = 0;
  Completer<void> _nextEvent = Completer<void>();
  bool _disposed = false;

  void Function(int downloadedBytes, int totalBytes)? onProgress;
  void Function(int pieceIndex)? onPieceCompleted;

  TorrentFile get targetFile => metadata.files[targetFileIndex];
  int get firstPiece => _firstPiece;
  int get lastPiece => _lastPiece;
  List<PieceState> get pieceStates => _pieceStatesView;
  int get downloadedBytes => _downloadedBytes;
  int get torrentDownloadedBytes => _torrentDownloadedBytes;
  int get bufferRequiredBytes => math.min(_bufferTarget, targetFile.length);
  bool get isReadyToPlay => contiguousBytes >= bufferRequiredBytes;
  double get progress => targetFile.length == 0
      ? 1
      : (_downloadedBytes / targetFile.length).clamp(0, 1);

  bool get isTargetComplete => _remainingPieces == 0;

  bool get isComplete => isTargetComplete;

  Iterable<int> get completedPieceIndices sync* {
    for (var i = _firstPiece; i <= _lastPiece; i++) {
      if (_stateOf(i) == PieceState.completed) yield i;
    }
  }

  bool hasPiece(int pieceIndex) =>
      pieceIndex >= _firstPiece &&
      pieceIndex <= _lastPiece &&
      _stateOf(pieceIndex) == PieceState.completed;

  int get contiguousBytes => _contiguousBytes;

  Future<void> get nextProgress => _nextEvent.future;

  BlockRequest? nextBlock({
    required bool Function(int pieceIndex) peerHasPiece,
  }) {
    if (_disposed || isTargetComplete) return null;
    final now = _requestClock.elapsedMilliseconds;
    for (var piece = _firstIncompletePiece; piece <= _lastPiece; piece++) {
      if (_stateOf(piece) == PieceState.completed || !peerHasPiece(piece)) {
        continue;
      }
      final blocks = _pieceBlocks[piece];
      final requested = _requestedBlocks[piece];
      final pieceSize = metadata.pieceSize(piece);
      for (var offset = 0; offset < pieceSize; offset += blockSize) {
        if (blocks?.containsKey(offset) == true) continue;
        final requestedAt = requested?[offset];
        if (requestedAt != null && now - requestedAt < _requestTimeoutMs) {
          continue;
        }
        _setState(piece, PieceState.downloading);
        (_requestedBlocks[piece] ??= {})[offset] = now;
        return BlockRequest(
          piece,
          offset,
          math.min(blockSize, pieceSize - offset),
        );
      }
    }
    return null;
  }

  void cancelBlockRequest(int pieceIndex, int begin) {
    _requestedBlocks[pieceIndex]?.remove(begin);
  }

  void onBlockReceived(int pieceIndex, int begin, Uint8List data) {
    if (_disposed ||
        pieceIndex < _firstPiece ||
        pieceIndex > _lastPiece ||
        begin < 0 ||
        _stateOf(pieceIndex) == PieceState.completed) {
      return;
    }
    final pieceSize = metadata.pieceSize(pieceIndex);
    if (data.isEmpty || begin + data.length > pieceSize) return;

    final blocks = _pieceBlocks[pieceIndex] ??= {};
    _requestedBlocks[pieceIndex]?.remove(begin);
    if (blocks.containsKey(begin)) return;
    blocks[begin] = data;
    _downloadedBytes += _targetOverlapBytes(pieceIndex, begin, data.length);
    _torrentDownloadedBytes += data.length;

    if (_blockBytes(blocks) >= pieceSize) {
      final assembled = _assemblePiece(blocks, pieceSize);
      if (_verifyPiece(pieceIndex, assembled)) {
        _cache
          ..setPositionSync(pieceIndex * metadata.pieceLength)
          ..writeFromSync(assembled);
        _setState(pieceIndex, PieceState.completed);
        _remainingPieces--;
        _advanceContiguousPrefix();
        _pieceBlocks.remove(pieceIndex);
        _requestedBlocks.remove(pieceIndex);
        onPieceCompleted?.call(pieceIndex);
      } else {
        for (final entry in blocks.entries) {
          _downloadedBytes -= _targetOverlapBytes(
            pieceIndex,
            entry.key,
            entry.value.length,
          );
          _torrentDownloadedBytes -= entry.value.length;
        }
        _pieceBlocks.remove(pieceIndex);
        _requestedBlocks.remove(pieceIndex);
        _setState(pieceIndex, PieceState.pending);
      }
    }

    onProgress?.call(_downloadedBytes, targetFile.length);
    _signalProgress();
  }

  Uint8List? readFileData(int fileOffset, int length) {
    if (_disposed ||
        fileOffset < 0 ||
        length <= 0 ||
        fileOffset + length > targetFile.length) {
      return null;
    }
    final globalStart = targetFile.offset + fileOffset;
    final globalEnd = globalStart + length;
    final first = globalStart ~/ metadata.pieceLength;
    final last = (globalEnd - 1) ~/ metadata.pieceLength;
    for (var piece = first; piece <= last; piece++) {
      if (!hasPiece(piece)) return null;
    }
    _cache.setPositionSync(globalStart);
    final bytes = _cache.readSync(length);
    return bytes.length == length ? bytes : null;
  }

  Uint8List? readPieceBlock(int pieceIndex, int begin, int length) {
    if (_disposed ||
        !hasPiece(pieceIndex) ||
        begin < 0 ||
        length <= 0 ||
        length > maxPeerRequestSize ||
        begin + length > metadata.pieceSize(pieceIndex)) {
      return null;
    }
    _cache.setPositionSync(pieceIndex * metadata.pieceLength + begin);
    final bytes = _cache.readSync(length);
    return bytes.length == length ? bytes : null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _signalProgress();
    _pieceBlocks.clear();
    _requestedBlocks.clear();
    _cache.closeSync();
    if (_cacheFile.existsSync()) _cacheFile.deleteSync();
  }

  void _signalProgress() {
    final event = _nextEvent;
    _nextEvent = Completer<void>();
    if (!event.isCompleted) event.complete();
  }

  PieceState _stateOf(int pieceIndex) => _pieceStates[pieceIndex - _firstPiece];

  void _setState(int pieceIndex, PieceState state) {
    _pieceStates[pieceIndex - _firstPiece] = state;
  }

  void _advanceContiguousPrefix() {
    while (_firstIncompletePiece <= _lastPiece &&
        _stateOf(_firstIncompletePiece) == PieceState.completed) {
      _contiguousBytes +=
          metadata.pieceSize(_firstIncompletePiece) -
          (_firstIncompletePiece == _firstPiece ? _firstPieceOffset : 0);
      _firstIncompletePiece++;
    }
    if (_contiguousBytes > targetFile.length) {
      _contiguousBytes = targetFile.length;
    }
  }

  static int _blockBytes(Map<int, Uint8List> blocks) {
    var total = 0;
    for (final block in blocks.values) {
      total += block.length;
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

  static Uint8List _assemblePiece(Map<int, Uint8List> blocks, int pieceSize) {
    final result = Uint8List(pieceSize);
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
}
