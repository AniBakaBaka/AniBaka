import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:baka/services/torrent/bencode.dart';
import 'package:baka/services/torrent/piece_manager.dart';
import 'package:baka/services/torrent/tracker_client.dart';

/// BitTorrent peer wire 消息类型
class BtMessage {
  static const int choke = 0;
  static const int unchoke = 1;
  static const int interested = 2;
  static const int notInterested = 3;
  static const int have = 4;
  static const int bitfield = 5;
  static const int request = 6;
  static const int piece = 7;
  static const int cancel = 8;
  static const int extended = 20;
}

const _handshakeLen = 68;
const _protocolName = 'BitTorrent protocol';
const _extensionReservedByteOffset = 25; // 20 + reserved[5]
const _extensionProtocolMask = 0x10;
const _utMetadataLocalId = 1;
const _metadataBlockSize = 16 * 1024;
const _maxMetadataSize = 8 * 1024 * 1024;

abstract class _PeerBase {
  final PeerAddress address;
  final Uint8List infoHash;
  final Uint8List peerId;

  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  ConnectionTask<Socket>? _connecting;
  bool _disconnected = false;

  Future<Socket> _openSocket() async {
    final task = await Socket.startConnect(address.ip, address.port);
    _connecting = task;
    if (_disconnected) task.cancel();
    try {
      final socket = await task.socket.timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          task.cancel();
          throw TimeoutException('Peer connect timed out');
        },
      );
      if (_disconnected) {
        socket.destroy();
        throw StateError('Peer stopped');
      }
      return socket;
    } finally {
      _connecting = null;
    }
  }

  bool _connected = false;
  bool _handshakeDone = false;
  bool _sentHandshake = false;
  bool _remoteSupportsExtensions = false;
  int? _remoteUtMetadataId;

  Uint8List? _frame;
  int _frameOffset = 0;
  int _frameLength = _handshakeLen;
  bool _readingLength = false;
  Completer<bool>? _handshake;

  _PeerBase({
    required this.address,
    required this.infoHash,
    required this.peerId,
  });

  bool get isConnected => _connected;
  int get _maxMessageLength => _metadataBlockSize + 1024;

  /// 子类实现：握手完成后发送的初始消息。
  void _sendPostHandshakeMessages();

  /// 子类实现：处理非扩展消息（PeerConnection 处理全部，MetadataPeerConnection 忽略）。
  void _handleWireMessage(int type, Uint8List? payload) {}

  /// 子类实现：处理 ut_metadata 消息。
  void _handleMetadataMessage(Uint8List body) {}

  /// 子类实现：连接失败/断开时的清理。
  void _onDisconnected() {}

  void disconnect() {
    if (_disconnected) return;
    _disconnected = true;
    _connecting?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
    final completer = _handshake;
    if (completer != null && !completer.isCompleted) completer.complete(false);
    _connected = false;
    _frame = null;
    _onDisconnected();
    _socket?.destroy();
    _socket = null;
  }

  Future<bool> _doHandshake(Socket socket, {required bool sendFirst}) async {
    if (_disconnected) {
      socket.destroy();
      return false;
    }
    _socket = socket;
    _connected = true;
    _subscription = socket.listen(
      _onData,
      onError: (_) => disconnect(),
      onDone: disconnect,
      cancelOnError: true,
    );

    _handshake = Completer<bool>();
    if (sendFirst) _sendHandshake();

    final ok = await _handshake!.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => false,
    );
    _handshake = null;
    if (!ok) {
      disconnect();
      return false;
    }
    return _connected;
  }

  void _sendHandshake() {
    if (!_connected || _socket == null || _sentHandshake) return;
    final buf = Uint8List(_handshakeLen)
      ..[0] = 19
      ..setRange(1, 20, _protocolName.codeUnits)
      ..[_extensionReservedByteOffset] = _extensionProtocolMask
      ..setRange(28, 48, infoHash)
      ..setRange(48, 68, peerId);
    _sentHandshake = true;
    _socket!.add(buf);
  }

  bool _sendMessage(int type, [Uint8List? payload, Uint8List? tail]) {
    if (!_connected || _socket == null) return false;
    final payloadLen = payload?.length ?? 0;
    final tailLen = tail?.length ?? 0;
    final msg = ByteData(4 + 1 + payloadLen + tailLen);
    msg.setUint32(0, 1 + payloadLen + tailLen);
    msg.setUint8(4, type);
    final bytes = Uint8List.view(msg.buffer);
    if (payload != null) bytes.setRange(5, 5 + payloadLen, payload);
    if (tail != null) bytes.setRange(5 + payloadLen, bytes.length, tail);
    try {
      _socket!.add(bytes);
      return true;
    } catch (_) {
      disconnect();
      return false;
    }
  }

  bool _sendExtended(int extendedId, Uint8List body) {
    return _sendMessage(
      BtMessage.extended,
      Uint8List(1)..[0] = extendedId,
      body,
    );
  }

  void _onData(Uint8List data) {
    var offset = 0;
    try {
      while (offset < data.length && !_disconnected) {
        if (_frame == null && data.length - offset >= _frameLength) {
          final end = offset + _frameLength;
          _processFrame(Uint8List.sublistView(data, offset, end));
          offset = end;
          continue;
        }
        final frame = _frame ??= Uint8List(_frameLength);
        final count = math.min(
          _frameLength - _frameOffset,
          data.length - offset,
        );
        frame.setRange(_frameOffset, _frameOffset + count, data, offset);
        _frameOffset += count;
        offset += count;
        if (_frameOffset == _frameLength) {
          _frame = null;
          _frameOffset = 0;
          _processFrame(frame);
        }
      }
    } on FormatException {
      disconnect();
    } on RangeError {
      disconnect();
    }
  }

  void _processFrame(Uint8List bytes) {
    if (!_handshakeDone) {
      if (bytes[0] != 19 ||
          utf8.decode(Uint8List.sublistView(bytes, 1, 20)) != _protocolName ||
          !_bytesEqual(Uint8List.sublistView(bytes, 28, 48), infoHash)) {
        _handshake?.complete(false);
        disconnect();
        return;
      }
      _remoteSupportsExtensions =
          bytes[_extensionReservedByteOffset] & _extensionProtocolMask != 0;
      _handshakeDone = true;
      if (!_sentHandshake) _sendHandshake();
      _handshake?.complete(true);
      _sendPostHandshakeMessages();
    } else if (_readingLength) {
      final length = ByteData.sublistView(bytes).getUint32(0);
      if (length == 0) return;
      if (length > _maxMessageLength) {
        disconnect();
        return;
      }
      _frameLength = length;
      _readingLength = false;
      return;
    } else {
      _dispatchMessage(
        bytes[0],
        bytes.length > 1 ? Uint8List.sublistView(bytes, 1) : null,
      );
    }
    _frameLength = 4;
    _readingLength = true;
  }

  void _dispatchMessage(int type, Uint8List? payload) {
    if (type == BtMessage.extended) {
      _handleExtended(payload);
    } else {
      _handleWireMessage(type, payload);
    }
  }

  void _handleExtended(Uint8List? payload) {
    if (payload == null || payload.isEmpty) return;
    final extendedId = payload[0];
    final body = Uint8List.sublistView(payload, 1);
    if (extendedId == 0) {
      _handleExtendedHandshake(body);
    } else if (extendedId == _utMetadataLocalId) {
      _handleMetadataMessage(body);
    }
  }

  void _handleExtendedHandshake(Uint8List body) {
    try {
      final decoded = Bencode.decode(body);
      if (decoded is! Map) return;
      final extensions = decoded['m'];
      if (extensions is Map) {
        final id = (extensions['ut_metadata'] as int?) ?? 0;
        _remoteUtMetadataId = id > 0 ? id : null;
      }
      _onExtendedHandshakeParsed(decoded);
    } catch (_) {}
  }

  /// 子类可覆盖以从扩展握手中提取额外字段（如 metadata_size）。
  void _onExtendedHandshakeParsed(Map handshake) {}

  void _sendMetadataReject(int piece) {
    final remoteId = _remoteUtMetadataId;
    if (remoteId != null) {
      _sendExtended(remoteId, Bencode.encode({'msg_type': 2, 'piece': piece}));
    }
  }
}

