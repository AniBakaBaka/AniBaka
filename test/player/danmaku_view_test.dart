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

  test('reset keeps the current media time as the danmaku anchor', () {
    final controller = DanmakuController();
    final listener = _ProbeDanmakuListener();
    controller.syncTime(const Duration(minutes: 18));
    controller.attach(listener);
    listener.events.clear();

    controller.reset();

    expect(listener.events, ['reset', 'sync:1080000']);
    expect(listener.lastPosition, const Duration(minutes: 18));
    controller.detach(listener);
  });

  test('inline view keeps time sync after fullscreen listener detaches', () {
    final controller = DanmakuController();
    final inline = _ProbeDanmakuListener();
    final fullscreen = _ProbeDanmakuListener();

    controller.syncTime(const Duration(seconds: 12));
    controller.attach(inline);
    controller.attach(fullscreen);
    expect(inline.lastPosition, const Duration(seconds: 12));
    expect(fullscreen.lastPosition, const Duration(seconds: 12));

    controller.syncTime(const Duration(seconds: 48));
    controller.detach(fullscreen);
    controller.syncTime(const Duration(seconds: 49));

    expect(inline.lastPosition, const Duration(seconds: 49));
    expect(fullscreen.lastPosition, const Duration(seconds: 48));
    controller.detach(inline);
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

  testWidgets('current position can be replayed before the first layout', (
    tester,
  ) async {
    final controller = DanmakuController();
    controller.syncTime(const Duration(minutes: 18));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DanmakuView(controller: controller)),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _ProbeDanmakuListener implements DanmakuListener {
  Duration? lastPosition;
  final List<String> events = [];

  @override
  void onDanmakuTimeSync(Duration position) {
    lastPosition = position;
    events.add('sync:${position.inMilliseconds}');
  }

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
  void onDanmakuReset() {
    lastPosition = null;
    events.add('reset');
  }

  @override
  void onDanmakuResume() {}
}
