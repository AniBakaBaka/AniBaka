import 'package:baka/utils/platform_page_route.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('custom routes retain the interactive iOS back gesture', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final route = platformPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('second page')),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    );
    debugDefaultTargetPlatformOverride = null;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(route),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('second page'), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.text('second page'))),
      isA<CupertinoPageRoute<void>>(),
    );

    await tester.dragFrom(const Offset(5, 300), const Offset(700, 0));
    await tester.pumpAndSettle();

    expect(find.text('second page'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
