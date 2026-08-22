import 'package:baka/instance.dart';
import 'package:baka/app_state.dart';
import 'package:baka/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
    state = AppState()..onInit();
  });

  tearDown(() => state.onClose());

  test('reduced visual effects are disabled by default', () {
    expect(state.reduceVisualEffects, isFalse);
  });

  test('dynamic color is disabled by default', () {
    expect(state.dynamicColor, isFalse);
  });

  test('app font defaults to Noto Serif SC', () {
    expect(state.fontFamily, 'Noto Serif SC');
  });

  test('dynamic color preference persists', () async {
    state.setDynamicColor(true);

    expect(state.dynamicColor, isTrue);
    expect(Instances.sp.getBool('dynamic_color'), isTrue);
  });

  test('reduced visual effects preference persists', () async {
    state.setReduceVisualEffects(true);

    expect(state.reduceVisualEffects, isTrue);
    expect(Instances.sp.getBool('reduce_visual_effects'), isTrue);
  });

  test('supported font preference persists', () async {
    state.setFontFamily('Zen Maru Gothic');

    expect(state.fontFamily, 'Zen Maru Gothic');
  });

  test('removed fonts fall back to the default font', () async {
    for (final font in ['Ma Shan Zheng', 'Noto Sans TC', 'Dela Gothic One']) {
      await Instances.sp.setString(AppFonts.spKey, font);

      final restored = AppState()..onInit();
      expect(restored.fontFamily, AppFonts.defaultFont);
      restored.onClose();
    }
  });
}
