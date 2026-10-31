import 'package:baka/source/engine/recipes.dart';
import 'package:baka/source/engine/rule_language_spec.dart';
import 'package:baka/source/models/source_rule.dart';

/// 规则静态校验结果。
class RuleValidation {
  final List<String> errors;
  final List<String> warnings;

  const RuleValidation(this.errors, this.warnings);

  bool get isValid => errors.isEmpty;
}

/// 规则静态校验器。
class RuleValidator {
  RuleValidator._();

  static RuleValidation validate(SourceRule rule) {
    final errors = <String>[];
    final warnings = <String>[];

    if (rule.id.trim().isEmpty) errors.add('缺少 id');
    if (rule.name.trim().isEmpty) errors.add('缺少 name');
    if (rule.baseUrl.trim().isEmpty) {
      errors.add('缺少 baseUrl');
    } else if (Uri.tryParse(rule.baseUrl) == null) {
      errors.add('baseUrl 不是合法 URL: ${rule.baseUrl}');
    }
    if (rule.iconUrl.isNotEmpty) {
      final iconUri = Uri.tryParse(rule.iconUrl);
      if (iconUri == null ||
          (iconUri.scheme != 'http' && iconUri.scheme != 'https') ||
          iconUri.host.isEmpty) {
        errors.add('iconUrl 不是合法 HTTP URL: ${rule.iconUrl}');
      }
    }

    for (final recipe in rule.recipes) {
      if (!Recipes.known.contains(recipe.toLowerCase())) {
        warnings.add('未知配方: $recipe');
      }
    }

    final expanded = Recipes.expand(rule);
    if (expanded.search.isEmpty) warnings.add('search 管线为空');
    if (expanded.detail.isEmpty) warnings.add('detail 管线为空');
    if (expanded.play.isEmpty) warnings.add('play 管线为空');

    _validateSteps(expanded.search, 'search', errors, warnings);
    _validateSteps(expanded.detail, 'detail', errors, warnings);
    _validateSteps(expanded.play, 'play', errors, warnings);

    return RuleValidation(errors, warnings);
  }

  static void _validateSteps(
    List<PipelineStep> steps,
    String stage,
    List<String> errors,
    List<String> warnings,
  ) {
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      late final at = '$stage[$i] ${step.op}';
      if (!RuleLanguageSpec.operations.containsKey(step.op)) {
        errors.add('$at: 未知 op');
        continue;
      }

      switch (step.op) {
        case 'regex':
        case 'replace':
          final pattern = step.str('pattern') ?? '';
          if (pattern.isEmpty) {
            errors.add('$at: 缺少 pattern');
          } else if (step.op == 'regex' || step.flag('regex')) {
            try {
              RegExp(
                pattern.replaceAll(RuleLanguageSpec.templatePlaceholder, '0'),
              );
            } catch (_) {
              errors.add('$at: 正则无法编译: $pattern');
            }
          }
          break;
        case 'select':
          if ((step.str('css') ?? '').isEmpty) errors.add('$at: 缺少 css');
          if ((step.str('nextSelector') ?? '').isNotEmpty &&
              !step.flag('all')) {
            errors.add('$at: nextSelector 需要 all=true');
          }
          if (step.params.containsKey('maxPages')) {
            final maxPages = step.intValue('maxPages');
            if (maxPages == null || maxPages < 1 || maxPages > 256) {
              errors.add('$at: maxPages 必须在 1..256 之间');
            }
          }
          break;
        case 'crypto':
          final algo = (step.str('algo') ?? '').toLowerCase();
          const algos = {
            'base64',
            'md5',
            'sha1',
            'sha256',
            'aes-cbc',
            'aes-gcm',
          };
          if (!algos.contains(algo)) errors.add('$at: 未知 algo: $algo');
          break;
        case 'baseN':
          final alphabet = step.str('alphabet') ?? '';
          if (alphabet.length < 2) {
            errors.add('$at: alphabet 至少需要两个字符');
          }
          break;
        case 'playerDecrypt':
          if ((step.str('salt') ?? '').isEmpty) {
            errors.add('$at: 缺少 salt');
          }
          break;
        case 'sniff':
          final readyRegex = step.str('readyRegex') ?? '';
          if (readyRegex.isNotEmpty) {
            try {
              RegExp(
                readyRegex.replaceAll(
                  RuleLanguageSpec.templatePlaceholder,
                  '0',
                ),
              );
            } catch (_) {
              errors.add('$at: readyRegex 无法编译: $readyRegex');
            }
          }
          break;
        case 'jsonSeries':
        case 'maccmsSuggest':
          if ((step.str('idTransform') ?? '').toLowerCase() == 'basen' &&
              (step.str('idAlphabet') ?? step.str('alphabet') ?? '').length <
                  2) {
            errors.add('$at: baseN idTransform 的 idAlphabet 至少需要两个字符');
          }
          break;
        case 'first':
          final branches = step.branches;
          if (branches.isEmpty) {
            errors.add('$at: branches 为空');
          }
          for (final branch in branches) {
            _validateSteps(branch, '$at.branch', errors, warnings);
          }
          break;
        case 'searchList':
          if (!_hasSelector(step, 'selectors') &&
              (step.str('listXPath') ?? '').trim().isEmpty) {
            errors.add('$at: 缺少 selectors / listXPath');
          }
          break;
        case 'episodes':
          final roadsXPath = (step.str('roadsXPath') ?? '').trim();
          if (!_hasSelector(step, 'listSelectors') && roadsXPath.isEmpty) {
            errors.add('$at: 缺少 listSelectors / roadsXPath');
          }
          if (roadsXPath.isNotEmpty &&
              (step.str('itemsXPath') ?? '').trim().isEmpty) {
            errors.add('$at: roadsXPath 需要 itemsXPath');
          }
          final episodeNumberPattern = step.str('episodeNumberPattern');
          if (episodeNumberPattern != null) {
            try {
              RegExp(episodeNumberPattern);
            } on FormatException {
              errors.add('$at: episodeNumberPattern 正则无法编译');
            }
          }
          break;
      }
    }
  }

  static bool _hasSelector(PipelineStep step, String key) {
    final value = step.params[key];
    if (value is String) return value.trim().isNotEmpty;
    return value is List &&
        value.every((selector) => selector is String) &&
        value.any((selector) => (selector as String).trim().isNotEmpty);
  }
}
