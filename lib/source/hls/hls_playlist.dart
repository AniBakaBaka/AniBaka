import 'dart:typed_data';

/// Source offsets keep filtering and proxy rendering on the same playlist.
class HlsPlaylist {
  HlsPlaylist.parse(this.body, this.uri) {
    if (!body.startsWith('#EXTM3U')) {
      throw const FormatException('invalid HLS manifest');
    }
    int? blockStart;
    var duration = 0.0;
    var discontinuity = false;
    var groupFirst = 0;
    var groupSeconds = 0.0;
    String? attributes;
    String? variantPath;
    var bandwidth = -1;
    String? resolution;
    var alternativeRenditions = false;

    for (var start = 0; start < body.length;) {
      final newline = body.indexOf('\n', start);
      final end = newline < 0 ? body.length : newline + 1;
      final contentEnd = newline < 0 ? body.length : newline;
      final lineEnd =
          contentEnd > start && body.codeUnitAt(contentEnd - 1) == 13
          ? contentEnd - 1
          : contentEnd;
      final line = body.substring(start, lineEnd).trim();
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        isMaster = true;
        attributes = line.substring(18);
      } else if (line.startsWith('#EXT-X-MEDIA:')) {
        alternativeRenditions = true;
      } else if (line == '#EXT-X-ENDLIST') {
        isVod = true;
      } else if (line.startsWith('#EXTINF:')) {
        blockStart ??= start;
        final comma = line.indexOf(',', 8);
        duration = double.parse(line.substring(8, comma < 0 ? null : comma));
      } else if (line == '#EXT-X-DISCONTINUITY') {
        blockStart ??= start;
        discontinuity = true;
      } else if (line.startsWith('#EXT-X-KEY:') ||
          line.startsWith('#EXT-X-MAP:') ||
          line.startsWith('#EXT-X-BYTERANGE:')) {
        canFilter = false;
      } else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:') ||
          line.startsWith('#EXT-X-DATERANGE:') ||
          line.startsWith('#EXT-X-CUE') ||
          line.startsWith('#EXT-X-BITRATE:')) {
        blockStart ??= start;
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        if (attributes != null) {
          final value = int.parse(_bandwidth.firstMatch(attributes)!.group(1)!);
          if (value > bandwidth) {
            bandwidth = value;
            resolution = _resolution.firstMatch(attributes)?.group(1);
            variantPath = line;
          }
          attributes = null;
        } else if (!isMaster) {
          if (discontinuity && segments.length > groupFirst) {
            groups.add((
              first: groupFirst,
              end: segments.length,
              seconds: groupSeconds,
            ));
            groupFirst = segments.length;
            groupSeconds = 0;
          }
          segments.add((
            start: blockStart ?? start,
            end: end,
            uriStart: start,
            uriEnd: lineEnd,
            duration: duration,
            discontinuity: discontinuity,
          ));
          groupSeconds += duration;
          totalSeconds += duration;
          blockStart = null;
          duration = 0;
          discontinuity = false;
        }
      }
      start = end;
    }
    if (groupFirst < segments.length) {
      groups.add((
        first: groupFirst,
        end: segments.length,
        seconds: groupSeconds,
      ));
    }
    if (!alternativeRenditions && variantPath != null) {
      variant = (
        uri: uri.resolve(variantPath),
        bandwidth: bandwidth,
        resolution: resolution,
      );
    }
  }

  static final _bandwidth = RegExp(r'(?:^|,)BANDWIDTH=(\d+)(?=,|$)');
  static final _resolution = RegExp(
    r'(?:^|,)RESOLUTION=([0-9]+x[0-9]+)(?=,|$)',
  );
  static final _uriAttribute = RegExp(r'URI="([^"]+)"');

  final String body;
  final Uri uri;
  final segments =
      <
        ({
          int start,
          int end,
          int uriStart,
          int uriEnd,
          double duration,
          bool discontinuity,
        })
      >[];
  final groups = <({int first, int end, double seconds})>[];
  ({Uri uri, int bandwidth, String? resolution})? variant;
  bool isMaster = false;
  bool isVod = false;
  bool canFilter = true;
  double totalSeconds = 0;
  Uint8List? removed;

  Uri segmentUri(int index) {
    final segment = segments[index];
    return uri.resolve(body.substring(segment.uriStart, segment.uriEnd).trim());
  }

  /// Renders once, optionally rewriting resource URIs for the playback proxy.
  String render({String Function(Uri uri, bool isSegment)? rewrite}) {
    if (removed == null && rewrite == null) return body;
    final output = StringBuffer();
    void writeTags(int start, int end) {
      if (start == end) return;
      final text = body.substring(start, end);
      output.write(
        rewrite == null
            ? text
            : text.replaceAllMapped(
                _uriAttribute,
                (match) =>
                    'URI="${rewrite(uri.resolve(match.group(1)!), false)}"',
              ),
      );
    }

    var cursor = 0;
    var boundary = false;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      writeTags(cursor, segment.start);
      boundary |= segment.discontinuity;
      if (removed?[i] != 1) {
        if (boundary && !segment.discontinuity) {
          output.write('#EXT-X-DISCONTINUITY\n');
        }
        writeTags(segment.start, segment.uriStart);
        output.write(
          rewrite == null
              ? body.substring(segment.uriStart, segment.uriEnd)
              : rewrite(segmentUri(i), true),
        );
        output.write(body.substring(segment.uriEnd, segment.end));
        boundary = false;
      }
      cursor = segment.end;
    }
    writeTags(cursor, body.length);
    return output.toString();
  }
}
