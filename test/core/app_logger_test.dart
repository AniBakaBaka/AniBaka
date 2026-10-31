import 'package:baka/core/app_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('log lines redact credentials in query, JSON and header forms', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);

    Log.w(
      'Api',
      'GET /collection?token=abc123&page=2',
      StateError('{"refresh_token":"r-1","pwd":"p@ss"}'),
    );
    Log.i('Http', 'Authorization: Bearer eyJ.hdr.sig');

    final text = lines.join('\n');
    for (final secret in ['abc123', 'r-1', 'p@ss', 'eyJ.hdr.sig']) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, contains('page=2'));
    expect(text, contains('W/Api: GET /collection'));
  });
}
