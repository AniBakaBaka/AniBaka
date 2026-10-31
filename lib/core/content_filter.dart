import 'dart:convert';

import 'package:baka/instance.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

final contentFilter = ContentFilter();
final contentVisibility = ContentVisibility();

/// Hides NSFW items from display lists only; cached data and pagination keep
/// the full results.
class ContentFilter extends ValueNotifier<bool> {
  ContentFilter() : super(false);

  static const _key = 'hide_nsfw';

  void load() => value = Instances.sp.getBool(_key) ?? false;

  Future<void> setEnabled(bool enabled) {
    value = enabled;
    return Instances.sp.setBool(_key, enabled);
  }

  static bool isNsfw(Map item) =>
      item['nsfw'] == true || (item['bgmDetailData'] as Map?)?['nsfw'] == true;

  bool allows(Map item) => !value || !isNsfw(item);

  List<T> visibleItems<T extends Map>(List<T> items) => value
      ? items.where((item) => !isNsfw(item)).toList(growable: false)
      : items;
}

/// Dismissals of announcements and pinned comments. A dismissal applies to one
/// content revision, across pages and restarts.
class ContentVisibility extends ChangeNotifier {
  static String _key(String id) => 'dismissed_content_$id';

  static String _fingerprint(String content) =>
      sha256.convert(utf8.encode(content)).toString();

  bool isDismissed(String id, String content) =>
      Instances.sp.getString(_key(id)) == _fingerprint(content);

  Future<void> dismiss(String id, String content) async {
    await Instances.sp.setString(_key(id), _fingerprint(content));
    notifyListeners();
  }
}
