import 'dart:io';

import 'package:baka/services/app_storage.dart';
import 'package:baka/services/play_history_sync_service.dart';
import 'package:baka/services/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;

  setUpAll(() async {
    hiveDirectory = await Directory.systemTemp.createTemp(
      'baka-play-resume-test-',
    );
    Hive.init(hiveDirectory.path);
    await Hive.openBox<List>(AppStorage.playHistoryBoxName);
  });

  setUp(() => AppStorage.playHistoryBox.clear());

  tearDownAll(() async {
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  test('remembers the latest episode across playback sources', () async {
    await PlayHistorySyncService.rememberEpisode(
      videoData: {
        'id': 'source-a-series',
        'bgmId': 123,
        'title': 'Test Anime',
        'source': 'custom_a',
      },
      episodeIndex: 6,
      urlIndex: 2,
    );

    final resume = PlayHistorySyncService.getResumeSelection({
      'id': 'source-b-series',
      'bgmId': 123,
      'title': 'Different Source Title',
      'source': 'custom_b',
    });

    expect(resume?.episodeIndex, 6);
    expect(resume?.lineIndex, 1);
  });

  test('uses existing history as a migration fallback', () async {
    await AppStorage.playHistoryBox.put('history', [
      {
        'id': 'legacy-id',
        'title': 'Legacy Anime',
        'index': 4,
        'url': 1,
        'watchTime': 100,
      },
    ]);

    final resume = PlayHistorySyncService.getResumeSelection({
      'id': 'another-id',
      'title': 'Legacy Anime',
    });

    expect(resume?.episodeIndex, 4);
  });

  test(
    'player restores remembered episode unless an index is explicit',
    () async {
      final identity = {
        'id': 'not-a-post-id',
        'bgmId': 456,
        'title': 'Resume Anime',
        'source': 'internal',
      };
      await PlayHistorySyncService.rememberEpisode(
        videoData: identity,
        episodeIndex: 2,
        urlIndex: 1,
      );

      final rememberedService = PlayerService(
        data: {
          ...identity,
          'videos': 'Episode 1\$a\nEpisode 2\$b\nEpisode 3\$c',
        },
      );
      await rememberedService.loadDetail();
      expect(rememberedService.currPlayIndex, 2);

      final explicitService = PlayerService(
        data: {
          ...identity,
          'videos': 'Episode 1\$a\nEpisode 2\$b\nEpisode 3\$c',
        },
        posIndex: 1,
      );
      await explicitService.loadDetail();
      expect(explicitService.currPlayIndex, 1);
    },
  );
}
