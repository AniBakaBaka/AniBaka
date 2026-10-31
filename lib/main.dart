import 'package:baka/app/app_runtime.dart';
import 'package:baka/app/baka_app.dart';
import 'package:baka/core/app_logger.dart';
import 'package:flutter/widgets.dart';

Future<void> main() => Log.runZoned(() async {
  final runtime = AppRuntime();
  await runtime.initialize();
  runApp(const BakaApp());
  WidgetsBinding.instance.addPostFrameCallback((_) => runtime.markReady());
});
