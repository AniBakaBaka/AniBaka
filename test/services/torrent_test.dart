import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:baka/services/torrent/bencode.dart';
import 'package:baka/services/torrent/peer_protocol.dart';
import 'package:baka/services/torrent/piece_manager.dart';
import 'package:baka/services/torrent/stream_server.dart';
import 'package:baka/services/torrent/torrent_model.dart';
import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/services/torrent/tracker_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'selected file spans pieces: out of order, corrupt data, retry and read',
    () {
      final bytes = Uint8List.fromList(List.generate(70000, (i) => i % 251));
      final meta = _metadata(
        bytes,
        pieceLength: 32768,
        files: [
          {
            'length': 17000,
            'path': ['before.txt'],
          },
          {
            'length': 50000,
            'path': ['episode.mp4'],
          },
          {
            'length': 3000,
            'path': ['after.txt'],
          },
        ],
      );
      final pm = PieceManager(metadata: meta, targetFileIndex: 1);
      addTearDown(pm.dispose);
      final available = Uint8List.fromList([0xe0]);
      final first = pm.nextBlock(available)!;
      final second = pm.nextBlock(available)!;
      expect((first.pieceIndex, first.begin), (0, 0));
      expect((second.pieceIndex, second.begin), (0, 16384));
      pm.cancelBlockRequest(first.pieceIndex, first.begin);
      expect(pm.nextBlock(available)!.begin, 0);

      pm.onBlockReceived(0, 0, Uint8List(16384));
      pm.onBlockReceived(0, 16384, Uint8List.sublistView(bytes, 16384, 32768));
      expect(pm.hasPiece(0), isFalse);
      expect(pm.downloadedBytes, 0);
      expect(pm.verifiedBytes, 0);
      expect(pm.torrentDownloadedBytes, 32768);
      expect(pm.nextBlock(available)!.pieceIndex, 0);

      _receivePiece(pm, bytes, 2);
      expect(pm.contiguousBytes, 0);
      expect(pm.nextBlock(Uint8List.fromList([0x20])), isNull);
      _receivePiece(pm, bytes, 0);
      expect(pm.contiguousBytes, 32768 - 17000);
      expect(pm.readFileData(0, 50000), isNull);
      _receivePiece(pm, bytes, 1);
      expect(pm.isComplete, isTrue);
      expect(pm.isReadyToPlay, isTrue);
      expect(pm.progress, 1);
      expect(pm.downloadedBytes, 50000);
      expect(pm.verifiedBytes, 70000);
      expect(pm.contiguousBytes, 50000);
      expect(pm.readFileData(0, 50000), bytes.sublist(17000, 67000));
      expect(pm.readPieceBlock(2, 0, 4464), bytes.sublist(65536));
    },
  );

  test('piece selection respects sparse peers and nonzero bitmap origin', () {
    final bytes = Uint8List(12 * 16384);
    final meta = _metadata(
      bytes,
      pieceLength: 16384,
      files: [
        {
          'length': 9 * 16384,
          'path': ['prefix.bin'],
        },
        {
          'length': 3 * 16384,
          'path': ['episode.mp4'],
        },
      ],
    );
    final pm = PieceManager(metadata: meta, targetFileIndex: 1);
    addTearDown(pm.dispose);
    final peer = Uint8List.fromList([0xff, 0x20]);
    final request = pm.nextBlock(peer)!;
    expect(request.pieceIndex, 10);
    expect(pm.nextBlock(peer), isNull);
    pm.cancelBlockRequest(request.pieceIndex, request.begin);
    expect(pm.nextBlock(peer)!.pieceIndex, 10);
    _receivePiece(pm, bytes, 10);
    pm.cancelBlockRequest(10, 0);
    expect(pm.nextBlock(peer), isNull);
    expect(pm.nextBlock(Uint8List.fromList([0xff, 0xff]))!.pieceIndex, 9);
  });

  test(
    'video selection rejects archives and metadata hashes exact info bytes',
    () {
      final rawInfo = Uint8List.fromList(
        'd6:lengthi4e4:name5:a.zip12:piece lengthi4e6:pieces20:01234567890123456789e'
            .codeUnits,
      );
      final torrent =
          (BytesBuilder()
                ..add('d4:info'.codeUnits)
                ..add(rawInfo)
                ..addByte(101))
              .takeBytes();
      final meta = TorrentMetadata.fromBytes(torrent);
      expect(meta.infoHash, sha1.convert(rawInfo).bytes);
      expect(meta.rawInfoBytes, rawInfo);
      expect(meta.findVideoFileIndex(), isNull);
    },
  );

  test(
    'HTTP tracker preserves counters and supplied tracker interval',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = TrackerClient();
      addTearDown(() async {
        client.dispose();
        await server.close(force: true);
      });
      final queries = <Map<String, String>>[];
      server.listen((request) async {
        queries.add(request.uri.queryParameters);
        request.response.add(
          Bencode.encode({'interval': 47, 'peers': _compactPeer(34567)}),
        );
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/announce';
      final result = await client.announce(
        infoHash: Uint8List(20),
        trackers: [url, url],
        left: 8192,
        downloaded: 32768,
        uploaded: 99,
        port: 45678,
      );
      expect(queries, hasLength(1));
      expect(queries.single['left'], '8192');
      expect(queries.single['downloaded'], '32768');
      expect(queries.single['uploaded'], '99');
      expect(queries.single['port'], '45678');
      expect(queries.single.containsKey('event'), isFalse);
      expect(result.interval, const Duration(seconds: 47));
      expect(result.peers, [const PeerAddress('127.0.0.1', 34567)]);
      expect(
        (await client.announce(
          infoHash: Uint8List(20),
          trackers: [],
          left: 1,
        )).peers,
        isEmpty,
      );
    },
  );

  test(
    'UDP tracker announces the peer listen port, not the tracker port',
    () async {
      final server = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final client = TrackerClient();
      addTearDown(() {
        client.dispose();
        server.close();
      });
      final announced = Completer<ByteData>();
      server.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = server.receive()!;
        final data = ByteData.sublistView(datagram.data);
        if (data.getInt32(8) == 0) {
          final reply = ByteData(16)
            ..setInt32(0, 0)
            ..setInt32(4, data.getInt32(12))
            ..setInt64(8, 123);
          server.send(
            reply.buffer.asUint8List(),
            datagram.address,
            datagram.port,
          );
        } else {
          announced.complete(data);
          final reply = ByteData(26)
            ..setInt32(0, 1)
            ..setInt32(4, data.getInt32(12))
            ..setInt32(8, 61);
          reply.buffer.asUint8List().setRange(20, 26, _compactPeer(34567));
          server.send(
            reply.buffer.asUint8List(),
            datagram.address,
            datagram.port,
          );
        }
      });
      final result = await client.announce(
        infoHash: Uint8List(20),
        trackers: ['udp://127.0.0.1:${server.port}/announce'],
        left: 800,
        downloaded: 200,
        uploaded: 100,
        port: 45678,
        event: 'started',
      );
      final packet = await announced.future;
      expect(packet.getUint16(96), 45678);
      expect(packet.getInt64(56), 200);
      expect(packet.getInt64(64), 800);
      expect(packet.getInt64(72), 100);
      expect(packet.getInt32(80), 2);
      expect(result.interval, const Duration(seconds: 61));
      expect(result.peers.single.port, 34567);
    },
  );

  test(
    'BEP 9 handles split frames, out of order blocks and duplicate data',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = Uint8List.fromList(List.generate(40000, (i) => i % 251));
      final serving = server.first.then((socket) async {
        final wire = _Wire(socket);
        addTearDown(wire.close);
        final handshake = await wire.read(68);
        await wire.fragment(handshake);
        wire.send(
          _extended(
            0,
            Bencode.encode({
              'm': {'ut_metadata': 4},
              'metadata_size': bytes.length,
            }),
          ),
        );
        final requested = <int>{};
        while (requested.length < 3) {
          final message = await wire.message();
          if (message[0] != 20 || message[1] != 4) continue;
          final header =
              Bencode.decode(Uint8List.sublistView(message, 2)) as Map;
          requested.add(header['piece'] as int);
        }
        expect(requested, {0, 1, 2});
        for (final piece in [2, 2, 0, 1]) {
          final start = piece * 16384;
          final block = Uint8List.sublistView(
            bytes,
            start,
            math.min(start + 16384, bytes.length),
          );
          final body =
              (BytesBuilder()
                    ..add(
                      Bencode.encode({
                        'msg_type': 1,
                        'piece': piece,
                        'total_size': bytes.length,
                      }),
                    )
                    ..add(block))
                  .takeBytes();
          await wire.fragment(_extended(1, body));
        }
      });
      final peer = MetadataPeerConnection(
        address: PeerAddress('127.0.0.1', server.port),
        infoHash: Uint8List(20),
        peerId: TrackerClient.peerId,
      );
      addTearDown(() async {
        peer.disconnect();
        await server.close();
      });
      expect(await peer.fetch(), bytes);
      await serving;
    },
  );

  for (final magnet in [false, true]) {
    test(
      '${magnet ? 'magnet xs' : 'torrent URL'} resolves through tracker and peer to verified HTTP ranges',
      () async {
        final data = Uint8List.fromList(List.generate(96000, (i) => i % 251));
        final peerServer = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final service = TorrentService();
        final client = HttpClient();
        addTearDown(() async {
          await service.dispose();
          client.close(force: true);
          await http.close(force: true);
          await peerServer.close();
        });
        final meta = _metadata(data, pieceLength: 65536);
        final torrent = Bencode.encode({
          'announce': 'http://127.0.0.1:${http.port}/announce',
          'info': Bencode.decode(meta.rawInfoBytes),
        });
        expect(
          TorrentMetadata.fromBytes(torrent).infoHashHex,
          meta.infoHashHex,
        );
        http.listen((request) async {
          request.response.add(
            request.uri.path == '/file.torrent'
                ? torrent
                : Bencode.encode({
                    'interval': 3600,
                    'peers': _compactPeer(peerServer.port),
                  }),
          );
          await request.response.close();
        });
        final serving = peerServer.first.then((socket) async {
          final wire = _Wire(socket);
          addTearDown(wire.close);
          wire.send(await wire.read(68));
          // Unchoke alone does not imply that the peer has any piece.
          wire.send(_message(BtMessage.unchoke));
          wire.send(_message(BtMessage.bitfield, Uint8List.fromList([0x40])));
          var received = 0;
          var announcedFirst = false;
          while (received < data.length) {
            final message = await wire.message();
            if (message[0] != BtMessage.request) continue;
            final request = ByteData.sublistView(message, 1);
            final piece = request.getUint32(0),
                begin = request.getUint32(4),
                length = request.getUint32(8);
            if (!announcedFirst) expect(piece, 1);
            final block = Uint8List(8 + length);
            ByteData.sublistView(block)
              ..setUint32(0, piece)
              ..setUint32(4, begin);
            block.setRange(8, block.length, data, piece * 65536 + begin);
            await wire.fragment(_message(BtMessage.piece, block));
            received += length;
            if (!announcedFirst && received == data.length - 65536) {
              announcedFirst = true;
              wire.send(
                _message(
                  BtMessage.have,
                  (ByteData(4)..setUint32(0, 0)).buffer.asUint8List(),
                ),
              );
            }
          }
        });
        final source = 'http://127.0.0.1:${http.port}/file.torrent';
        final url = await service.resolvePlaybackUrl(
          magnet
              ? 'MAGNET:?xt=urn:btih:${meta.infoHashHex}&xs=${Uri.encodeQueryComponent(source)}'
              : source,
        );
        await serving;
        expect(service.statsNotifier.value!.downloadedBytes, data.length);
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('Range', 'bytes=65000-66000');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.partialContent);
        final body = await response.fold(
          BytesBuilder(),
          (b, chunk) => b..add(chunk),
        );
        expect(body.takeBytes(), data.sublist(65000, 66001));
        await service.stopStream();
        expect(service.statsNotifier.value, isNull);
      },
    );
  }

  test(
    'replacing a resolving session isolates cancellation from the new session',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = TorrentService();
      addTearDown(() async {
        await service.dispose();
        await server.close(force: true);
      });
      final arrived = Completer<void>();
      final secondArrived = Completer<void>();
      server.listen((request) {
        if (!arrived.isCompleted) {
          arrived.complete();
        } else if (!secondArrived.isCompleted) {
          secondArrived.complete();
        }
      });
      final pending = service.resolvePlaybackUrl(
        'http://127.0.0.1:${server.port}/file.torrent',
      );
      final result = expectLater(pending, throwsA(anything));
      await arrived.future;
      final second = expectLater(
        service.resolvePlaybackUrl(
          'http://127.0.0.1:${server.port}/second.torrent',
        ),
        throwsA(anything),
      );
      await secondArrived.future;
      await result;
      expect(service.statsNotifier.value, isNotNull);
      await service.stopStream();
      await second;
      expect(
        await service.resolvePlaybackUrl('https://example.com/video.mp4'),
        'https://example.com/video.mp4',
      );
      expect(service.statsNotifier.value, isNull);
    },
  );

  test(
    'HTTP requests for a disposed cache terminate without a stall timer',
    () async {
      final pm = PieceManager(
        metadata: _metadata(Uint8List(32768)),
        targetFileIndex: 0,
      );
      final server = TorrentStreamServer();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.stop();
        pm.dispose();
      });
      await server.start(pm);
      final waiting = pm.nextProgress;
      pm.dispose();
      await waiting;
      final request = await client.getUrl(Uri.parse(server.streamUrl));
      // A closed cache produces a terminated response, never another 60s wait.
      await expectLater(
        request.close().then((r) => r.drain<void>()),
        throwsA(isA<HttpException>()),
      );
    },
  );

  test(
    'peer deadlines retry stalled requests and disconnect releases ownership',
    () async {
      final pm = PieceManager(
        metadata: _metadata(Uint8List(98304), pieceLength: 98304),
        targetFileIndex: 0,
      );
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final disconnected = Completer<void>();
      final peer = PeerConnection(
        address: PeerAddress('127.0.0.1', server.port),
        peerId: TrackerClient.peerId,
        pieceManager: pm,
        onDisconnected: disconnected.complete,
      );
      addTearDown(() async {
        peer.disconnect();
        pm.dispose();
        await server.close();
      });
      final serving = server.first.then((socket) async {
        final wire = _Wire(socket);
        addTearDown(wire.close);
        wire.send(await wire.read(68));
        wire.send(_message(BtMessage.bitfield, Uint8List.fromList([0x80])));
        wire.send(_message(BtMessage.unchoke));
        final begins = <int>[];
        while (begins.length < 6) {
          final message = await wire.message();
          if (message[0] == BtMessage.request) {
            begins.add(ByteData.sublistView(message, 1).getUint32(4));
          }
        }
        expect(begins.take(5), [0, 16384, 32768, 49152, 65536]);
        expect(begins.last, 0);
        await wire.close();
      });
      expect(await peer.connect(), isTrue);
      await serving;
      await disconnected.future;
      expect(pm.nextBlock(Uint8List.fromList([0x80]))!.begin, 0);
    },
  );

  test(
    'buffer deadline stops pending work; absent discovery reports DHT support',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((_) {});
      final service = TorrentService();
      addTearDown(() async {
        await service.dispose();
        await server.close(force: true);
      });
      await expectLater(
        service.resolvePlaybackUrl(
          'http://127.0.0.1:${server.port}/file.torrent',
          bufferTimeout: Duration.zero,
        ),
        throwsA(isA<TorrentPlaybackException>()),
      );
      expect(service.statsNotifier.value, isNull);
      await expectLater(
        service.resolvePlaybackUrl('magnet:?xt=urn:btih:${'0' * 40}'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('DHT'),
          ),
        ),
      );
      expect(service.statsNotifier.value, isNull);
    },
  );
}

