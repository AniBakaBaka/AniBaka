import 'package:baka/instance.dart';
import 'package:baka/services/media_session_service.dart';
import 'package:baka/services/playback_session_coordinator.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_playback_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  test('progress is throttled to 30 seconds and saved at boundaries', () async {
    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    final content = _RecordingPlayerService();
    final coordinator = PlaybackSessionCoordinator(
      controller: controller,
      danmakuController: DanmakuController(),
      content: content,
      onNextEpisode: () {},
      onPreviousEpisode: () {},
      mediaSession: MediaSessionService(),
    );
    await coordinator.start();
    backend.emitDuration(const Duration(minutes: 10));

    backend.emitPosition(const Duration(seconds: 29));
    await Future<void>.delayed(Duration.zero);
    expect(content.savedPositions, isEmpty);

    backend.emitPosition(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);
    expect(content.savedPositions, [const Duration(seconds: 30)]);

    await controller.seek(const Duration(seconds: 50));
    await Future<void>.delayed(Duration.zero);
    expect(content.savedPositions.last, const Duration(seconds: 50));

    await coordinator.saveAndResetForSwitch();
    expect(content.savedPositions.last, const Duration(seconds: 50));
    expect(content.historyWrites, 1);

    await coordinator.dispose();
    expect(content.savedPositions.last, const Duration(seconds: 50));
    expect(content.historyWrites, 2);
    expect(content.savedPositions, [
      const Duration(seconds: 30),
      const Duration(seconds: 50),
    ]);
    await controller.dispose();
  });
}

class _RecordingPlayerService extends PlayerService {
  _RecordingPlayerService()
    : super(
        data: <String, Object>{
          'source': '_local',
          'localFilePath': 'video.mp4',
        },
      );

  final savedPositions = <Duration>[];
  int historyWrites = 0;

  @override
  Future<void> saveProgress(
    Duration position,
    bool rememberLastPosition,
  ) async {
    if (rememberLastPosition) savedPositions.add(position);
  }

  @override
  void saveHistory({required int positionMs, required int durationMs}) {
    historyWrites++;
  }
}
