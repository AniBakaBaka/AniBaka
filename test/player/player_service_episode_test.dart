import 'package:baka/models/playback_episode.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/source/adapter_base.dart';
import 'package:baka/source/models/series.dart';
import 'package:baka/source/models/source.dart';
import 'package:flutter_test/flutter_test.dart';

class _KeepAliveAdapter extends AdapterBase {
  _KeepAliveAdapter() : super('keep-alive-test');

  int starts = 0;
  int stops = 0;
  String? lastMediaUrl;

  @override
  String get baseUrl => 'https://example.com';

  @override
  Future<String> getDownloadUrl(String episodeId) async => '';

  @override
  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
    int maxAttempts = 2,
    Duration? reachTimeout,
  }) async => (
    url: episodeId == 'good' ? 'https://example.com/good.mp4' : '',
    httpHeaders: const <String, String>{},
  );

  @override
  Future<PlaybackCatalog> getPlaybackCatalog(String seriesId) async =>
      PlaybackCatalog.empty;

  @override
  Future<List<Series>> search(
    String query, {
    bool enhanceWithBgm = true,
  }) async => const [];

  @override
  Future<void> startPlaybackKeepAlive(String mediaUrl) async {
    starts++;
    lastMediaUrl = mediaUrl;
  }

  @override
  void stopPlaybackKeepAlive() {
    stops++;
  }
}

void main() {
  test('accepts an untyped route map without copying its data', () {
    final routeData = <dynamic, dynamic>{'source': 'internal', 'title': 'A'};
    final service = PlayerService(data: routeData);

    service.data['title'] = 'B';
    expect(routeData['title'], 'B');
    routeData['id'] = 42;
    expect(service.data['id'], 42);
  });

  test(
    'player service keeps typed episodes and clamps line selection',
    () async {
      final data = <String, Object>{
        'source': 'internal',
        'videos': '01. 正片\$line-a\n1 正片\$line-b\n02. 下一集\$line-c',
      };
      final service = PlayerService(data: data);
      await service.loadDetail();
      final episodes = service.videoList;

      expect(episodes, hasLength(2));
      expect(episodes.first.title, '01. 正片');
      expect(episodes.first.lines, ['line-a', 'line-b']);
      service.syncVideoData(
        episodes,
        preferredEpisodeIndex: 99,
        preferredLineIndex: 9,
      );
      expect(service.currPlayIndex, 1);
      expect(service.currUrl, 1);
      expect(service.currentVideoItem, isA<PlaybackEpisode>());
      expect(data['videoList'], same(episodes));
    },
  );

  test('line switch changes typed selection without reparsing data', () {
    final service = PlayerService(data: <String, Object>{'source': 'internal'});
    service.syncVideoData(const [
      PlaybackEpisode(title: '第一集', lines: ['a', 'b']),
      PlaybackEpisode(title: '第二集', lines: ['c']),
    ]);

    service.applySelection(service.normalizeSelection(0, 2));
    expect(service.currentEpisodeId, 'b');
    // 同集同线路的归一化结果与当前状态相同，调用方据此判等即可跳过切换
    final repeated = service.normalizeSelection(0, 2);
    expect(repeated.episodeIndex, service.currPlayIndex);
    expect(repeated.lineIndex, service.currUrl);
    service.applySelection(service.normalizeSelection(1, 2));
    expect(service.currUrl, 1);
    expect(service.currentEpisodeId, 'c');
  });

  test('episodeAt parses only the requested episode', () {
    final data = <String, dynamic>{
      'videos': 'ep1\$a1\$a2\nep2\$first\$second\$third\n\nep3\$c1',
    };

    expect(PlaybackEpisodeCatalog.countFrom(data), 3);

    final episode = PlaybackEpisodeCatalog.episodeAt(data, 1);
    expect(episode, isNotNull);
    expect(episode!.title, 'ep2');
    expect(episode.lineCount, 3);
    expect(episode.lineAt(1), 'first');
    expect(episode.lineAt(2), 'second');
    expect(episode.lineAt(3), 'third');
    expect(episode.lineAt(4), isNull);

    expect(PlaybackEpisodeCatalog.episodeAt(data, 3), isNull);
  });

  test('episodeAt skips blank videoList entries like rawEpisodesOf', () {
    final data = <String, dynamic>{
      'videoList': ['', 'ep1\$a', '   ', 'ep2\$b'],
    };

    expect(PlaybackEpisodeCatalog.countFrom(data), 2);
    expect(PlaybackEpisodeCatalog.rawEpisodesOf(data), ['ep1\$a', 'ep2\$b']);
    expect(PlaybackEpisodeCatalog.episodeAt(data, 1)?.title, 'ep2');
  });

  test('playback keep-alive follows the active media lifecycle', () async {
    final service = PlayerService(data: <String, Object>{'source': 'internal'});
    final adapter = _KeepAliveAdapter();

    final first = await service.startAdapterPlaybackKeepAlive(
      adapter,
      'https://example.com/first.m3u8',
    );
    final second = await service.startAdapterPlaybackKeepAlive(
      adapter,
      'https://example.com/second.m3u8',
    );

    expect(adapter.starts, 2);
    expect(adapter.stops, 1);
    expect(adapter.lastMediaUrl, 'https://example.com/second.m3u8');

    service.stopAdapterPlaybackKeepAlive(first);
    expect(
      adapter.stops,
      1,
      reason: 'stale playback must not stop the new one',
    );

    service.stopAdapterPlaybackKeepAlive(second);
    expect(adapter.stops, 2);
    service.dispose();
  });

  test('validated source falls back to another playback line', () async {
    final service = PlayerService(data: <String, Object>{'source': 'internal'});
    service.syncVideoData(const [
      PlaybackEpisode(title: 'Episode', lines: ['blocked', 'good']),
    ]);

    final media = await service.resolveAdapterPlaybackMedia(
      _KeepAliveAdapter(),
      'blocked',
    );

    expect(media.url, 'https://example.com/good.mp4');
    expect(service.currUrl, 2);
    service.dispose();
  });
}
