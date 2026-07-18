enum StorageItemType { directory, file }

class StorageItem {
  static const _videoExtensions = {
    '.mp4',
    '.mkv',
    '.avi',
    '.flv',
    '.wmv',
    '.mov',
    '.webm',
    '.m4v',
    '.ts',
    '.rmvb',
    '.rm',
    '.3gp',
    '.mpg',
    '.mpeg',
  };

  final String name;
  final String path;
  final StorageItemType type;
  final int? size;
  final DateTime? modified;
  final String _normalizedName;

  StorageItem({
    required this.name,
    required this.path,
    required this.type,
    this.size,
    this.modified,
  }) : _normalizedName = name.toLowerCase();

  bool get isDirectory => type == StorageItemType.directory;
  bool get isFile => type == StorageItemType.file;

  bool get isVideo {
    final dot = _normalizedName.lastIndexOf('.');
    return dot >= 0 &&
        _videoExtensions.contains(_normalizedName.substring(dot));
  }

  String get displaySize {
    final bytes = size;
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

enum StorageProviderType { local, webdav, smb }

abstract class StorageProvider {
  String get displayName;

  Map<String, String>? get httpHeaders => null;

  Future<List<StorageItem>> listDirectory(String path);

  String playableUrl(String path);

  void dispose() {}
}

abstract final class StoragePath {
  static String name(String path) {
    var end = path.length;
    while (end > 0 && _isSeparator(path.codeUnitAt(end - 1))) {
      end--;
    }
    if (end == 0) return '';

    var start = end - 1;
    while (start >= 0 && !_isSeparator(path.codeUnitAt(start))) {
      start--;
    }
    return path.substring(start + 1, end);
  }

  static String trimTrailingSlash(String path) {
    var end = path.length;
    while (end > 1 && path.codeUnitAt(end - 1) == 0x2f) {
      end--;
    }
    return end == path.length ? path : path.substring(0, end);
  }

  static void sort(List<StorageItem> items) {
    items.sort((a, b) {
      final typeOrder = a.type.index.compareTo(b.type.index);
      return typeOrder != 0
          ? typeOrder
          : a._normalizedName.compareTo(b._normalizedName);
    });
  }

  static bool _isSeparator(int codeUnit) =>
      codeUnit == 0x2f || codeUnit == 0x5c;
}
