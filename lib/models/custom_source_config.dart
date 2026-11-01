import 'package:baka/source/models/source_rule.dart';

class CustomSourceConfig {
  /// The catalog, validator and adapter share this parsed rule.
  final SourceRule rule;
  String get id => rule.id;
  String get name => rule.name;
  String get baseUrl => rule.baseUrl;
  String get iconUrl => rule.iconUrl;
  String get description => rule.description;

  /// v2 管线规则体（recipes/headers/search/detail/play/useWebview）。
  final bool hasPipeline;
  Map<String, dynamic>? pipelineJson() =>
      hasPipeline ? rule.pipelineJson() : null;

  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  CustomSourceConfig({
    required String id,
    required String name,
    required String baseUrl,
    String? iconUrl,
    String? description,
    Map<String, dynamic>? pipeline,
    bool? enabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : rule = SourceRule.fromJson({
         'id': id,
         'name': name,
         'baseUrl': baseUrl,
         'iconUrl': iconUrl ?? '',
         'description': description ?? '',
         ...?pipeline,
       }),
       hasPipeline = pipeline != null,
       enabled = enabled ?? true,
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  CustomSourceConfig.fromRule(
    this.rule, {
    this.hasPipeline = true,
    this.enabled = true,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  factory CustomSourceConfig.fromJson(Map<String, dynamic> json) {
    final pipeline = (json['pipeline'] as Map?)?.cast<String, dynamic>();
    return CustomSourceConfig.fromRule(
      SourceRule.fromJson(pipeline == null ? json : {...json, ...pipeline}),
      hasPipeline: pipeline != null || SourceRule.isV2Json(json),
      enabled: json['enabled'] as bool? ?? true,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'format': kSourceRuleFormatV2,
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    if (iconUrl.isNotEmpty) 'iconUrl': iconUrl,
    'description': description,
    'pipeline': pipelineJson(),
    'enabled': enabled,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  CustomSourceConfig copyWith({
    String? name,
    bool? enabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => CustomSourceConfig.fromRule(
    name == null ? rule : rule.copyWith(name: name),
    hasPipeline: hasPipeline,
    enabled: enabled ?? this.enabled,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomSourceConfig &&
          id == other.id &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(id, updatedAt);
}
