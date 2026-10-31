import 'package:baka/app/watch_party_links.dart';
import 'dart:io';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:baka/instance.dart';
import 'package:baka/core/app_logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

Future<void> configurePlatform() async {
  if (Platform.isWindows) WatchPartyLinks.registerWindowsScheme();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );

  if (Platform.isAndroid) {
    const platformChannel = MethodChannel('baka/platform');
    Map<String, dynamic>? displayDiagnostics;
    try {
      Instances.isTV =
          await platformChannel.invokeMethod<bool>('isTV') ?? false;
    } catch (error, stackTrace) {
      Instances.isTV = false;
      Log.w(
        'Display',
        'Android TV detection failed; using phone behavior',
        error,
        stackTrace,
      );
    }

    try {
      displayDiagnostics = await platformChannel
          .invokeMapMethod<String, dynamic>('getDisplayDiagnostics');
      Log.i('Display', 'Android display diagnostics: $displayDiagnostics');
    } catch (error, stackTrace) {
      Log.w(
        'Display',
        'Unable to read Android display diagnostics',
        error,
        stackTrace,
      );
    }

    if (Instances.isTV) {
      Log.i(
        'Display',
        'TV rendering policy: system display mode, '
            'impeller=${displayDiagnostics?['impellerEnabled']}',
      );
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      // Let Android TV keep the display mode selected by the system. Forcing
      // the highest phone refresh mode can make Flutter and video textures
      // alternate frames on TV firmware with incomplete mode support.
      try {
        await FlutterDisplayMode.setHighRefreshRate();
        Log.i(
          'Display',
          'Android rendering policy: high refresh mode request completed',
        );
      } catch (error, stackTrace) {
        Log.w(
          'Display',
          'Android high refresh mode request failed',
          error,
          stackTrace,
        );
      }
    }
  }

  if (Instances.isDesktopPlatform) {
    doWhenWindowReady(() {
      appWindow.minSize = const Size(800, 600);
      appWindow.size = const Size(1280, 720);
      appWindow.alignment = Alignment.center;
      appWindow.title = 'Baka';
      appWindow.show();
    });
  }
}
