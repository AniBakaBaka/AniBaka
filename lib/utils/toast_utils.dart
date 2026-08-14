import 'dart:io';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void showSnackBar(
  String text, {
  ToastGravity gravity = ToastGravity.BOTTOM,
  bool isError = false,
}) {
  debugPrint(text);
  if (Platform.isWindows || Platform.isMacOS) {
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? const Color(0xFFD32F2F) : null,
      ),
    );
  } else {
    Fluttertoast.showToast(
      msg: text,
      gravity: gravity,
      backgroundColor: isError ? const Color(0xFFD32F2F) : null,
    );
  }
}

void showActionSnackBar(
  String text, {
  required String actionLabel,
  required VoidCallback onAction,
}) {
  debugPrint(text);
  scaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 4),
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(label: actionLabel, onPressed: onAction),
    ),
  );
}
