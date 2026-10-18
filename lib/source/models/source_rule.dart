/// anx-rule/2 规则模型（管线内核）。
///
/// search / detail / play 都是一组可序列化、可静态校验的 [PipelineStep]。
library;

/// v2 规则格式标识。
const String kSourceRuleFormatV2 = 'anx-rule/2';

/// 单个管线步骤：一个操作符（op）加上其参数。字符串参数支持 `{var}` 模板。
class PipelineStep {
  const PipelineStep(this.op, this.params) : branches = const [];

  /// `first` 的分支，依次试跑。
  const PipelineStep.first(this.branches)
    : op = 'first',
      params = const <String, dynamic>{};

  PipelineStep._(this.op, this.params, this.branches);

  /// Branches are compiled once at load, never on each execution.
  factory PipelineStep.fromJson(Map<String, dynamic> json) => PipelineStep._(
    (json['op'] as String?)?.trim() ?? '',
    {
      for (final entry in json.entries)
        if (entry.key != 'op' && entry.key != 'branches')
          entry.key: entry.value,
    },
    switch (json['branches']) {
      final List raw => List.unmodifiable(
        raw.whereType<List>().map(
          (branch) => List<PipelineStep>.unmodifiable(
            branch.whereType<Map>().map(
              (step) => PipelineStep.fromJson(step.cast<String, dynamic>()),
            ),
          ),
        ),
      ),
      _ => const <List<PipelineStep>>[],
    },
  );

  final String op;
  final Map<String, dynamic> params;
  final List<List<PipelineStep>> branches;

  Map<String, dynamic> toJson() => {
    'op': op,
    ...params,
    if (branches.isNotEmpty)
      'branches': [
        for (final branch in branches)
          [for (final step in branch) step.toJson()],
      ],
  };

  String? str(String key) {
    final value = params[key];
    return value is String ? value : value?.toString();
  }

  bool flag(String key) {
    final value = params[key];
    return value == true || (value is String && value.toLowerCase() == 'true');
  }

  int? intValue(String key) => switch (params[key]) {
    final num value => value.toInt(),
    final String value => int.tryParse(value.trim()),
    _ => null,
  };

  List<String> strList(String key) => switch (params[key]) {
    final String value => [value],
    final List<String> value => value,
    final List value => value.cast<String>(),
    _ => const [],
  };
}

/// 一个完整的 v2 源规则。
class SourceRule {
  const SourceRule({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.iconUrl = '',
    this.description = '',
    this.headers = const {},
    this.recipes = const [],
    this.search = const [],
    this.detail = const [],
    this.play = const [],
    this.useWebview = false,
    this.directConnection = false,
    this.mediaValidationTimeoutMs = 0,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String iconUrl;
  final String description;

  /// 全局请求头，作用于本规则发起的所有请求。
  final Map<String, String> headers;

  /// 预置配方（管线宏），如 `maccms`、`player_aaaa`。
  final List<String> recipes;

  /// 搜索管线：输入关键词，产出 `Series` 列表。
  final List<PipelineStep> search;

  /// 详情管线：输入 seriesId，产出播放线路（`Source`）。
  final List<PipelineStep> detail;

  /// 播放管线：输入 episodeId，产出可播放直链。
  final List<PipelineStep> play;

  /// 是否使用 WebView 渲染/嗅探。
  final bool useWebview;
  final bool directConnection;

  /// Media probe timeout for slow sources; zero keeps the default.
  final int mediaValidationTimeoutMs;

  /// 判断一个 JSON 是否声明为 v2 规则格式。
  static bool isV2Json(Map<String, dynamic> json) =>
      (json['format'] as String?)?.trim().toLowerCase() ==
          kSourceRuleFormatV2 ||
      (json['search'] is List &&
          (json['detail'] is List || json['play'] is List));

  factory SourceRule.fromJson(Map<String, dynamic> json) {
    List<PipelineStep> steps(Object? value) => value is List
        ? List.unmodifiable(
            value.whereType<Map>().map(
              (step) => PipelineStep.fromJson(step.cast<String, dynamic>()),
            ),
          )
        : const [];

    return SourceRule(
      id: (json['id'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '未命名源',
      baseUrl: (json['baseUrl'] as String?)?.trim() ?? '',
      iconUrl: json['iconUrl']?.toString().trim() ?? '',
      description: (json['description'] as String?)?.trim() ?? '',
      headers: switch (json['headers']) {
        final Map raw => Map.unmodifiable({
          for (final entry in raw.entries)
            entry.key.toString(): entry.value.toString(),
        }),
        _ => const {},
      },
      recipes: switch (json['recipes']) {
        final List raw => List.unmodifiable(raw.map((e) => e.toString())),
        _ => const [],
      },
      search: steps(json['search']),
      detail: steps(json['detail']),
      play: steps(json['play']),
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
    ...pipelineJson(),
  };

  /// JSON is materialized only for editing, exporting or persistence.
  Map<String, dynamic> pipelineJson() => {
    if (headers.isNotEmpty) 'headers': headers,
    if (recipes.isNotEmpty) 'recipes': recipes,
    'search': [for (final step in search) step.toJson()],
    'detail': [for (final step in detail) step.toJson()],
    'play': [for (final step in play) step.toJson()],
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
    List<PipelineStep>? search,
    List<PipelineStep>? detail,
    List<PipelineStep>? play,
  }) => SourceRule(
    id: id ?? this.id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    iconUrl: iconUrl ?? this.iconUrl,
    description: description ?? this.description,
    headers: headers,
    recipes: recipes,
    search: search ?? this.search,
    detail: detail ?? this.detail,
    play: play ?? this.play,
    useWebview: useWebview,
    directConnection: directConnection,
    mediaValidationTimeoutMs: mediaValidationTimeoutMs,
  );
}
