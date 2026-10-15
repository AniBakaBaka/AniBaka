import 'dart:async';
import 'dart:io';

import 'package:baka/core/http_request.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void showSnackBar(
  String text, {
  ToastGravity gravity = ToastGravity.BOTTOM,
  bool isError = false,
  SnackBarAction? action,
  Duration? duration,
}) {
  if (action != null ||
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux) {
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: duration ?? Duration(seconds: action == null ? 2 : 4),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? const Color(0xFFD32F2F) : null,
        action: action,
      ),
    );
  } else {
    Fluttertoast.showToast(
      msg: text,
      gravity: gravity,
      toastLength: duration != null && duration.inSeconds > 2
          ? Toast.LENGTH_LONG
          : Toast.LENGTH_SHORT,
      backgroundColor: isError ? const Color(0xFFD32F2F) : null,
    );
  }
}

/// Coalesces background failures without hiding errors from request callers.
class NetworkNotices {
  NetworkNotices({
    required this.onNetworkError,
    required this.onImageFailures,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const networkCooldown = Duration(minutes: 1);
  static const imageCooldown = Duration(minutes: 10);
  static const imageWindow = Duration(minutes: 1);
  static const imageSettleTime = Duration(seconds: 2);
  static const minImageFailures = 8;
  static const minImageFailureRatio = 0.7;

  final void Function() onNetworkError;
  final void Function() onImageFailures;
  final DateTime Function() _now;
  final _images = <String, ({DateTime at, bool? succeeded})>{};
  DateTime? _lastNetworkNotice, _lastImageNotice;
  Timer? _imageTimer;
  bool _disposed = false;

  static bool isNetworkError(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      (error is http.ClientException &&
          error is! http.RequestAbortedException) ||
      (error is ApiException &&
          (error.statusCode == 408 ||
              error.statusCode == 429 ||
              (error.statusCode != null && error.statusCode! >= 500)));

  void reportNetworkError(Object error) {
    if (_disposed || !isNetworkError(error)) return;
    final now = _now();
    if (_coolingDown(_lastNetworkNotice, networkCooldown, now)) return;
    _lastNetworkNotice = now;
    onNetworkError();
  }

  void reportImageStarted(String url) => _recordImage(url, null);

  void reportImageResult(String url, {required bool succeeded}) =>
      _recordImage(url, succeeded);

  void _recordImage(String url, bool? succeeded) {
    if (_disposed) return;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return;
    }
    final now = _now();
    _pruneImages(now);
    // Rebuilds, retries and different widgets showing one URL count only once.
    final key = uri.removeFragment().toString();
    final result = (at: now, succeeded: succeeded);
    if (succeeded == null) {
      _images.putIfAbsent(key, () => result);
    } else {
      _images[key] = result;
    }
    if (succeeded == false &&
        _imageTimer == null &&
        !_coolingDown(_lastImageNotice, imageCooldown, now) &&
        _hasWidespreadImageFailures) {
      // Let successful requests in the same batch finish before judging it.
      _imageTimer = Timer(imageSettleTime, _checkImageFailures);
    }
  }

  void _pruneImages(DateTime now) => _images.removeWhere(
    (_, result) => now.difference(result.at) >= imageWindow,
  );

  bool get _hasWidespreadImageFailures {
    final failures = _images.values.where((r) => r.succeeded == false).length;
    return failures >= minImageFailures &&
        failures / _images.length >= minImageFailureRatio;
  }

  void _checkImageFailures() {
    _imageTimer = null;
    if (_disposed) return;
    final now = _now();
    _pruneImages(now);
    if (!_hasWidespreadImageFailures ||
        _coolingDown(_lastImageNotice, imageCooldown, now)) {
      return;
    }
    _lastImageNotice = now;
    // The more useful image hint also covers subsequent generic failures.
    _lastNetworkNotice = now;
    onImageFailures();
  }

  bool _coolingDown(DateTime? last, Duration cooldown, DateTime now) =>
      last != null && now.difference(last) < cooldown;

  void dispose() {
    _disposed = true;
    _imageTimer?.cancel();
    _imageTimer = null;
    _images.clear();
  }
}
