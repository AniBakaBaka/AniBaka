import 'dart:async';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_episode.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/matching/match_memory_service.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source_search_result.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/widgets/anime_detail/controller/video_source_search_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

SourceSearchResult result([String id = 'one', String source = 'test']) =>
    SourceSearchResult(
      Series(id, 'Example'),
      source: source,
      displayName: source,
    );

PlaybackRequest catalog(List<List<String>> lines, {String source = 'test'}) =>
    PlaybackRequest(
      source: source,
      episodes: [
        for (final values in lines)
          PlaybackEpisode(title: 'Episode', lines: values),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Repository repository;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    sourceCatalog = _Catalog();
    repository = _Repository(sourceCatalog);
    sourceRepository = repository;
    addTearDown(sourceCatalog.dispose);
    addTearDown(repository.dispose);
  });
  tearDown(() => VideoSourceSearchController.globalCached?.dispose());

  test('concurrent probes share one request and immutable catalog', () async {
    repository.data = catalog([
      ['direct'],
    ]);
    final controller = _Controller();
    addTearDown(controller.dispose);
    final item = result();
    final a = controller.ensureCandidatePlayable(
      item,
      episodeIndex: 0,
      preferredLine: 1,
    );
    final b = controller.ensureCandidatePlayable(
      item,
      episodeIndex: 0,
      preferredLine: 1,
    );
    expect(a, same(b));
    final probe = await a;
    expect(probe, same(await b));
    expect(probe.isInstantPlayable, isTrue);
    expect(repository.loads, 1);
    expect(controller.calls, ['direct']);
    expect(probe.data!.episodes, same(repository.data.episodes));
    expect(repository.data.prefetched, isNull);
    expect(repository.data.lineIndex, isNull);
    expect(
      await controller.ensureCandidatePlayable(
        item,
        episodeIndex: 0,
        preferredLine: 1,
      ),
      same(probe),
    );
  });

  test('transfers the latest detail controller to the player', () {
    final first = VideoSourceSearchController(title: 'Example');
    final next = VideoSourceSearchController(title: 'Other');
    VideoSourceSearchController.cacheGlobal(first);
    VideoSourceSearchController.cacheGlobal(next);
    expect(first.isDisposed, isTrue);
    final taken = VideoSourceSearchController.takeCachedFor(title: 'Other')!;
    addTearDown(taken.dispose);
    expect(taken, same(next));
    expect(VideoSourceSearchController.globalCached, isNull);
  });

  test('slow resolution stays pending until its actual result', () async {
    repository.data = catalog([
      ['slow'],
    ]);
    final controller = _Controller()..pending['slow'] = Completer<String>();
    addTearDown(controller.dispose);
    final work = controller.ensureCandidatePlayable(
      result(),
      episodeIndex: 0,
      preferredLine: 1,
      raceMode: true,
    );
    await controller.started.future;
    expect(
      await Future.any<SourceProbeState?>([work, Future.value(null)]),
      isNull,
    );
    controller.pending['slow']!.complete('https://fixture.test/slow.mp4');
    expect((await work).isInstantPlayable, isTrue);
    expect(controller.calls.length, 1);
  });

  test('deadline cancels work and never adopts a late result', () async {
    repository.data = catalog([
      ['slow'],
    ]);
    final controller = _Controller(timeout: const Duration(milliseconds: 30))
      ..pending['slow'] = Completer<String>();
    addTearDown(controller.dispose);
    final probe = await controller.ensureCandidatePlayable(
      result(),
      episodeIndex: 0,
      preferredLine: 1,
      raceMode: true,
    );
    expect(probe.status, SourceProbeStatus.failed);
    expect(probe.isReady, isFalse);
    expect(controller.operations.single.isCancelled, isTrue);
    controller.pending['slow']!.complete('https://fixture.test/late.mp4');
    await Future<void>.delayed(Duration.zero);
    expect(probe.status, SourceProbeStatus.failed);
    expect(probe.data, isNull);
  });

  test('first ready line cancels siblings and deduplicates tokens', () async {
    repository.data = catalog([
      ['slow', 'slow', 'fast'],
    ]);
    final controller = _Controller()..pending['slow'] = Completer<String>();
    addTearDown(controller.dispose);
    final probe = await controller.ensureCandidatePlayable(
      result(),
      episodeIndex: 0,
      preferredLine: 1,
      raceMode: true,
    );
    expect(controller.calls, ['slow', 'fast']);
    expect(probe.data!.lineIndex, 3);
    expect(probe.data!.prefetched!.episodeId, 'fast');
    expect(controller.operations.every((op) => op.isCancelled), isTrue);
    controller.pending['slow']!.complete('https://fixture.test/late.mp4');
    await Future<void>.delayed(Duration.zero);
    expect(probe.data!.prefetched!.episodeId, 'fast');
  });

  test('manual probes scan sparse unique lines sequentially', () async {
    repository.data = catalog([
      ['', 'bad', 'bad', 'fast'],
    ]);
    final controller = _Controller()..fail.add('bad');
    addTearDown(controller.dispose);
    final probe = await controller.ensureCandidatePlayable(
      result(),
      episodeIndex: 0,
      preferredLine: 1,
    );
    expect(controller.calls, ['bad', 'fast']);
    expect(probe.isInstantPlayable, isTrue);
    expect(probe.resolvedLineIndex, 4);
  });

  test(
    'missing episode and empty lines cannot fall back to episode zero',
    () async {
      repository.data = catalog([
        [],
        ['valid'],
      ]);
      final controller = _Controller();
      addTearDown(controller.dispose);
      final missing = await controller.ensureCandidatePlayable(
        result(),
        episodeIndex: 20,
        preferredLine: 1,
      );
      final empty = await controller.ensureCandidatePlayable(
        result(),
        episodeIndex: 0,
        preferredLine: 1,
      );
      expect(missing.isReady, isFalse);
      expect(empty.isReady, isFalse);
      expect(controller.calls, isEmpty);
    },
  );

  test(
    'changing episode cancels stale probes and reuses the catalog',
    () async {
      repository.data = catalog([
        ['slow'],
        ['fast'],
      ]);
      final controller = _Controller()..pending['slow'] = Completer<String>();
      addTearDown(controller.dispose);
      final item = result();
      final old = controller.ensureCandidatePlayable(
        item,
        episodeIndex: 0,
        preferredLine: 1,
      );
      final cancelled = expectLater(
        old,
        throwsA(isA<RequestCancelledException>()),
      );
      await controller.started.future;
      final next = await controller.ensureCandidatePlayable(
        item,
        episodeIndex: 1,
        preferredLine: 1,
      );
      await cancelled;
      expect(next.data!.episodeIndex, 1);
      expect(repository.loads, 1);
      controller.pending['slow']!.complete('https://fixture.test/late.mp4');
      await Future<void>.delayed(Duration.zero);
      expect(next.data!.prefetched!.episodeId, 'fast');
    },
  );

  test(
    'changing selection cancels an unfinished catalog and starts a fresh one',
    () async {
      repository.catalogGate = Completer<void>();
      repository.data = catalog([
        ['old'],
        ['new'],
      ]);
      final controller = _Controller();
      addTearDown(controller.dispose);
      final item = result();
      final old = controller.ensureCandidatePlayable(
        item,
        episodeIndex: 0,
        preferredLine: 1,
      );
      final rejected = expectLater(
        old,
        throwsA(isA<RequestCancelledException>()),
      );
      await repository.catalogStarted.future;
      final oldOperation = repository.catalogOperation!;
      final oldGate = repository.catalogGate!;
      repository.catalogGate = null;
      final next = await controller.ensureCandidatePlayable(
        item,
        episodeIndex: 1,
        preferredLine: 1,
      );
      await rejected;
      expect(oldOperation.isCancelled, isTrue);
      expect(repository.loads, 2);
      expect(next.data!.prefetched!.episodeId, 'new');
      oldGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(await controller.resolveVideoData(item), same(repository.data));
    },
  );

  test('candidate deadline cancels a pending catalog too', () async {
    repository.catalogGate = Completer<void>();
    final controller = _Controller(timeout: const Duration(milliseconds: 30));
    addTearDown(controller.dispose);
    final probe = await controller.ensureCandidatePlayable(
      result(),
      episodeIndex: 0,
      preferredLine: 1,
    );
    expect(probe.status, SourceProbeStatus.failed);
    expect(repository.catalogOperation!.isCancelled, isTrue);
    expect(controller.calls, isEmpty);
    repository.catalogGate!.complete();
  });

  test('immediate retry survives cleanup from a cancelled probe', () async {
    repository.data = catalog([
      ['slow'],
    ]);
    final controller = _Controller()..pending['slow'] = Completer<String>();
    addTearDown(controller.dispose);
    final item = result();
    final first = controller.ensureCandidatePlayable(
      item,
      episodeIndex: 0,
      preferredLine: 1,
    );
    final cancelled = expectLater(
      first,
      throwsA(isA<RequestCancelledException>()),
    );
    await controller.started.future;
    controller.cancelSearch();
    controller.pending['slow']!.complete('https://fixture.test/first.mp4');
    controller.pending['slow'] = Completer<String>();
    final second = controller.ensureCandidatePlayable(
      item,
      episodeIndex: 0,
      preferredLine: 1,
    );
    await cancelled;
    expect(
      controller.ensureCandidatePlayable(
        item,
        episodeIndex: 0,
        preferredLine: 1,
      ),
      same(second),
    );
    controller.pending['slow']!.complete('https://fixture.test/second.mp4');
    expect(
      (await second).data!.prefetched!.url,
      'https://fixture.test/second.mp4',
    );
  });

  test('route keys preserve URL case and namespace source tokens', () async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    Future<String?> key(String source, String token) async {
      repository.data = catalog([
        [token],
      ], source: source);
      return (await controller.ensureCandidatePlayable(
        result(token, source),
        episodeIndex: 0,
        preferredLine: 1,
      )).routeKey;
    }

    expect(
      await key('a', 'https://cdn.test/A.mp4'),
      isNot(await key('b', 'https://cdn.test/a.mp4')),
    );
    expect(await key('a', 'token'), isNot(await key('b', 'token')));
    expect(
      await key('a', 'https://cdn.test/shared.mp4'),
      await key('b', 'https://cdn.test/shared.mp4'),
    );
  });

  test(
    'empty search succeeds and first keyword hit cancels siblings',
    () async {
      final controller = VideoSourceSearchController(title: 'Example');
      addTearDown(controller.dispose);
      controller.manualAliases = ['Alias'];
      final slow = Completer<List<SourceSearchResult>>();
      repository.searcher = (source, query) async {
        if (query == 'Example') {
          return SourceOperation.current!.wait(slow.future);
        }
        return [result('found', source)];
      };
      await controller.startSearch();
      expect(controller.results.length, 1);
      expect(repository.searchOperations.every((op) => op.isCancelled), isTrue);
      expect(repository.loads, 0);
      slow.complete([]);
      repository.searcher = (_, _) async => [];
      await controller.startSearch();
      expect(controller.results, isEmpty);
      expect(
        controller.searchErrors.where((e) => !e.startsWith('站内')),
        isEmpty,
      );
    },
  );

  test(
    'switching episodes releases prior states and keeps the probe window full',
    () async {
      repository.searcher = (source, _) async => [
        for (var i = 0; i < 5; i++) result('$i', source),
      ];
      repository.catalogFor = (item) => catalog([
        [item.id],
        [item.id],
      ]);
      final controller = _Controller();
      for (var i = 0; i < 5; i++) {
        controller.pending['$i'] = Completer<String>();
      }
      addTearDown(controller.dispose);
      await controller.startSearch();
      final first = controller.getDirectSourceGroups(
        episodeIndex: 0,
        preferredLine: 1,
      );
      final candidates = first.expand((group) => group.origins).toList();
      controller.startSwitchProbes(candidates);
      await controller.started.future;
      expect(controller.calls.length, 4);
      final completed = candidates.first.future!;
      controller.pending['0']!.complete('https://fixture.test/0.mp4');
      await completed;
      controller.startSwitchProbes(candidates);
      await Future<void>.delayed(Duration.zero);
      expect(controller.calls.length, 5);
      controller.getDirectSourceGroups(episodeIndex: 1, preferredLine: 1);
      final revisited = controller.getDirectSourceGroups(
        episodeIndex: 0,
        preferredLine: 1,
      );
      expect(revisited.first.primary, isNot(same(first.first.primary)));
      expect(
        revisited.every((group) => group.status == SourceProbeStatus.pending),
        isTrue,
      );
      for (var i = 1; i < 5; i++) {
        controller.pending['$i']!.complete('https://fixture.test/$i.mp4');
      }
    },
  );

  test('empty automatic search finishes with one failure callback', () async {
    var failures = 0;
    final controller = VideoSourceSearchController(
      title: 'No matches',
      autoMatchMode: true,
      onMatchFailed: () => failures++,
    );
    addTearDown(controller.dispose);
    await controller.startSearch();
    expect(failures, 1);
    expect(controller.isSearching, isFalse);
    expect(controller.progressingSources, isEmpty);
  });

  test('short-title search only probes the actual work', () async {
    repository.searcher = (source, _) async => [
      SourceSearchResult(
        Series('other', '深海鱼'),
        source: source,
        displayName: source,
      ),
      SourceSearchResult(
        Series('exact', '深海'),
        source: source,
        displayName: source,
      ),
      SourceSearchResult(
        Series('adventure', '深海历险记'),
        source: source,
        displayName: source,
      ),
    ];
    repository.catalogFor = (item) => catalog([
      [item.id],
    ]);
    final matches = <PlaybackRequest>[];
    final controller = _Controller(
      title: '深海',
      autoMatch: true,
      onMatch: matches.add,
    );
    addTearDown(controller.dispose);
    addTearDown(() => MatchMemoryService.remove(title: '深海'));

    await controller.startSearch();

    expect(controller.results.map((item) => item.id), ['exact']);
    expect(controller.calls, ['exact']);
    expect(matches.single.prefetched!.episodeId, 'exact');
  });

  test('does not reuse a playable but unrelated remembered match', () async {
    for (final rememberedTitle in ['深海鱼', 'Totally Different Show', null]) {
      await MatchMemoryService.writeSuccess(
        title: '深海',
        bgmId: 999001,
        source: 'test',
        seriesId: 'wrong-memory',
        candidateTitle: rememberedTitle,
      );
      final matches = <PlaybackRequest>[];
      var failures = 0;
      final controller = _Controller(
        title: '深海',
        seedData: {'bgmId': 999001},
        autoMatch: true,
        onMatch: matches.add,
        onMatchFailed: () => failures++,
      );
      addTearDown(controller.dispose);

      await controller.startSearch();

      expect(matches, isEmpty, reason: rememberedTitle);
      expect(controller.calls, isEmpty);
      expect(failures, 1);
      expect(MatchMemoryService.read(title: '深海', bgmId: 999001), isNull);
    }
  });

  test(
    'still reuses an exact remembered match after title validation',
    () async {
      await MatchMemoryService.writeSuccess(
        title: '深海',
        bgmId: 999002,
        source: 'test',
        seriesId: 'correct-memory',
        candidateTitle: '深海【国语】',
      );
      repository.catalogFor = (item) => catalog([
        [item.id],
      ]);
      final matches = <PlaybackRequest>[];
      final controller = _Controller(
        title: '深海',
        seedData: {'bgmId': 999002},
        autoMatch: true,
        onMatch: matches.add,
      );
      addTearDown(controller.dispose);
      addTearDown(() => MatchMemoryService.remove(title: '深海', bgmId: 999002));

      await controller.startSearch();

      expect(controller.calls, ['correct-memory']);
      expect(matches.single.prefetched!.episodeId, 'correct-memory');
    },
  );

  test('automatic fallback never switches to a low-confidence work', () async {
    repository.searcher = (source, _) async => [
      SourceSearchResult(
        Series('wrong', 'Example Unrelated Story'),
        source: source,
        displayName: source,
      ),
    ];
    final controller = _Controller();
    addTearDown(controller.dispose);
    await controller.startSearch();

    expect(controller.results, hasLength(1));
    expect(
      await controller.findNextPlayableCandidate(excludedSources: {}),
      isNull,
    );
    expect(repository.loads, 0);
  });

  test('manual selection cancels automatic work before it can claim', () async {
    repository.data = catalog([
      ['slow'],
    ]);
    repository.searcher = (source, _) async => [result('found', source)];
    final matches = <PlaybackRequest>[];
    final controller = _Controller(autoMatch: true, onMatch: matches.add)
      ..pending['slow'] = Completer<String>();
    addTearDown(controller.dispose);
    final search = controller.startSearch();
    await controller.started.future;
    controller.markUserSelected();
    await search;
    expect(controller.isSearching, isFalse);
    expect(controller.operations.every((op) => op.isCancelled), isTrue);
    controller.pending['slow']!.complete('https://fixture.test/late.mp4');
    await Future<void>.delayed(Duration.zero);
    expect(matches, isEmpty);
  });

  test('automatic search claims once and cancels pending line work', () async {
    repository.data = catalog([
      ['slow', 'fast'],
    ]);
    repository.searcher = (source, _) async => [result('found', source)];
    final matches = <PlaybackRequest>[];
    final controller = _Controller(autoMatch: true, onMatch: matches.add)
      ..pending['slow'] = Completer<String>();
    addTearDown(controller.dispose);
    await controller.startSearch();
    expect(matches.length, 1);
    expect(controller.hasMatched, isTrue);
    expect(controller.isSearching, isFalse);
    expect(matches.single.prefetched!.episodeId, 'fast');
    expect(controller.operations.every((op) => op.isCancelled), isTrue);
    controller.pending['slow']!.complete('https://fixture.test/late.mp4');
    await Future<void>.delayed(Duration.zero);
    expect(matches.length, 1);
  });
}

