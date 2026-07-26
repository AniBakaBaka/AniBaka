import 'package:baka/models/custom_source_config.dart';
import 'package:baka/source/model/source_rule.dart';

/// 由 [CustomSourceConfig] 得到可执行的 [SourceRule]。
class RuleMigrator {
  RuleMigrator._();

  static const Set<String> _legacyDirectConnectionRules = {'ani_pekolove'};

  /// 由存储的配置得到可执行规则。
  static SourceRule ruleForConfig(CustomSourceConfig config) {
    final pipeline = Map<String, dynamic>.from(config.pipeline!);
    // Older CustomSourceConfig decoding omitted directConnection. Preserve
    // direct routing for installed rules whose media authorization binds the
    // token request and segment requests to the same network exit.
    if (_legacyDirectConnectionRules.contains(config.id)) {
      pipeline.putIfAbsent('directConnection', () => true);
    }
    return SourceRule.fromJson(<String, dynamic>{
      'id': config.id,
      'name': config.name,
      'baseUrl': config.baseUrl,
      'iconUrl': config.iconUrl,
      'description': config.description,
      ...pipeline,
    });
  }
}
