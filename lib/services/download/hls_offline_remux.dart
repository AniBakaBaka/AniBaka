import 'dart:convert';
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
  static Future<String?> remuxManifest(
    String manifestPath, {
    void Function()? checkCancelled,
  }) async {
    checkCancelled?.call();
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
        await sliceFileToByteRange(
          File(part.path),
          part.range!,
          checkCancelled: checkCancelled,
        );
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
        checkCancelled?.call();
        final src = File(part.path);
        if (!await src.exists()) {
          throw StateError('missing segment ${part.path}');
        }
        await sink.addStream(
          src.openRead().map((chunk) {
            checkCancelled?.call();
            return chunk;
          }),
        );
      }
      await sink.flush();
      await sink.close();
      checkCancelled?.call();
      if (await outFile.exists()) await outFile.delete();
      await partial.rename(outPath);
    } catch (error, stack) {
      debugPrint('HlsOfflineRemux failed: $error\n$stack');
      try {
        await sink.close();
      } catch (_) {}
      if (await partial.exists()) await partial.delete();
      checkCancelled?.call();
      return null;
    }

    await _cleanupFragments(dir, keepFileName: outName);
    debugPrint('HlsOfflineRemux: wrote $outPath');
    return outPath;
  }

  /// 将 [file] 裁剪为 byterange 指定的内容。已是目标长度则跳过。
  static Future<bool> sliceFileToByteRange(
    File file,
    HlsByteRange range, {
    void Function()? checkCancelled,
  }) async {
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
          .map((chunk) {
            checkCancelled?.call();
            return chunk;
          })
          .pipe(partial.openWrite(mode: FileMode.writeOnly));
      checkCancelled?.call();
      await file.delete();
      await partial.rename(file.path);
      return true;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      checkCancelled?.call();
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
      // Concatenation cannot decrypt encrypted segments. Keep the local HLS
      // manifest and keys so the player can handle them instead.
      if (upper.startsWith('#EXT-X-KEY:') &&
          _m3u8Attribute(line, 'METHOD')?.value != 'NONE') {
        return null;
      }

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
    final victims = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isEmpty
          ? entity.path
          : entity.uri.pathSegments.last;
      if (name == keepFileName) continue;
      if (name.endsWith('_danmaku.json') || name.endsWith('.json')) continue;
      victims.add(entity);
    }
    // 串行逐个删在 Windows 上是几百次同步等待；分批并发删除能明显缩短
    // 下载收尾（界面停在最后进度）的时间。
    const batch = 64;
    for (var i = 0; i < victims.length; i += batch) {
      final end = i + batch > victims.length ? victims.length : i + batch;
      await Future.wait([
        for (final f in victims.sublist(i, end)) _deleteQuietly(f),
      ]);
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      await f.delete();
    } catch (_) {}
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

// Pure playlist planning: stable manifest order and URL/range deduplication.
typedef HlsAsset = ({String url, String localName, HlsByteRange? byteRange});
final _bandwidthRe = RegExp(r'BANDWIDTH=(\d+)');

/// 取码率最高的变体。单趟扫描直接留最大值，不再物化整张变体表再排序。
Uri? selectHlsVariant(String content, Uri playlistUrl) {
  Uri? best;
  var bestBandwidth = -1;
  int? pendingBandwidth;
  for (final raw in LineSplitter.split(content)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-STREAM-INF')) {
      pendingBandwidth =
          int.tryParse(_bandwidthRe.firstMatch(line)?.group(1) ?? '') ?? 0;
      continue;
    }
    if (!line.startsWith('#') &&
        pendingBandwidth != null &&
        pendingBandwidth > bestBandwidth) {
      best = playlistUrl.resolve(line);
      bestBandwidth = pendingBandwidth;
    }
    pendingBandwidth = null;
  }
  return best;
}

