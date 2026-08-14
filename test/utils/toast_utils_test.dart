import 'package:baka/utils/toast_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('action snackbar uses the app ScaffoldMessenger', (tester) async {
    var actionInvoked = false;
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: scaffoldMessengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );

    showActionSnackBar(
      'download completed',
      actionLabel: 'open',
      onAction: () => actionInvoked = true,
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('download completed'), findsOneWidget);
    tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
    expect(actionInvoked, isTrue);
  });
}
