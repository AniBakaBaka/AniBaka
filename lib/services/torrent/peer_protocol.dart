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
  final String peerId;

  Socket? _socket;
  bool _connected = false;
  bool _handshakeDone = false;
  bool _sentHandshake = false;
  bool _postHandshakeSent = false;
  bool _remoteSupportsExtensions = false;
  int? _remoteUtMetadataId;

  final BytesBuilder _buffer = BytesBuilder(copy: true);
  Completer<bool>? _handshake;

  _PeerBase({
    required this.address,
    required this.infoHash,
    required this.peerId,
  });

  bool get isConnected => _connected;

  /// 子类实现：握手完成后发送的初始消息。
  void _sendPostHandshakeMessages();

  /// 子类实现：处理非扩展消息（PeerConnection 处理全部，MetadataPeerConnection 忽略）。
  void _handleWireMessage(int type, Uint8List? payload) {}

  /// 子类实现：处理 ut_metadata 消息。
  void _handleMetadataMessage(Uint8List body) {}

  /// 子类实现：连接失败/断开时的清理。
  void _onDisconnected() {}

  void disconnect() {
    final completer = _handshake;
    if (completer != null && !completer.isCompleted) completer.complete(false);
    if (!_connected && _socket == null) return;
    _connected = false;
    _onDisconnected();
    _socket?.destroy();
    _socket = null;
  }

  Future<bool> _doHandshake(Socket socket, {required bool sendFirst}) async {
    _socket = socket;
    _connected = true;
    socket.listen(
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
    return true;
  }

  void _sendHandshake() {
    if (!_connected || _socket == null || _sentHandshake) return;
    final reserved = Uint8List(8);
    reserved[5] |= _extensionProtocolMask;
    final padded = utf8.encode(peerId.padRight(20)).sublist(0, 20);
    final buf = BytesBuilder()
      ..addByte(19)
      ..add(utf8.encode(_protocolName))
      ..add(reserved)
      ..add(infoHash)
      ..add(padded);
    _sentHandshake = true;
    _socket!.add(buf.toBytes());
  }

  bool _sendMessage(int type, [Uint8List? payload]) {
    if (!_connected || _socket == null) return false;
    final payloadLen = payload?.length ?? 0;
    final msg = ByteData(4 + 1 + payloadLen);
    msg.setUint32(0, 1 + payloadLen);
    msg.setUint8(4, type);
    final bytes = Uint8List.view(msg.buffer);
    if (payload != null) bytes.setRange(5, 5 + payloadLen, payload);
    try {
      _socket!.add(bytes);
      return true;
    } catch (_) {
      disconnect();
      return false;
    }
  }

  bool _sendExtended(int extendedId, Uint8List body) {
    final payload = Uint8List(1 + body.length)
      ..[0] = extendedId
      ..setRange(1, 1 + body.length, body);
    return _sendMessage(BtMessage.extended, payload);
  }

  void _onData(Uint8List data) {
    _buffer.add(data);
    _processBuffer();
  }

  void _processBuffer() {
    final bytes = _buffer.toBytes();
    _buffer.clear();
    var offset = 0;

    if (!_handshakeDone) {
      if (bytes.length < _handshakeLen) {
        _buffer.add(bytes);
        return;
      }
      if (bytes[0] != 19 ||
          utf8.decode(bytes.sublist(1, 20)) != _protocolName ||
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
      _sendPostHandshakeMessagesOnce();
      offset = _handshakeLen;
    }

    while (offset + 4 <= bytes.length) {
      final msgLen = ByteData.sublistView(
        bytes,
        offset,
        offset + 4,
      ).getUint32(0);
      if (msgLen == 0) {
        offset += 4;
        continue;
      }
      if (offset + 4 + msgLen > bytes.length) break;

      final type = bytes[offset + 4];
      final payload = msgLen > 1
          ? Uint8List.sublistView(bytes, offset + 5, offset + 4 + msgLen)
          : null;
      _dispatchMessage(type, payload);
      offset += 4 + msgLen;
    }

    if (offset < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, offset));
    }
  }

  void _sendPostHandshakeMessagesOnce() {
    if (_postHandshakeSent || !_connected) return;
    _postHandshakeSent = true;
    _sendPostHandshakeMessages();
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
        final id = bencodeInt(extensions['ut_metadata'] ?? 0);
        _remoteUtMetadataId = id > 0 ? id : null;
      }
      _onExtendedHandshakeParsed(decoded);
    } catch (_) {}
  }

  /// 子类可覆盖以从扩展握手中提取额外字段（如 metadata_size）。
  void _onExtendedHandshakeParsed(Map handshake) {}
}


class PeerConnection extends _PeerBase {
  final PieceManager pieceManager;
  final Uint8List metadataBytes;
  final void Function(int bytes)? onUploaded;

