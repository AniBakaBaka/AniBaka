/// anx-rule/2 规则模型（管线内核）。
///
/// search / detail / play 都是一组可序列化、可静态校验的 [PipelineStep]。
library;

import 'dart:collection';

/// v2 规则格式标识。
const String kSourceRuleFormatV2 = 'anx-rule/2';

/// 单个管线步骤：一个操作符（op）加上其参数。
class PipelineStep {
  /// 操作符名，如 `fetch`/`select`/`regex`/`first`。
  final String op;

  /// 该 op 的参数。约定：字符串参数支持 `{var}` 模板占位符。
  final Map<String, dynamic> params;

  /// JSON 载入时一次性编译的分支，避免每次执行重新创建整棵步骤树。
  final List<List<PipelineStep>>? _parsedBranches;

  const PipelineStep(this.op, this.params) : _parsedBranches = null;

  const PipelineStep.first(List<List<PipelineStep>> branches)
    : op = 'first',
      params = const <String, dynamic>{},
      _parsedBranches = branches;

  PipelineStep._(this.op, this.params, this._parsedBranches);

  factory PipelineStep.fromJson(Map<String, dynamic> json) {
    final params = <String, dynamic>{
      for (final entry in json.entries)
        if (entry.key != 'op' && entry.key != 'branches')
          entry.key: entry.value,
    };
    return PipelineStep._(
      (json['op'] as String?)?.trim() ?? '',
      UnmodifiableMapView(params),
      _parseBranches(json['branches']),
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'op': op, ...params};
    final branches = _parsedBranches;
    if (branches != null) {
      json['branches'] = [
        for (final branch in branches)
          [for (final step in branch) step.toJson()],
      ];
    }
    return json;
  }

  /// 取字符串参数。
  String? str(String key) {
    final value = params[key];
    return value is String ? value : value?.toString();
  }

  /// 取布尔参数。
  bool flag(String key, {bool fallback = false}) {
    final value = params[key];
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    return fallback;
  }

