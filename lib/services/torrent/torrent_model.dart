import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:baka/services/torrent/bencode.dart';

const _videoExts = {'.mkv', '.mp4', '.avi', '.wmv', '.flv', '.webm', '.ts'};

/// Torrent 元数据模型
class TorrentMetadata {
  /// Info hash (20 字节 SHA1)
  final Uint8List infoHash;

  /// Info hash 的小写十六进制字符串
  String get infoHashHex =>
      infoHash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// 原始 info 字典字节，用于 BEP 9 metadata 上传。
  final Uint8List rawInfoBytes;

  /// 种子名称
  final String name;

  /// 单个分片大小（字节）
  final int pieceLength;

  /// 所有分片的 SHA1 哈希值拼接（每 20 字节一个）
  final Uint8List pieces;

  /// 分片数量
  int get pieceCount => pieces.length ~/ 20;

  /// 文件列表（单文件种子也统一为列表）
  final List<TorrentFile> files;

  /// 总大小（字节）
  final int totalSize;

  /// Tracker URL 列表（去重合并 announce + announce-list）
  final List<String> trackers;

  const TorrentMetadata({
    required this.infoHash,
    required this.rawInfoBytes,
    required this.name,
    required this.pieceLength,
    required this.pieces,
    required this.files,
    required this.totalSize,
    required this.trackers,
  });

  /// 从 .torrent 文件字节解析
  factory TorrentMetadata.fromBytes(Uint8List data) {
    final decoded = Bencode.decodeWithRange(data, 'info');
    final root = decoded.root;
    final info = root['info'] as Map<String, dynamic>;
    final rawInfoBytes = Uint8List.fromList(
      data.sublist(decoded.start, decoded.end),
    );

    final infoHash = Uint8List.fromList(sha1.convert(rawInfoBytes).bytes);

    final trackers = <String>{};
    final announce = root['announce'];
    if (announce != null) trackers.add(bencodeString(announce));
    final announceList = root['announce-list'];
    if (announceList is List) {
      for (final tier in announceList) {
        if (tier is! List) continue;
        for (final url in tier) {
          trackers.add(bencodeString(url));
        }
      }
    }

    return _fromInfo(
      info: info,
      infoHash: infoHash,
      rawInfoBytes: rawInfoBytes,
      trackers: trackers,
    );
  }

  /// 从 BEP 9 获取到的 info 字典字节构建 metadata。
  factory TorrentMetadata.fromInfoBytes(
    Uint8List infoBytes, {
    Iterable<String> trackers = const <String>[],
  }) {
    final decoded = Bencode.decode(infoBytes);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('BEP 9 metadata 不是有效的 info 字典');
    }
    return _fromInfo(
      info: decoded,
      infoHash: Uint8List.fromList(sha1.convert(infoBytes).bytes),
      rawInfoBytes: Uint8List.fromList(infoBytes),
      trackers: trackers,
    );
  }

  static TorrentMetadata _fromInfo({
    required Map<String, dynamic> info,
    required Uint8List infoHash,
    required Uint8List rawInfoBytes,
    required Iterable<String> trackers,
  }) {
    final name = bencodeString(info['name']);
    final pieceLength = bencodeInt(info['piece length']);
    final pieces = info['pieces'] as Uint8List;

    final files = <TorrentFile>[];
    var totalSize = 0;
    final rawFiles = info['files'];
    if (rawFiles is List) {
      for (final entry in rawFiles) {
        final f = entry as Map<String, dynamic>;
        final path = (f['path'] as List).map(bencodeString).join('/');
        final length = bencodeInt(f['length']);
        files.add(TorrentFile(path: path, length: length, offset: totalSize));
        totalSize += length;
      }
    } else {
      final length = bencodeInt(info['length']);
      files.add(TorrentFile(path: name, length: length, offset: 0));
      totalSize = length;
    }

    return TorrentMetadata(
      infoHash: infoHash,
      rawInfoBytes: rawInfoBytes,
      name: name,
      pieceLength: pieceLength,
      pieces: pieces,
      files: files,
      totalSize: totalSize,
      trackers: trackers
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toSet()
          .toList(),
    );
  }

  /// 获取第 pieceIndex 个分片的期望 SHA1 哈希值（20 字节）
  Uint8List pieceHash(int pieceIndex) =>
      Uint8List.sublistView(pieces, pieceIndex * 20, pieceIndex * 20 + 20);

  /// 获取第 pieceIndex 个分片的实际大小（最后一片可能较小）
  int pieceSize(int pieceIndex) {
    final tail = totalSize % pieceLength;
    return pieceIndex == pieceCount - 1 && tail != 0 ? tail : pieceLength;
  }

  /// 找到主视频文件索引：优先按视频扩展名挑最大；若无匹配则取整体最大文件。
  int? findVideoFileIndex() {
    if (files.isEmpty) return null;
    int videoIdx = -1, videoSize = -1;
    int largestIdx = 0, largestSize = files[0].length;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      if (f.length > largestSize) {
        largestIdx = i;
        largestSize = f.length;
      }
      final lower = f.path.toLowerCase();
      if (_videoExts.any(lower.endsWith) && f.length > videoSize) {
        videoIdx = i;
        videoSize = f.length;
      }
    }
    return videoIdx >= 0 ? videoIdx : largestIdx;
  }

  @override
  String toString() =>
      'TorrentMetadata(name: $name, files: ${files.length}, '
      'size: ${(totalSize / 1024 / 1024).toStringAsFixed(1)}MB, '
      'pieces: $pieceCount)';
}

