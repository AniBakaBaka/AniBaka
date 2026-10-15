import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:baka/source/runtime/request_scheduler.dart';
import 'package:baka/source/runtime/scheduler_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _StreamingAdapter implements HttpClientAdapter {
  final body = StreamController<Uint8List>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody(body.stream, 200);

  @override
  void close({bool force = false}) {
    unawaited(body.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('scheduling', () {
    test('available host bypasses requests blocked by another host', () async {
      final scheduler = RequestScheduler(maxConcurrent: 2, maxPerHost: 1);
      await scheduler.acquire('a');
      var started = false;
      final blocked = scheduler.run(() async => started = true, host: 'a');
      await scheduler.acquire('b');
      expect(started, isFalse);
      scheduler.release('b');
      scheduler.release('a');
      await blocked;
      expect(started, isTrue);
    });

    test(
      'eligible hosts preserve priority and FIFO across saturated hosts',
      () async {
        final scheduler = RequestScheduler(maxConcurrent: 2, maxPerHost: 1);
        await scheduler.acquire('a');
        await scheduler.acquire('b');
        final starts = <String>[];
        Future<void> enqueue(
          String host,
          String label,
          RequestPriority priority,
        ) => scheduler.run(
          () async {
            starts.add(label);
          },
          host: host,
          priority: priority,
        );
        final jobs = [
          enqueue('a', 'a-search', RequestPriority.search),
          enqueue('c', 'c-play', RequestPriority.play),
          enqueue('b', 'b-play', RequestPriority.play),
          enqueue('c', 'c-search', RequestPriority.search),
        ];
        scheduler.release('b');
        await Future.wait(jobs.skip(1));
        expect(starts, ['c-play', 'b-play', 'c-search']);
        scheduler.release('a');
        await Future.wait(jobs);
        expect(starts.last, 'a-search');
      },
    );

    test(
      'queued cancellation releases listeners and allows host reuse',
      () async {
        final scheduler = RequestScheduler(maxConcurrent: 2, maxPerHost: 1);
        await scheduler.acquire('a');
        final token = RequestCancelToken();
        var cancelled = 0;
        final jobs = [
          for (var i = 0; i < 3; i++)
            scheduler
                .acquire('a', cancelToken: token)
                .then<void>(
                  (_) => fail('cancelled request started'),
                  onError: (Object e) {
                    expect(e, isA<RequestCancelledException>());
                    cancelled++;
                  },
                ),
        ];
        token.cancel();
        await Future.wait(jobs);
        expect(cancelled, 3);
        scheduler.release('a');
        await scheduler.run(() async {}, host: 'a');
      },
    );

    test('exceptions and cancellation after acquire return the slot', () async {
      final scheduler = RequestScheduler(maxConcurrent: 1);
      final token = RequestCancelToken();
      final cancelled = scheduler.run(
        () async => fail('cancelled task ran'),
        host: 'a',
        cancelToken: token,
      );
      token.cancel();
      await expectLater(cancelled, throwsA(isA<RequestCancelledException>()));
      await expectLater(
        scheduler.run(() async => throw StateError('test'), host: 'a'),
        throwsStateError,
      );
      expect(await scheduler.run(() async => 42, host: 'b'), 42);
    });
  });

  test(
    'cancellation allows listeners to detach or register during dispatch',
    () {
      final token = RequestCancelToken();
      final called = <String>[];
      late void Function() detachSecond;
      token.onCancel(() {
        called.add('first');
        detachSecond();
        token.onCancel(() => called.add('late'));
        token.cancel();
      });
      detachSecond = token.onCancel(() => called.add('second'));
      final detachUnused = token.onCancel(() => called.add('detached'));
      detachUnused();
      token.cancel();
      detachSecond();
      token.cancel();
      expect(called, ['first', 'late', 'second']);
    },
  );

  group('Dio cancellation', () {
    test(
      'cancelled Dio requests leave the queue without sending HTTP or leaking slots',
      () async {
        final previousOverrides = HttpOverrides.current;
        addTearDown(() => HttpOverrides.global = previousOverrides);
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var received = 0;
        server.listen((request) async {
          received++;
          request.response.write('ok');
          await request.response.close();
        });
        final scheduler = RequestScheduler(maxConcurrent: 1, maxPerHost: 1);
        final interceptor = SchedulerInterceptor(scheduler: scheduler);
        await scheduler.acquire('127.0.0.1');
        final dio = Dio()..interceptors.add(interceptor);
        addTearDown(() async {
          dio.close(force: true);
          await server.close(force: true);
        });
        final cancel = CancelToken();
        final request = dio.get<String>(
          'http://127.0.0.1:${server.port}/',
          cancelToken: cancel,
        );
        await Future<void>.delayed(Duration.zero);
        cancel.cancel();
        await expectLater(
          request,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        expect(received, 0);
        scheduler.release('127.0.0.1');
        expect(
          (await dio.get<String>('http://127.0.0.1:${server.port}/')).data,
          'ok',
        );
        expect(received, 1);
      },
    );
  });

  for (final end in ['done', 'cancel', 'unread cancel', 'error']) {
    test('stream slot held until $end, then released once', () async {
      final scheduler = RequestScheduler(maxConcurrent: 1, maxPerHost: 1);
      final adapter = _StreamingAdapter();
      final dio = Dio()
        ..httpClientAdapter = adapter
        ..interceptors.add(SchedulerInterceptor(scheduler: scheduler));
      addTearDown(() => dio.close(force: true));
      final cancel = CancelToken();
      final first = await dio.get<ResponseBody>(
        'https://fixture.test/first',
        cancelToken: cancel,
        options: Options(responseType: ResponseType.stream),
      );
      StreamSubscription<Uint8List>? subscription;
      if (end == 'cancel') subscription = first.data!.stream.listen((_) {});
      var acquired = false;
      final second = scheduler.run(
        () async => acquired = true,
        host: 'fixture.test',
      );
      await Future<void>.value();
      expect(
        acquired,
        isFalse,
        reason: 'response headers alone must not release the slot',
      );
      switch (end) {
        case 'done':
          final drained = first.data!.stream.drain<void>();
          await adapter.body.close();
          await drained;
        case 'cancel':
          await subscription!.cancel();
        case 'unread cancel':
          cancel.cancel();
        case 'error':
          final failure = expectLater(
            first.data!.stream.drain<void>(),
            throwsStateError,
          );
          adapter.body.addError(StateError('broken stream'));
          await failure;
      }
      await second;
      expect(acquired, isTrue);
      cancel.cancel();
      await Future<void>.value();
      // Repeated termination must not return an extra slot.
      await scheduler.acquire('fixture.test');
      acquired = false;
      final queued = scheduler.run(
        () async => acquired = true,
        host: 'fixture.test',
      );
      await Future<void>.value();
      expect(acquired, isFalse);
      scheduler.release('fixture.test');
      await queued;
      expect(acquired, isTrue);
    });
  }
}
