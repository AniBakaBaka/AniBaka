import 'dart:io';

import 'package:baka/services/app_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

      final recoveries = await AppStorage.init(hiveDirectory: hiveDirectory);

      expect(recoveries, hasLength(1));
      expect(recoveries.single.boxName, AppStorage.videoProgressBoxName);
      expect(recoveries.single.reason, contains('unknown typeId: 69'));
      expect(recoveries.single.backupPath, isNotNull);
      expect(await File(recoveries.single.backupPath!).exists(), isTrue);
      expect(AppStorage.videoProgressBox.isEmpty, isTrue);
      expect(AppStorage.customSourcesBox.isOpen, isTrue);
    },
  );
}

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
