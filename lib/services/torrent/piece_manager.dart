import 'dart:async';
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

/// Downloads only the selected media file and stores verified pieces on disk.
class PieceManager {
  PieceManager({required this.metadata, required this.targetFileIndex}) {
    final file = metadata.files[targetFileIndex];
    _firstPiece = file.offset ~/ metadata.pieceLength;
    _lastPiece = (file.end - 1) ~/ metadata.pieceLength;
    _firstPieceOffset = file.offset % metadata.pieceLength;
    _bitmapOffset = _firstPiece ~/ 8;
    _requestable = Uint8List(_lastPiece ~/ 8 - _bitmapOffset + 1);
    _completed = Uint8List(_requestable.length);
    for (var piece = _firstPiece; piece <= _lastPiece; piece++) {
      _requestable[piece ~/ 8 - _bitmapOffset] |= 0x80 >> (piece % 8);
    }
    _remainingPieces = _lastPiece - _firstPiece + 1;
    _firstIncompletePiece = _firstPiece;
    _cacheFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'anibaka-${metadata.infoHashHex}-$targetFileIndex.part',
    );
    _cache = _cacheFile.openSync(mode: FileMode.write);
  }

  static const int blockSize = 16 * 1024;
  static const int maxPeerRequestSize = 128 * 1024;
  static const int _bufferTarget = 2 * 1024 * 1024;

  final TorrentMetadata metadata;
  final int targetFileIndex;
  late final int _firstPiece;
  late final int _lastPiece;
  late final int _firstPieceOffset;
  late final int _bitmapOffset;
  late final Uint8List _requestable;
  late final Uint8List _completed;
  int _firstRequestableByte = 0;
  late final File _cacheFile;
  late final RandomAccessFile _cache;

  final Map<int, _PieceDownload> _downloads = {};
  late int _remainingPieces;
  late int _firstIncompletePiece;
  int _contiguousBytes = 0;
  int _downloadedBytes = 0;
  int _torrentDownloadedBytes = 0;
  int _verifiedBytes = 0;
  Completer<void> _nextEvent = Completer<void>();
  bool _disposed = false;

  void Function(int pieceIndex)? onPieceCompleted;

  TorrentFile get targetFile => metadata.files[targetFileIndex];
  int get downloadedBytes => _downloadedBytes;
  int get torrentDownloadedBytes => _torrentDownloadedBytes;
  int get verifiedBytes => _verifiedBytes;
  int get bufferRequiredBytes => math.min(_bufferTarget, targetFile.length);
  bool get isReadyToPlay => contiguousBytes >= bufferRequiredBytes;
  double get progress => targetFile.length == 0
      ? 1
      : (_downloadedBytes / targetFile.length).clamp(0, 1);

  bool get isComplete => _remainingPieces == 0;
  bool get isDisposed => _disposed;

  Iterable<int> get completedPieceIndices sync* {
    for (var i = _firstPiece; i <= _lastPiece; i++) {
      if (hasPiece(i)) yield i;
    }
  }

  bool hasPiece(int pieceIndex) =>
      pieceIndex >= _firstPiece &&
      pieceIndex <= _lastPiece &&
      _completed[pieceIndex ~/ 8 - _bitmapOffset] &
              (0x80 >> (pieceIndex % 8)) !=
          0;

  int get contiguousBytes => _contiguousBytes;

  Future<void> get nextProgress => _nextEvent.future;

  BlockRequest? nextBlock(Uint8List peerBitfield) {
    if (_disposed || isComplete) return null;
    for (var i = _firstRequestableByte; i < _requestable.length; i++) {
      final available = _requestable[i] & peerBitfield[i + _bitmapOffset];
      if (available == 0) continue;
      final piece = (i + _bitmapOffset) * 8 + 8 - available.bitLength;
      final size = metadata.pieceSize(piece);
      final download = _downloads[piece] ??= _PieceDownload(size);
      final block = download.nextBlock;
      download.requested[block] = 1;
      download.advance();
      if (download.nextBlock == download.blocks.length) {
        _requestable[i] &= ~(0x80 >> (piece % 8));
        while (_firstRequestableByte < _requestable.length &&
            _requestable[_firstRequestableByte] == 0) {
          _firstRequestableByte++;
        }
      }
      final begin = block * blockSize;
      return BlockRequest(piece, begin, math.min(blockSize, size - begin));
    }
    return null;
  }

  void cancelBlockRequest(int pieceIndex, int begin) {
    final download = _downloads[pieceIndex];
    if (download == null) return;
    final block = begin ~/ blockSize;
    if (download.blocks[block] != null) return;
    download.requested[block] = 0;
    download.nextBlock = math.min(download.nextBlock, block);
    _makeRequestable(pieceIndex);
  }

  void onBlockReceived(int pieceIndex, int begin, Uint8List data) {
    if (_disposed ||
        pieceIndex < _firstPiece ||
        pieceIndex > _lastPiece ||
        begin < 0 ||
        begin % blockSize != 0 ||
        hasPiece(pieceIndex)) {
      return;
    }
    final pieceSize = metadata.pieceSize(pieceIndex);
    if (begin >= pieceSize ||
        data.length != math.min(blockSize, pieceSize - begin)) {
      return;
    }

    final download = _downloads[pieceIndex] ??= _PieceDownload(pieceSize);
    final block = begin ~/ blockSize;
    if (download.blocks[block] != null) return;
    download.blocks[block] = data;
    download.receivedBytes += data.length;
    download.advance();
    if (download.nextBlock == download.blocks.length) {
      _requestable[pieceIndex ~/ 8 - _bitmapOffset] &=
          ~(0x80 >> (pieceIndex % 8));
    }
    _downloadedBytes += _targetOverlapBytes(pieceIndex, begin, data.length);
    _torrentDownloadedBytes += data.length;

    if (download.receivedBytes == pieceSize) {
      final assembled = Uint8List(pieceSize);
      for (var i = 0; i < download.blocks.length; i++) {
        final bytes = download.blocks[i]!;
        assembled.setRange(i * blockSize, i * blockSize + bytes.length, bytes);
      }
      if (_verifyPiece(pieceIndex, assembled)) {
        _cache
          ..setPositionSync(pieceIndex * metadata.pieceLength)
          ..writeFromSync(assembled);
        final byte = pieceIndex ~/ 8 - _bitmapOffset;
        final mask = 0x80 >> (pieceIndex % 8);
        _completed[byte] |= mask;
        _requestable[byte] &= ~mask;
        _verifiedBytes += pieceSize;
        _remainingPieces--;
        _advanceContiguousPrefix();
        _downloads.remove(pieceIndex);
        onPieceCompleted?.call(pieceIndex);
        _signalProgress();
      } else {
        _downloadedBytes -= _targetOverlapBytes(pieceIndex, 0, pieceSize);
        _downloads.remove(pieceIndex);
        _makeRequestable(pieceIndex);
      }
    }
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
    _downloads.clear();
    _cache.closeSync();
    if (_cacheFile.existsSync()) _cacheFile.deleteSync();
  }

  void _signalProgress() {
    final event = _nextEvent;
    if (!_disposed) _nextEvent = Completer<void>();
    event.complete();
  }

  void _makeRequestable(int pieceIndex) {
    final byte = pieceIndex ~/ 8 - _bitmapOffset;
    _requestable[byte] |= 0x80 >> (pieceIndex % 8);
    _firstRequestableByte = math.min(_firstRequestableByte, byte);
  }

  void _advanceContiguousPrefix() {
    while (_firstIncompletePiece <= _lastPiece &&
        hasPiece(_firstIncompletePiece)) {
      _contiguousBytes +=
          metadata.pieceSize(_firstIncompletePiece) -
          (_firstIncompletePiece == _firstPiece ? _firstPieceOffset : 0);
      _firstIncompletePiece++;
    }
    if (_contiguousBytes > targetFile.length) {
      _contiguousBytes = targetFile.length;
    }
  }

  int _targetOverlapBytes(int pieceIndex, int begin, int length) {
    final blockStart = pieceIndex * metadata.pieceLength + begin;
    final blockEnd = blockStart + length;
    final overlapStart = math.max(blockStart, targetFile.offset);
    final overlapEnd = math.min(blockEnd, targetFile.end);
    return math.max(0, overlapEnd - overlapStart);
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

/// Allocated only for active pieces; request deadlines belong to the peer.
class _PieceDownload {
  _PieceDownload(int size)
    : blocks = List.filled(
        (size + PieceManager.blockSize - 1) ~/ PieceManager.blockSize,
        null,
      ),
      requested = Uint8List(
        (size + PieceManager.blockSize - 1) ~/ PieceManager.blockSize,
      );

  final List<Uint8List?> blocks;
  final Uint8List requested;
  int nextBlock = 0;
  int receivedBytes = 0;

  void advance() {
    while (nextBlock < blocks.length &&
        (requested[nextBlock] != 0 || blocks[nextBlock] != null)) {
      nextBlock++;
    }
  }
}
