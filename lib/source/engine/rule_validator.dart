import 'package:baka/source/engine/recipes.dart';
import 'package:baka/source/model/source_rule.dart';

/// 规则静态校验结果。
class RuleValidation {
  final List<String> errors;
  final List<String> warnings;

  const RuleValidation(this.errors, this.warnings);

  bool get isValid => errors.isEmpty;
}

/// 规则静态校验器。
///
/// 在**安装/导入时**干跑规则的结构：检查必填元数据、op 名合法性、
/// 每个 op 的必填参数、正则可编译性。错误在导入时暴露，而不是等到播放时。
class RuleValidator {
  RuleValidator._();

  /// 引擎认识的全部 op。
  static const Set<String> knownOps = {
    'template',
    'setVar',
    'query',
    'fetch',
    'follow',
    'select',
    'regex',
    'replace',
    'json',
    'pick',
    'crypto',
    'baseN',
    'ecPlayer',
    'maccmsVerify',
    'first',
    'searchList',
    'jsonSeries',
    'episodes',
    'jsonEpisodes',
    'videoUrl',
    'setMediaHeaders',
    'playerAaaa',
    'playerDecrypt',
    'sniff',
    'anime1Search',
    'anime1Detail',
    'anime1Play',
    'hhPlayer',
    'torrentRecords',
    'maccmsSuggest',
  };

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
      final at = '$stage[$i] ${step.op}';
      if (!knownOps.contains(step.op)) {
        errors.add('$at: 未知 op');
        continue;
      }

      switch (step.op) {
        case 'regex':
          final pattern = step.str('pattern') ?? '';
          if (pattern.isEmpty) {
            errors.add('$at: 缺少 pattern');
          } else {
            try {
              RegExp(_regexValidationPattern(pattern));
            } catch (_) {
              errors.add('$at: 正则无法编译: $pattern');
            }
          }
          break;
        case 'replace':
          final pattern = step.str('pattern') ?? '';
          if (pattern.isEmpty) {
            errors.add('$at: 缺少 pattern');
          } else if (step.flag('regex')) {
            try {
              RegExp(_regexValidationPattern(pattern));
            } catch (_) {
              errors.add('$at: 正则无法编译: $pattern');
            }
          }
          break;
        case 'select':
          if ((step.str('css') ?? '').isEmpty) errors.add('$at: 缺少 css');
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
              RegExp(_regexValidationPattern(readyRegex));
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
          if (step.strList('selectors').isEmpty &&
              step.str('listXPath') == null) {
            warnings.add('$at: 未提供 selectors / listXPath');
          }
          break;
      }
    }
  }

  static String _regexValidationPattern(String pattern) {
    return pattern.replaceAllMapped(
      RegExp(r'\{[a-zA-Z0-9_]+(?::raw)?\}'),
      (_) => '0',
    );
  }
}
