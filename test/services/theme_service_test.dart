import 'package:baka/instance.dart';
import 'package:baka/services/settings_service.dart';
import 'package:baka/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  test('reduced visual effects are disabled by default', () {
    expect(ThemeService.getReduceVisualEffects(), isFalse);
  });

  test('dynamic color is disabled by default', () {
    expect(ThemeService.getDynamicColor(), isFalse);
  });

  test('app font defaults to Noto Serif SC', () {
    expect(ThemeService.getFontFamily(), 'Noto Serif SC');
  });

  test('dynamic color preference persists', () async {
    await ThemeService.setDynamicColor(true);

    expect(ThemeService.getDynamicColor(), isTrue);
    expect(Instances.sp.getBool('dynamic_color'), isTrue);
  });

  test('reduced visual effects preference persists', () async {
    await ThemeService.setReduceVisualEffects(true);

    expect(ThemeService.getReduceVisualEffects(), isTrue);
    expect(Instances.sp.getBool('reduce_visual_effects'), isTrue);
  });

  test('supported font preference persists', () async {
    await ThemeService.setFontFamily('Zen Maru Gothic');

    expect(ThemeService.getFontFamily(), 'Zen Maru Gothic');
  });

  test('removed fonts fall back to the default font', () async {
    for (final font in ['Ma Shan Zheng', 'Noto Sans TC', 'Dela Gothic One']) {
      await Instances.sp.setString(AppFonts.spKey, font);

      expect(ThemeService.getFontFamily(), AppFonts.defaultFont);
    }
  });
}
