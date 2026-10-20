import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

final contentVisibility = ContentVisibility();

/// A dismissal applies to this content revision, across pages and app restarts.
class ContentVisibility extends ChangeNotifier {
  String _fingerprint(String content) =>
      sha256.convert(utf8.encode(content)).toString();

  bool isDismissed(
    SharedPreferences preferences, {
    required String id,
    required String content,
  }) => preferences.getString('dismissed_content_$id') == _fingerprint(content);

  Future<void> dismiss(
    SharedPreferences preferences, {
    required String id,
    required String content,
  }) async {
    await preferences.setString('dismissed_content_$id', _fingerprint(content));
    notifyListeners();
  }
}
