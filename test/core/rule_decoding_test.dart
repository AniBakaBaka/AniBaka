import 'dart:convert';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/source/engine/anime_rule_ops.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('JSON paths select the first existing candidate', () {
    for (final (input, path, expected) in <(Object, String, Object?)>[
      (
        {
          'data': {'url': 'video.m3u8'},
        },
        'data.url',
        'video.m3u8',
      ),
      (
        {
          'data': {'url': 'video.m3u8'},
        },
        'data.url|data',
        'video.m3u8',
      ),
      ({'data': 'direct.mp4'}, 'data.url|data', 'direct.mp4'),
      ({'data': {}}, 'data.url|data.missing', null),
    ]) {
      expect(
        AnimeRuleOps.jsonPath(input, path),
        expected,
        reason: '$input / $path',
      );
    }
  });

  group('mapped base64', () {
    String decode(String text, Map<String, String> map) =>
        AnimeRuleOps.decodeMappedBase64(base64.encode(utf8.encode(text)), map);
    test(
      'longest token wins; unmatched Unicode and empty replacements survive',
      () {
        expect(
          decode('ababa😀!?', {
            'a': '1',
            'ab': '2',
            'aba': '3',
            '😀': '',
            '': 'ignored',
          }),
          '3b1!?',
        );
        expect(decode('未命中😀', {'abc': 'x'}), '未命中😀');
      },
    );
  });

  group('source codec', () {
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

    test('decoder imports existing bakax links', () {
      const encrypted =
          'bakax://aGVhmIB10XI5jabJQuHb7rKI47U8gj7PJVc3wQOUl1ZaZbMdwNyueMcbM1YbTAD1zkeSqp9G20Z4FWo4YxNaKmN-NwC5h7YCx19yyLrr9t-9hyZcowGkhqmOoRM4LRQnFyBH2iKZt3RgD-2YKyl4cg';
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
  });
}
