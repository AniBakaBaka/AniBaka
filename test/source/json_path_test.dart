import 'package:test/test.dart';
import 'package:baka/source/engine/anime_rule_ops.dart';

void main() {
  group('AnimeRuleOps.jsonPath', () {
    test('standard single path extraction', () {
      final json = {
        'code': 0,
        'data': {
          'url': 'https://example.com/video.m3u8',
          'title': 'Test Video',
        },
      };
      expect(
        AnimeRuleOps.jsonPath(json, 'data.url'),
        equals('https://example.com/video.m3u8'),
      );
    });

    test('fallback with pipe delimiter when first path succeeds', () {
      final json = {
        'code': 0,
        'data': {
          'name': '正片',
          'url': 'https://example.com/stream.m3u8',
        },
      };
      expect(
        AnimeRuleOps.jsonPath(json, 'data.url|data'),
        equals('https://example.com/stream.m3u8'),
      );
    });

    test('fallback to second path when first path is missing', () {
      final json = {
        'code': 0,
        'data': 'https://example.com/direct.mp4',
      };
      expect(
        AnimeRuleOps.jsonPath(json, 'data.url|data'),
        equals('https://example.com/direct.mp4'),
      );
    });

    test('fallback returns null if all candidate paths fail', () {
      final json = {
        'code': 0,
        'data': {},
      };
      expect(
        AnimeRuleOps.jsonPath(json, 'data.url|data.non_existent'),
        isNull,
      );
    });
  });
}
