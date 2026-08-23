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

/// 按语义化版本比较，remote 比 local 新时返回 true。
bool _isVersionNewer(String remoteVersion, String localVersion) {
  var remoteOffset = 0;
  var localOffset = 0;
  while (remoteOffset < remoteVersion.length ||
      localOffset < localVersion.length) {
    final remoteEnd = remoteVersion.indexOf('.', remoteOffset);
    final localEnd = localVersion.indexOf('.', localOffset);
    final r =
        int.tryParse(
          remoteVersion.substring(
            remoteOffset,
            remoteEnd < 0 ? remoteVersion.length : remoteEnd,
          ),
        ) ??
        0;
    final l =
        int.tryParse(
          localVersion.substring(
            localOffset,
            localEnd < 0 ? localVersion.length : localEnd,
          ),
        ) ??
        0;
    if (r > l) return true;
    if (r < l) return false;
    remoteOffset = remoteEnd < 0 ? remoteVersion.length : remoteEnd + 1;
    localOffset = localEnd < 0 ? localVersion.length : localEnd + 1;
  }
  return false;
}

class VersionService {
  static String get _currentPlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    return 'unknown';
  }

  static Future<UpdateInfo> checkUpdateInfo() async {
    final appInfo = await checkAppUpdateApi();
    final localVersion = Instances.appVersion;

    final appUpdate = appInfo['app_update'] as Map<String, dynamic>;
    final platforms = appUpdate['platforms'] as Map<String, dynamic>;
    final platformConfig = platforms[_currentPlatform] as Map<String, dynamic>?;
    if (platformConfig == null) {
      return UpdateInfo(
        hasUpdate: false,
        forceUpdate: false,
        changelog: '',
        downloadUrl: '',
        latestVersion: localVersion,
      );
    }
    final latestVersion = platformConfig['latest_version'] as String;

    return UpdateInfo(
      hasUpdate: _isVersionNewer(latestVersion, localVersion),
      forceUpdate: platformConfig['force'] as bool,
      changelog: platformConfig['changelog'] as String,
      downloadUrl: platformConfig['download_url'] as String,
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
        final announcement = await getPostDetail(1);
        announcementContent = announcement['content'] as String? ?? '';
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
          UpdateInfo(hasUpdate: false, latestVersion: Instances.appVersion),
    );
  }
}
