import 'package:baka/source/runtime/source_operation.dart';
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';

/// 探测单个分片，返回它的编码指纹。探测失败（网络错误、非 TS 分片、前缀太短）
/// 返回 null，调用方一律按「与主体一致」处理，避免误删。
typedef HlsSegmentFingerprintProbe =
    Future<HlsVideoFingerprint?> Function(Uri segmentUri);

/// 过滤结果。[manifest] 未发生过滤时与入参完全相同。
class HlsAdFilterOutcome {
  const HlsAdFilterOutcome({
    required this.manifest,
    required this.removedSegments,
    required this.removedSeconds,
    required this.detail,
    this.timelineKey = 'original',
  });

  final String manifest;
  final String timelineKey;
  final int removedSegments;
  final double removedSeconds;

  /// 一行说明，用于日志。
  final String detail;

  bool get changed => removedSegments > 0;
}

/// 清单里的一个分片：从属于自己的标签行（`#EXTINF`、可能还有
/// `#EXT-X-DISCONTINUITY` 等）到 URI 行的行号区间。
class _Segment {
  const _Segment({
    required this.firstLine,
    required this.lastLine,
    required this.duration,
    required this.uri,
    required this.discontinuityBefore,
  });

  /// 起始行号（含）。
  final int firstLine;

  /// 结束行号（含），即 URI 所在行。
  final int lastLine;

  final double duration;
  final Uri uri;

  /// 本分片之前是否有 `#EXT-X-DISCONTINUITY`，即它是不是一个分组的首片。
  final bool discontinuityBefore;
}

/// 解析成「行 + 分片」的清单模型，便于按分片删除整段行。
class _Playlist {
  const _Playlist({required this.lines, required this.segments});

  final List<String> lines;
  final List<_Segment> segments;

  static _Playlist parse(String text, Uri baseUri) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final segments = <_Segment>[];

    int? blockStart;
    var duration = 0.0;
    var discontinuity = false;

    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('#')) {
        if (blockStart == null && _startsSegmentBlock(trimmed)) blockStart = i;
        if (trimmed.startsWith('#EXTINF:')) {
          duration = _duration(trimmed);
        } else if (trimmed == '#EXT-X-DISCONTINUITY') {
          discontinuity = true;
        }
        continue;
      }

      final start = blockStart ?? i;
      Uri uri;
      try {
        uri = baseUri.resolve(trimmed);
      } catch (_) {
        uri = Uri.parse(trimmed);
      }
      segments.add(
        _Segment(
          firstLine: start,
          lastLine: i,
          duration: duration,
          uri: uri,
          discontinuityBefore: discontinuity,
        ),
      );
      blockStart = null;
      duration = 0;
      discontinuity = false;
    }

    return _Playlist(lines: lines, segments: segments);
  }

  /// 能归属到某个分片的标签。清单级标签（`#EXT-X-TARGETDURATION`、
  /// `#EXT-X-MEDIA-SEQUENCE` 等）与全局生效的 `#EXT-X-KEY`/`#EXT-X-MAP`
  /// 都不算在内，删除分片时它们会原样留下。
  static bool _startsSegmentBlock(String line) {
    return line.startsWith('#EXTINF') ||
        line == '#EXT-X-DISCONTINUITY' ||
        line.startsWith('#EXT-X-BYTERANGE') ||
        line.startsWith('#EXT-X-PROGRAM-DATE-TIME') ||
        line.startsWith('#EXT-X-DATERANGE') ||
        line.startsWith('#EXT-X-CUE') ||
        line.startsWith('#EXT-X-BITRATE');
  }

  static double _duration(String line) {
    final value = line.substring(line.indexOf(':') + 1).split(',').first.trim();
    return double.tryParse(value) ?? 0;
  }

  /// 按 `#EXT-X-DISCONTINUITY` 切分出的连续分片组。
  List<({int first, int end, double seconds})> groups() {
    final groups = <({int first, int end, double seconds})>[];
    var first = 0;
    var seconds = 0.0;
    for (var i = 0; i < segments.length; i++) {
      if (i > first && segments[i].discontinuityBefore) {
        groups.add((first: first, end: i, seconds: seconds));
        first = i;
        seconds = 0;
      }
      seconds += segments[i].duration;
    }
    if (first < segments.length) {
      groups.add((first: first, end: segments.length, seconds: seconds));
    }
    return groups;
  }
}

