/// 远程规则库（Rule Hub）的数据模型。
///
/// 规则库索引默认从 GitHub 加速节点获取，并依次回退到 jsDelivr 和 GitHub。
/// 采用与 kazumi 不同的清单式字段命名，索引结构如下：
///
/// ```json
/// {
///   "format": "anx-rulehub/1",
///   "title": "AniBaka 官方规则库",
///   "intro": "社区维护的图源规则集合",
///   "synced": "2026-01-01T00:00:00Z",
///   "entries": [
///     {
///       "key": "example-source",
///       "title": "示例源",
///       "by": "someone",
///       "rev": 3,
///       "intro": "支持 1080P / 弹幕",
///       "site": "https://example.com",
///       "badge": "https://.../icon.png",
///       "labels": ["1080P", "弹幕"],
///       "pack": "baka://...",          // 推荐：内联编码配置
///       "ref": "rules/example.json",   // 或：相对索引的远程文件
///       "raw": { ... }                 // 或：内联原始 JSON 配置
///     }
///   ]
/// }
/// ```
library;

class RuleHubIndex {
  static const String currentSchema = 'anx-rulehub/1';

  final String schema;
  final String name;
  final String? description;
  final DateTime? updatedAt;

  /// 该索引的来源订阅 URL。
  final String sourceUrl;
  final List<RuleHubItem> rules;

  const RuleHubIndex({
    required this.schema,
    required this.name,
    required this.sourceUrl,
    required this.rules,
    this.description,
    this.updatedAt,
  });

  factory RuleHubIndex.fromJson(
    Map<String, dynamic> json, {
    required String sourceUrl,
  }) {
    final rawEntries = _firstValue(json, const [
      'entries',
      'rules',
      'items',
      'sources',
    ]);
    final rules = <RuleHubItem>[];
    if (rawEntries is List) {
      for (final item in rawEntries.whereType<Map>()) {
        try {
          rules.add(RuleHubItem.fromJson(Map<String, dynamic>.from(item)));
        } catch (_) {
          // 跳过无效条目
        }
      }
    }
    return RuleHubIndex(
      schema: _stringValue(json, const ['format', 'schema']) ?? currentSchema,
      name: _stringValue(json, const ['title', 'name']) ?? '未命名规则库',
      description: _stringValue(json, const ['intro', 'description']),
      updatedAt: _parseDate(
        _firstValue(json, const [
          'synced',
          'updatedAt',
          'updated',
          'updateTime',
        ]),
      ),
      sourceUrl: sourceUrl,
      rules: rules,
    );
  }

  static DateTime? _parseDate(Object? value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }
}

class RuleHubItem {
  final String id;
  final String name;
  final String? author;
  final String? description;
  final String? baseUrl;
  final String? iconUrl;
  final int version;
  final String versionLabel;
  final List<String> tags;

  /// 内联编码配置（`baka://...`），优先级最高。
  final String? config;

  /// 相对索引 URL 的远程配置文件路径。
  final String? file;

  /// 内联原始 JSON 配置。
  final Map<String, dynamic>? inline;

  const RuleHubItem({
    required this.id,
    required this.name,
    this.author,
    this.description,
    this.baseUrl,
    this.iconUrl,
    this.version = 1,
    this.versionLabel = '1',
    this.tags = const [],
    this.config,
    this.file,
    this.inline,
  });

  bool get hasResolvableConfig =>
      (config != null && config!.isNotEmpty) ||
      (file != null && file!.isNotEmpty) ||
      (inline != null && inline!.isNotEmpty);

  String get displayVersion =>
      versionLabel.isNotEmpty ? versionLabel : version.toString();

  String get installKey {
    if (id.isNotEmpty) return id;
    if (name.isNotEmpty) return name;
    if (file?.isNotEmpty ?? false) return file!;
    if (baseUrl?.isNotEmpty ?? false) return baseUrl!;
    return displayVersion;
  }

  factory RuleHubItem.fromJson(Map<String, dynamic> json) {
    final rawVersion = _firstValue(json, const ['rev', 'version', 'ver']);
    final rawConfig = _firstValue(json, const ['raw', 'config']);
    final configString =
        _stringValue(json, const ['pack', 'encoded']) ??
        (rawConfig is String ? rawConfig.trim() : null);
    final rawTags = _firstValue(json, const ['labels', 'tags']);

    return RuleHubItem(
      id: _stringValue(json, const ['key', 'id']) ?? '',
      name: _stringValue(json, const ['title', 'name']) ?? '未命名规则',
      author: _stringValue(json, const ['by', 'author']),
      description: _stringValue(json, const ['intro', 'description']),
      baseUrl: _stringValue(json, const ['site', 'baseUrl', 'homepage']),
      iconUrl: _stringValue(json, const [
        'badge',
        'iconUrl',
        'icon',
        'favicon',
      ]),
      version: _parseVersionCode(rawVersion),
      versionLabel: _versionLabel(rawVersion),
      tags: rawTags is List
          ? rawTags
                .map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .toList(growable: false)
          : const [],
      config: configString,
      file: _stringValue(json, const ['ref', 'file', 'path']),
      inline: rawConfig is Map ? Map<String, dynamic>.from(rawConfig) : null,
    );
  }

  static int _parseVersionCode(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty) return 1;
      final direct = int.tryParse(text);
      if (direct != null) return direct;

      final parts = RegExp(r'\d+')
          .allMatches(text)
          .map((m) => int.tryParse(m.group(0) ?? '') ?? 0)
          .take(4)
          .toList(growable: false);
      if (parts.isEmpty) return 1;

      var code = 0;
      for (final part in parts) {
        code = code * 1000 + part.clamp(0, 999);
      }
      return code == 0 ? 1 : code;
    }
    return 1;
  }

  static String _versionLabel(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? '1' : text;
  }
}

Object? _firstValue(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    if (json.containsKey(key)) return json[key];
  }
  return null;
}

String? _stringValue(Map<String, dynamic> json, List<String> keys) {
  final value = _firstValue(json, keys);
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
