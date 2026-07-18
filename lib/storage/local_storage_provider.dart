import 'dart:io';

import 'package:baka/storage/storage_provider.dart';

class LocalStorageProvider extends StorageProvider {
  @override
  final String displayName;

  LocalStorageProvider({required String rootPath, String? name})
    : displayName = name ?? StoragePath.name(rootPath);

  @override
  Future<List<StorageItem>> listDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return const [];

    final items = <StorageItem>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = StoragePath.name(entity.path);
      if (name.isEmpty || name.startsWith('.')) continue;

      if (entity is Directory) {
        items.add(
          StorageItem(
            name: name,
            path: entity.path,
            type: StorageItemType.directory,
          ),
        );
        continue;
      }

      final stat = await entity.stat();
      items.add(
        StorageItem(
          name: name,
          path: entity.path,
          type: StorageItemType.file,
          size: stat.size,
          modified: stat.modified,
        ),
      );
    }

    StoragePath.sort(items);
    return items;
  }

  @override
  String playableUrl(String path) => path;
}