TorrentMetadata _metadata(
  Uint8List data, {
  int pieceLength = 32768,
  List<Map<String, Object>>? files,
}) {
  final hashes = BytesBuilder();
  for (var start = 0; start < data.length; start += pieceLength) {
    hashes.add(
      sha1
          .convert(
            Uint8List.sublistView(
              data,
              start,
              math.min(start + pieceLength, data.length),
            ),
          )
          .bytes,
    );
  }
  return TorrentMetadata.fromInfoBytes(
    Bencode.encode({
      'name': 'episode.mp4',
      'piece length': pieceLength,
      'pieces': hashes.takeBytes(),
      if (files == null) 'length': data.length else 'files': files,
    }),
  );
}

void _receivePiece(PieceManager pm, Uint8List data, int piece) {
  final start = piece * pm.metadata.pieceLength;
  for (
    var begin = 0;
    begin < pm.metadata.pieceSize(piece);
    begin += PieceManager.blockSize
  ) {
    pm.onBlockReceived(
      piece,
      begin,
      Uint8List.sublistView(
        data,
        start + begin,
        math.min(
          start + begin + PieceManager.blockSize,
          start + pm.metadata.pieceSize(piece),
        ),
      ),
    );
  }
}

Uint8List _compactPeer(int port) =>
    Uint8List.fromList([127, 0, 0, 1, port >> 8, port & 255]);