/// 去掉 HLS 里拼接进来的广告分片。
///
/// 做法：按 `#EXT-X-DISCONTINUITY` 分组，探测每组首片的编码指纹，按组时长加权
/// 取多数指纹作为正片指纹，丢弃指纹不同的分片。组首探测失败时补探组内分片，
/// 但未知指纹的分片始终保留。
///
/// 只识别「与正片不同编码」的广告。为了避免把多段不同编码的正片误删，过滤设有
/// 两道闸门：单段连续删除不超过 [_maxRunSeconds]，删除总量不超过整条清单的
/// [_maxRemovableFraction]；任一超限就整条放弃，保持清单原样。
abstract final class HlsAdFilter {
  /// 单段连续删除时长上限（秒）。广告插播通常十几到几十秒，整段正片远大于此。
  static const double _maxRunSeconds = 60;

  /// 删除总量占整条清单时长的上限。
  static const double _maxRemovableFraction = 0.15;

  static Future<HlsAdFilterOutcome> apply({
    required String manifest,
    required Uri manifestUri,
    required HlsSegmentFingerprintProbe probe,
    int concurrency = 6,
  }) async {
    SourceOperation.check();
    if (RegExp(
      r'^[ \t]*#EXT-X-(KEY|MAP|BYTERANGE):',
      multiLine: true,
    ).hasMatch(manifest)) {
      return HlsAdFilterOutcome(
        manifest: manifest,
        removedSegments: 0,
        removedSeconds: 0,
        detail: '加密、初始化段或字节范围清单保持原样',
      );
    }
    final playlist = _Playlist.parse(manifest, manifestUri);
    final segments = playlist.segments;
    final groups = playlist.groups();
    final totalSeconds = segments.fold<double>(
      0,
      (sum, segment) => sum + segment.duration,
    );

    HlsAdFilterOutcome unchanged(String detail) => HlsAdFilterOutcome(
      manifest: manifest,
      removedSegments: 0,
      removedSeconds: 0,
      detail: detail,
    );

    if (segments.length < 4 || groups.length < 2 || totalSeconds <= 0) {
      return unchanged('分片或分组过少，跳过去广告');
    }

    // 缓存只属于本次过滤：复用组首取样，同时允许下次播放重试网络失败。
    final probes = <Uri, Future<HlsVideoFingerprint?>>{};
    Future<HlsVideoFingerprint?> fingerprintAt(int index) => probes.putIfAbsent(
      segments[index].uri,
      () => _safeProbe(probe, segments[index].uri),
    );
    final heads = List<HlsVideoFingerprint?>.filled(groups.length, null);
    await runConcurrent(groups.length, concurrency, (i) async {
      final group = groups[i];
      // 不因一次组首超时漏掉整组；最多补探中间和末尾两片。
      for (final index in {
        group.first,
        group.first + (group.end - group.first) ~/ 2,
        group.end - 1,
      }) {
        if ((heads[i] = await fingerprintAt(index)) != null) return;
      }
    });

    // 按组时长加权投票，取多数指纹作为正片指纹。
    final weights = <HlsVideoFingerprint, double>{};
    for (var i = 0; i < groups.length; i++) {
      final fingerprint = heads[i];
      if (fingerprint == null) continue;
      weights[fingerprint] = (weights[fingerprint] ?? 0) + groups[i].seconds;
    }
    if (weights.isEmpty) return unchanged('没有任何分片指纹可读，跳过去广告');

    final dominant = weights.entries
        .reduce((a, b) => b.value > a.value ? b : a)
        .key;
    if (weights.length == 1) {
      final unknownGroups = heads.where((head) => head == null).length;
      if (unknownGroups > 0) {
        return unchanged('$unknownGroups 个分组指纹读取失败，已保留未确认分片，请重试');
      }
      return unchanged('全部 $dominant，未发现异编码片段');
    }

    // 头部指纹与主体不同的组：逐片确认，只删真正不匹配的分片。
    final drop = <int>{};
    for (var g = 0; g < groups.length; g++) {
      final head = heads[g];
      if (head == null || head.matches(dominant)) continue;
      final group = groups[g];
      final count = group.end - group.first;
      if (count == 1) {
        drop.add(group.first);
        continue;
      }
      final fingerprints = List<HlsVideoFingerprint?>.filled(count, null);
      await runConcurrent(
        count,
        concurrency,
        (i) async => fingerprints[i] = await fingerprintAt(group.first + i),
      );
      for (var k = 0; k < count; k++) {
        final fingerprint = fingerprints[k];
        if (fingerprint != null && !fingerprint.matches(dominant)) {
          drop.add(group.first + k);
        }
      }
    }

    if (drop.isEmpty) return unchanged('主体指纹 $dominant，未发现异编码分片');
    if (drop.length == segments.length) {
      return unchanged('异编码分片覆盖整条清单，判定为多路正片，跳过去广告');
    }

    // Groups and their segments were visited in order; the set preserves it.
    var removedSeconds = 0.0;
    var runSeconds = 0.0;
    int? previous;
    for (final index in drop) {
      final duration = segments[index].duration;
      if (previous != null && index == previous + 1) {
        runSeconds += duration;
      } else {
        if (runSeconds > _maxRunSeconds) {
          return unchanged(
            '存在 ${runSeconds.toStringAsFixed(1)}s 的连续异编码片段，'
            '超过 ${_maxRunSeconds.toStringAsFixed(0)}s 上限，跳过去广告',
          );
        }
        runSeconds = duration;
      }
      previous = index;
      removedSeconds += duration;
    }
    if (runSeconds > _maxRunSeconds) {
      return unchanged(
        '存在 ${runSeconds.toStringAsFixed(1)}s 的连续异编码片段，'
        '超过 ${_maxRunSeconds.toStringAsFixed(0)}s 上限，跳过去广告',
      );
    }
    final fractionLimit = totalSeconds * _maxRemovableFraction;
    if (removedSeconds > fractionLimit) {
      return unchanged(
        '待删 ${removedSeconds.toStringAsFixed(1)}s 超过整条清单 '
        '${totalSeconds.toStringAsFixed(1)}s 的 '
        '${(_maxRemovableFraction * 100).toStringAsFixed(0)}% 上限，跳过去广告',
      );
    }

    final droppedLines = <int>{};
    for (final index in drop) {
      final segment = segments[index];
      for (var line = segment.firstLine; line <= segment.lastLine; line++) {
        droppedLines.add(line);
      }
    }
    // Move the group's boundary onto its first retained segment when its head
    // was removed. Never treat the playlist-level sequence tag as a segment.
    final movedBoundaries = <int>{};
    for (final group in groups) {
      if (!segments[group.first].discontinuityBefore ||
          !drop.contains(group.first)) {
        continue;
      }
      for (var index = group.first; index < group.end; index++) {
        if (!drop.contains(index)) {
          movedBoundaries.add(segments[index].firstLine);
          break;
        }
      }
    }
    final filtered = [
      for (var i = 0; i < playlist.lines.length; i++) ...[
        if (movedBoundaries.contains(i)) '#EXT-X-DISCONTINUITY',
        if (!droppedLines.contains(i)) playlist.lines[i],
      ],
    ].join('\n');

    return HlsAdFilterOutcome(
      manifest: filtered,
      timelineKey:
          'hls:${sha256.convert(utf8.encode(jsonEncode([
            for (var i = 0; i < segments.length; i++) [(segments[i].duration * 1000).round(), drop.contains(i)],
          ])))}',
      removedSegments: drop.length,
      removedSeconds: removedSeconds,
      detail:
          '主体指纹 $dominant，删除 ${drop.length} 个异编码分片，'
          '共 ${removedSeconds.toStringAsFixed(3)}s',
    );
  }

  /// 探测异常按「指纹未知」处理，不影响其余分片判定。
  static Future<HlsVideoFingerprint?> _safeProbe(
    HlsSegmentFingerprintProbe probe,
    Uri uri,
  ) async {
    try {
      SourceOperation.check();
      final result = await probe(uri);
      SourceOperation.check();
      return result;
    } catch (_) {
      SourceOperation.check();
      return null;
    }
  }
}
