import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/models/rule_hub.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/models/source_rule.dart';
import 'package:baka/source/source_registry.dart';

/// Loads the built-in sources from bundled `anx-rule/2` assets.
///
/// Community rules are maintained by AniBakaRule and fetched by Rule Hub
/// instead of being duplicated in the application repository.
class BundledRuleStore {
  BundledRuleStore._();

  static String assetFor(String key) => 'assets/rules/$key.json';

  /// Generated together with the rule files by tool/sync_bundled_rules.dart.
  /// Uses the repository's anx-rulehub/2 rev, never the application version.
  static const indexAsset = 'assets/rules/index.json';
  static Map<String, int> _versions = const {};
  static Map<String, SourceRule> _rules = const {};
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= _load();

  static SourceRule? ruleFor(String key) => _rules[key];

  static int versionFor(String key) => _versions[key] ?? 0;

  static Future<void> _load() async {
    final index = RuleHubIndex.fromJson(
      jsonDecode(await rootBundle.loadString(indexAsset))
          as Map<String, dynamic>,
      sourceUrl: 'asset://$indexAsset',
    );
    final loaded = await Future.wait(
      AdapterRegistry.builtinSources.map((source) async {
        final asset = assetFor(source.key);
        final rule = CustomSourceConfig.fromJson(
          jsonDecode(await rootBundle.loadString(asset))
              as Map<String, dynamic>,
        ).rule;
        assert(() {
          final validation = RuleValidator.validate(rule);
          if (!validation.isValid || rule.id != source.key) {
            throw FormatException(
              '$asset: id ${rule.id}; ${validation.errors.join('; ')}',
            );
          }
          return true;
        }());
        return MapEntry(source.key, rule);
      }),
    );
    _rules = Map.fromEntries(loaded);
    _versions = {for (final item in index.rules) item.id: item.version};
  }
}
