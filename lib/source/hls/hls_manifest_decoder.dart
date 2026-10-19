import 'dart:convert';
import 'dart:typed_data';

/// Decodes a rule-declared binary playlist without executing site scripts.
abstract final class HlsManifestDecoder {
  static String decode(List<int> bytes, Map<String, dynamic> declaration) {
    if (declaration['scheme'] != 'xor') {
      throw const FormatException('unsupported HLS manifest decoder');
    }
    final prefixBytes = utf8.encode(declaration['prefix'] as String);
    var matchesPrefix = bytes.length >= prefixBytes.length;
    for (var index = 0; matchesPrefix && index < prefixBytes.length; index++) {
      matchesPrefix = bytes[index] == prefixBytes[index];
    }
    // Plain playlists remain valid when a site changes a line back to normal HLS.
    // Unknown or corrupt responses are left for the playlist validation to reject.
    if (!matchesPrefix) return utf8.decode(bytes);
    final skipBytes = declaration['skipBytes'] as int;
    if (bytes.length <= skipBytes) {
      throw const FormatException('truncated encrypted HLS manifest');
    }

    final key = declaration['key'] as List;
    final period = declaration['period'] as int;
    final fallbackIndex = declaration['fallbackIndex'] as int;
    final xor = declaration['xor'] as int;
    final mask = List<int>.generate(
      period,
      (position) =>
          (key[position < key.length ? position : fallbackIndex] as int) ^ xor,
      growable: false,
    );
    final decoded = Uint8List(bytes.length - skipBytes);
    var position = skipBytes % period;
    for (var index = skipBytes; index < bytes.length; index++) {
      decoded[index - skipBytes] = bytes[index] ^ mask[position];
      if (++position == period) position = 0;
    }
    var manifest = utf8.decode(decoded);
    if (declaration['trimPrefixBeforeM3u8'] == true) {
      final start = manifest.indexOf('#EXTM3U');
      if (start > 0) manifest = manifest.substring(start);
    }
    return manifest;
  }
}
