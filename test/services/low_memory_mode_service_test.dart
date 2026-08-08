import 'package:baka/services/playback_settings_service.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cache = PaintingBinding.instance.imageCache;
  final normalImageCount = cache.maximumSize;
  final normalImageBytes = cache.maximumSizeBytes;

  tearDown(() {
    PlaybackSettingsService.applyLowMemoryMode(false);
  });

  test('low memory mode applies and restores the decoded image budget', () {
    PlaybackSettingsService.applyLowMemoryMode(true);

    expect(
      cache.maximumSize,
      PlaybackSettingsService.lowMemoryImageCount,
    );
    expect(
      cache.maximumSizeBytes,
      PlaybackSettingsService.lowMemoryImageBytes,
    );

    PlaybackSettingsService.applyLowMemoryMode(false);

    expect(cache.maximumSize, normalImageCount);
    expect(cache.maximumSizeBytes, normalImageBytes);
  });
}