  static const int _maxPendingRequests = 5;
  static const Duration _requestTimeout = Duration(seconds: 8);

  bool _choked = true;
  bool _amChoking = true;
  final Map<({int pieceIndex, int begin}), DateTime> _pendingRequests = {};
  int _uploadedBytes = 0;

  final Set<int> _peerPieces = {};
  bool _receivedBitfield = false;
  Set<int>? _allPieces;

  Timer? _keepAliveTimer;

  PeerConnection({
    required super.address,
    required super.infoHash,
    required super.peerId,
    required this.pieceManager,
    this.onUploaded,
    Uint8List? metadataBytes,
  }) : metadataBytes = metadataBytes ?? pieceManager.metadata.rawInfoBytes;

  bool get isChoked => _choked;
  int get uploadedBytes => _uploadedBytes;

  /// 主动连接 + 握手。
  Future<bool> connect() async {
    try {
      final socket = await Socket.connect(
        address.ip,
        address.port,
        timeout: const Duration(seconds: 8),
      );
      if (!await _doHandshake(socket, sendFirst: true)) return false;
    } catch (_) {
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
      const Duration(seconds: 60),
      (_) => _socket?.add(Uint8List(4)),
    );
  }

  /// 填充下载请求流水线。
  void fillRequestPipeline() {
    if (_choked || !_connected || pieceManager.isComplete) return;
    _expirePendingRequests();
    final pieces = _availablePieces;
    while (_pendingRequests.length < _maxPendingRequests) {
      final block = pieceManager.nextBlock(availablePieces: pieces);
      if (block == null) break;
      if (!_sendRequest(block.pieceIndex, block.begin, block.length)) {
        pieceManager.cancelBlockRequest(block.pieceIndex, block.begin);
        break;
      }
      _pendingRequests[(pieceIndex: block.pieceIndex, begin: block.begin)] =
          DateTime.now();
    }
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
  }

  /// 已知 peer 拥有的分片：未收到 bitfield/have 时假设其全有。
  Set<int> get _availablePieces {
    if (_receivedBitfield || _peerPieces.isNotEmpty) return _peerPieces;
    return _allPieces ??= {
      for (var i = 0; i < pieceManager.metadata.pieceCount; i++) i,
    };
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
    final payload = Uint8List(8 + block.length);
    final view = ByteData.sublistView(payload);
    view
      ..setUint32(0, pieceIndex)
      ..setUint32(4, begin);
    payload.setRange(8, payload.length, block);
    if (_sendMessage(BtMessage.piece, payload)) {
      _recordUploaded(block.length);
    }
  }

  void _recordUploaded(int bytes) {
    if (bytes <= 0) return;
    _uploadedBytes += bytes;
    onUploaded?.call(bytes);
  }

  void _sendBitfield() {
    final totalPieces = pieceManager.metadata.pieceCount;
    final bytes = Uint8List((totalPieces + 7) ~/ 8);
    var hasAny = false;
    for (final pieceIndex in pieceManager.completedPieceIndices) {
      if (pieceIndex < 0 || pieceIndex >= totalPieces) continue;
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
          if (piece < pieceManager.metadata.pieceCount) _peerPieces.add(piece);
        }
      case BtMessage.bitfield:
        if (payload != null) {
          _peerPieces.clear();
          _parseBitfield(payload);
          _receivedBitfield = true;
          _releaseUnavailableRequests();
        }
        if (!_choked) fillRequestPipeline();
      case BtMessage.request:
        _handleRequest(payload);
      case BtMessage.piece:
        _handlePieceData(payload);
    }
  }

  void _parseBitfield(Uint8List bitfield) {
    final totalPieces = pieceManager.metadata.pieceCount;
    for (var byteIdx = 0; byteIdx < bitfield.length; byteIdx++) {
      final b = bitfield[byteIdx];
      if (b == 0) continue;
      for (var bitIdx = 0; bitIdx < 8; bitIdx++) {
        if (b & (0x80 >> bitIdx) == 0) continue;
        final pieceIndex = byteIdx * 8 + bitIdx;
        if (pieceIndex < totalPieces) _peerPieces.add(pieceIndex);
      }
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

    _pendingRequests.remove((pieceIndex: pieceIndex, begin: begin));
    pieceManager.onBlockReceived(pieceIndex, begin, block);
    fillRequestPipeline();
  }

  void _expirePendingRequests() {
    final now = DateTime.now();
    final expired = _pendingRequests.entries
        .where((entry) => now.difference(entry.value) >= _requestTimeout)
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final request in expired) {
      _pendingRequests.remove(request);
      pieceManager.cancelBlockRequest(request.pieceIndex, request.begin);
    }
  }

  void _releaseUnavailableRequests() {
    final unavailable = _pendingRequests.keys
        .where((request) => !_peerPieces.contains(request.pieceIndex))
        .toList(growable: false);
    for (final request in unavailable) {
      _pendingRequests.remove(request);
      pieceManager.cancelBlockRequest(request.pieceIndex, request.begin);
    }
  }

  void _releasePendingRequests() {
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
      final msgType = bencodeInt(decoded['msg_type'] ?? -1);
      final piece = bencodeInt(decoded['piece'] ?? -1);
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
      _recordUploaded(block.length);
    }
  }

  void _sendMetadataReject(int piece) {
    final remoteId = _remoteUtMetadataId;
    if (remoteId == null) return;
    _sendExtended(remoteId, Bencode.encode({'msg_type': 2, 'piece': piece}));
  }
}


