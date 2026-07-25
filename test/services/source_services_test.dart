import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;
  late SourceAdapterService service;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();

    hiveDirectory = await Directory.systemTemp.createTemp('baka-source-test-');
    Hive.init(hiveDirectory.path);
    await Hive.openBox<List>(AppStorage.customSourcesBoxName);

    service = SourceAdapterService.instance;
    await service.init();
    await service.clearAllCustomSources();
  });

  tearDownAll(() async {
    await service.clearAllCustomSources();
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  test('custom adapter cache follows the current rule revision', () async {
    final source = CustomSourceConfig(
      id: 'cache-test',
      name: 'Cache Test',
      baseUrl: 'https://example.com',
      pipeline: const {
        'search': <Map<String, dynamic>>[],
        'detail': <Map<String, dynamic>>[],
        'play': <Map<String, dynamic>>[],
      },
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    expect(await service.addCustomSource(source), isTrue);

    final searchService = SourceAdapterService();
    final first = searchService.getCustomAdapter(source);
    expect(first, isNotNull);

    final updated = source.copyWith(name: 'Updated Cache Test');
    expect(await service.updateCustomSource(updated), isTrue);

    final second = searchService.getCustomAdapter(source);
    expect(second, isNotNull);
    expect(second, isNot(same(first)));
    expect(second!.name, 'Updated Cache Test');

    searchService.dispose();
    expect(await service.deleteCustomSource(source.id), isTrue);
  });

  test('rule hub matches all items with one indexed source scan', () async {
    final source = CustomSourceConfig(
      id: 'bulk-match',
      name: 'Bulk Match',
      baseUrl: 'https://bulk.example.com',
      pipeline: const {
        'search': <Map<String, dynamic>>[],
        'detail': <Map<String, dynamic>>[],
        'play': <Map<String, dynamic>>[],
      },
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    expect(await service.addCustomSource(source), isTrue);

    const byId = RuleHubItem(id: 'bulk-match', name: 'By Id', version: 2);
    const byName = RuleHubItem(id: '', name: 'Bulk Match', version: 2);
    const byUrl = RuleHubItem(
      id: '',
      name: 'By Url',
      baseUrl: 'https://bulk.example.com',
      version: 2,
    );
    const missing = RuleHubItem(id: 'missing', name: 'Missing');

    final result = RuleRepositoryService.instance.inspectItems(const [
      byId,
      byName,
      byUrl,
      missing,
    ]);

    expect(result[byId]!.source?.id, source.id);
    expect(result[byName]!.source?.id, source.id);
    expect(result[byUrl]!.source?.id, source.id);
    expect(result[byId]!.status, InstallStatus.updateAvailable);
    expect(result[missing]!.status, InstallStatus.notInstalled);

    expect(await service.deleteCustomSource(source.id), isTrue);
  });

  test(
    'rule hub treats a bundled rule as installed and updates it in place',
    () async {
      const current = RuleHubItem(id: 'akianime', name: 'AkiAnime', version: 4);
      const newer = RuleHubItem(
        id: 'akianime',
        name: 'AkiAnime',
        version: 5,
        inline: {
          'format': 'anx-rule/2',
          'id': 'akianime',
          'name': 'AkiAnime Updated',
          'baseUrl': 'https://updated.akianime.example',
          'iconUrl': 'https://updated.akianime.example/icon.png',
          'search': <Map<String, dynamic>>[],
          'detail': <Map<String, dynamic>>[],
          'play': <Map<String, dynamic>>[],
        },
      );

      await Instances.sp.remove('rule_hub_version:akianime');
      final initial = RuleRepositoryService.instance.inspectItems(const [
        current,
        newer,
      ]);
      expect(initial[current]!.source?.id, 'akianime');
      expect(initial[current]!.status, InstallStatus.upToDate);
      expect(initial[newer]!.status, InstallStatus.updateAvailable);

      final previousAdapter = service.getBuiltinAdapter('akianime');
      final result = await RuleRepositoryService.instance.install(
        newer,
        indexUrl: 'https://rules.example/index.json',
      );

      expect(result, RuleInstallResult.updated);
      expect(service.customSourceById('akianime'), isNull);
      expect(
        service.allCustomSources.where((source) => source.id == 'akianime'),
        isEmpty,
      );
      expect(
        service.builtinSourceById('akianime')?.baseUrl,
        'https://updated.akianime.example',
      );
      expect(
        service.builtinSourceById('akianime')?.iconUrl,
        'https://updated.akianime.example/icon.png',
      );
      final updatedAdapter = service.getBuiltinAdapter('akianime');
      expect(updatedAdapter, isNot(same(previousAdapter)));
      expect(updatedAdapter?.baseUrl, 'https://updated.akianime.example');
      expect(
        RuleRepositoryService.instance.inspectItems(const [
          newer,
        ])[newer]!.status,
        InstallStatus.upToDate,
      );

      expect(await service.resetBuiltinSource('akianime'), isTrue);
      await Instances.sp.remove('rule_hub_version:akianime');
      await Instances.sp.remove('rule_hub_source_id:akianime');
    },
  );
}
