import 'dart:async';

import 'package:baka/api/request_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent callers share one request and parsed value', () async {
    final cache = RequestCache<String, Object>(limit: 4);
    final gate = Completer<Object>();
    var requests = 0;

    Future<Object> load() {
      requests++;
      return gate.future;
    }

    final callers = [for (var i = 0; i < 20; i++) cache.get('same', load)];
    expect(requests, 1);
    final value = Object();
    gate.complete(value);
    final results = await Future.wait(callers);

    expect(requests, 1);
    expect(results.every((result) => identical(result, value)), isTrue);
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
    'deduplicator collapses concurrent calls without retaining data',
    () async {
      final requests = RequestDeduplicator<String, int>();
      var loads = 0;

      Future<int> load() async {
        loads++;
        await Future<void>.value();
        return loads;
      }

      final first = await Future.wait([
        for (var i = 0; i < 20; i++) requests.run('collection:1', load),
      ]);
      expect(loads, 1);
      expect(first, everyElement(1));

      expect(await requests.run('collection:1', load), 2);
      expect(loads, 2);
    },
  );
}
