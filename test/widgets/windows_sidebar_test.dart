import 'dart:convert';

import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/widgets/platform/windows/windows_sidebar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    Get.testMode = true;
    SharedPreferences.setMockInitialValues({
      'bangumi_access_token': 'bgm-token',
      'bangumi_account': jsonEncode({
        'username': 'sai',
        'nickname': 'Bangumi 测试用户',
        'avatar_url': 'https://lain.bgm.tv/pic/user/l/icon.jpg',
      }),
      'sidebarCollapsed': false,
    });
    Instances.sp = await SharedPreferences.getInstance();
    Get.put(AppState());
  });

  tearDown(() {
    Get.reset();
  });

  testWidgets('uses Bangumi identity and opens the real login route', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        routes: {'Baka://login': (_) => const Scaffold(body: Text('统一登录页面'))},
        home: Scaffold(
          body: WindowsSidebar(currentPageIndex: 0, onPageChange: (_) {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Bangumi 测试用户'), findsOneWidget);
    expect(find.text('Bangumi 登录'), findsOneWidget);
    final avatar = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage).first,
    );
    expect(Uri.parse(avatar.imageUrl).host, 'wsrv.nl');
    expect(avatar.imageUrl, contains('lain.bgm.tv'));

    await tester.tap(find.text('Bangumi 测试用户'));
    await tester.pumpAndSettle();

    expect(find.text('统一登录页面'), findsOneWidget);
  });
}
