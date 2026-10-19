import 'dart:math' as math;
import 'dart:typed_data';

import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';

/// Streams MPEG-TS after removing a bounded image/junk prefix when requested by
/// a rule. Unknown bodies pass through unchanged; whole segments are not buffered.
abstract final class HlsTsPrefix {
  static Stream<Uint8List> strip(
    Stream<Uint8List> source, {
    required void Function(int removedBytes) onTransportStream,
  }) async* {
    Uint8List? pending;
    var length = 0;
    var searched = 0;
    var probing = true;
    await for (final chunk in source) {
      if (!probing) {
        yield chunk;
        continue;
      }
      final count = math.min(
        chunk.length,
        MpegTsFingerprint.probeBytes - length,
      );
      Uint8List bytes;
      if (pending == null) {
        bytes = Uint8List.sublistView(chunk, 0, count);
      } else {
        pending.setRange(length, length + count, chunk);
        bytes = Uint8List.sublistView(pending, 0, length + count);
      }
      length += count;
      final start = MpegTsFingerprint.findPacketStart(bytes, from: searched);
      if (start == null && length < MpegTsFingerprint.probeBytes) {
        pending ??= Uint8List(MpegTsFingerprint.probeBytes)
          ..setRange(0, length, bytes);
        searched = math.max(0, length - MpegTsFingerprint.packetSize * 2);
        continue;
      }
      probing = false;
      if (start != null) onTransportStream(start);
      yield start == null ? bytes : Uint8List.sublistView(bytes, start);
      if (count < chunk.length) yield Uint8List.sublistView(chunk, count);
      pending = null;
    }
    if (pending != null && length > 0) {
      yield Uint8List.sublistView(pending, 0, length);
    }
  }
}
