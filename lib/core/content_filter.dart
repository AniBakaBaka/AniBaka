import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

final contentFilter = ContentFilter();

/// Filters display lists only; cached data and pagination keep the full results.
class ContentFilter extends ValueNotifier<bool> {
  ContentFilter() : super(false);

  static const preferenceKey = 'hide_nsfw';

  void load(SharedPreferences preferences) {
    value = preferences.getBool(preferenceKey) ?? false;
  }

  Future<void> setEnabled(bool enabled, SharedPreferences preferences) async {
    value = enabled;
    await preferences.setBool(preferenceKey, enabled);
  }

  static bool isNsfw(Map item) =>
      item['nsfw'] == true || (item['bgmDetailData'] as Map?)?['nsfw'] == true;

  bool allows(Map item) => !value || !isNsfw(item);

  List<T> visibleItems<T extends Map>(List<T> items) =>
      value ? items.where(allows).toList(growable: false) : items;
}
