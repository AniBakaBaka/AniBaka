import 'package:baka/services/low_memory_mode_service.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cache = PaintingBinding.instance.imageCache;
  final normalImageCount = cache.maximumSize;
  final normalImageBytes = cache.maximumSizeBytes;

  tearDown(() {
    LowMemoryModeService.apply(false);
  });

  test('low memory mode applies and restores the decoded image budget', () {
    LowMemoryModeService.apply(true);

    expect(cache.maximumSize, LowMemoryModeService.lowMemoryImageCount);
    expect(cache.maximumSizeBytes, LowMemoryModeService.lowMemoryImageBytes);

    LowMemoryModeService.apply(false);

    expect(cache.maximumSize, normalImageCount);
    expect(cache.maximumSizeBytes, normalImageBytes);
  });
}
