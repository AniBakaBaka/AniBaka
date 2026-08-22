import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';

class Instances {
  static const String desktopDataFolderName = 'baka';
  static const String _workspaceVersionKey = 'desktop_workspace_version';
  static const int _workspaceVersion = 1;

  static final navigatorKey = GlobalKey<NavigatorState>();
  static final Map<String, Future<Directory>> _desktopDirectories = {};
  static Future<Directory>? _documentsDirectory;

  static BuildContext get currentContext =>
      navigatorKey.currentState!.overlay!.context;

  static late SharedPreferences sp;

  static String appVersion = '0.0.0';

  /// 获取用户认证 token（封装 SP 访问）
  static String get userToken => sp.getString('usertoken') ?? '';

  static bool isTV = false;

  static bool get isDesktopPlatform => Platform.isWindows || Platform.isMacOS;

  static bool get isWindows => isDesktopPlatform;

  static Future<void> init() async {
    final preferences = SharedPreferences.getInstance();
    final version = PackageInfo.fromPlatform().then(
      (info) => info.version,
      onError: (Object _, StackTrace _) => '0.0.0',
    );

    sp = await preferences;
    appVersion = await version;
  }

  static Future<Directory> desktopDataDirectory([String child = '']) {
    return _desktopDirectories.putIfAbsent(child, () async {
      final documents = await (_documentsDirectory ??=
          getApplicationDocumentsDirectory());
      final separator = Platform.pathSeparator;
      final root = '${documents.path}$separator$desktopDataFolderName';
      final path = child.isEmpty ? root : '$root$separator$child';
      return Directory(path).create(recursive: true);
    });
  }

  static Future<void> prepareDesktopWorkspace({
    List<String> legacyHiveBoxes = const <String>[],
  }) async {
    if (!isDesktopPlatform ||
        sp.getInt(_workspaceVersionKey) == _workspaceVersion) {
      return;
    }

    final rootDir = await desktopDataDirectory();
    final documentsDir = rootDir.parent;
    final separator = Platform.pathSeparator;
    final moves = <(FileSystemEntity, String)>[
      (
        Directory('${documentsDir.path}$separator.cookies'),
        '${rootDir.path}${separator}cookies',
      ),
      (
        Directory('${documentsDir.path}${separator}shaders'),
        '${rootDir.path}${separator}shaders',
      ),
    ];

    if (legacyHiveBoxes.isNotEmpty) {
      final hiveDir = await desktopDataDirectory('hive');
      for (final boxName in legacyHiveBoxes) {
        moves.addAll([
          (
            File('${documentsDir.path}$separator$boxName.hive'),
            '${hiveDir.path}$separator$boxName.hive',
          ),
          (
            File('${documentsDir.path}$separator$boxName.lock'),
            '${hiveDir.path}$separator$boxName.lock',
          ),
        ]);
      }
    }

    final results = await Future.wait(
      moves.map((move) => _moveLegacyPath(move.$1, move.$2)),
    );
    if (results.every((moved) => moved)) {
      await sp.setInt(_workspaceVersionKey, _workspaceVersion);
    }
  }

  static Future<bool> _moveLegacyPath(
    FileSystemEntity source,
    String targetPath,
  ) async {
    if (!await source.exists() ||
        await FileSystemEntity.type(targetPath) !=
            FileSystemEntityType.notFound) {
      return true;
    }

    try {
      await source.rename(targetPath);
      return true;
    } catch (_) {
      return false;
    }
  }
}

extension ScreenUtils on BuildContext {
  bool get isTablet => MediaQuery.sizeOf(this).shortestSide >= 600;

  bool get reduceMotion => MediaQuery.disableAnimationsOf(this);
}