class PeerConnection extends _PeerBase {
  final PieceManager pieceManager;
  final void Function(int bytes)? onUploaded;
  final void Function()? onDisconnected;

  static const int _maxPendingRequests = 5;
  static const int _requestTimeoutMs = 8000;

  bool _choked = true;
  bool _amChoking = true;
  final Map<({int pieceIndex, int begin}), int> _pendingRequests = {};
  final Stopwatch _requestClock = Stopwatch()..start();

  Uint8List? _peerBitfield;
  Timer? _keepAliveTimer;
  Timer? _requestTimer;

  PeerConnection({
    required super.address,
    required super.peerId,
    required this.pieceManager,
    this.onUploaded,
    this.onDisconnected,
  }) : super(infoHash: pieceManager.metadata.infoHash);

  Uint8List get metadataBytes => pieceManager.metadata.rawInfoBytes;

  @override
  int get _maxMessageLength => math.max(
    super._maxMessageLength,
    (pieceManager.metadata.pieceCount + 7) ~/ 8 + 1,
  );

  /// 主动连接 + 握手。
  Future<bool> connect() async {
    try {
      final socket = await _openSocket();
      if (!await _doHandshake(socket, sendFirst: true)) return false;
    } catch (_) {
      disconnect();
      return false;
    }
    _startKeepAlive();
    return true;
  }

