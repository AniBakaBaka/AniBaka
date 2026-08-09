import 'dart:io';

import 'package:baka/instance.dart';
import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/services/app_storage.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/source_adapter_service.dart';
import 'package:baka/source/source_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;
  late SourceAdapterService service;
  late SourceCatalog catalog;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();

    hiveDirectory = await Directory.systemTemp.createTemp('baka-source-test-');
    Hive.init(hiveDirectory.path);
    await Hive.openBox<List>(AppStorage.customSourcesBoxName);

    service = SourceAdapterService.instance;
    await service.init();
    catalog = SourceCatalog.instance;
    await catalog.clearCustomSources();
  });

  tearDownAll(() async {
    await catalog.clearCustomSources();
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  test('rule hub uses the GitHub mirror by default', () async {
    expect(
      RuleRepositoryService.defaultSubscription,
      RuleRepositoryService.mirrorSubscription,
    );
    expect(
      RuleRepositoryService.resolveRuleUrl(
        RuleRepositoryService.defaultSubscription,
        'rules/example.json',
      ),
      '${RuleRepositoryService.githubMirrorPrefix}'
      'https://raw.githubusercontent.com/AniBakaBaka/AniBakaRule/main/'
      'rules/example.json',
    );

    await Instances.sp.setStringList('rule_hub_subscriptions', const [
      RuleRepositoryService.directSubscription,
    ]);
    expect(RuleRepositoryService.instance.subscriptions, const [
      RuleRepositoryService.mirrorSubscription,
    ]);
    await Instances.sp.remove('rule_hub_subscriptions');
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
    expect(await catalog.addCustomSource(source), isTrue);

    final first = service.adapterFor(
      AdapterRegistry.customSourceKey(source.id),
    );
    expect(first, isNotNull);

    final updated = source.copyWith(name: 'Updated Cache Test');
    expect(await catalog.updateCustomSource(updated), isTrue);

    final second = service.adapterFor(
      AdapterRegistry.customSourceKey(source.id),
    );
    expect(second, isNotNull);
    expect(second, isNot(same(first)));
    expect(second!.name, 'Updated Cache Test');

    expect(await catalog.deleteCustomSource(source.id), isTrue);
  });

  test('rule hub matches official entries by their stable key', () async {
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
    expect(await catalog.addCustomSource(source), isTrue);

    const byId = RuleHubItem(
      id: 'bulk-match',
      name: 'By Id',
      file: 'bulk-match.json',
      version: 2,
    );
    const missing = RuleHubItem(
      id: 'missing',
      name: 'Missing',
      file: 'missing.json',
    );

    final result = RuleRepositoryService.instance.inspectItems(const [
      byId,
      missing,
    ]);

    expect(result[byId]!.source?.id, source.id);
    expect(result[byId]!.status, InstallStatus.updateAvailable);
    expect(result[missing]!.status, InstallStatus.notInstalled);

    expect(await catalog.deleteCustomSource(source.id), isTrue);
  });

  test(
    'rule hub treats a bundled rule as installed and updates it in place',
    () async {
      const current = RuleHubItem(
        id: 'akianime',
        name: 'AkiAnime',
        file: 'akianime.json',
        version: 4,
      );
      const newer = RuleHubItem(
        id: 'akianime',
        name: 'AkiAnime',
        file: 'akianime.json',
        version: 5,
      );

      await Instances.sp.remove('rule_hub_version:akianime');
      final initial = RuleRepositoryService.instance.inspectItems(const [
        current,
        newer,
      ]);
      expect(initial[current]!.source?.id, 'akianime');
      expect(initial[current]!.status, InstallStatus.upToDate);
      expect(initial[newer]!.status, InstallStatus.updateAvailable);

      final previousAdapter = service.adapterFor('akianime');
      final result = await RuleRepositoryService.instance.install(
        newer,
        indexUrl: 'asset://assets/rules/index.json',
      );

      expect(result, RuleInstallResult.updated);
      expect(SourceCatalog.instance.customSourceById('akianime'), isNull);
      expect(
        SourceCatalog.instance.customSources.where(
          (source) => source.id == 'akianime',
        ),
        isEmpty,
      );
      expect(
        SourceCatalog.instance.builtinSourceById('akianime')?.baseUrl,
        'https://www.akianime.com',
      );
      expect(
        SourceCatalog.instance.builtinSourceById('akianime')?.iconUrl,
        'https://www.akianime.com/template/dsn2/static/img/ico.png',
      );
      final updatedAdapter = service.adapterFor('akianime');
      expect(updatedAdapter, isNot(same(previousAdapter)));
      expect(updatedAdapter?.baseUrl, 'https://www.akianime.com');
      expect(
        RuleRepositoryService.instance.inspectItems(const [
          newer,
        ])[newer]!.status,
        InstallStatus.upToDate,
      );

      expect(await catalog.resetBuiltinSource('akianime'), isTrue);
      await Instances.sp.remove('rule_hub_version:akianime');
      await Instances.sp.remove('rule_hub_source_id:akianime');
    },
  );
}
