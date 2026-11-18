import 'dart:io';

import 'package:baka/app/app_runtime.dart';
import 'package:baka/app/baka_app.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/app/page_routes.dart';
import 'package:flutter/widgets.dart';

Future<void> main() => Log.runZoned(() async {
  if (Platform.isAndroid || Platform.isIOS) MobileRouteBinding();
  final runtime = AppRuntime();
  await runtime.initialize();
  runApp(const BakaApp());
  WidgetsBinding.instance.addPostFrameCallback((_) => runtime.markReady());
});
