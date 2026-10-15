import '../support/app_dependencies.dart';
import 'dart:convert';

import 'package:baka/core/api_transport.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/models/skip_segment.dart';
import 'package:baka/services/playback/skip_segments.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/player/skip_selection_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const current = SkipContext(
  sourceKey: 'episode-two',
  seriesKey: 'series-line-a',
  subjectId: 1,
  episodeId: 20,
  episodeNumber: 2,
);
const next = SkipContext(
  sourceKey: 'episode-three',
  seriesKey: 'series-line-a',
  subjectId: 1,
  episodeId: 30,
  episodeNumber: 3,
);
const opening = SkipSegment(
  id: 'local:op',
  type: 'op',
  startMs: 10000,
  endMs: 100000,
  durationMs: 1440000,
  origin: 'local',
  automatic: true,
);
const ending = SkipSegment(
  id: 'local:ed',
  type: 'ed',
  startMs: 1300000,
  endMs: 1390000,
  durationMs: 1440000,
  origin: 'local',
  automatic: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SkipSegmentsService service;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    configurePlaybackServices();
    service = SkipSegmentsService();
  });

  SkipData local(SkipContext context, {int duration = 1440000}) =>
      service.mergeLocal(context, duration, const [], message: 'test');

  test(
    'OP and ED can be applied independently across episodes and durations',
    () async {
      await service.saveLocal(current, opening, allEpisodes: true);
      await service.saveLocal(current, ending);
      expect(local(current).segments.map((s) => s.type), ['op', 'ed']);
      final data = local(next, duration: 1500000);
      expect(data.segments.single.type, 'op');
      expect(data.segments.single.allEpisodes, isTrue);
      expect(data.segments.single.fits(1500000), isTrue);
      await service.saveLocal(current, ending, allEpisodes: true);
      expect(local(next).segments.map((s) => s.type), ['op', 'ed']);
    },
  );

  test(
    'episode correction overrides template; applying again replaces only current correction',
    () async {
      await service.saveLocal(current, opening, allEpisodes: true);
      final correction = SkipSegment.fromJson({
        ...opening.toJson(),
        'start_ms': 12000,
      });
      await service.saveLocal(next, correction);
      await service.saveLocal(current, correction);
      await service.saveLocal(current, opening, allEpisodes: true);
      expect(local(current).segments.single.startMs, 10000);
      expect(local(next).segments.single.startMs, 12000);
      expect(local(next).segments.single.allEpisodes, isFalse);
    },
  );

  test(
    'templates never cross series, line or timeline and never exceed video bounds',
    () async {
      await service.saveLocal(current, opening, allEpisodes: true);
      for (final context in const [
        SkipContext(
          sourceKey: 'another-series',
          seriesKey: 'other-series-line-a',
        ),
        SkipContext(sourceKey: 'other-line', seriesKey: 'series-line-b'),
        SkipContext(
          sourceKey: 'other-cut',
          seriesKey: 'series-line-a',
          timelineKey: 'hls:other',
        ),
        SkipContext(sourceKey: 'unidentified'),
      ]) {
        expect(local(context).segments, isEmpty);
      }
      expect(local(next, duration: 99000).segments, isEmpty);
    },
  );

  test(
    'episode disable is respected without disabling the template for other episodes',
    () async {
      await service.saveLocal(current, opening, allEpisodes: true);
      await service.disable(next, 'op', true);
      expect(local(next).segments, isEmpty);
      expect(local(next).editableSegments.single.type, 'op');
      expect(local(current).segments.single.type, 'op');
      await service.disable(next, 'op', false);
      expect(local(next).segments.single.type, 'op');
    },
  );

  test('legacy episode segments retain strict duration matching', () {
    final legacy = opening.toJson()..remove('scope');
    final segment = SkipSegment.fromJson(legacy);
    expect(segment.allEpisodes, isFalse);
    expect(segment.fits(1500000), isFalse);
    expect(segment.fits(1441000), isTrue);
  });

  void transport(Future<http.Response> Function(http.Request) respond) {
    final client = MockClient(respond);
    addTearDown(client.close);
    apiTransport = ApiTransport(
      session: apiTransport.session,
      client: client,
      version: 'test',
      credentialOrigin: () => Uri.parse('https://www.anibaka.com'),
    );
  }

  test(
    'upload explicitly distinguishes series identity from episode identity',
    () async {
      final bodies = <Map<String, dynamic>>[];
      transport((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        return http.Response(
          jsonEncode({
            'code': 200,
            'data': {'id': 1, 'scope': body['scope']},
          }),
          200,
        );
      });
      await service.submit(current, opening, allEpisodes: true);
      await service.submit(current, ending);
      expect(bodies.first['scope'], 'series');
      expect(bodies.first['source_key'], current.seriesKey);
      expect(bodies.first['episode_id'], 20);
      expect(bodies.last['scope'], 'episode');
      expect(bodies.last['source_key'], current.sourceKey);
    },
  );

  test(
    'old server cannot silently report a series upload as successful',
    () async {
      transport(
        (_) async => http.Response('{"code":200,"data":{"id":1}}', 200),
      );
      await expectLater(
        service.submit(current, opening, allEpisodes: true),
        throwsFormatException,
      );
    },
  );

  test('query and feedback include series identity', () async {
    final requests = <http.Request>[];
    transport((request) async {
      requests.add(request);
      return http.Response('{"code":200,"data":{"segments":[]}}', 200);
    });
    await service.load(next, 1500000);
    await service.feedback(next, opening, true);
    expect(requests.first.url.queryParameters['series_key'], next.seriesKey);
    expect(
      (jsonDecode(requests.last.body) as Map)['series_key'],
      next.seriesKey,
    );
  });

  testWidgets('in-video save menu applies the selected type to all episodes', (
    tester,
  ) async {
    final controller = PlaybackController();
    controller.setSkipContext(current);
    controller.timeline.value = const PlaybackTimelineState(
      duration: Duration(minutes: 24),
    );
    controller.beginSkipSelection('op');
    controller.updateSkipSelection(10000, 100000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SkipSelectionControls(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('save-skip-selection-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('片头应用到全集'));
    await tester.pumpAndSettle();
    expect(controller.skipSelection.value, isNull);
    expect(local(next).segments.single.startMs, 10000);
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });
}
