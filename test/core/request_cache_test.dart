import 'dart:async';

import 'package:baka/api/request_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'refresh bypasses completed values but shares a running refresh',
    () async {
      final cache = RequestCache<String, int>(limit: 1);
      expect(await cache.get('a', () async => 1), 1);
      final gate = Completer<int>();
      final first = cache.get('a', () => gate.future, refresh: true);
      final second = cache.get('a', () async => 3, refresh: true);
      expect(identical(first, second), isTrue);
      gate.complete(2);
      expect(await second, 2);
      expect(await cache.get('a', () async => 4), 2);
    },
  );

  test('removed refresh cannot replace a newer value', () async {
    final cache = RequestCache<String, int>(limit: 1);
    final gate = Completer<int>();
    final old = cache.get('a', () => gate.future, refresh: true);
    cache.remove('a');
    expect(await cache.get('a', () async => 2), 2);
    gate.complete(1);
    await old;
    expect(await cache.get('a', () async => 3), 2);
  });
  test('capacity never evicts an in-flight request', () async {
    final cache = RequestCache<int, int>(limit: 2, ttl: Duration.zero);
    final gates = List.generate(3, (_) => Completer<int>());
    var loads = 0;
    final calls = [
      for (var repeat = 0; repeat < 5; repeat++)
        for (var key = 0; key < 3; key++)
          cache.get(key, () {
            loads++;
            return gates[key].future;
          }),
    ];
    expect(loads, 3);
    for (var i = 0; i < 3; i++) {
      gates[i].complete(i);
    }
    expect(await Future.wait(calls), [
      for (var i = 0; i < 5; i++) ...[0, 1, 2],
    ]);
    expect(await cache.get(0, () async => 99), 99);
  });

  test('invalidated pending results cannot replace newer values', () async {
    final cache = RequestCache<int, int>(limit: 2);
    final stale = Completer<int>();
    final first = cache.get(1, () => stale.future);
    cache.clear();
    expect(await cache.get(1, () async => 2), 2);
    stale.complete(1);
    expect(await first, 1);
    expect(await cache.get(1, () async => 3), 2);
    cache.remove(1);
    expect(await cache.get(1, () async => 3), 3);
  });

  test('synchronous futures and throwing loaders complete normally', () async {
    final cache = RequestCache<int, int>(limit: 2);
    expect(await cache.get(1, () => SynchronousFuture(7)), 7);
    await expectLater(
      cache.get(2, () => throw StateError('sync')),
      throwsStateError,
    );
    expect(await cache.get(2, () async => 8), 8);
  });

  test('failed and rejected values are not retained', () async {
    var requests = 0;
    final cache = RequestCache<String, int?>(
      limit: 2,
      shouldCache: (value) => value != null,
    );

    Future<int?> loadNull() async {
      requests++;
      return null;
    }

    await cache.get('null', loadNull);
    await cache.get('null', loadNull);
    expect(requests, 2);

    Future<int?> fail() async {
      requests++;
      throw StateError('failed');
    }

    await expectLater(cache.get('failure', fail), throwsStateError);
    await expectLater(cache.get('failure', fail), throwsStateError);
    expect(requests, 4);
  });

  test(
    'zero capacity shares pending requests without retaining data',
    () async {
      final requests = RequestCache<String, int>(limit: 0);
      var loads = 0;

      Future<int> load() async {
        loads++;
        await Future<void>.value();
        return loads;
      }

      final first = await Future.wait([
        for (var i = 0; i < 20; i++) requests.get('collection:1', load),
      ]);
      expect(loads, 1);
      expect(first, everyElement(1));

      expect(await requests.get('collection:1', load), 2);
      expect(loads, 2);
      expect(requests.peek('collection:1'), isNull);
      requests.put('collection:1', 99);
      expect(requests.peek('collection:1'), isNull);
    },
  );

  test('zero capacity releases synchronous results and failed loads', () async {
    final requests = RequestCache<int, int>(limit: 0);
    expect(await requests.get(1, () => SynchronousFuture(1)), 1);
    expect(await requests.get(1, () => SynchronousFuture(2)), 2);
    await expectLater(
      requests.get(2, () => throw StateError('sync')),
      throwsStateError,
    );
    expect(await requests.get(2, () async => 3), 3);
  });

  test(
    'invalidated zero-capacity work cannot release its replacement',
    () async {
      final requests = RequestCache<int, int>(limit: 0);
      final old = Completer<int>();
      final next = Completer<int>();
      final first = requests.get(1, () => old.future);
      requests.clear();
      final second = requests.get(1, () => next.future);
      old.complete(1);
      expect(await first, 1);
      expect(requests.get(1, () async => 3), same(second));
      next.complete(2);
      expect(await second, 2);
      expect(requests.peek(1), isNull);
    },
  );
}
