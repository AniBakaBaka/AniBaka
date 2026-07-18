import 'package:baka/widgets/common/refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('短列表上滑可以加载更多，切换内容后会恢复分页', (tester) async {
    final section = ValueNotifier('推荐');
    var loadMoreCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RefreshWrapper(
            onRefresh: () async {},
            onLoadMore: () async {
              loadMoreCalls++;
              return false;
            },
            loadMoreResetListenable: section,
            showInitialIndicator: false,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [SizedBox(height: 100)],
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(loadMoreCalls, 1);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(loadMoreCalls, 1);

    section.value = '最新';
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(loadMoreCalls, 2);

    section.dispose();
  });
}
