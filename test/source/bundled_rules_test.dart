import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/store/bundled_rule_store.dart';
import 'package:baka/source/store/rule_migrator.dart';

void main() {
  final assetDirectory = Directory('assets/rules');
  final assetFiles = assetDirectory
      .listSync()
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.json'))
      .toList(growable: false);

  test('only registered built-in rules are stored locally', () {
    expect(assetDirectory.existsSync(), isTrue);
    expect(
      assetFiles.map((file) => file.path.replaceAll(r'\', '/')).toSet(),
      BundledRuleStore.builtinAssets.values.toSet(),
    );
    final oldRuleDirectory = Directory('rule');
    expect(
      !oldRuleDirectory.existsSync() || oldRuleDirectory.listSync().isEmpty,
      isTrue,
    );
  });

  test('all built-in assets contain valid v2 pipeline rules', () {
    for (final file in assetFiles) {
      final name = file.uri.pathSegments.last;
      final decoded = SourceCodec.decode(file.readAsStringSync().trim());
      expect(decoded, isA<Map>(), reason: '$name must contain a JSON object');

      final config = CustomSourceConfig.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      );
      expect(config.id, isNotEmpty, reason: '$name missing id');
      expect(config.baseUrl, isNotEmpty, reason: '$name missing baseUrl');
      expect(config.iconUrl, isNotEmpty, reason: '$name missing iconUrl');

      final validation = RuleValidator.validate(
        RuleMigrator.ruleForConfig(config),
      );
      expect(
        validation.isValid,
        isTrue,
        reason: '$name invalid: ${validation.errors.join('; ')}',
      );
    }
  });

  test('each bundled asset decodes to a rule id matching its registry key', () {
    BundledRuleStore.builtinAssets.forEach((key, path) {
      final decoded = jsonDecode(File(path).readAsStringSync());
      final rule = SourceRule.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      );
      expect(rule.id, key, reason: '$path id must match registry key $key');
    });
  });

  test('pubspec bundles the built-in asset directory only', () {
    final pubspec = File(
      'pubspec.yaml',
    ).readAsLinesSync().map((line) => line.trim());
    expect(pubspec, contains('- assets/rules/'));
    expect(pubspec.any((line) => line.startsWith('- rule/')), isFalse);
  });
}