class MetadataPeerConnection extends _PeerBase {
  int? _metadataSize;
  int _inFlight = 0;

  final Set<int> _requestedPieces = {};
  List<Uint8List?>? _metadataPieces;
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
      final socket = await Socket.connect(
        address.ip,
        address.port,
        timeout: const Duration(seconds: 8),
      );
      _metadataResult = Completer<Uint8List?>();

      // 覆盖 disconnect 以同时完成 metadata result
      if (!await _doHandshake(socket, sendFirst: true)) return null;

      try {
        return await _metadataResult!.future.timeout(
          timeout,
          onTimeout: () => null,
        );
      } finally {
        disconnect();
      }
    } catch (_) {
      return null;
    }
  }

  @override
  void _onDisconnected() {
    _completeMetadata(null);
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
    final size = bencodeInt(handshake['metadata_size'] ?? 0);
    if (size <= 0 || size > _maxMetadataSize || _remoteUtMetadataId == null) {
      _completeMetadata(null);
      return;
    }
    _metadataSize = size;
    _metadataPieces = List<Uint8List?>.filled(
      (size + _metadataBlockSize - 1) ~/ _metadataBlockSize,
      null,
    );
    _requestMoreMetadata();
  }

  @override
  void _handleMetadataMessage(Uint8List body) {
    try {
      final decoded = Bencode.decodePrefix(body);
      final header = decoded.value;
      if (header is! Map) return;
      final msgType = bencodeInt(header['msg_type'] ?? -1);
      final piece = bencodeInt(header['piece'] ?? -1);

      if (msgType == 0) {
        _sendMetadataReject(piece);
        return;
      }

      if (msgType == 2) {
        _completeMetadata(null);
        return;
      }

      if (msgType != 1 || piece < 0) return;
      final pieces = _metadataPieces;
      final size = _metadataSize;
      if (pieces == null || size == null || piece >= pieces.length) return;

      final totalSize = bencodeInt(header['total_size'] ?? size);
      if (totalSize != size) {
        _completeMetadata(null);
        return;
      }

      final block = Uint8List.sublistView(body, decoded.end);
      if (block.length != _metadataPieceLength(piece)) {
        _completeMetadata(null);
        return;
      }
      pieces[piece] = Uint8List.fromList(block);
      if (_inFlight > 0) _inFlight--;

      if (pieces.every((item) => item != null)) {
        _completeMetadata(_assembleMetadata());
      } else {
        _requestMoreMetadata();
      }
    } catch (_) {
      _completeMetadata(null);
    }
  }

  void _requestMoreMetadata() {
    final pieces = _metadataPieces;
    if (pieces == null) return;
    while (_inFlight < 4) {
      final nextPiece = _nextMetadataPiece();
      if (nextPiece == null) return;
      if (!_sendMetadataRequest(nextPiece)) {
        _completeMetadata(null);
        return;
      }
      _requestedPieces.add(nextPiece);
      _inFlight++;
    }
  }

  int? _nextMetadataPiece() {
    final pieces = _metadataPieces;
    if (pieces == null) return null;
    for (var i = 0; i < pieces.length; i++) {
      if (pieces[i] == null && !_requestedPieces.contains(i)) return i;
    }
    return null;
  }

  bool _sendMetadataRequest(int piece) {
    final remoteId = _remoteUtMetadataId;
    if (remoteId == null) return false;
    return _sendExtended(
      remoteId,
      Bencode.encode({'msg_type': 0, 'piece': piece}),
    );
  }

  void _sendMetadataReject(int piece) {
    final remoteId = _remoteUtMetadataId;
    if (remoteId == null) return;
    _sendExtended(remoteId, Bencode.encode({'msg_type': 2, 'piece': piece}));
  }

  int _metadataPieceLength(int piece) {
    final size = _metadataSize ?? 0;
    final start = piece * _metadataBlockSize;
    return math.min(_metadataBlockSize, size - start);
  }

  Uint8List _assembleMetadata() {
    final builder = BytesBuilder(copy: false);
    for (final piece in _metadataPieces!) {
      builder.add(piece!);
    }
    return builder.toBytes();
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
