class UpdateInfo {
  final bool hasUpdate;
  final bool forceUpdate;
  final String changelog;
  final String downloadUrl;
  final String latestVersion;

  const UpdateInfo({
    required this.hasUpdate,
    required this.latestVersion,
    this.forceUpdate = false,
    this.changelog = '',
    this.downloadUrl = 'https://app.anibaka.com',
  });
}

class VersionManager {
  /// 按语义化版本比较，remote 比 local 新时返回 true。
  static bool isVersionNewer(String remoteVersion, String localVersion) {
    final remote = remoteVersion
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final local = localVersion
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final maxLength = remote.length > local.length
        ? remote.length
        : local.length;

    for (int i = 0; i < maxLength; i++) {
      final r = i < remote.length ? remote[i] : 0;
      final l = i < local.length ? local[i] : 0;
      if (r > l) return true;
      if (r < l) return false;
    }
    return false;
  }
}
