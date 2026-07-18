import 'dart:convert';
import 'dart:io';

import 'package:baka/api/post.dart';
import 'package:baka/instance.dart';
import 'package:baka/utils/version_util.dart';
import 'package:baka/widgets/dialog/update_dialog.dart';
import 'package:flutter/foundation.dart';

const _kLastCheckTimeKey = 'last_announcement_check_time';
const _kLastShownDateKey = 'last_announcement_shown_date';
const _kAnnouncementContentKey = 'last_announcement_content';

String _todayString() => DateTime.now().toIso8601String().substring(0, 10);

class VersionService {
  static String get _currentPlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'unknown';
  }

  static Future<UpdateInfo> checkUpdateInfo() async {
    final response = await checkAppUpdateApi();
    final data = response.data;
    final appInfo =
        (data is String ? jsonDecode(data) : data) as Map<String, dynamic>;
    final localVersion = Instances.appVersion;

    final appUpdate = appInfo['app_update'] as Map<String, dynamic>? ?? {};
    final platformConfig =
        (appUpdate['platforms'] as Map<String, dynamic>?)?[_currentPlatform]
            as Map<String, dynamic>? ??
        {};

    final latestVersion =
        platformConfig['latest_version'] as String? ??
        appInfo['version'] as String? ??
        localVersion;

    return UpdateInfo(
      hasUpdate: VersionManager.isVersionNewer(latestVersion, localVersion),
      forceUpdate:
          platformConfig['force'] as bool? ??
          appUpdate['force'] as bool? ??
          false,
      changelog:
          platformConfig['changelog'] as String? ??
          appUpdate['changelog'] as String? ??
          '',
      downloadUrl:
          platformConfig['download_url'] as String? ??
          appUpdate['download_url'] as String? ??
          'https://app.anibaka.com',
      latestVersion: latestVersion,
    );
  }

  static Future<void> checkAndShowUpdate() async {
    UpdateInfo? updateInfo;
    try {
      updateInfo = await checkUpdateInfo();
    } catch (e) {
      debugPrint('版本检查失败: $e');
    }

    String announcementContent = '';
    try {
      final lastCheckTime = Instances.sp.getInt(_kLastCheckTimeKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if ((now - lastCheckTime) > 86400000) {
        final response = await getGonggao();
        final data = response.data;
        final map = data is String ? jsonDecode(data) : data;
        announcementContent = map['data']['content'] as String? ?? '';
        await Instances.sp.setInt(_kLastCheckTimeKey, now);
        await Instances.sp.setString(
          _kAnnouncementContentKey,
          announcementContent,
        );
      } else {
        announcementContent =
            Instances.sp.getString(_kAnnouncementContentKey) ?? '';
      }
    } catch (e) {
      debugPrint('公告获取失败: $e');
      announcementContent =
          Instances.sp.getString(_kAnnouncementContentKey) ?? '';
    }

    final hasUpdate = updateInfo?.hasUpdate ?? false;
    final forceUpdate = updateInfo?.forceUpdate ?? false;
    final todayStr = _todayString();

    if (!forceUpdate &&
        !hasUpdate &&
        (announcementContent.isEmpty ||
            Instances.sp.getString(_kLastShownDateKey) == todayStr)) {
      return;
    }

    if (!forceUpdate) {
      await Instances.sp.setString(_kLastShownDateKey, todayStr);
    }

    showAnnouncementDialog(
      content: announcementContent,
      updateInfo:
          updateInfo ??
          UpdateInfo(
            hasUpdate: false,
            latestVersion: Instances.appVersion,
          ),
    );
  }
}