({String localContent, List<HlsAsset> assets}) planHlsDownload(
  Uri playlistUrl,
  String content,
) {
  final rewritten = StringBuffer();
  final assets = <HlsAsset>[];
  // 同一 URL 不同 BYTERANGE 必须落成不同本地文件。
  final localNameByKey = <String, String>{};
  var segmentIndex = 0;
  var keyIndex = 0;
  var mapIndex = 0;
  HlsByteRange? pendingByteRange;

  String addAsset(String rawUrl, String localName, {HlsByteRange? byteRange}) {
    final absoluteUrl = playlistUrl.resolve(rawUrl).toString();
    final key = byteRange == null
        ? absoluteUrl
        : '$absoluteUrl#${byteRange.offset}:${byteRange.length}';
    return localNameByKey.putIfAbsent(key, () {
      assets.add((
        url: absoluteUrl,
        localName: localName,
        byteRange: byteRange,
      ));
      return localName;
    });
  }

  for (final line in LineSplitter.split(content)) {
    final trimmed = line.trim();
    if (trimmed.toUpperCase().startsWith('#EXT-X-BYTERANGE:')) {
      pendingByteRange = HlsByteRange.tryParse(
        trimmed.substring('#EXT-X-BYTERANGE:'.length),
      );
      // 离线文件是完整分片，清单里不再保留 BYTERANGE。
      continue;
    }

    final isKey = trimmed.startsWith('#EXT-X-KEY');
    if (isKey || trimmed.startsWith('#EXT-X-MAP')) {
      final uri = _m3u8Attribute(line, 'URI');
      if (uri == null || uri.value.isEmpty) {
        rewritten.writeln(line);
        continue;
      }
      final mapRange = HlsByteRange.tryParse(
        _m3u8Attribute(line, 'BYTERANGE')?.value,
      );
      final localName = addAsset(
        uri.value,
        isKey
            ? 'key_${(keyIndex++).toString().padLeft(3, '0')}'
                  '${_extensionFromUrl(uri.value, '.key')}'
            : 'map_${(mapIndex++).toString().padLeft(3, '0')}'
                  '${_extensionFromUrl(uri.value, '.mp4')}',
        byteRange: mapRange,
      );
      // 去掉 MAP 上的 BYTERANGE，URI 换成本地名。
      var mapped = line.replaceRange(uri.start, uri.end, 'URI="$localName"');
      mapped = mapped.replaceAll(
        RegExp(r',?\s*BYTERANGE=(?:"[^"]+"|[^\s,]+)', caseSensitive: false),
        '',
      );
      rewritten.writeln(mapped);
      pendingByteRange = null;
    } else if (trimmed.isEmpty || trimmed.startsWith('#')) {
      rewritten.writeln(line);
    } else {
      final range = pendingByteRange;
      pendingByteRange = null;
      final localName = addAsset(
        trimmed,
        'segment_${(segmentIndex++).toString().padLeft(5, '0')}${_extensionFromUrl(trimmed, '.ts')}',
        byteRange: range,
      );
      rewritten.writeln(localName);
    }
  }

  if (segmentIndex == 0) {
    throw StateError('m3u8 playlist has no segments');
  }

  var localContent = rewritten.toString();
  if (!localContent.contains('#EXT-X-ENDLIST')) {
    localContent = '$localContent#EXT-X-ENDLIST\n';
  }
  return (localContent: localContent, assets: assets);
}

/// 定位 `NAME=` 属性并同时给出值与可替换区间。
///
/// 取代原先「按属性名现编正则、读一次、再编一次同样的正则写回」的两趟写法：
/// 属性语法只有「引号包裹」和「读到逗号为止」两种，单趟扫描即可，且每行零正则编译。
({int start, int end, String value})? _m3u8Attribute(String line, String name) {
  final at = line.indexOf('$name=');
  if (at < 0) return null;

  final valueStart = at + name.length + 1;
  if (valueStart < line.length) {
    final quote = line.codeUnitAt(valueStart);
    if (quote == 0x22 || quote == 0x27) {
      final close = line.indexOf(String.fromCharCode(quote), valueStart + 1);
      if (close > 0) {
        return (
          start: at,
          end: close + 1,
          value: line.substring(valueStart + 1, close),
        );
      }
    }
  }

  var end = line.indexOf(',', valueStart);
  if (end < 0) end = line.length;
  return (start: at, end: end, value: line.substring(valueStart, end).trim());
}

String _extensionFromUrl(String url, String fallback) {
  final path = Uri.tryParse(url)?.path ?? url;
  final fileName = path.split('/').last;
  final dot = fileName.lastIndexOf('.');
  if (dot == -1 || dot == fileName.length - 1) return fallback;

  final extension = fileName.substring(dot);
  if (extension.length > 8) return fallback;
  return extension;
}
