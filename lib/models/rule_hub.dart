class RuleHubIndex {
  /// 该索引的来源订阅 URL。
  final String sourceUrl;
  final List<RuleHubItem> rules;

  const RuleHubIndex({required this.sourceUrl, required this.rules});

  factory RuleHubIndex.fromJson(Map json, {required String sourceUrl}) {
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
          rules.add(RuleHubItem.fromJson(item));
        } catch (_) {
          // 跳过无效条目
        }
      }
    }
    return RuleHubIndex(sourceUrl: sourceUrl, rules: rules);
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

  factory RuleHubItem.fromJson(Map json) {
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

      // 单趟 code-unit 扫描：取前 4 段数字，每段截断到 999 后按千进制拼合。
      var code = 0;
      var parts = 0;
      var current = -1;
      for (var i = 0; i <= text.length && parts < 4; i++) {
        final u = i == text.length ? -1 : text.codeUnitAt(i);
        if (u >= 0x30 && u <= 0x39) {
          current = (current < 0 ? 0 : current * 10 + (u - 0x30));
          if (current > 999) current = 999;
        } else if (current >= 0) {
          code = code * 1000 + current;
          parts++;
          current = -1;
        }
      }
      if (parts == 0) return 1;
      return code == 0 ? 1 : code;
    }
    return 1;
  }

  static String _versionLabel(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? '1' : text;
  }
}

Object? _firstValue(Map json, List<String> keys) {
  for (final key in keys) {
    if (json.containsKey(key)) return json[key];
  }
  return null;
}

String? _stringValue(Map json, List<String> keys) {
  final value = _firstValue(json, keys);
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