class _Catalog extends SourceCatalog {
  _Catalog() : super(Instances.sp);
  @override
  List<AdapterDescriptor> get quickSearchSources => [
    AdapterRegistry.builtinSources.first,
  ];
}

class _Repository extends SourceAdapterService {
  _Repository(super.catalog);
  PlaybackRequest data = catalog([
    ['fast'],
  ]);
  int loads = 0;
  PlaybackRequest Function(SourceSearchResult)? catalogFor;
  Completer<void>? catalogGate;
  SourceOperation? catalogOperation;
  final catalogStarted = Completer<void>();
  final searchOperations = <SourceOperation>[];
  Future<List<SourceSearchResult>> Function(String, String) searcher =
      (_, _) async => [];
  @override
  Future<void> init() async {}
  @override
  Future<PlaybackRequest?> buildPlaybackRequest(
    SourceSearchResult item, {
    Map<String, dynamic> metadata = const {},
  }) async {
    loads++;
    catalogOperation = SourceOperation.current!;
    if (!catalogStarted.isCompleted) catalogStarted.complete();
    if (catalogGate != null) await catalogOperation!.wait(catalogGate!.future);
    return catalogFor?.call(item) ?? data;
  }

  @override
  Future<List<SourceSearchResult>> search(
    String sourceKey,
    String query, {
    String fallbackDescription = '',
    bool skipBgmEnhancement = false,
  }) {
    searchOperations.add(SourceOperation.current!);
    return searcher(sourceKey, query);
  }
}

class _Controller extends VideoSourceSearchController {
  _Controller({
    this.timeout = const Duration(seconds: 15),
    String title = 'Example',
    super.seedData,
    bool autoMatch = false,
    void Function(PlaybackRequest)? onMatch,
    super.onMatchFailed,
  }) : super(title: title, autoMatchMode: autoMatch, onMatchFound: onMatch);
  final Duration timeout;
  final pending = <String, Completer<String>>{};
  final calls = <String>[];
  final fail = <String>{};
  final operations = <SourceOperation>[];
  final started = Completer<void>();
  @override
  Duration get candidateTimeout => timeout;
  @override
  Duration get raceTimeout => timeout;
  @override
  Future<({String url, Map<String, String> httpHeaders})> resolveLineMedia({
    required String sourceKey,
    required String lineToken,
  }) async {
    calls.add(lineToken);
    operations.add(SourceOperation.current!);
    if (!started.isCompleted) started.complete();
    if (fail.contains(lineToken)) throw StateError('Fixture unavailable');
    final url = pending[lineToken] == null
        ? 'https://fixture.test/$lineToken.mp4'
        : await SourceOperation.current!.wait(pending[lineToken]!.future);
    return (url: url, httpHeaders: const <String, String>{});
  }
}
