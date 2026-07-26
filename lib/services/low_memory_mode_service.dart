import 'package:flutter/painting.dart';

/// Applies the process-wide RAM budget used by decoded network images.
///
/// The normal values are captured from Flutter instead of duplicating its
/// defaults so disabling the mode restores the budget provided by the current
/// engine version.
class LowMemoryModeService {
  LowMemoryModeService._();

  static const lowMemoryImageCount = 80;
  static const lowMemoryImageBytes = 32 * 1024 * 1024;

  static int? _normalImageCount;
  static int? _normalImageBytes;

  static void apply(bool enabled) {
    final cache = PaintingBinding.instance.imageCache;
    _normalImageCount ??= cache.maximumSize;
    _normalImageBytes ??= cache.maximumSizeBytes;

    cache.maximumSize = enabled ? lowMemoryImageCount : _normalImageCount!;
    cache.maximumSizeBytes = enabled ? lowMemoryImageBytes : _normalImageBytes!;

    if (enabled) {
      // Drop entries retained only by Flutter's live-image tracking. Images
      // that are still displayed remain alive through their widget listeners.
      cache.clearLiveImages();
    }
  }
}
