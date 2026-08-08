import 'package:baka/instance.dart';
import 'package:baka/models/playback_state.dart';
import 'package:baka/services/playback_settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  tearDown(() {
    Instances.isTV = false;
  });

  test('persists only keys changed between preference snapshots', () async {
    const previous = PlaybackPreferences();
    final next = previous.copyWith(autoFullscreen: true, longPressSpeed: 2.5);
    await PlaybackSettingsService.saveChanges(previous, next);

    expect(Instances.sp.getKeys(), {
      'player_autoFullscreen',
      'player_longPressSpeed',
    });
    expect(Instances.sp.getBool('player_autoFullscreen'), isTrue);
    expect(Instances.sp.getDouble('player_longPressSpeed'), 2.5);
  });

  test('identical snapshots do not write any preference key', () async {
    const preferences = PlaybackPreferences();
    await PlaybackSettingsService.saveChanges(preferences, preferences);
    expect(Instances.sp.getKeys(), isEmpty);
  });

  test('low memory mode is off by default and persists changes', () async {
    expect(PlaybackSettingsService.getLowMemoryMode(), isFalse);

    await PlaybackSettingsService.setLowMemoryMode(true);

    expect(PlaybackSettingsService.getLowMemoryMode(), isTrue);
    expect(Instances.sp.getBool('app_lowMemoryMode'), isTrue);
  });

  test('persists and migrates the video renderer selection', () async {
    const previous = PlaybackPreferences();
    final next = previous.copyWith(videoRenderer: 'gpu-next');

    await PlaybackSettingsService.saveChanges(previous, next);

    expect(Instances.sp.getString('player_videoRenderer'), 'gpu-next');
    expect(PlaybackSettingsService.normalizeVideoRenderer('auto'), 'gpu');
    expect(
      PlaybackSettingsService.normalizeVideoRenderer('compatibility'),
      'gpu',
    );
    expect(
      PlaybackSettingsService.normalizeVideoRenderer('quality'),
      'gpu-next',
    );
    expect(PlaybackSettingsService.normalizeVideoRenderer('gpu'), 'gpu');
    expect(
      PlaybackSettingsService.normalizeVideoRenderer('gpu-next'),
      'gpu-next',
    );
    expect(
      PlaybackSettingsService.normalizeVideoRenderer('mediacodec_embed'),
      'mediacodec_embed',
    );
    expect(PlaybackSettingsService.normalizeVideoRenderer(null), 'gpu');
  });

  test('Android migrates gpu-next and quality renderers down to gpu', () {
    expect(
      PlaybackSettingsService.normalizeVideoRenderer('gpu-next', android: true),
      'gpu',
    );
    expect(
      PlaybackSettingsService.normalizeVideoRenderer('quality', android: true),
      'gpu',
    );
    expect(
      PlaybackSettingsService.normalizeVideoRenderer(
        'mediacodec_embed',
        android: true,
      ),
      'mediacodec_embed',
    );
    expect(
      PlaybackSettingsService.normalizeVideoRenderer('gpu', android: true),
      'gpu',
    );
    expect(
      PlaybackSettingsService.normalizeVideoRenderer(null, android: true),
      'gpu',
    );
  });

  test('normalizes hwdec modes including the Android TV default', () {
    expect(PlaybackSettingsService.normalizeHwdecMode('auto'), 'auto');
    expect(
      PlaybackSettingsService.normalizeHwdecMode('auto-safe'),
      'auto-safe',
    );
    expect(
      PlaybackSettingsService.normalizeHwdecMode('mediacodec-copy'),
      'mediacodec-copy',
    );
    expect(PlaybackSettingsService.normalizeHwdecMode('no'), 'no');
    expect(PlaybackSettingsService.normalizeHwdecMode('bogus'), 'auto');
    expect(PlaybackSettingsService.normalizeHwdecMode(null), 'auto');
  });

  test('Android TV defaults to and migrates to mediacodec-copy', () {
    Instances.isTV = true;
    // 未设置或遗留的 auto 一律落到 mediacodec-copy。
    expect(PlaybackSettingsService.normalizeHwdecMode(null), 'mediacodec-copy');
    expect(
      PlaybackSettingsService.normalizeHwdecMode('auto'),
      'mediacodec-copy',
    );
    expect(
      PlaybackSettingsService.normalizeHwdecMode('bogus'),
      'mediacodec-copy',
    );
    // 用户显式选择的模式保持不变。
    expect(
      PlaybackSettingsService.normalizeHwdecMode('auto-safe'),
      'auto-safe',
    );
    expect(PlaybackSettingsService.normalizeHwdecMode('no'), 'no');
    expect(
      PlaybackSettingsService.normalizeHwdecMode('mediacodec-copy'),
      'mediacodec-copy',
    );
  });

  test('platform hwdec options hide auto on Android TV', () {
    expect(
      PlaybackSettingsService.hwdecModeOptionsForPlatform,
      contains('auto'),
    );
    expect(
      PlaybackSettingsService.hwdecModeLabelsForPlatform.containsKey('auto'),
      isTrue,
    );

    Instances.isTV = true;
    expect(
      PlaybackSettingsService.hwdecModeOptionsForPlatform,
      isNot(contains('auto')),
    );
    expect(
      PlaybackSettingsService.hwdecModeLabelsForPlatform.containsKey('auto'),
      isFalse,
    );
    expect(
      PlaybackSettingsService.hwdecModeOptionsForPlatform,
      containsAll(['auto-safe', 'mediacodec-copy', 'no']),
    );
  });

  test(
    'migrates enabled legacy Anime4K levels to the same named levels',
    () async {
      SharedPreferences.setMockInitialValues({
        'player_enableAnime4K': true,
        'player_anime4KLevel': 'high',
      });
      Instances.sp = await SharedPreferences.getInstance();

      final preferences = PlaybackSettingsService.loadAll();

      expect(preferences.videoEnhancementMode, VideoEnhancementMode.high);
      expect(preferences.lastVideoEnhancementMode, VideoEnhancementMode.high);
    },
  );

  test('keeps legacy disabled while remembering its migrated mode', () async {
    SharedPreferences.setMockInitialValues({
      'player_enableAnime4K': false,
      'player_anime4KLevel': 'ultra',
    });
    Instances.sp = await SharedPreferences.getInstance();

    final preferences = PlaybackSettingsService.loadAll();

    expect(preferences.videoEnhancementMode, VideoEnhancementMode.off);
    expect(preferences.lastVideoEnhancementMode, VideoEnhancementMode.ultra);
  });

  test('persists new enhancement mode without rewriting legacy keys', () async {
    const previous = PlaybackPreferences();
    final next = previous.copyWith(
      videoEnhancementMode: VideoEnhancementMode.medium,
      lastVideoEnhancementMode: VideoEnhancementMode.medium,
    );

    await PlaybackSettingsService.saveChanges(previous, next);

    expect(Instances.sp.getString('player_videoEnhancementMode'), 'medium');
    expect(Instances.sp.containsKey('player_enableAnime4K'), isFalse);
    expect(Instances.sp.containsKey('player_anime4KLevel'), isFalse);
  });

  test(
    'persists subtitle configuration with the preference snapshot',
    () async {
      const previous = PlaybackPreferences();
      final next = previous.copyWith(
        subtitleConfig: previous.subtitleConfig.copyWith(fontSize: 32),
      );

      await PlaybackSettingsService.saveChanges(previous, next);

      expect(Instances.sp.getKeys(), {'subtitle_settings'});
      expect(
        Instances.sp.getString('subtitle_settings'),
        contains('"fontSize":32'),
      );
    },
  );
}
