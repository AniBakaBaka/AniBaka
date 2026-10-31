import 'dart:async';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/webview_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cancellation stops delay and leaves sibling operations alive',
    () async {
      final first = SourceOperation();
      final sibling = SourceOperation();
      var continued = false;
      final work = first.run(() async {
        await SourceOperation.delay(const Duration(seconds: 30));
        continued = true;
      });
      final failure = expectLater(
        work,
        throwsA(isA<RequestCancelledException>()),
      );
      first.cancel();
      await failure;
      expect(continued, isFalse);
      expect(await sibling.run(() async => 42), 42);
      first.close();
      sibling.close();
    },
  );

  test('a caller soft timeout does not cancel a late result', () async {
    final operation = SourceOperation();
    final ready = Completer<int>();
    final work = operation.run(() => ready.future);
    await expectLater(
      work.timeout(const Duration(milliseconds: 5)),
      throwsA(isA<TimeoutException>()),
    );
    ready.complete(42);
    expect(await work, 42);
    expect(operation.isCancelled, isFalse);
    operation.close();
  });

  for (final phase in ['initialize', 'navigate', 'poll']) {
    test(
      'WebView $phase timeout resets the browser and releases queue',
      () async {
        final queue = WebViewTaskQueue();
        final stuck = Completer<void>();
        final events = <String>[];
        final first = queue.run<String>(
          timeout: const Duration(milliseconds: 30),
          action: () async {
            for (final stage in ['initialize', 'navigate', 'poll']) {
              SourceOperation.check();
              events.add(stage);
              if (stage == phase) await stuck.future;
            }
            SourceOperation.check();
            events.add('late write');
            return 'first';
          },
          cleanup: () async => events.add('clean'),
          discard: () => events.add('discard'),
        );
        final second = queue.run<String>(
          timeout: const Duration(seconds: 1),
          action: () async => 'second',
          cleanup: () async {},
          discard: () {},
        );
        expect(await first, isNull);
        expect(await second, 'second');
        expect(events, contains('clean'));
        expect(events, isNot(contains('discard')));
        stuck.complete();
        await Future<void>.delayed(Duration.zero);
        expect(events, isNot(contains('late write')));
      },
    );
  }

  test('a failed WebView task discards the browser and rethrows', () async {
    final queue = WebViewTaskQueue();
    var cleaned = 0;
    var discarded = 0;
    await expectLater(
      queue.run<int>(
        timeout: const Duration(seconds: 1),
        action: () async => throw StateError('platform failure'),
        cleanup: () async => cleaned++,
        discard: () => discarded++,
      ),
      throwsStateError,
    );
    expect((cleaned, discarded), (0, 1));
    expect(
      await queue.run<int>(
        timeout: const Duration(seconds: 1),
        action: () async => 2,
        cleanup: () async {},
        discard: () {},
      ),
      2,
    );
  });

  test(
    'WebView reset has its own deadline and cannot block next task',
    () async {
      final queue = WebViewTaskQueue();
      final reset = Completer<void>();
      var discarded = 0;
      final first = queue.run<int>(
        timeout: const Duration(seconds: 1),
        action: () async => 1,
        cleanup: () => reset.future,
        cleanupTimeout: const Duration(milliseconds: 20),
        discard: () => discarded++,
      );
      final second = queue.run<int>(
        timeout: const Duration(seconds: 1),
        action: () async => 2,
        cleanup: () async {},
        discard: () {},
      );
      expect(await first, 1);
      expect(await second, 2);
      expect(discarded, 1);
      reset.complete();
    },
  );

  test('expired queued WebView task never navigates', () async {
    final queue = WebViewTaskQueue();
    final gate = Completer<void>();
    var navigations = 0;
    final first = queue.run<int>(
      timeout: const Duration(seconds: 1),
      action: () async {
        await gate.future;
        return 1;
      },
      cleanup: () async {},
      discard: () {},
    );
    final second = queue.run<int>(
      timeout: const Duration(milliseconds: 10),
      action: () async {
        navigations++;
        return 2;
      },
      cleanup: () async {},
      discard: () {},
    );
    expect(await second, isNull);
    gate.complete();
    expect(await first, 1);
    await Future<void>.delayed(Duration.zero);
    expect(navigations, 0);
  });
}
