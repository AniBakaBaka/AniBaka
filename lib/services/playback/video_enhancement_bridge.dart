import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:baka/core/app_logger.dart';

/// Shared state for the Windows renderer. Only changed properties cross the
/// channel; each playback reads the same map instead of requesting snapshots.
class VideoEnhancementBridge {
  VideoEnhancementBridge._() {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'Video.Property':
          final [handle, name, value] = call.arguments as List;
          final state = _players[handle as int];
          if (state != null && state.values[name] != value) {
            state.values[name as String] = value as String;
            state.changed();
          }
        case 'Dlss.Status':
          final status = call.arguments as String;
          if (status != dlssStatus.value &&
              (status.startsWith('普通画面：') || status.contains('纹理同步失败'))) {
            Log.w('VideoRenderer', status);
          }
          dlssStatus.value = status;
      }
    });
  }

  static final instance = VideoEnhancementBridge._();
  static const channel = MethodChannel('com.anibaka/video_enhancement');
  final dlssStatus = ValueNotifier<String>('');
  final _players = <int, VideoProperties>{};

  VideoProperties attach(int handle) => _players[handle] = VideoProperties();

  void detach(int handle) {
    _players.remove(handle)?.dispose();
  }

  Future<Map<String, String>> snapshot(int handle) async =>
      (await channel.invokeMapMethod<String, String>('Video.Properties', {
        'handle': handle,
      }))!;
}

class VideoProperties extends ChangeNotifier {
  final values = <String, String>{};
  void changed() => notifyListeners();
}
