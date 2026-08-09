class RuleHubIndex {
  const RuleHubIndex({required this.sourceUrl, required this.rules});

  factory RuleHubIndex.fromJson(
    Map<String, dynamic> json, {
    required String sourceUrl,
  }) {
    if (json['format'] != 'anx-rulehub/2') {
      throw const FormatException('Unsupported rule hub format');
    }
    final entries = json['entries'] as List<dynamic>;
    return RuleHubIndex(
      sourceUrl: sourceUrl,
      rules: entries
          .cast<Map<String, dynamic>>()
          .map(RuleHubItem.fromJson)
          .toList(growable: false),
    );
  }

  final String sourceUrl;
  final List<RuleHubItem> rules;
}

class RuleHubItem {
  const RuleHubItem({
    required this.id,
    required this.name,
    required this.file,
    this.author,
    this.description,
    this.baseUrl,
    this.iconUrl,
    this.version = 1,
    this.tags = const [],
  });

  factory RuleHubItem.fromJson(Map<String, dynamic> json) {
    return RuleHubItem(
      id: json['key'] as String,
      name: json['title'] as String,
      file: json['ref'] as String,
      author: json['by'] as String?,
      description: json['intro'] as String?,
      baseUrl: json['site'] as String?,
      iconUrl: json['badge'] as String?,
      version: json['rev'] as int,
      tags:
          (json['labels'] as List<dynamic>?)?.cast<String>() ??
          const <String>[],
    );
  }

  final String id;
  final String name;
  final String file;
  final String? author;
  final String? description;
  final String? baseUrl;
  final String? iconUrl;
  final int version;
  final List<String> tags;

  bool get hasResolvableConfig => file.isNotEmpty;
  String get displayVersion => version.toString();
  String get installKey => id;
}
