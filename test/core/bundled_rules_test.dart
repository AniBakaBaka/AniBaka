import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/source_registry.dart';
import 'package:baka/source/store/bundled_rule_store.dart';

void main() {
  final assetDirectory = Directory('assets/rules');
  final assetFiles = assetDirectory
      .listSync()
      .whereType<File>()
      .where(
        (file) =>
            file.path.toLowerCase().endsWith('.json') &&
            file.uri.pathSegments.last != 'index.json',
      )
      .toList(growable: false);

  test('all built-in assets contain valid v2 pipeline rules', () {
    for (final file in assetFiles) {
      final name = file.uri.pathSegments.last;
      final decoded = SourceCodec.decode(file.readAsStringSync().trim());
      expect(decoded, isA<Map>(), reason: '$name must contain a JSON object');

      // Use the same parser as BundledRuleStore, without import normalization.
      final rule = CustomSourceConfig.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      ).rule;
      expect(
        AdapterRegistry.isBuiltinSource(rule.id) &&
            BundledRuleStore.assetFor(rule.id) ==
                file.path.replaceAll(r'\', '/'),
        isTrue,
        reason: '$name registry mismatch',
      );
      expect(rule.baseUrl, isNotEmpty, reason: '$name missing baseUrl');
      expect(rule.search, isNotEmpty, reason: '$name missing search pipeline');
      expect(rule.detail, isNotEmpty, reason: '$name missing detail pipeline');
      expect(rule.play, isNotEmpty, reason: '$name missing play pipeline');

      final validation = RuleValidator.validate(rule);
      expect(
        validation.isValid,
        isTrue,
        reason: '$name invalid: ${validation.errors.join('; ')}',
      );
    }
  });

  test('bundled revisions identify the exact shipped rule contents', () {
    final index =
        jsonDecode(File(BundledRuleStore.indexAsset).readAsStringSync()) as Map;
    expect(index['format'], 'anx-rulehub/2');
    final entries = (index['entries'] as List).cast<Map>();
    final keys = AdapterRegistry.builtinSources.map((source) => source.key);
    expect(entries.map((entry) => entry['key']).toSet(), keys.toSet());
    expect(entries.length, keys.length);
    for (final entry in entries) {
      final path = BundledRuleStore.assetFor(entry['key'] as String);
      expect(path, 'assets/rules/${entry['ref']}');
      final body = File(path).readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        sha256.convert(utf8.encode(body)).toString(),
        entry['sha256'],
        reason: '${entry['key']}: sync content and rev together',
      );
      expect(entry['rev'], isNonNegative);
    }
  });
}
