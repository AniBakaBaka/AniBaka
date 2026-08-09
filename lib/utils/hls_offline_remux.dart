import 'dart:io';

import 'package:flutter/foundation.dart';

/// HLS byte-range: `length@offset`（RFC 8216）。
class HlsByteRange {
  const HlsByteRange({required this.length, required this.offset});

  final int length;
  final int offset;

  /// 解析 `2083369@12421` 或 `"1353@12421"`。
  static HlsByteRange? tryParse(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.startsWith('"') && text.endsWith('"') && text.length >= 2) {
      text = text.substring(1, text.length - 1);
    }
    final at = text.indexOf('@');
    if (at <= 0) return null;
    final length = int.tryParse(text.substring(0, at));
    final offset = int.tryParse(text.substring(at + 1));
    if (length == null || offset == null || length <= 0 || offset < 0) {
      return null;
    }
    return HlsByteRange(length: length, offset: offset);
  }

  @override
  String toString() => '$length@$offset';
}

/// HLS 离线缓存：把分片合并成单一媒体文件，从根源解决 m3u8 seek 问题。
///
/// 支持：
/// - fMP4 / CMAF：`#EXT-X-MAP` init + 若干 `moof/mdat` 分片 → `video.mp4`
/// - MPEG-TS：顺序拼接分片 → `video.ts`
abstract final class HlsOfflineRemux {
  static const _remuxedMp4Name = 'video.mp4';
  static const _remuxedTsName = 'video.ts';

  static final _mapUriRe = RegExp(
    r'URI=(?:"([^"]+)"|([^,\s]+))',
    caseSensitive: false,
  );
  static final _standaloneByteRangeRe = RegExp(
    r'^#EXT-X-BYTERANGE:(.+)$',
    caseSensitive: false,
  );
  static final _mapByteRangeAttrRe = RegExp(
    r'BYTERANGE=(?:"([^"]+)"|([^,\s]+))',
    caseSensitive: false,
  );

  /// 将清单对应分片合并为单文件，成功返回输出路径。
  static Future<String?> remuxManifest(String manifestPath) async {
    final file = File(manifestPath);
    if (!await file.exists()) return null;
    final dir = file.parent;

    final existing = await _existingRemux(dir);
    if (existing != null) return existing;

    final raw = await file.readAsString();
    final plan = await _buildRemuxPlan(dir, raw);
    if (plan == null || plan.parts.isEmpty) {
      debugPrint('HlsOfflineRemux: empty plan for $manifestPath');
      return null;
    }

    for (final part in plan.parts) {
      if (part.range != null) {
        await sliceFileToByteRange(File(part.path), part.range!);
      }
    }

    final outName = plan.isFmp4 ? _remuxedMp4Name : _remuxedTsName;
    final outPath = _join(dir.path, outName);
    final outFile = File(outPath);
    final partial = File('$outPath.partial');
    if (await partial.exists()) await partial.delete();

    final sink = partial.openWrite();
    try {
      for (final part in plan.parts) {
        final src = File(part.path);
        if (!await src.exists()) {
          throw StateError('missing segment ${part.path}');
        }
        await sink.addStream(src.openRead());
      }
      await sink.flush();
      await sink.close();
      if (await outFile.exists()) await outFile.delete();
      await partial.rename(outPath);
    } catch (error, stack) {
      debugPrint('HlsOfflineRemux failed: $error\n$stack');
      try {
        await sink.close();
      } catch (_) {}
      if (await partial.exists()) await partial.delete();
      return null;
    }

    await _cleanupFragments(dir, keepFileName: outName);
    debugPrint('HlsOfflineRemux: wrote $outPath');
    return outPath;
  }

  /// 将 [file] 裁剪为 byterange 指定的内容。已是目标长度则跳过。
  static Future<bool> sliceFileToByteRange(
    File file,
    HlsByteRange range,
  ) async {
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length == range.length) return false;
    final end = range.offset + range.length;
    if (length < end) return false;
    final partial = File('${file.path}.range');
    try {
      if (await partial.exists()) await partial.delete();
      await file
          .openRead(range.offset, end)
          .pipe(partial.openWrite(mode: FileMode.writeOnly));
      await file.delete();
      await partial.rename(file.path);
      return true;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      return false;
    }
  }

  static Future<String?> _existingRemux(Directory dir) async {
    for (final name in [_remuxedMp4Name, _remuxedTsName]) {
      final f = File(_join(dir.path, name));
      if (await f.exists() && await f.length() > 0) return f.path;
    }
    return null;
  }

  static Future<_RemuxPlan?> _buildRemuxPlan(
    Directory dir,
    String content,
  ) async {
    final lines = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final parts = <_RemuxPart>[];
    String? mapUri;
    HlsByteRange? mapRange;
    HlsByteRange? pendingRange;

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final upper = line.toUpperCase();

      final br = _standaloneByteRangeRe.firstMatch(line);
      if (br != null) {
        pendingRange = HlsByteRange.tryParse(br.group(1));
        continue;
      }

      if (upper.startsWith('#EXT-X-MAP:')) {
        final uri = _mapUriRe.firstMatch(line);
        mapUri = uri?.group(1) ?? uri?.group(2);
        final rangeMatch = _mapByteRangeAttrRe.firstMatch(line);
        mapRange = HlsByteRange.tryParse(
          rangeMatch?.group(1) ?? rangeMatch?.group(2),
        );
        continue;
      }

      if (line.startsWith('#')) continue;

      parts.add(_RemuxPart(path: _join(dir.path, line), range: pendingRange));
      pendingRange = null;
    }

    if (mapUri != null && mapUri.isNotEmpty) {
      parts.insert(
        0,
        _RemuxPart(path: _join(dir.path, mapUri), range: mapRange),
      );
    }
    if (parts.isEmpty) return null;

    final probe = File(parts.first.path);
    final isFmp4 = await _looksLikeFmp4(probe);
    return _RemuxPlan(parts: parts, isFmp4: isFmp4 || mapUri != null);
  }

  static Future<void> _cleanupFragments(
    Directory dir, {
    required String keepFileName,
  }) async {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isEmpty
          ? entity.path
          : entity.uri.pathSegments.last;
      if (name == keepFileName) continue;
      if (name.endsWith('_danmaku.json') || name.endsWith('.json')) continue;
      try {
        await entity.delete();
      } catch (_) {}
    }
  }

  static Future<bool> _looksLikeFmp4(File file) async {
    if (!await file.exists()) return false;
    final raf = await file.open();
    try {
      final header = await raf.read(12);
      if (header.length < 8) return false;
      final tag = String.fromCharCodes(header, 4, 8);
      return tag == 'ftyp' || tag == 'moof' || tag == 'styp';
    } catch (_) {
      return false;
    } finally {
      await raf.close();
    }
  }

  static String _join(String parent, String child) {
    if (parent.endsWith('/') || parent.endsWith(r'\')) return '$parent$child';
    return '$parent${Platform.pathSeparator}$child';
  }
}

class _RemuxPart {
  const _RemuxPart({required this.path, this.range});
  final String path;
  final HlsByteRange? range;
}

class _RemuxPlan {
  const _RemuxPlan({required this.parts, required this.isFmp4});
  final List<_RemuxPart> parts;
  final bool isFmp4;
}
