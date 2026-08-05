import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/model/source_rule.dart';

/// Loads the former built-in sources from bundled `anx-rule/2` assets.
///
/// Built-in rules live under `assets/rules/`. Community rules are maintained
/// by AniBakaRule and are fetched by Rule Hub instead of being duplicated in
/// the application repository.
class BundledRuleStore {
  BundledRuleStore._();

  static const Map<String, String> builtinAssets = <String, String>{
    'akianime': 'assets/rules/akianime.json',
    'aniwatch': 'assets/rules/aniwatch.json',
    'cycani': 'assets/rules/cycani.json',
    'anime7': 'assets/rules/anime7.json',
    'dm84': 'assets/rules/dm84.json',
    'fsdm02': 'assets/rules/fsdm02.json',
    'girigirilove': 'assets/rules/girigirilove.json',
    'lm6': 'assets/rules/lm6.json',
    'jcydmz': 'assets/rules/jcydmz.json',
    'mgnacg': 'assets/rules/mgnacg.json',
    'ios_mifun': 'assets/rules/ios_mifun.json',
    'xifanacg': 'assets/rules/xifanacg.json',
  };

  /// Rule Hub revisions represented by the bundled copies.
  ///
  /// A zero revision means the rule is bundled only and has no matching
  /// official Rule Hub entry yet.
  static const Map<String, int> builtinVersions = <String, int>{
    'akianime': 4,
    'aniwatch': 0,
    'cycani': 2,
    'anime7': 2,
    'dm84': 0,
    'fsdm02': 0,
    'girigirilove': 2,
    'lm6': 4,
    'jcydmz': 0,
    'mgnacg': 0,
    'ios_mifun': 4,
    'xifanacg': 2,
  };

  static Map<String, SourceRule> _rules = const <String, SourceRule>{};
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= _load();

  static SourceRule? ruleFor(String key) => _rules[key];

  static int versionFor(String key) => builtinVersions[key] ?? 0;

  static Future<void> _load() async {
    final loaded = await Future.wait(
      builtinAssets.entries.map((entry) async {
        final raw = await rootBundle.loadString(entry.value);
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw FormatException('${entry.value}: rule root must be an object');
        }
        final rule = SourceRule.fromJson(Map<String, dynamic>.from(decoded));
        assert(() {
          final validation = RuleValidator.validate(rule);
          if (!validation.isValid) {
            throw FormatException(
              '${entry.value}: ${validation.errors.join('; ')}',
            );
          }
          if (rule.id != entry.key) {
            throw FormatException(
              '${entry.value}: asset id ${rule.id} does not match '
              'registry key ${entry.key}',
            );
          }
          return true;
        }());
        return MapEntry(entry.key, rule);
      }),
    );
    _rules = Map<String, SourceRule>.unmodifiable(
      Map<String, SourceRule>.fromEntries(loaded),
    );
  }
}
