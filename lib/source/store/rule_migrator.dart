import 'package:baka/models/custom_source_config.dart';
import 'package:baka/source/model/source_rule.dart';

/// 由 [CustomSourceConfig] 得到可执行的 [SourceRule]。
class RuleMigrator {
  RuleMigrator._();

  /// 由存储的配置得到可执行规则。
  static SourceRule ruleForConfig(CustomSourceConfig config) {
    return SourceRule.fromJson(<String, dynamic>{
      'id': config.id,
      'name': config.name,
      'baseUrl': config.baseUrl,
      'iconUrl': config.iconUrl,
      'description': config.description,
      ...config.pipeline!,
    });
  }
}