/// 种子内的单个文件
class TorrentFile {
  final String path;
  final int length;

  /// 在整个种子数据中的字节偏移量
  final int offset;

  const TorrentFile({
    required this.path,
    required this.length,
    required this.offset,
  });

  /// 文件结束的字节偏移量
  int get end => offset + length;

  @override
  String toString() =>
      'TorrentFile(path: $path, size: ${(length / 1024 / 1024).toStringAsFixed(1)}MB)';
}

/// Magnet 链接
class MagnetLink {
  /// Info hash（小写十六进制，40 字符）
  final String infoHash;

  /// Tracker 列表
  final List<String> trackers;

  /// BEP 9/缓存不可用时可直接下载元数据的精确来源（BEP 9 `xs`）。
  final List<String> exactSources;

  const MagnetLink({
    required this.infoHash,
    required this.trackers,
    this.exactSources = const <String>[],
  });

  /// Info hash 字节（20 字节）
  Uint8List get infoHashBytes {
    final bytes = Uint8List(20);
    for (var i = 0; i < 20; i++) {
      bytes[i] = int.parse(infoHash.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// 从 magnet URI 解析
  factory MagnetLink.parse(String uri) {
    final parsed = Uri.parse(uri.trim());
    if (parsed.scheme.toLowerCase() != 'magnet') {
      throw FormatException('无效的 magnet 链接: $uri');
    }

    final xt = parsed.queryParameters['xt'] ?? '';
    if (!xt.startsWith('urn:btih:')) {
      throw const FormatException('magnet 链接缺少 xt=urn:btih: 参数');
    }
    final hash = xt.substring(9);
    final String infoHash;
    if (hash.length == 40) {
      infoHash = hash.toLowerCase();
    } else if (hash.length == 32) {
      infoHash = _base32ToHex(hash);
    } else {
      throw FormatException('无效的 info hash 长度: ${hash.length}');
    }

    final trackers = [
      for (final t in parsed.queryParametersAll['tr'] ?? const <String>[])
        if (t.isNotEmpty) t,
    ];
    final exactSources = [
      for (final source in parsed.queryParametersAll['xs'] ?? const <String>[])
        if (source.startsWith('http://') || source.startsWith('https://'))
          source,
    ];

    return MagnetLink(
      infoHash: infoHash,
      trackers: trackers,
      exactSources: exactSources,
    );
  }

  static String _base32ToHex(String base32) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final bytes = <int>[];
    var buf = 0;
    var bits = 0;
    for (final c in base32.toUpperCase().codeUnits) {
      final idx = alphabet.indexOf(String.fromCharCode(c));
      if (idx == -1) continue;
      buf = (buf << 5) | idx;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        bytes.add((buf >> bits) & 0xff);
      }
    }
    if (bytes.length != 20) {
      throw FormatException('无效的 base32 info hash: $base32');
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  String toString() =>
      'MagnetLink(hash: $infoHash, trackers: ${trackers.length}, '
      'exactSources: ${exactSources.length})';
}
