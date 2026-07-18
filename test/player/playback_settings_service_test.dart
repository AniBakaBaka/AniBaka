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