  /// 接受远端主动连入的 socket。
  Future<bool> accept(Socket socket) async {
    if (!await _doHandshake(socket, sendFirst: false)) return false;
    _startKeepAlive();
    return true;
  }

  void _startKeepAlive() {
    _keepAliveTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _socket?.add(Uint8List(4)),
    );
  }

  /// 填充下载请求流水线。
  void fillRequestPipeline() {
    final bitfield = _peerBitfield;
    if (_choked || !_connected || pieceManager.isComplete || bitfield == null) {
      return;
    }
    while (_pendingRequests.length < _maxPendingRequests) {
      final block = pieceManager.nextBlock(bitfield);
      if (block == null) break;
      if (!_sendRequest(block.pieceIndex, block.begin, block.length)) {
        pieceManager.cancelBlockRequest(block.pieceIndex, block.begin);
        break;
      }
      _pendingRequests[(pieceIndex: block.pieceIndex, begin: block.begin)] =
          _requestClock.elapsedMilliseconds;
    }
    _scheduleRequestTimeout();
  }

  void announcePiece(int pieceIndex) {
    if (!_connected || !pieceManager.hasPiece(pieceIndex)) return;
    final payload = ByteData(4)..setUint32(0, pieceIndex);
    _sendMessage(BtMessage.have, Uint8List.view(payload.buffer));
  }

  @override
  void _onDisconnected() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _releasePendingRequests();
    _peerBitfield = null;
    onDisconnected?.call();
  }

  bool _peerHasPiece(int pieceIndex) {
    final bitfield = _peerBitfield;
    if (bitfield == null) return false;
    final byteIndex = pieceIndex ~/ 8;
    return byteIndex < bitfield.length &&
        bitfield[byteIndex] & (0x80 >> (pieceIndex % 8)) != 0;
  }

  @override
  void _sendPostHandshakeMessages() {
    _sendBitfield();
    if (_remoteSupportsExtensions) _sendExtendedHandshake();
    if (!pieceManager.isComplete) _sendMessage(BtMessage.interested);
    _sendUnchoke();
  }

  bool _sendRequest(int pieceIndex, int begin, int length) {
    final p = ByteData(12)
      ..setUint32(0, pieceIndex)
      ..setUint32(4, begin)
      ..setUint32(8, length);
    return _sendMessage(BtMessage.request, Uint8List.view(p.buffer));
  }

  void _sendPiece(int pieceIndex, int begin, Uint8List block) {
    final header = ByteData(8)
      ..setUint32(0, pieceIndex)
      ..setUint32(4, begin);
    if (_sendMessage(BtMessage.piece, Uint8List.view(header.buffer), block)) {
      onUploaded?.call(block.length);
    }
  }

  void _sendBitfield() {
    final totalPieces = pieceManager.metadata.pieceCount;
    final bytes = Uint8List((totalPieces + 7) ~/ 8);
    var hasAny = false;
    for (final pieceIndex in pieceManager.completedPieceIndices) {
      bytes[pieceIndex ~/ 8] |= 0x80 >> (pieceIndex % 8);
      hasAny = true;
    }
    if (hasAny) _sendMessage(BtMessage.bitfield, bytes);
  }

  void _sendUnchoke() {
    if (!_amChoking) return;
    _amChoking = false;
    _sendMessage(BtMessage.unchoke);
  }

  void _sendExtendedHandshake() {
    final payload = Bencode.encode({
      'm': {'ut_metadata': _utMetadataLocalId},
      'metadata_size': metadataBytes.length,
      'reqq': 64,
      'v': 'Baka/1.0',
    });
    _sendExtended(0, payload);
  }

  @override
  void _handleWireMessage(int type, Uint8List? payload) {
    switch (type) {
      case BtMessage.choke:
        _choked = true;
        _releasePendingRequests();
      case BtMessage.unchoke:
        _choked = false;
        fillRequestPipeline();
      case BtMessage.interested:
        _sendUnchoke();
      case BtMessage.have:
        if (payload != null && payload.length >= 4) {
          final piece = ByteData.sublistView(payload).getUint32(0);
          if (piece < pieceManager.metadata.pieceCount) {
            final bitfield = _peerBitfield ??= Uint8List(
              (pieceManager.metadata.pieceCount + 7) ~/ 8,
            );
            bitfield[piece ~/ 8] |= 0x80 >> (piece % 8);
            fillRequestPipeline();
          }
        }
      case BtMessage.bitfield:
        if (payload != null) {
          final expected = (pieceManager.metadata.pieceCount + 7) ~/ 8;
          if (payload.length == expected) {
            _peerBitfield = Uint8List.fromList(payload);
            _releaseUnavailableRequests();
          }
        }
        if (!_choked) fillRequestPipeline();
      case BtMessage.request:
        _handleRequest(payload);
      case BtMessage.piece:
        _handlePieceData(payload);
    }
  }

  void _handleRequest(Uint8List? payload) {
    if (payload == null || payload.length < 12 || _amChoking) return;
    final view = ByteData.sublistView(payload);
    final pieceIndex = view.getUint32(0);
    final begin = view.getUint32(4);
    final length = view.getUint32(8);
    final block = pieceManager.readPieceBlock(pieceIndex, begin, length);
    if (block == null) return;
    _sendPiece(pieceIndex, begin, block);
  }

  void _handlePieceData(Uint8List? payload) {
    if (payload == null || payload.length < 8) return;
    final view = ByteData.sublistView(payload);
    final pieceIndex = view.getUint32(0);
    final begin = view.getUint32(4);
    final block = Uint8List.sublistView(payload, 8);

    if (_pendingRequests.remove((pieceIndex: pieceIndex, begin: begin)) ==
        null) {
      return;
    }
    pieceManager.cancelBlockRequest(pieceIndex, begin);
    pieceManager.onBlockReceived(pieceIndex, begin, block);
    fillRequestPipeline();
  }

  void _scheduleRequestTimeout() {
    _requestTimer?.cancel();
    if (_pendingRequests.isEmpty) return;
    final remaining =
        _pendingRequests.values.first +
        _requestTimeoutMs -
        _requestClock.elapsedMilliseconds;
    _requestTimer = Timer(Duration(milliseconds: math.max(0, remaining)), () {
      final deadline = _requestClock.elapsedMilliseconds - _requestTimeoutMs;
      _pendingRequests.removeWhere((request, sentAt) {
        if (sentAt > deadline) return false;
        pieceManager.cancelBlockRequest(request.pieceIndex, request.begin);
        return true;
      });
      fillRequestPipeline();
    });
  }

  void _releaseUnavailableRequests() {
    _pendingRequests.removeWhere((request, _) {
      if (_peerHasPiece(request.pieceIndex)) return false;
      pieceManager.cancelBlockRequest(request.pieceIndex, request.begin);
      return true;
    });
  }

  void _releasePendingRequests() {
    _requestTimer?.cancel();
    _requestTimer = null;
    for (final request in _pendingRequests.keys) {
      pieceManager.cancelBlockRequest(request.pieceIndex, request.begin);
    }
    _pendingRequests.clear();
  }

  @override
  void _handleMetadataMessage(Uint8List body) {
    try {
      final decoded = Bencode.decodePrefix(body).value;
      if (decoded is! Map) return;
      final msgType = decoded['msg_type'] as int;
      final piece = decoded['piece'] as int;
      if (msgType == 0) _sendMetadataPieceOrReject(piece);
    } catch (_) {}
  }

  void _sendMetadataPieceOrReject(int piece) {
    if (piece < 0 || metadataBytes.isEmpty) {
      _sendMetadataReject(piece);
      return;
    }

    final start = piece * _metadataBlockSize;
    if (start >= metadataBytes.length) {
      _sendMetadataReject(piece);
      return;
    }
    final end = math.min(start + _metadataBlockSize, metadataBytes.length);
    final block = Uint8List.sublistView(metadataBytes, start, end);
    final header = Bencode.encode({
      'msg_type': 1,
      'piece': piece,
      'total_size': metadataBytes.length,
    });
    final body = Uint8List(header.length + block.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + block.length, block);
    final remoteId = _remoteUtMetadataId;
    if (remoteId != null && _sendExtended(remoteId, body)) {
      onUploaded?.call(block.length);
    }
  }
}

