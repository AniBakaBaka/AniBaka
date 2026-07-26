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
