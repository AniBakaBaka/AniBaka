import 'dart:io';
import 'package:baka/core/app_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _LegacyValue {
  const _LegacyValue(this.value);

  final String value;
}

class _LegacyValueAdapter extends TypeAdapter<_LegacyValue> {
  @override
  int get typeId => 37;

  @override
  _LegacyValue read(BinaryReader reader) => _LegacyValue(reader.readString());

  @override
  void write(BinaryWriter writer, _LegacyValue object) {
    writer.writeString(object.value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('recovery', () {
    test(
      'backs up and rebuilds only a box with an unknown legacy type',
      () async {
        final hiveDirectory = await Directory.systemTemp.createTemp(
          'baka-storage-recovery-test-',
        );
        addTearDown(() async {
          await Hive.close();
          if (await hiveDirectory.exists()) {
            await hiveDirectory.delete(recursive: true);
          }
        });
        Hive.init(hiveDirectory.path);
        Hive.registerAdapter<_LegacyValue>(_LegacyValueAdapter());

        final brokenBox = await Hive.openBox<Map>(
          AppStorage.videoProgressBoxName,
        );
        await brokenBox.put('progress', <String, Object>{
          'legacy': const _LegacyValue('unreadable'),
        });
        await Hive.close();
        Hive.resetAdapters();

        await AppStorage.init(hiveDirectory: hiveDirectory);

        final backups = Directory(
          '${hiveDirectory.path}${Platform.pathSeparator}recovery',
        ).listSync().map((entity) => entity.uri.pathSegments.last);
        expect(backups, [startsWith('${AppStorage.videoProgressBoxName}-')]);
        expect(AppStorage.videoProgressBox.isEmpty, isTrue);
        expect(AppStorage.customSourcesBox.isOpen, isTrue);
      },
    );
  });

  group('lazy boxes', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('baka-lazy-');
      Hive.init(directory.path);
    });
    tearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });
    test('startup opens its dependencies and defers feature storage', () async {
      await AppStorage.init(
        hiveDirectory: directory,
        boxes: AppStorage.startupBoxes,
      );
      expect(Hive.isBoxOpen(AppStorage.homeCacheBoxName), isTrue);
      expect(Hive.isBoxOpen(AppStorage.customSourcesBoxName), isFalse);
      expect(Hive.isBoxOpen(AppStorage.downloadTasksBoxName), isFalse);
      expect(Hive.isBoxOpen(AppStorage.threadCommentsBoxName), isFalse);
      final opening = AppStorage.open(AppStorage.downloadTasksBoxName);
      expect(
        identical(opening, AppStorage.open(AppStorage.downloadTasksBoxName)),
        isTrue,
      );
      await opening;
      expect(AppStorage.downloadTasksBox.isOpen, isTrue);
    });
  });
}
