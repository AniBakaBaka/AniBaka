import '../support/app_dependencies.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/widgets/anime_detail/anime_detail_placeholder.dart';
import 'package:baka/widgets/anime_detail/anime_detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一页假的「播放页」：整页能点，上面一个按钮打开详情面板。
Widget _harness({
  required VoidCallback onBackgroundTap,
  required Widget Function(VoidCallback close) panel,
}) {
  return MaterialApp(
    home: Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onBackgroundTap,
        child: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showAnimeDetailSheet(
                context,
                page: (_, close) => panel(close),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 收起动画走完以后还要再出一帧，面板才真正从界面上消失。
Future<void> _settleClosed(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('面板从底部升起、占大部分高度，点暗处关闭且不漏给播放页', (tester) async {
    var backgroundTaps = 0;
    await tester.pumpWidget(
      _harness(
        onBackgroundTap: () => backgroundTaps++,
        panel: (_) => const ColoredBox(
          color: Colors.red,
          child: Center(child: Text('panel-body')),
        ),
      ),
    );
    await _open(tester);
    expect(find.text('panel-body'), findsOneWidget);

    final screen = tester.getSize(find.byType(MaterialApp));
    final sheet = tester.getSize(find.byKey(const ValueKey('animeDetailSheet')));
    // 比普通底部弹窗宽：占窗口 80%，两侧还能看到播放页。
    expect(sheet.height, closeTo(screen.height * 0.8, 1));
    expect(sheet.width, closeTo(screen.width * 0.8, 1));

    // 面板上方的暗层：点击被吃掉，只负责关闭。
    await tester.tapAt(const Offset(400, 12));
    await _settleClosed(tester);
    expect(find.text('panel-body'), findsNothing);
    expect(backgroundTaps, 0);
  });

  testWidgets('Esc 能收起面板，顶部没有关闭按钮', (tester) async {
    var backgroundTaps = 0;
    await tester.pumpWidget(
      _harness(
        onBackgroundTap: () => backgroundTaps++,
        panel: (_) => const ColoredBox(color: Colors.red),
      ),
    );
    await _open(tester);
    expect(find.byTooltip('关闭详情'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleClosed(tester);
    expect(find.byKey(const ValueKey('animeDetailSheet')), findsNothing);
    expect(backgroundTaps, 0);
  });

  testWidgets('面板里的按钮调用 close 后面板收起', (tester) async {
    var backgroundTaps = 0;
    var closedWith = 0;
    await tester.pumpWidget(
      _harness(
        onBackgroundTap: () => backgroundTaps++,
        panel: (close) => ColoredBox(
          color: Colors.red,
          child: Center(
            child: TextButton(
              onPressed: () {
                closedWith++;
                close();
              },
              child: const Text('pick'),
            ),
          ),
        ),
      ),
    );
    await _open(tester);
    await tester.tap(find.text('pick'));
    await _settleClosed(tester);
    expect(closedWith, 1);
    expect(find.text('pick'), findsNothing);
  });

  group('选集区', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      configurePlaybackServices();
    });

    PlaybackContent localContent(int currentIndex) => PlaybackContent(
      request: PlaybackRequest.fromMap({
        'source': '_local',
        'title': 'One',
        'id': 7,
        'videoList': [for (var i = 1; i <= 12; i++) '第$i集\$ep$i.mp4'],
        'currPlayIndex': currentIndex,
      }),
      sources: sourceRepository,
      collections: collections,
      history: historyRepository,
    );

    Future<void> pumpEpisodes(
      WidgetTester tester,
      PlaybackContent content,
      ValueChanged<int> onSelected,
    ) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              PlayerDetailEpisodes(content: content, onSelected: onSelected),
            ],
          ),
        ),
      ),
    );

    testWidgets('默认只列当前集所在的 10 集，点一集回传它的下标', (tester) async {
      final content = localContent(3);
      addTearDown(content.dispose);
      int? picked;
      await pumpEpisodes(tester, content, (index) => picked = index);
      await tester.pump();

      expect(find.text('第 1–10 集 · 共 12 集'), findsOneWidget);
      expect(find.text('第5集'), findsOneWidget);
      expect(find.text('第11集'), findsNothing);

      await tester.tap(find.text('第5集'));
      expect(picked, 4);
    });

    testWidgets('当前集靠后时列出它附近的那一页', (tester) async {
      final content = localContent(11);
      addTearDown(content.dispose);
      await pumpEpisodes(tester, content, (_) {});
      await tester.pump();

      expect(find.text('第 11–12 集 · 共 12 集'), findsOneWidget);
      expect(find.text('第12集'), findsOneWidget);
    });

    testWidgets('「显示全部」列出全部集数', (tester) async {
      final content = localContent(0);
      addTearDown(content.dispose);
      await pumpEpisodes(tester, content, (_) {});
      await tester.pump();

      await tester.tap(find.text('显示全部'));
      await tester.pumpAndSettle();
      expect(find.text('共 12 集'), findsOneWidget);
      expect(find.text('第12集'), findsOneWidget);
    });

    testWidgets('面板里放完整的详情页：选集可见，「切换播放源」交给播放页', (
      tester,
    ) async {
      final content = localContent(2);
      addTearDown(content.dispose);
      var sourceTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showAnimeDetailSheet(
                    context,
                    page: (_, close) => AnimeDetailPlaceholder(
                      data: content.detailData,
                      headerSliver: PlayerDetailEpisodes(
                        content: content,
                        onSelected: (_) => close(),
                      ),
                      onSearchTap: () {
                        sourceTaps++;
                        close();
                      },
                      searchLabel: '切换播放源',
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await _open(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.text('切换播放源'), findsOneWidget);
      expect(find.text('第3集'), findsOneWidget);
      // 用的是完整详情页（同一套组件），不是简化过的简介卡。
      expect(find.byType(AnimeDetailPlaceholder), findsOneWidget);

      await tester.tap(find.text('切换播放源'));
      await _settleClosed(tester);
      expect(tester.takeException(), isNull);
      expect(sourceTaps, 1);
      expect(find.text('切换播放源'), findsNothing);
    });
  });
}
