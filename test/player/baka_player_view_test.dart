import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:baka/instance.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_playback_backend.dart';

void main() {
  test('fullscreen view receives the existing player arguments', () async {
    final controller = PlaybackController();
    const header = SizedBox(key: Key('header'));
    void pickEpisode() {}
    void nextEpisode() {}
    void fullscreenChanged(bool value) {}

    final source = BakaPlayer(
      controller: controller,
      canSearchSource: true,
      headerControl: header,
      danmakuEnabled: true,
      onPickEpisode: pickEpisode,
      hasNextEpisode: true,
      onNextEpisode: nextEpisode,
      onFullScreenChanged: fullscreenChanged,
    );
    final fullscreen = source.fullscreenView();

    expect(fullscreen.full, isTrue);
    expect(fullscreen.controller, same(controller));
    expect(fullscreen.canSearchSource, isTrue);
    expect(fullscreen.headerControl, same(header));
    expect(fullscreen.danmakuEnabled, isTrue);
    expect(fullscreen.onPickEpisode, same(pickEpisode));
    expect(fullscreen.hasNextEpisode, isTrue);
    expect(fullscreen.onNextEpisode, same(nextEpisode));
    expect(fullscreen.onFullScreenChanged, same(fullscreenChanged));
    await controller.dispose();
  });

  testWidgets('progress bar drag seeks to the finger position', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    Instances.isTV = false;

    final backend = FakePlaybackBackend();
    final controller = PlaybackController(backend: backend);
    await controller.open('file:///tmp/test.mp4');
    backend.emitDuration(const Duration(minutes: 24));
    backend.emitPosition(const Duration(minutes: 20));
    controller.setControlsVisible(true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BakaPlayer(controller: controller, full: true)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final progressBarFinder = find.byType(ProgressBar);
    expect(progressBarFinder, findsOneWidget);
    final rect = tester.getRect(progressBarFinder);
    final gesture = await tester.startGesture(
      Offset(rect.left + rect.width * 0.5, rect.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(Offset(rect.left + rect.width * 0.5, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));

    // 拖动条按手指位置 seek，而不是跳到结尾。
    expect(backend.lastSeek, const Duration(minutes: 12));
    controller.dispose();
  });
}
