import 'package:baka/instance.dart';
import 'package:baka/services/danmaku_service.dart';
import 'package:baka/theme.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  tearDown(DanmakuService.clearCache);

  test('parses, filters and sorts only when input is out of order', () async {
    final items = await DanmakuService.decode(
      '{"data":['
      '{"m":"later","p":"2.5,1,16711680"},'
      '{"m":"bottom","p":"1.0,4,255"},'
      '{"m":"","p":"0,1,1"},'
      '{"m":"unsupported","p":"0,8,1"}'
      ']}',
    );
    expect(items.map((item) => item.text), ['bottom', 'later']);
    expect(items.first.time, 1000);
    expect(items.first.type, 4);
    expect(items.last.color, const Color(0xFFFF0000));
  });

  test('parses color from standard parameters after font size', () async {
    final items = await DanmakuService.decode(
      '{"data":['
      '{"m":"white","p":"0.0,1,25,16777215,source"},'
      '{"m":"red","p":"1.0,1,25,16711680,source"}'
      ']}',
    );

    expect(items.map((item) => item.color), [
      const Color(0xFFFFFFFF),
      const Color(0xFFFF0000),
    ]);
  });

  test('serializes typed items for local download compatibility', () async {
    const item = DanmakuItem(
      'hello',
      time: 1250,
      type: 5,
      color: Color(0xFF00FF00),
    );
    final raw = DanmakuService.encode([item]);
    final reparsed = await DanmakuService.decode(raw);
    expect(reparsed.single.text, 'hello');
    expect(reparsed.single.time, 1250);
    expect(reparsed.single.type, 5);
    expect(reparsed.single.color, const Color(0xFF00FF00));
  });

  test('LRU cache enforces episode and item budgets', () {
    const item = DanmakuItem('x');
    for (var index = 0; index < DanmakuService.maxCachedEpisodes + 1; index++) {
      DanmakuService.cacheItems('episode-$index', const [item]);
    }
    expect(DanmakuService.cacheSize.episodes, DanmakuService.maxCachedEpisodes);
    expect(DanmakuService.cachedKeys, isNot(contains('episode-0')));

    DanmakuService.clearCache();
    DanmakuService.cacheItems(
      'oversized',
      List<DanmakuItem>.filled(DanmakuService.maxCachedItems + 1, item),
    );
    expect(DanmakuService.cacheSize, (episodes: 0, items: 0));
  });

  test('persists and restores the selected danmaku font', () async {
    final controller = DanmakuController();
    controller.updateOption(
      controller.option.copyWith(fontFamily: 'Zen Maru Gothic'),
    );

    await DanmakuService.saveSettings(controller);
    final restored = DanmakuController();
    await DanmakuService.loadSettings(restored);

    expect(restored.option.fontFamily, 'Zen Maru Gothic');
  });

  test('updates the font without discarding other danmaku settings', () async {
    await Instances.sp.setString(
      'danmaku_settings',
      '{"fontSize":26,"opacity":0.5}',
    );

    await DanmakuService.setFontFamily('Sawarabi Gothic');
    final controller = DanmakuController();
    await DanmakuService.loadSettings(controller);

    expect(controller.option.fontFamily, 'Sawarabi Gothic');
    expect(controller.option.fontSize, 26);
    expect(controller.option.opacity, 0.5);
  });

  test('keeps legacy settings aligned with the app default font', () async {
    await Instances.sp.setString('danmaku_settings', '{"fontSize":18}');
    final controller = DanmakuController();

    await DanmakuService.loadSettings(controller);

    expect(controller.option.fontFamily, AppFonts.defaultFont);
  });
}
