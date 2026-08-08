import 'package:baka/instance.dart';
import 'package:baka/services/settings_service.dart';
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
}