  /// 取整型参数。
  int? intValue(String key) {
    final value = params[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// `first` 的分支列表；JSON 规则在载入时只解析一次。
  List<List<PipelineStep>> get branches => _parsedBranches ?? const [];

  static List<List<PipelineStep>>? _parseBranches(Object? value) {
    if (value is! List) return null;
    final branches = <List<PipelineStep>>[];
    for (final rawBranch in value) {
      if (rawBranch is! List) continue;
      final branch = <PipelineStep>[];
      for (final rawStep in rawBranch) {
        if (rawStep is PipelineStep) {
          branch.add(rawStep);
        } else if (rawStep is Map) {
          branch.add(PipelineStep.fromJson(Map<String, dynamic>.from(rawStep)));
        }
      }
      branches.add(List<PipelineStep>.unmodifiable(branch));
    }
    return List<List<PipelineStep>>.unmodifiable(branches);
  }

  /// 取字符串列表参数。
  List<String> strList(String key) {
    final value = params[key];
    if (value is String) return [value];
    if (value is List) {
      return value.map((e) => e.toString()).toList(growable: false);
    }
    return const [];
  }
}

/// 一个完整的 v2 源规则。
class SourceRule {
  final String id;
  final String name;
  final String baseUrl;
  final String iconUrl;
  final String description;

  /// 全局请求头，作用于本规则发起的所有请求。
  final Map<String, String> headers;

  /// 预置配方（管线宏），如 `maccms`、`player_aaaa`。安装时展开为管线片段。
  final List<String> recipes;

  /// 搜索管线：输入关键词，产出 `Series` 列表。
  final List<PipelineStep> search;

  /// 详情管线：输入 seriesId，产出播放线路（`Source`）。
  final List<PipelineStep> detail;

  /// 播放管线：输入 episodeId，产出可播放直链（String）。
  final List<PipelineStep> play;

  /// 是否使用 WebView 渲染/嗅探。
  final bool useWebview;
  final bool directConnection;

  /// Optional lower bound for media reachability probes used by slow sources.
  /// Zero keeps the caller/default timeout unchanged.
  final int mediaValidationTimeoutMs;

  SourceRule({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.iconUrl = '',
    this.description = '',
    Map<String, String>? headers,
    List<String>? recipes,
    List<PipelineStep>? search,
    List<PipelineStep>? detail,
    List<PipelineStep>? play,
    this.useWebview = false,
    this.directConnection = false,
    this.mediaValidationTimeoutMs = 0,
  }) : headers = Map.unmodifiable(headers ?? const {}),
       recipes = List.unmodifiable(recipes ?? const []),
       search = List.unmodifiable(search ?? const []),
       detail = List.unmodifiable(detail ?? const []),
       play = List.unmodifiable(play ?? const []);

  /// 判断一个 JSON 是否声明为 v2 规则格式。
  static bool isV2Json(Map<String, dynamic> json) {
    final format = (json['format'] as String?)?.trim().toLowerCase();
    if (format == kSourceRuleFormatV2) return true;
    // 未声明 format 但含 search/detail/play 管线数组，也视为 v2。
    return json['search'] is List &&
        (json['detail'] is List || json['play'] is List);
  }

  factory SourceRule.fromJson(Map<String, dynamic> json) {
    List<PipelineStep> parseSteps(Object? value) {
      if (value is! List) return const [];
      return value
          .whereType<Map>()
          .map((e) => PipelineStep.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }

    return SourceRule(
      id: (json['id'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '未命名源',
      baseUrl: (json['baseUrl'] as String?)?.trim() ?? '',
      iconUrl: json['iconUrl']?.toString().trim() ?? '',
      description: (json['description'] as String?)?.trim() ?? '',
      headers: json['headers'] is Map
          ? {
              for (final entry in (json['headers'] as Map).entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const {},
      recipes: json['recipes'] is List
          ? (json['recipes'] as List)
                .map((e) => e.toString())
                .toList(growable: false)
          : const [],
      search: parseSteps(json['search']),
      detail: parseSteps(json['detail']),
      play: parseSteps(json['play']),
      useWebview: json['useWebview'] == true,
      directConnection: json['directConnection'] == true,
      mediaValidationTimeoutMs:
          int.tryParse(json['mediaValidationTimeoutMs']?.toString() ?? '') ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'format': kSourceRuleFormatV2,
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    if (iconUrl.isNotEmpty) 'iconUrl': iconUrl,
    if (description.isNotEmpty) 'description': description,
    if (headers.isNotEmpty) 'headers': headers,
    if (recipes.isNotEmpty) 'recipes': recipes,
    'search': search.map((s) => s.toJson()).toList(),
    'detail': detail.map((s) => s.toJson()).toList(),
    'play': play.map((s) => s.toJson()).toList(),
    if (useWebview) 'useWebview': true,
    if (directConnection) 'directConnection': true,
    if (mediaValidationTimeoutMs > 0)
      'mediaValidationTimeoutMs': mediaValidationTimeoutMs,
  };

  SourceRule copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? iconUrl,
    String? description,
    Map<String, String>? headers,
    List<String>? recipes,
    List<PipelineStep>? search,
    List<PipelineStep>? detail,
    List<PipelineStep>? play,
    bool? useWebview,
    bool? directConnection,
    int? mediaValidationTimeoutMs,
  }) {
    return SourceRule(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      iconUrl: iconUrl ?? this.iconUrl,
      description: description ?? this.description,
      headers: headers ?? this.headers,
      recipes: recipes ?? this.recipes,
      search: search ?? this.search,
      detail: detail ?? this.detail,
      play: play ?? this.play,
      useWebview: useWebview ?? this.useWebview,
      directConnection: directConnection ?? this.directConnection,
      mediaValidationTimeoutMs:
          mediaValidationTimeoutMs ?? this.mediaValidationTimeoutMs,
    );
  }
}