Uint8List _message(int type, [Uint8List? body]) {
  final bytes = Uint8List(5 + (body?.length ?? 0));
  ByteData.sublistView(bytes).setUint32(0, bytes.length - 4);
  bytes[4] = type;
  if (body != null) bytes.setRange(5, bytes.length, body);
  return bytes;
}

Uint8List _extended(int id, Uint8List body) => _message(
  20,
  Uint8List(body.length + 1)
    ..[0] = id
    ..setRange(1, body.length + 1, body),
);

class _Wire {
  _Wire(this.socket) : input = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<Uint8List> input;
  Uint8List chunk = Uint8List(0);
  int offset = 0;
  Future<Uint8List> read(int count) async {
    final bytes = Uint8List(count);
    var copied = 0;
    while (copied < count) {
      if (offset == chunk.length) {
        if (!await input.moveNext()) throw StateError('Peer closed');
        chunk = input.current;
        offset = 0;
      }
      final length = math.min(count - copied, chunk.length - offset);
      bytes.setRange(copied, copied + length, chunk, offset);
      copied += length;
      offset += length;
    }
    return bytes;
  }

  Future<Uint8List> message() async {
    var length = 0;
    while (length == 0) {
      length = ByteData.sublistView(await read(4)).getUint32(0);
    }
    return read(length);
  }

  void send(Uint8List data) => socket.add(data);
  Future<void> fragment(Uint8List bytes) async {
    for (var start = 0; start < bytes.length; start += 1021) {
      socket.add(
        Uint8List.sublistView(
          bytes,
          start,
          math.min(start + 1021, bytes.length),
        ),
      );
      await socket.flush();
    }
  }

  Future<void> close() async {
    socket.destroy();
    await input.cancel();
  }
}
