import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:baka/source/hls/hls_playlist.dart';
import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';
import 'package:baka/source/runtime/source_operation.dart';

class HlsAdFilterOutcome {
  const HlsAdFilterOutcome({
    required this.detail,
    this.removedSegments = 0,
    this.removedSeconds = 0,
    this.timelineKey = 'original',
  });

  final int removedSegments;
  final double removedSeconds;
  final String detail;
  final String timelineKey;
  bool get changed => removedSegments > 0;
}

/// Samples each discontinuity group, then confirms only mismatching segments.
abstract final class HlsAdFilter {
  static const double _maxRunSeconds = 60;
  static const double _maxRemovableFraction = 0.15;

  static Future<HlsAdFilterOutcome> apply(
    HlsPlaylist playlist, {
    required Future<HlsVideoFingerprint?> Function(Uri) probe,
    int concurrency = 4,
  }) async {
    assert(concurrency > 0);
    SourceOperation.check();
    if (!playlist.canFilter) {
      return const HlsAdFilterOutcome(detail: '加密、初始化段或字节范围清单保持原样');
    }
    final segments = playlist.segments;
    final groups = playlist.groups;
    final totalSeconds = playlist.totalSeconds;
    if (segments.length < 4 || groups.length < 2 || totalSeconds <= 0) {
      return const HlsAdFilterOutcome(detail: '分片或分组过少，跳过去广告');
    }

    final probes = <Uri, Future<HlsVideoFingerprint?>>{};
    Future<HlsVideoFingerprint?> fingerprintAt(int index) {
      SourceOperation.check();
      final uri = playlist.segmentUri(index);
      return probes.putIfAbsent(uri, () => probe(uri));
    }

    final heads = List<HlsVideoFingerprint?>.filled(groups.length, null);
    await runConcurrent(groups.length, concurrency, (i) async {
      heads[i] = await fingerprintAt(groups[i].first);
    });
    SourceOperation.check();

    final weights = <HlsVideoFingerprint, double>{};
    for (var i = 0; i < groups.length; i++) {
      final head = heads[i];
      if (head != null) {
        weights[head] = (weights[head] ?? 0) + groups[i].seconds;
      }
    }
    if (weights.isEmpty) {
      return const HlsAdFilterOutcome(detail: '没有任何分片指纹可读，跳过去广告');
    }
    final dominant = weights.entries
        .reduce((a, b) => b.value > a.value ? b : a)
        .key;
    if (weights.length == 1) {
      return HlsAdFilterOutcome(detail: '全部已知分组为 $dominant，未发现异编码片段');
    }

    final drop = Uint8List(segments.length);
    // One lazy queue shares the concurrency limit across all suspect groups.
    Iterable<int> candidates() sync* {
      for (var g = 0; g < groups.length; g++) {
        if (heads[g] == null || heads[g] == dominant) continue;
        final group = groups[g];
        drop[group.first] = 1;
        for (var i = group.first + 1; i < group.end; i++) {
          yield i;
        }
      }
    }

    final pending = candidates().iterator;
    await runConcurrent(concurrency, concurrency, (_) async {
      while (pending.moveNext()) {
        final index = pending.current;
        final fingerprint = await fingerprintAt(index);
        if (fingerprint != null && fingerprint != dominant) drop[index] = 1;
      }
    });
    SourceOperation.check();

    var removedSeconds = 0.0;
    var removedSegments = 0;
    var runSeconds = 0.0;
    for (var i = 0; i < segments.length; i++) {
      if (drop[i] == 0) {
        runSeconds = 0;
        continue;
      }
      removedSegments++;
      removedSeconds += segments[i].duration;
      runSeconds += segments[i].duration;
      if (runSeconds > _maxRunSeconds) {
        return HlsAdFilterOutcome(
          detail:
              '存在 ${runSeconds.toStringAsFixed(1)}s 的连续异编码片段，超过 60s 上限，跳过去广告',
        );
      }
    }
    if (removedSeconds > totalSeconds * _maxRemovableFraction) {
      return HlsAdFilterOutcome(
        detail:
            '待删 ${removedSeconds.toStringAsFixed(1)}s 超过整条清单 ${totalSeconds.toStringAsFixed(1)}s 的 15% 上限，跳过去广告',
      );
    }

    // Preserve existing timeline IDs without building a nested JSON list.
    var timelineKey = '';
    final hash = sha256.startChunkedConversion(
      ChunkedConversionSink.withCallback(
        (digests) => timelineKey = 'hls:${digests.single}',
      ),
    );
    final encoded = utf8.encoder.startChunkedConversion(hash)..add('[');
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) encoded.add(',');
      encoded.add('[${(segments[i].duration * 1000).round()},${drop[i] == 1}]');
    }
    encoded
      ..add(']')
      ..close();
    playlist.removed = drop;
    return HlsAdFilterOutcome(
      timelineKey: timelineKey,
      removedSegments: removedSegments,
      removedSeconds: removedSeconds,
      detail:
          '主体指纹 $dominant，删除 $removedSegments 个异编码分片，共 ${removedSeconds.toStringAsFixed(3)}s',
    );
  }
}
