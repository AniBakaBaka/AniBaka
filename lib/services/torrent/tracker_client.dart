import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:baka/services/torrent/bencode.dart';
import 'package:flutter/foundation.dart';
import 'package:baka/services/torrent/torrent_model.dart';

/// Tracker 客户端 — 从 HTTP/UDP tracker 获取 peer 列表
class TrackerClient {
  /// 整个 BT 客户端共享的 peer-id（peer 握手与 tracker announce 必须一致）
  static final Uint8List peerId = Uint8List.fromList(
    utf8.encode(_generatePeerId()),
  );

  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  static const int defaultListenPort = 6881;

  static const List<String> _fallbackTrackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.openbittorrent.com:6969/announce',
    'https://tracker.gbitt.info/announce',
  ];

  static String _generatePeerId() {
    final rng = Random();
    final suffix = List.generate(12, (_) => rng.nextInt(10).toString()).join();
    return '-BK0100-$suffix';
  }

  /// Announces in parallel and keeps the interval returned by trackers.
  static Future<TrackerAnnounceResult> announce({
    required Uint8List infoHash,
    required Iterable<String> trackers,
    int totalSize = 0,
    int downloaded = 0,
    int uploaded = 0,
    int port = defaultListenPort,
    String? event,
  }) async {
    final urls = _normalizeTrackers(trackers);
    final results = await Future.wait(
      urls.map(
        (url) => _announceOne(
          url: url,
          infoHash: infoHash,
          totalSize: totalSize,
          downloaded: downloaded,
          uploaded: uploaded,
          port: port,
          event: event,
        ).catchError((_) => const TrackerAnnounceResult()),
      ),
    );
    Duration? interval;
    final peers = <PeerAddress>{};
    for (final result in results) {
      peers.addAll(result.peers);
      final candidate = result.interval;
      if (candidate != null &&
          candidate > Duration.zero &&
          (interval == null || candidate < interval)) {
        interval = candidate;
      }
    }
    return TrackerAnnounceResult(
      peers: peers.toList(growable: false),
      interval: interval,
    );
  }

  static Future<TrackerAnnounceResult> announceMetadata({
    required TorrentMetadata metadata,
    int downloaded = 0,
    int uploaded = 0,
    int port = defaultListenPort,
    String? event,
  }) {
    return announce(
      infoHash: metadata.infoHash,
      trackers: metadata.trackers,
      totalSize: metadata.totalSize,
      downloaded: downloaded,
      uploaded: uploaded,
      port: port,
      event: event,
    );
  }

  static Future<TrackerAnnounceResult> announceFromMagnet({
    required MagnetLink magnet,
    int port = defaultListenPort,
  }) {
    return announce(
      infoHash: magnet.infoHashBytes,
      trackers: magnet.trackers,
      totalSize: 1,
      port: port,
    );
  }

  static List<String> _normalizeTrackers(Iterable<String> trackers) {
    final seen = <String>{};
    final result = <String>[];
    final source = trackers.isEmpty ? _fallbackTrackers : trackers;
    for (final raw in source) {
      final url = raw.trim();
      final lower = url.toLowerCase();
      if (url.isEmpty || !seen.add(lower)) continue;
      if (lower.startsWith('http://') ||
          lower.startsWith('https://') ||
          lower.startsWith('udp://')) {
        result.add(url);
      }
    }
    return result;
  }

  static Future<TrackerAnnounceResult> _announceOne({
    required String url,
    required Uint8List infoHash,
    required int totalSize,
    required int downloaded,
    required int uploaded,
    required int port,
    String? event,
  }) {
    return url.toLowerCase().startsWith('udp://')
        ? _announceUdp(
            url: url,
            infoHash: infoHash,
            totalSize: totalSize,
            downloaded: downloaded,
            uploaded: uploaded,
            port: port,
            event: event,
          )
        : _announceHttp(
            url: url,
            infoHash: infoHash,
            totalSize: totalSize,
            downloaded: downloaded,
            uploaded: uploaded,
            port: port,
            event: event,
          );
  }

  static Future<TrackerAnnounceResult> _announceHttp({
    required String url,
    required Uint8List infoHash,
    required int totalSize,
    required int downloaded,
    required int uploaded,
    required int port,
    String? event,
  }) async {
    final left = (totalSize - downloaded).clamp(0, totalSize);
    final query = StringBuffer()
      ..write('info_hash=${_urlEncodeBytes(infoHash)}')
      ..write('&peer_id=${_urlEncodeBytes(peerId)}')
      ..write('&port=$port')
      ..write('&uploaded=$uploaded')
      ..write('&downloaded=$downloaded')
      ..write('&left=$left')
      ..write('&compact=1')
      ..write('&numwant=80');
    final announceEvent = event ?? (downloaded == 0 ? 'started' : null);
    if (announceEvent != null) query.write('&event=$announceEvent');

    final separator = url.contains('?') ? '&' : '?';
    final requestUrl = '$url$separator$query';

    try {
      final request = await _httpClient.getUrl(Uri.parse(requestUrl));
      request.headers.set('User-Agent', 'Baka/1.0');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) return const TrackerAnnounceResult();

      final body = await _collectBytes(response);
      final decoded = Bencode.decode(body);
      if (decoded is! Map) return const TrackerAnnounceResult();

      final failure = decoded['failure reason'];
      if (failure != null) {
        debugPrint('[Tracker] $url 失败: ${bencodeString(failure)}');
        return const TrackerAnnounceResult();
      }
      final seconds = bencodeInt(decoded['interval']);
      return TrackerAnnounceResult(
        peers: _parsePeers(decoded['peers']),
        interval: seconds > 0 ? Duration(seconds: seconds) : null,
      );
    } catch (e) {
      debugPrint('[Tracker] $url 请求失败: $e');
      return const TrackerAnnounceResult();
    }
  }

  static Future<TrackerAnnounceResult> _announceUdp({
    required String url,
    required Uint8List infoHash,
    required int totalSize,
    required int downloaded,
    required int uploaded,
    required int port,
    String? event,
  }) async {
    RawDatagramSocket? socket;
    StreamIterator<RawSocketEvent>? events;
    try {
      final uri = Uri.parse(url);
      final addresses = await InternetAddress.lookup(
        uri.host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 8));
      if (addresses.isEmpty) return const TrackerAnnounceResult();

      final address = addresses.first;
      final port = uri.hasPort ? uri.port : 80;
      final rng = Random();
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      events = StreamIterator<RawSocketEvent>(socket);

      final connectTx = rng.nextInt(0x7fffffff);
      final connectReq = ByteData(16)
        ..setInt64(0, 0x41727101980)
        ..setInt32(8, 0)
        ..setInt32(12, connectTx);
      socket.send(Uint8List.view(connectReq.buffer), address, port);

      final connectResp = await _readUdp(socket, events: events);
      if (connectResp == null || connectResp.length < 16) {
        return const TrackerAnnounceResult();
      }
      final connectView = ByteData.sublistView(connectResp);
      if (connectView.getInt32(0) != 0 ||
          connectView.getInt32(4) != connectTx) {
        return const TrackerAnnounceResult();
      }

      final connectionId = connectView.getInt64(8);
      final announceTx = rng.nextInt(0x7fffffff);
      final left = (totalSize - downloaded).clamp(0, totalSize);
      final eventId = switch (event ?? (downloaded == 0 ? 'started' : null)) {
        'completed' => 1,
        'started' => 2,
        'stopped' => 3,
        _ => 0,
      };
      final announceReq = ByteData(98)
        ..setInt64(0, connectionId)
        ..setInt32(8, 1)
        ..setInt32(12, announceTx)
        ..setInt64(56, downloaded)
        ..setInt64(64, left)
        ..setInt64(72, uploaded)
        ..setInt32(80, eventId)
        ..setInt32(84, 0)
        ..setInt32(88, rng.nextInt(0x7fffffff))
        ..setInt32(92, 80) // numwant
        ..setUint16(96, port);
      final announceBytes = Uint8List.view(announceReq.buffer);
      announceBytes.setRange(16, 36, infoHash);
      announceBytes.setRange(36, 56, peerId);
      socket.send(announceBytes, address, port);

      final announceResp = await _readUdp(socket, events: events);
      if (announceResp == null || announceResp.length < 20) {
        return const TrackerAnnounceResult();
      }
      final announceView = ByteData.sublistView(announceResp);
      if (announceView.getInt32(0) != 1 ||
          announceView.getInt32(4) != announceTx) {
        return const TrackerAnnounceResult();
      }
      final seconds = announceView.getInt32(8);
      return TrackerAnnounceResult(
        peers: _parsePeers(Uint8List.sublistView(announceResp, 20)),
        interval: seconds > 0 ? Duration(seconds: seconds) : null,
      );
    } catch (e) {
      debugPrint('[Tracker] $url UDP 请求失败: $e');
      return const TrackerAnnounceResult();
    } finally {
      await events?.cancel();
      socket?.close();
    }
  }

  static Future<Uint8List?> _readUdp(
    RawDatagramSocket socket, {
    required StreamIterator<RawSocketEvent> events,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final datagram = socket.receive();
      if (datagram != null) return datagram.data;

      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      try {
        final hasEvent = await events.moveNext().timeout(remaining);
        if (!hasEvent || events.current == RawSocketEvent.closed) return null;
      } on TimeoutException {
        return null;
      }
    }
  }

  static List<PeerAddress> _parsePeers(dynamic peers) {
    if (peers is Uint8List) {
      // 紧凑模式：每 6 字节 = 4 字节 IP + 2 字节端口
      final result = <PeerAddress>[];
      for (var i = 0; i + 6 <= peers.length; i += 6) {
        final port = (peers[i + 4] << 8) | peers[i + 5];
        if (port == 0) continue;
        final ip =
            '${peers[i]}.${peers[i + 1]}.${peers[i + 2]}.${peers[i + 3]}';
        result.add(PeerAddress(ip, port));
      }
      return result;
    }
    if (peers is List) {
      return [
        for (final p in peers.whereType<Map>())
          if (bencodeInt(p['port'] ?? 0) > 0)
            PeerAddress(bencodeString(p['ip'] ?? ''), bencodeInt(p['port'])),
      ];
    }
    return const [];
  }

  static String _urlEncodeBytes(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      final unreserved =
          (b >= 0x30 && b <= 0x39) || // 0-9
          (b >= 0x41 && b <= 0x5A) || // A-Z
          (b >= 0x61 && b <= 0x7A) || // a-z
          b == 0x2D ||
          b == 0x2E ||
          b == 0x5F ||
          b == 0x7E;
      if (unreserved) {
        sb.writeCharCode(b);
      } else {
        sb.write('%${b.toRadixString(16).padLeft(2, '0').toUpperCase()}');
      }
    }
    return sb.toString();
  }

  static Future<Uint8List> _collectBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    return builder.toBytes();
  }
}

class TrackerAnnounceResult {
  const TrackerAnnounceResult({
    this.peers = const <PeerAddress>[],
    this.interval,
  });

  final List<PeerAddress> peers;
  final Duration? interval;
}

/// Peer 地址
class PeerAddress {
  final String ip;
  final int port;

  const PeerAddress(this.ip, this.port);

  @override
  bool operator ==(Object other) =>
      other is PeerAddress && other.ip == ip && other.port == port;

  @override
  int get hashCode => Object.hash(ip, port);

  @override
  String toString() => '$ip:$port';
}
