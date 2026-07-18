import 'dart:io';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get/get.dart';

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
  if (Platform.isWindows || Platform.isMacOS) {
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: actionLabel, onPressed: onAction),
      ),
    );
  } else {
    Get.snackbar(
      '',
      text,
      titleText: const SizedBox.shrink(),
      snackPosition: SnackPosition.BOTTOM,
      mainButton: TextButton(
        onPressed: () {
          if (Get.isSnackbarOpen) Get.closeCurrentSnackbar();
          onAction();
        },
        child: Text(actionLabel, style: const TextStyle(color: Colors.blue)),
      ),
      duration: const Duration(seconds: 4),
      backgroundColor: Colors.grey[900],
      colorText: Colors.white,
      margin: const EdgeInsets.all(16),
      borderRadius: 8,
    );
  }
}

void cancelSnackBar() {
  if (Platform.isWindows || Platform.isMacOS) {
    scaffoldMessengerKey.currentState?.clearSnackBars();
  } else {
    Fluttertoast.cancel();
  }
}
