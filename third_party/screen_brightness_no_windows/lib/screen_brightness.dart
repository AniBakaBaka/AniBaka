import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

class ScreenBrightness {
  ScreenBrightness._();

  static final ScreenBrightness _instance = ScreenBrightness._();

  factory ScreenBrightness() => _instance;

  Future<double> get application => ScreenBrightnessPlatform.instance.application;

  Future<void> setApplicationScreenBrightness(double brightness) =>
      ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(brightness);

  Future<void> resetApplicationScreenBrightness() =>
      ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
}