import 'package:baka/widgets/danmaku/controller.dart';
import 'package:baka/widgets/danmaku/view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'repeat window extends from the latest duplicate and evicts in O(1)',
    () {
      final window = DanmakuRepeatWindow();
      expect(window.shouldBlock('same', 0), isFalse);
      expect(window.shouldBlock('same', 9000), isTrue);
      expect(window.shouldBlock('same', 11000), isTrue);
      expect(window.shouldBlock('same', 22000), isFalse);
      expect(window.retainedEventCount, 1);
    },
  );

  test('scroll track rejects overlap and accepts safe trailing gaps', () {
    final track = DanmakuScrollTrack();
    track.register(startMs: 0, width: 100, endMs: 8000, speed: 0.125);

    expect(track.canAccept(500, 0.1, 900), isFalse);
    expect(track.canAccept(900, 0.1, 900), isTrue);
    expect(track.canAccept(1000, 0.2, 900), isFalse);
    expect(track.canAccept(4000, 0.2, 900), isTrue);
  });

  test('paused controller still forwards seek synchronization', () {
    final controller = DanmakuController();
    final listener = _ProbeDanmakuListener();
    controller.attach(listener);
    controller.pause();
    controller.syncTime(const Duration(seconds: 42));
    expect(listener.lastPosition, const Duration(seconds: 42));
    controller.detach(listener);
  });

  testWidgets('idle timeline gaps do not schedule continuous frames', (
    tester,
  ) async {
    final controller = DanmakuController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 450,
            child: DanmakuView(controller: controller),
          ),
        ),
      ),
    );
    controller.setItems(const [DanmakuItem('future', time: 60000)]);
    controller.syncTime(Duration.zero);
    await tester.pump();

    expect(tester.binding.hasScheduledFrame, isFalse);

    controller.syncTime(const Duration(seconds: 60));
    await tester.pump();
    expect(find.byType(CustomPaint), findsWidgets);

    controller.pause();
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    final listener = _ProbeDanmakuListener();
    expect(() => controller.attach(listener), returnsNormally);
    controller.detach(listener);
  });
}

class _ProbeDanmakuListener implements DanmakuListener {
  Duration? lastPosition;

  @override
  void onDanmakuTimeSync(Duration position) => lastPosition = position;
  @override
  void onDanmakuInject(DanmakuItem item) {}
  @override
  void onDanmakuItemsChanged() {}
  @override
  void onDanmakuOptionChanged(DanmakuOption next, DanmakuOption previous) {}
  @override
  void onDanmakuPause() {}
  @override
  void onDanmakuPlaybackRateChanged(double rate) {}
  @override
  void onDanmakuReset() {}
  @override
  void onDanmakuResume() {}
}
