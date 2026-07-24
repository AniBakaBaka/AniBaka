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
  bool get validateAutoMatchedUrls => true;

  @override
  Future<({String url, Map<String, String> httpHeaders})> resolvePlaybackMedia(
    String episodeId, {
    bool skipValidation = false,
  }) async => (
    url: episodeId == 'good' ? 'https://example.com/good.mp4' : '',
    httpHeaders: const <String, String>{},
  );

  @override
  Future<List<Source>> getSources(String seriesId) async => const [];

  @override
  Future<List<Series>> search(
    String bangumiName,
    String searchKeyword, {
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
  test('player service keeps typed episodes and clamps line selection', () {
    final data = <String, Object>{
      'source': 'internal',
      'videos': '01. 正片\$line-a\n1 正片\$line-b\n02. 下一集\$line-c',
    };
    final service = PlayerService(data: data);
    final episodes = service.resolveInitialVideoList();

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
    expect(data['videoList'], ['01. 正片\$line-a\$line-b', '02. 下一集\$line-c']);
  });

  test('line switch changes typed selection without reparsing data', () {
    final service = PlayerService(data: <String, Object>{'source': 'internal'});
    service.syncVideoData(const [
      PlaybackEpisode(title: '第一集', lines: ['a', 'b']),
      PlaybackEpisode(title: '第二集', lines: ['c']),
    ]);

    expect(service.prepareSwitchEpisode(0, lineIndex: 2), isTrue);
    expect(service.currentEpisodeId, 'b');
    expect(service.prepareSwitchEpisode(0, lineIndex: 2), isFalse);
    expect(service.prepareSwitchEpisode(1, lineIndex: 2), isTrue);
    expect(service.currUrl, 1);
    expect(service.currentEpisodeId, 'c');
  });

  test('serialized line lookup scans only the requested segment', () {
    const episode = 'episode\$first\$second\$third';

    expect(VideoUtils.getPathCount(episode), 3);
    expect(VideoUtils.getVideoUrl(episode, 1), 'first');
    expect(VideoUtils.getVideoUrl(episode, 2), 'second');
    expect(VideoUtils.getVideoUrl(episode, 3), 'third');
    expect(VideoUtils.getVideoUrl(episode, 4), isNull);
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
