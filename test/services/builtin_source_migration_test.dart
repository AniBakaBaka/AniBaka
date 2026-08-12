import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'rule_hub_version:xifanacg': 3});
    Instances.sp = await SharedPreferences.getInstance();
    hiveDirectory = await Directory.systemTemp.createTemp(
      'baka-builtin-migration-test-',
    );
    Hive.init(hiveDirectory.path);
    await Hive.openBox<List>(AppStorage.customSourcesBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  test(
    'legacy custom entries with built-in ids migrate to overrides',
    () async {
      final timestamp = DateTime.utc(2026).toIso8601String();
      await AppStorage.customSourcesBox.put('custom_sources', [
        {
          'format': 'anx-rule/2',
          'id': 'akianime',
          'name': 'Migrated AkiAnime',
          'baseUrl': 'https://migrated.akianime.example',
          'pipeline': {
            'search': <Map<String, dynamic>>[],
            'detail': <Map<String, dynamic>>[],
            'play': <Map<String, dynamic>>[],
          },
          'enabled': true,
          'createdAt': timestamp,
          'updatedAt': timestamp,
        },
        {
          'format': 'anx-rule/2',
          'id': 'custom-only',
          'name': 'Custom Only',
          'baseUrl': 'https://custom.example',
          'pipeline': {
            'search': <Map<String, dynamic>>[],
            'detail': <Map<String, dynamic>>[],
            'play': <Map<String, dynamic>>[],
          },
          'enabled': true,
          'createdAt': timestamp,
          'updatedAt': timestamp,
        },
      ]);
      await AppStorage.customSourcesBox.put('builtin_source_overrides', [
        {
          'format': 'anx-rule/2',
          'id': 'xifanacg',
          'name': 'Stale Xifanacg',
          'baseUrl': 'https://anime.xifanacg.com',
          'pipeline': {
            'search': <Map<String, dynamic>>[],
            'detail': <Map<String, dynamic>>[],
            'play': <Map<String, dynamic>>[],
          },
          'enabled': true,
          'createdAt': timestamp,
          'updatedAt': timestamp,
        },
      ]);

      final service = SourceAdapterService.instance;
      await service.init();

      expect(SourceCatalog.instance.customSourceById('akianime'), isNull);
      expect(SourceCatalog.instance.customSourceById('custom-only'), isNotNull);
      expect(
        SourceCatalog.instance.builtinSourceById('akianime')?.baseUrl,
        'https://migrated.akianime.example',
      );
      expect(
        SourceCatalog.instance.builtinSourceById('xifanacg')?.baseUrl,
        'https://next.xifanacg.com',
      );

      final storedCustom =
          AppStorage.customSourcesBox.get('custom_sources') ?? const [];
      final storedOverrides =
          AppStorage.customSourcesBox.get('builtin_source_overrides') ??
          const [];
      expect(
        storedCustom.whereType<Map>().map((source) => source['id']),
        isNot(contains('akianime')),
      );
      expect(
        storedOverrides.whereType<Map>().map((source) => source['id']),
        contains('akianime'),
      );
      expect(
        storedOverrides.whereType<Map>().map((source) => source['id']),
        isNot(contains('xifanacg')),
      );
      expect(Instances.sp.getInt('rule_hub_version:xifanacg'), isNull);
    },
  );
}
