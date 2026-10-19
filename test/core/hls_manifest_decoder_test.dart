import 'dart:convert';

import 'package:baka/source/hls/hls_manifest_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

const _animoeDecoder = <String, dynamic>{
  'scheme': 'xor',
  'prefix': 'enc',
  'key': [144, 223, 214, 167, 22, 76, 53],
  'period': 10,
  'fallbackIndex': 6,
  'xor': 165,
  'skipBytes': 3,
  'trimPrefixBeforeM3u8': true,
};

void main() {
  test('decodes a fixed XOR fixture without mutating its bytes', () {
    final bytes = base64Decode(
      'ZW5jIfaxxN2jxT9ZNlrnxMi9xtVnKTpN/dOnmrPVbS5eWp6s3tTc2WYueQ==',
    );
    final original = List<int>.of(bytes);
    expect(
      HlsManifestDecoder.decode(bytes, _animoeDecoder),
      '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-ENDLIST\n',
    );
    expect(bytes, original);
  });

  test('accepts plain HLS and leaves unknown prefixes unchanged', () {
    const plain = '#EXTM3U\n#EXT-X-ENDLIST\n';
    expect(
      HlsManifestDecoder.decode(utf8.encode(plain), _animoeDecoder),
      plain,
    );
    expect(
      HlsManifestDecoder.decode(utf8.encode('other body'), _animoeDecoder),
      'other body',
    );
  });

  test('rejects truncated, corrupt and unsupported binary decoding', () {
    for (final bytes in [
      [101, 110, 99],
      [101, 110, 99, 0, 0, 0, 0],
    ]) {
      expect(
        () => HlsManifestDecoder.decode(bytes, _animoeDecoder),
        throwsFormatException,
      );
    }
    expect(
      () => HlsManifestDecoder.decode(
        [101, 110, 99, 1],
        {..._animoeDecoder, 'scheme': 'unknown'},
      ),
      throwsFormatException,
    );
  });
}
