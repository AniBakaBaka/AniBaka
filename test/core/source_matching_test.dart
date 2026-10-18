import 'package:baka/source/models/source_search_result.dart';
import 'dart:async';
import 'dart:convert';
import 'package:baka/instance.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/matching/media_readiness.dart';
import 'package:baka/services/matching/probe_scheduler.dart';
import 'package:baka/services/matching/source_match_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<SourceMatchScore> rank(
    List<SourceSearchResult> items,
    SourceMatchContext context,
  ) =>
      [for (final item in items) const SourceMatchEngine().score(item, context)]
        ..sort(SourceMatchEngine.compareScores);

  group('ranking', () {
    SourceSearchResult candidate(
      String key,
      String title, {
      required String source,
      required int episodes,
    }) {
      return SourceSearchResult.internal({
        'id': key,
        'title': title,
        'videoList': List.filled(episodes, 'Episode'),
      });
    }

    test('prefers the matching season with the expected episode count', () {
      final context = SourceMatchContext(
        primaryTitle: 'Example 第二季',
        bgmEpisodeCount: 24,
        querySeason: 2,
      );

      final ranked = rank([
        candidate('a', 'Example', source: 'source_a', episodes: 12),
        candidate('b', 'Example 第二季', source: 'source_b', episodes: 24),
      ], context);

      expect(ranked.first.candidate.id, 'b');
      expect(ranked.first.confidence, greaterThanOrEqualTo(0.8));
      expect(ranked.last.seasonConflict, isFalse);
      expect(ranked.first.score, greaterThan(ranked.last.score));
    });

    test('penalizes movie candidates when BGM expects a TV season', () {
      final context = SourceMatchContext(
        primaryTitle: 'Example',
        bgmEpisodeCount: 12,
      );

      final ranked = rank([
        candidate('movie', 'Example 剧场版', source: 'source_a', episodes: 1),
        candidate('tv', 'Example TV', source: 'source_b', episodes: 12),
      ], context);

      expect(ranked.first.candidate.id, 'tv');
      expect(
        ranked.first.score,
        greaterThan(ranked.firstWhere((s) => s.candidate.id == 'movie').score),
      );
    });

    test(
      'penalizes package resources that greatly exceed BGM episode count',
      () {
        final context = SourceMatchContext(
          primaryTitle: 'Example',
          bgmEpisodeCount: 12,
        );

        final ranked = rank([
          candidate('pack', 'Example 合集', source: 'source_a', episodes: 48),
          candidate('single', 'Example', source: 'source_b', episodes: 12),
        ], context);

        final pack = ranked.firstWhere((s) => s.candidate.id == 'pack');
        expect(ranked.first.candidate.id, 'single');
        expect(pack.severeEpisodeConflict, isTrue);
        expect(pack.confidence, lessThan(0.70));
      },
    );

    test('penalizes title similarity when modifiers differ (movie vs tv)', () {
      final context = SourceMatchContext(primaryTitle: '海贼王');
      final ranked = rank([
        candidate('movie', '海贼王 剧场版 红发歌姬', source: 's1', episodes: 1),
        candidate('tv', '海贼王', source: 's2', episodes: 1000),
      ], context);

      expect(ranked.first.candidate.id, 'tv');
      final movieScore = ranked.firstWhere((s) => s.candidate.id == 'movie');
      expect(movieScore.confidence, lessThan(0.70));
    });
  });

  group('admission', () {
    const engine = SourceMatchEngine();

    SourceSearchResult candidate(
      String key,
      String title, {
      required int episodes,
    }) => SourceSearchResult.internal({
      'id': key,
      'title': title,
      'videoList': List.filled(episodes, 'Episode'),
    });

    test('admits an exact match into the probe queue', () {
      final score = engine.score(
        candidate('exact', 'Example', episodes: 12),
        SourceMatchContext(primaryTitle: 'Example', bgmEpisodeCount: 12),
      );

      expect(score.confidence, 1);
      expect(score.shouldProbeImmediately, isTrue);
    });

    test(
      'rejects other works containing a short title from search results',
      () {
        // Titles returned by the rule hub when searching for 深海.
        for (final title in [
          '深海危情',
          '深海历险记',
          '深海危情 动态漫画',
          '二郎神之深海蛟龙',
          '海绵宝宝：深海大冒险',
          '猪猪侠之深海小英雄',
          '军曹大电影2：深海的公主是也',
          '深海鱼',
        ]) {
          final score = engine.score(
            candidate(title, title, episodes: 1),
            SourceMatchContext(primaryTitle: '深海', bgmEpisodeCount: 1),
          );
          expect(
            score.confidence,
            lessThan(SourceMatchEngine.admissionConfidence),
            reason: title,
          );
          expect(score.shouldProbeImmediately, isFalse, reason: title);
        }
      },
    );

    test('keeps exact short titles, release tags and explicit aliases', () {
      for (final title in ['深海', '深海【国语】', '深海 (1080p)']) {
        final score = engine.score(
          candidate(title, title, episodes: 1),
          SourceMatchContext(primaryTitle: '深海', bgmEpisodeCount: 1),
        );
        expect(score.shouldProbeImmediately, isTrue, reason: title);
      }
      final alias = engine.score(
        candidate('alias', 'Deep Sea', episodes: 1),
        SourceMatchContext(primaryTitle: '深海', manualAliases: ['Deep Sea']),
      );
      expect(alias.shouldProbeImmediately, isTrue);
    });

    test(
      'rejects short substrings in either direction and in Latin titles',
      () {
        for (final (query, title) in [
          ('深海危情', '深海'),
          ('龙珠', '龙珠超'),
          ('AIR', 'FAIRY'),
          ('K', 'K-ON!'),
        ]) {
          final score = engine.score(
            candidate(title, title, episodes: 12),
            SourceMatchContext(primaryTitle: query, bgmEpisodeCount: 12),
          );
          expect(
            score.confidence,
            lessThan(SourceMatchEngine.admissionConfidence),
            reason: '$query -> $title',
          );
          expect(score.shouldProbeImmediately, isFalse);
        }
      },
    );

    test(
      'rejects season and severe episode conflicts from the probe queue',
      () {
        final season = engine.score(
          candidate('season', 'Example 第二季', episodes: 12),
          SourceMatchContext(primaryTitle: 'Example', querySeason: 1),
        );
        expect(season.seasonConflict, isTrue);
        expect(season.shouldProbeImmediately, isFalse);

        final pack = engine.score(
          candidate('pack', 'Example', episodes: 24),
          SourceMatchContext(primaryTitle: 'Example', bgmEpisodeCount: 12),
        );
        expect(pack.severeEpisodeConflict, isTrue);
        expect(pack.shouldProbeImmediately, isFalse);
      },
    );

    test('rejects unrelated titles from the probe queue', () {
      final score = engine.score(
        candidate('other', 'Totally Different Show', episodes: 12),
        SourceMatchContext(primaryTitle: 'Example'),
      );

      // 子串判定是唯一的相似度算法：不构成子串即 0 分。
      expect(score.titleSimilarity, 0);
      expect(
        score.confidence,
        lessThan(SourceMatchEngine.immediateProbeConfidence),
      );
      expect(score.shouldProbeImmediately, isFalse);
    });
  });

  test(
    'media readiness distinguishes media, torrents and unresolved pages',
    () {
      for (final (url, kind) in [
        ('https://cdn.example.com/ep1/index.m3u8', MediaTokenKind.directMedia),
        ('https://cdn.example.com/a.mp4?token=1', MediaTokenKind.directMedia),
        ('magnet:?xt=urn:btih:abcdef', MediaTokenKind.torrent),
        (
          'https://site.example.com/play/12345.html',
          MediaTokenKind.needsResolve,
        ),
        (
          'https://site.example.com/vod/detail/id/9',
          MediaTokenKind.needsResolve,
        ),
        ('/bangumi/12/episode/3', MediaTokenKind.needsResolve),
        ('ep-12-line-1', MediaTokenKind.needsResolve),
      ]) {
        expect(MediaReadiness.classify(url), kind, reason: url);
      }
      expect(
        MediaReadiness.isAcceptablePlaybackUrl(
          'https://cdn.example.com/hls/index.m3u8',
        ),
        isTrue,
      );
      expect(
        MediaReadiness.isAcceptablePlaybackUrl(
          'https://site.example.com/play/1.html',
        ),
        isFalse,
      );
      expect(MediaReadiness.isAcceptablePlaybackUrl(''), isFalse);
    },
  );

  group('match memory', () {
    test(
      'bounded writes preserve newest entries and remove expired data',
      () async {
        final now = DateTime.now().millisecondsSinceEpoch;
        SharedPreferences.setMockInitialValues({
          'match_memory_v1': jsonEncode({
            for (var i = 1; i <= 205; i++)
              'bgm:$i': {
                'source': 'test',
                'seriesId': '$i',
                'updatedAtMs': now - 10000 + i,
              },
            'bgm:999': {
              'source': 'test',
              'seriesId': 'expired',
              'updatedAtMs': 0,
            },
          }),
        });
        Instances.sp = await SharedPreferences.getInstance();
        expect(MatchMemoryService.read(title: '', bgmId: 1), isNull);
        expect(MatchMemoryService.read(title: '', bgmId: 999), isNull);
        expect(MatchMemoryService.read(title: '', bgmId: 6)?.seriesId, '6');
        await MatchMemoryService.writeSuccess(
          title: '',
          bgmId: 6,
          source: 'updated',
          seriesId: 'new',
        );
        await MatchMemoryService.writeSuccess(
          title: '',
          bgmId: 206,
          source: 'test',
          seriesId: '206',
        );
        expect(MatchMemoryService.read(title: '', bgmId: 6)?.source, 'updated');
        expect(MatchMemoryService.read(title: '', bgmId: 7), isNull);
        expect(MatchMemoryService.read(title: '', bgmId: 206)?.seriesId, '206');
        expect(
          (jsonDecode(Instances.sp.getString('match_memory_v1')!) as Map)
              .length,
          200,
        );
        await MatchMemoryService.remove(title: '', bgmId: 206);
        expect(MatchMemoryService.read(title: '', bgmId: 206), isNull);
      },
    );
  });

  group('probes', () {
    group('ProbeScheduler', () {
      test('runs jobs with bounded concurrency', () async {
        final started = <int>[];
        final gates = <int, Completer<void>>{};
        final scheduler = ProbeScheduler<int>(
          concurrency: 2,
          keyOf: (job) => '$job',
          run: (job) {
            started.add(job);
            return (gates[job] = Completer<void>()).future;
          },
        );

        for (var job = 1; job <= 5; job++) {
          expect(scheduler.add(job), isTrue);
        }
        expect(started, [1, 2]);
        expect(scheduler.isBusy, isTrue);

        gates[1]!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(started, [1, 2, 3]);

        gates[2]!.complete();
        gates[3]!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(started, [1, 2, 3, 4, 5]);

        gates[4]!.complete();
        gates[5]!.complete();
        await scheduler.drained;
        expect(scheduler.isBusy, isFalse);
      });

      test('accepts each key once per run', () async {
        final runs = <String>[];
        final scheduler = ProbeScheduler<String>(
          concurrency: 2,
          keyOf: (job) => job,
          run: (job) async => runs.add(job),
        );

        expect(scheduler.add('a'), isTrue);
        expect(scheduler.add('a'), isFalse);
        await scheduler.drained;
        expect(scheduler.add('a'), isFalse);
        expect(runs, ['a']);
      });

      test(
        'close discards queued work and lets in-flight jobs settle',
        () async {
          final started = <int>[];
          final gate = Completer<void>();
          final scheduler = ProbeScheduler<int>(
            concurrency: 1,
            keyOf: (job) => '$job',
            run: (job) async {
              started.add(job);
              await gate.future;
            },
          );

          scheduler.add(1);
          scheduler.add(2);
          scheduler.close();
          expect(scheduler.isClosed, isTrue);
          expect(scheduler.add(3), isFalse);

          gate.complete();
          await scheduler.drained;
          expect(started, [1]);
          expect(scheduler.isBusy, isFalse);
        },
      );

      test('a failing job does not stop the remaining queue', () async {
        final runs = <int>[];
        final scheduler = ProbeScheduler<int>(
          concurrency: 2,
          keyOf: (job) => '$job',
          run: (job) async {
            if (job == 1) throw StateError('boom');
            runs.add(job);
          },
        );

        scheduler.add(1);
        scheduler.add(2);
        await scheduler.drained;
        expect(runs, [2]);
        expect(scheduler.isBusy, isFalse);
      });
    });
  });
}
