import 'package:baka/app/page_routes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'card motion stays continuous through interrupted and gesture pops',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final tile = GlobalKey();
      final detail = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: ContainerPageTransitionsBuilder(),
              },
            ),
          ),
          home: Center(
            child: SizedBox(
              key: tile,
              width: 100,
              height: 150,
              child: const TransitionOriginClip(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                child: ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      );
      void open() {
        MobileRouteBinding.useClip(tile.currentContext!);
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => SizedBox.expand(key: detail)),
        );
      }

      open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final partial = tester.getTopLeft(find.byKey(detail));
      expect(partial.dy, greaterThan(0));
      navigator.currentState!.pop();
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(detail)), partial);
      await tester.pumpAndSettle();
      expect(detail.currentContext, isNull);

      open();
      await tester.pumpAndSettle();
      final pageContext = detail.currentContext;
      Future<void> gesture(String method, [double? progress]) async {
        final message = MethodCall(
          method,
          progress == null
              ? null
              : {
                  'touchOffset': [5.0, 300.0],
                  'swipeEdge': 0,
                  'progress': progress,
                },
        );
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(message),
          (_) {},
        );
        await tester.pump();
      }

      for (final commit in [false, true]) {
        await gesture('startBackGesture', 0);
        await gesture('updateBackGestureProgress', 0.4);
        final releasedAt = tester.getTopLeft(find.byKey(detail));
        expect(releasedAt.dy, greaterThan(0));
        await gesture(commit ? 'commitBackGesture' : 'cancelBackGesture');
        expect(tester.getTopLeft(find.byKey(detail)), releasedAt);
        await tester.pumpAndSettle();
        expect(detail.currentContext, commit ? isNull : same(pageContext));
      }
    },
  );
}
