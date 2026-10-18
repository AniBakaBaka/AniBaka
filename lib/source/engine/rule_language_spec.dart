import 'package:baka/source/models/source_rule.dart';

/// Single prompt/validation-facing description of the anx-rule/2 language.
class RuleLanguageSpec {
  RuleLanguageSpec._();

  static final templatePlaceholder = RegExp(
    r'\{([a-zA-Z_][a-zA-Z0-9_]*)(:raw)?\}',
  );

  static const Map<String, String> operations = {
    'template': 'Render a string template with variables.',
    'setVar': 'Store a rendered value in a named variable.',
    'query': 'Build or transform URL query parameters.',
    'fetch': 'Perform an HTTP request and place its body in current.',
    'follow': 'Resolve and fetch a URL found in current content.',
    'delay': 'Pause execution for a given duration in milliseconds.',
    'select': 'Select HTML with css and extract text/html/attribute.',
    'regex': 'Extract a regex capture from current text.',
    'replace': 'Replace literal or regex text in current.',
    'json': 'Decode current text as JSON.',
    'pick': 'Read a JSON path or indexed value.',
    'crypto': 'Apply base64/hash/AES transformations.',
    'baseN': 'Encode or decode using a custom alphabet.',
    'ecPlayer': 'Resolve an EC player payload.',
    'maccmsVerify': 'Complete the supported MacCMS verification flow.',
    'first': 'Try branches in order and keep the first successful branch.',
    'searchList': 'Build Series items from HTML CSS/XPath selectors.',
    'jsonSeries': 'Build Series items from a JSON list.',
    'episodes': 'Build Source and Episode items from HTML.',
    'jsonEpisodes': 'Build Source and Episode items from JSON.',
    'maccmsApiEpisodes': 'Build episode lines from a MacCMS provide API.',
    'videoUrl': 'Extract a playable URL from current content.',
    'setMediaHeaders':
        'Attach HTTP headers to the resolved media (headers, jsonPath, remove).',
    'playerAaaa': 'Parse the common player_aaaa bootstrap object.',
    'playerDecrypt': 'Decrypt the supported player payload.',
    'sniff': 'Use WebView to follow a page and sniff playable media.',
    'anime1Search': 'Run the built-in Anime1 search protocol.',
    'anime1Detail': 'Run the built-in Anime1 episode protocol.',
    'anime1Play': 'Run the built-in Anime1 playback protocol.',
    'hhPlayer': 'Resolve the supported HHPlayer bootstrap API.',
    'torrentRecords': 'Build torrent episodes from supported records.',
    'maccmsSuggest': 'Search through MacCMS suggest endpoints.',
  };

  static String get promptReference {
    final ops = operations.entries
        .map((entry) => '- ${entry.key}: ${entry.value}')
        .join('\n');
    return '''
Format: $kSourceRuleFormatV2
Root fields: id, name, baseUrl, optional iconUrl/description, and pipeline.
Pipeline fields: optional recipes, headers, search, detail, play, useWebview,
directConnection, mediaValidationTimeoutMs. Each stage is an array of objects
with an op field. Supported recipes: maccms, player_aaaa.

Supported operations:
$ops

Stage flags are optional booleans on play-stage steps (branch steps included):
- materializeHls: serve a complete VOD HLS manifest through the app, so segment
  requests keep the rule's Referer/Cookie headers.
- stripHlsTsPrefix: remove an image/junk prefix before MPEG-TS packets in HLS
  segments. Implies materializeHls, including non-m3u8 playlist endpoints.
  Segments are served in full because removing a prefix changes byte offsets;
  encryption keys and initialization maps retain their original bytes/ranges.
- hlsManifestDecode: decode a binary HLS manifest using a declared map, e.g.
  {scheme: xor, prefix: enc, key: [144,223,214,167,22,76,53], period: 10,
   fallbackIndex: 6, xor: 165, skipBytes: 3, trimPrefixBeforeM3u8: true}.
  This enables materialization and resolves a master to one bitrate variant.
- filterHlsAds: drop HLS segments whose video encoding differs from the rest of
  the playlist, which removes ads spliced into the stream. Implies
  materializeHls; also resolves a master playlist down to one bitrate variant.
- resolveMediaRedirects: follow the media URL redirect chain before playback.
- validateWithCookies: validate the media URL with the play-stage cookies.
- followEmbeddedPlayer: follow embedded iframe players while sniffing.
- playbackKeepAlive: repeat this step's request while the media is playing.
- cookieSession: run the play stage one resolution at a time. Use it when the
  play page issues a single-use playback credential (cookie/session) that a
  concurrent resolution of another episode would invalidate.

The search stage must produce Series results, detail must produce playback
lines and episodes, and play must produce a direct media URL. Prefer generic
operations over inventing a new operation. Never return executable Dart code.
JSON paths and HTML selectors are exact: a missing path or selector does not
trigger a search elsewhere. Use explicit pipe-separated JSON paths or first
branches for known alternatives. An empty JSON path selects the root value.
HTML sniffing has no default settle delay. Declare readyRegex/readyContains for
dynamic pages; set settleMs only when the site's protocol requires a delay.
''';
  }
}
