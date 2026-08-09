import 'dart:convert';

import 'package:baka/services/source/source_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const config = <String, dynamic>{
    'id': 'example',
    'name': 'Example',
    'pipeline': <String, dynamic>{
      'search': <Object>[],
      'detail': <Object>[],
      'play': <Object>[],
    },
  };

  test('baka format round-trips compressed JSON', () {
    final encoded = SourceCodec.encode(config);

    expect(encoded, startsWith(SourceCodec.scheme));
    expect(SourceCodec.decode(encoded), config);
  });

  test('bakax format round-trips encrypted JSON', () {
    final encrypted = SourceCodec.encrypt(config);

    expect(encrypted, startsWith(SourceCodec.encryptedScheme));
    expect(SourceCodec.decode(encrypted), config);
  });

  test('decoder accepts naked JSON collections', () {
    expect(SourceCodec.decode(jsonEncode([config])), [config]);
  });

  test('decoder rejects empty and malformed input', () {
    expect(() => SourceCodec.decode(''), throwsFormatException);
    expect(() => SourceCodec.decode('not-a-rule'), throwsFormatException);
    final legacy = base64.encode(utf8.encode(jsonEncode(config)));
    expect(
      () => SourceCodec.decode('${SourceCodec.scheme}$legacy'),
      throwsA(anything),
    );
  });
}
