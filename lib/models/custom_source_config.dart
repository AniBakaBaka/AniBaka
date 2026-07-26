import 'package:baka/source/model/source_rule.dart';

class CustomSourceConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String iconUrl;
  final String description;

  /// v2 管线规则体（recipes/headers/search/detail/play/useWebview）。
  final Map<String, dynamic>? pipeline;

  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  CustomSourceConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    String? iconUrl,
    String? description,
    this.pipeline,
    bool? enabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : iconUrl = iconUrl ?? '',
       description = description ?? '',
       enabled = enabled ?? true,
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  factory CustomSourceConfig.fromJson(Map<String, dynamic> json) {
    final pipelineBody = _extractPipelineBody(json);
    return CustomSourceConfig(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '未命名源',
      baseUrl: (json['baseUrl'] as String?) ?? '',
      iconUrl:
          (json['iconUrl'] ?? json['icon'] ?? json['favicon'] ?? json['badge'])
              ?.toString() ??
          '',
      description: json['description'] as String?,
      pipeline: pipelineBody,
      enabled: json['enabled'] as bool?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }

  /// 从 JSON 中提取 v2 管线规则体；非 v2 返回 null。
  static Map<String, dynamic>? _extractPipelineBody(Map<String, dynamic> json) {
    if (json['pipeline'] is Map) {
      final pipeline = Map<String, dynamic>.from(json['pipeline'] as Map);
      if (!pipeline.containsKey('directConnection') &&
          json['directConnection'] != null) {
        pipeline['directConnection'] = json['directConnection'];
      }
      return pipeline;
    }
    if (!SourceRule.isV2Json(json)) return null;
    return <String, dynamic>{
      if (json['recipes'] != null) 'recipes': json['recipes'],
      if (json['headers'] != null) 'headers': json['headers'],
      if (json['search'] != null) 'search': json['search'],
      if (json['detail'] != null) 'detail': json['detail'],
      if (json['play'] != null) 'play': json['play'],
      if (json['useWebview'] != null) 'useWebview': json['useWebview'],
      if (json['directConnection'] != null)
        'directConnection': json['directConnection'],
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'format': kSourceRuleFormatV2,
      'id': id,
      'name': name,
      'baseUrl': baseUrl,
      if (iconUrl.isNotEmpty) 'iconUrl': iconUrl,
      'description': description,
      'pipeline': pipeline,
      'enabled': enabled,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  CustomSourceConfig copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? iconUrl,
    String? description,
    Map<String, dynamic>? pipeline,
    bool? enabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CustomSourceConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      iconUrl: iconUrl ?? this.iconUrl,
      description: description ?? this.description,
      pipeline: pipeline ?? this.pipeline,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'CustomSourceConfig(id: $id, name: $name, enabled: $enabled)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomSourceConfig &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(id, updatedAt);
}