class MetadataPeerConnection extends _PeerBase {
  Uint8List? _metadataBytes;
  int _nextPiece = 0;
  int _receivedBytes = 0;
  final Set<int> _requestedPieces = {};
  Completer<Uint8List?>? _metadataResult;

  MetadataPeerConnection({
    required super.address,
    required super.infoHash,
    required super.peerId,
  });

  Future<Uint8List?> fetch({
    Duration timeout = const Duration(seconds: 25),
  }) async {
    try {
      final socket = await _openSocket();
      _metadataResult = Completer<Uint8List?>();

      if (!await _doHandshake(socket, sendFirst: true)) return null;
      return await _metadataResult!.future.timeout(
        timeout,
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      disconnect();
    }
  }

  @override
  void _onDisconnected() {
    _completeMetadata(null);
    _metadataBytes = null;
    _requestedPieces.clear();
  }

  void _completeMetadata(Uint8List? metadata) {
    final completer = _metadataResult;
    if (completer != null && !completer.isCompleted) {
      completer.complete(metadata);
    }
  }

  @override
  void _sendPostHandshakeMessages() {
    if (!_remoteSupportsExtensions) {
      _completeMetadata(null);
      return;
    }
    _sendExtended(
      0,
      Bencode.encode({
        'm': {'ut_metadata': _utMetadataLocalId},
        'reqq': 32,
        'v': 'Baka/1.0',
      }),
    );
  }

  @override
  void _onExtendedHandshakeParsed(Map handshake) {
    final size = (handshake['metadata_size'] as int?) ?? 0;
    if (size <= 0 || size > _maxMetadataSize || _remoteUtMetadataId == null) {
      _completeMetadata(null);
      return;
    }
    if (_metadataBytes != null) return;
    _metadataBytes = Uint8List(size);
    _requestMoreMetadata();
  }

  @override
  void _handleMetadataMessage(Uint8List body) {
    try {
      final decoded = Bencode.decodePrefix(body);
      final header = decoded.value;
      if (header is! Map) return;
      final msgType = header['msg_type'] as int;
      final piece = header['piece'] as int;

      if (msgType == 0) {
        _sendMetadataReject(piece);
        return;
      }

      if (msgType == 2) {
        _completeMetadata(null);
        return;
      }

      if (msgType != 1 || piece < 0) return;
      final bytes = _metadataBytes;
      if (bytes == null || !_requestedPieces.remove(piece)) return;
      final size = bytes.length;
      final totalSize = header['total_size'] as int;
      if (totalSize != size) {
        _completeMetadata(null);
        return;
      }

      final block = Uint8List.sublistView(body, decoded.end);
      final start = piece * _metadataBlockSize;
      if (block.length != math.min(_metadataBlockSize, size - start)) {
        _completeMetadata(null);
        return;
      }
      bytes.setRange(start, start + block.length, block);
      _receivedBytes += block.length;

      if (_receivedBytes == size) {
        _completeMetadata(bytes);
      } else {
        _requestMoreMetadata();
      }
    } catch (_) {
      _completeMetadata(null);
    }
  }

  void _requestMoreMetadata() {
    final bytes = _metadataBytes!;
    while (_requestedPieces.length < 4 &&
        _nextPiece * _metadataBlockSize < bytes.length) {
      final piece = _nextPiece++;
      if (!_sendExtended(
        _remoteUtMetadataId!,
        Bencode.encode({'msg_type': 0, 'piece': piece}),
      )) {
        _completeMetadata(null);
        return;
      }
      _requestedPieces.add(piece);
    }
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
