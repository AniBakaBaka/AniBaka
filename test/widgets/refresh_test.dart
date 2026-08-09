import 'package:baka/widgets/common/refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('短列表向下滚动可以加载更多，切换内容后会恢复分页', (tester) async {
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

  testWidgets('内容不足一屏时也接受无位移的向下滚动', (tester) async {
    var loadMoreCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RefreshWrapper(
            onRefresh: () async {},
            onLoadMore: () async {
              loadMoreCalls++;
              return true;
            },
            showInitialIndicator: false,
            child: ListView(children: const [SizedBox(height: 100)]),
          ),
        ),
      ),
    );

    final scrollableContext = tester.element(find.byType(ListView));
    UserScrollNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 0,
        pixels: 0,
        viewportDimension: 600,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: scrollableContext,
      direction: ScrollDirection.reverse,
    ).dispatch(scrollableContext);
    await tester.pump();

    expect(loadMoreCalls, 1);
  });
}
