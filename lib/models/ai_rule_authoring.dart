import 'package:baka/models/custom_source_config.dart';

enum RuleAuthoringMode { create, repair }

class AiProviderConfig {
  const AiProviderConfig({
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
  });

  final String baseUrl;
  final String model;
  final String apiKey;

  bool get isConfigured => baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  Uri get chatCompletionsUri {
    final value = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (value.endsWith('/chat/completions')) return Uri.parse(value);
    return Uri.parse('$value/chat/completions');
  }
}

class RuleAuthoringSeed {
  const RuleAuthoringSeed({
    required this.mode,
    required this.siteUrl,
    required this.keyword,
    this.instructions = '',
    this.sourceKey,
    this.currentConfig,
    this.seriesId,
    this.episodeId,
    this.failureMessage,
    this.maxRounds = 25,
  });

  final RuleAuthoringMode mode;
  final String siteUrl;
  final String keyword;
  final String instructions;
  final String? sourceKey;
  final CustomSourceConfig? currentConfig;
  final String? seriesId;
  final String? episodeId;
  final String? failureMessage;
  final int maxRounds;
}

class RuleValidationReport {
  const RuleValidationReport({
    required this.success,
    required this.stage,
    required this.message,
    this.seriesCount = 0,
    this.lineCount = 0,
    this.episodeCount = 0,
    this.mediaKind,
  });

  final bool success;
  final String stage;
  final String message;
  final int seriesCount;
  final int lineCount;
  final int episodeCount;
  final String? mediaKind;

  Map<String, dynamic> toJson() => {
    'success': success,
    'stage': stage,
    'message': message,
    'seriesCount': seriesCount,
    'lineCount': lineCount,
    'episodeCount': episodeCount,
    if (mediaKind != null) 'mediaKind': mediaKind,
  };
}

class RuleAuthoringProgress {
  const RuleAuthoringProgress({
    required this.round,
    required this.stage,
    required this.message,
  });

  final int round;
  final String stage;
  final String message;
}

class RuleAuthoringResult {
  const RuleAuthoringResult({
    required this.config,
    required this.validation,
    required this.rounds,
  });

  final CustomSourceConfig config;
  final RuleValidationReport validation;
  final int rounds;
}

class PlayerFailureContext {
  const PlayerFailureContext({
    required this.message,
    required this.title,
    required this.sourceKey,
    required this.seriesId,
    required this.episodeId,
  });

  final String message;
  final String title;
  final String sourceKey;
  final String? seriesId;
  final String? episodeId;
}
