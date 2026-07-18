import 'package:baka/instance.dart';

class SwiperSettingsService {
  static const _key = 'swiper_hidden_until';

  static bool get isHidden {
    final hiddenUntilStr = Instances.sp.getString(_key);
    if (hiddenUntilStr == null) return false;
    final hideUntil = DateTime.tryParse(hiddenUntilStr);
    if (hideUntil != null && hideUntil.isAfter(DateTime.now())) {
      return true;
    }
    Instances.sp.remove(_key);
    return false;
  }

  static int get remainingDays {
    final hiddenStr = Instances.sp.getString(_key);
    return hiddenStr != null
        ? (DateTime.tryParse(hiddenStr)?.difference(DateTime.now()).inDays ?? 0)
        : 0;
  }

  static void hide() {
    Instances.sp.setString(
      _key,
      DateTime.now().add(const Duration(days: 14)).toIso8601String(),
    );
  }

  static void show() {
    Instances.sp.remove(_key);
  }
}
