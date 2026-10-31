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
    'query': 'Read a named query parameter from a URL.',
    'fetch': 'Perform an HTTP request and place its body in current.',
    'follow': 'Resolve and fetch a URL found in current content.',
    'delay': 'Pause execution for a given duration in milliseconds.',
    'select': 'Select HTML with css and extract text/html/attribute.',
    'urlDecode':
        'Decode percent-encoded text; form=true also decodes + as space.',
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
        'Attach media headers and select session cookies (headers, jsonPath, remove, cookieNames, cookiePrefixes).',
    'playerAaaa': 'Parse the common player_aaaa bootstrap object.',
    'playerDecrypt': 'Decrypt the supported player payload.',
    'sniff': 'Use WebView to follow a page and sniff playable media.',
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
- proxyMedia: stream HTTP media through the app's network client, preserving
  the source's proxy/DoH/ECH policy as well as Range and HEAD requests for files.
  Also enables materializeHls for complete VOD media playlists.
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
searchList requires selectors or listXPath. episodes requires listSelectors
or roadsXPath with itemsXPath. No site selectors are supplied by the engine;
CSS searchList reads linkSelector (default the row anchor or its a[href]), titleSelector
(default the link text), titleAttr (default text), imageSelector and imageAttr
(default src). An empty field selector reads the list item itself. Missing declared
fields stay empty; the engine does not search other titles or image attributes.
tabSelectors is optional. tabAttr chooses its field (default text); ownText
reads direct text nodes, excluding nested episode counts. Titles are preserved.
Episodes
are numbered in document order unless episodeNumberPattern is declared: its
first capture is the 1-based episode number in href; nonmatching links are skipped.
videoUrl scans literal media URLs only. Decode encoded fields with explicit
json/regex, urlDecode, or crypto steps. Playback URL normalization preserves
query values and signatures; extracting a nested player URL requires query.
jsonSeries accepts object rows and array rows; idKey/nameKey/imageKey/urlKey/
descKey are JSON paths (use [0], [1] for array columns). keywordMatch=true
filters names by bidirectional substring; caseSensitive defaults to false.
select with all=true returns a list. unique=true removes duplicate values.
To collect multiple HTML pages, first fetch the initial page, then use select
with nextSelector (a CSS selector for a link with href) and optional maxPages
(default 32, range 1..256, including the initial page). Relative links resolve
against each page; repeated URLs stop pagination. Optional headers apply to
subsequent page requests. Without nextSelector only the initial page is read.
jsonEpisodes with episodesPath="" reads a root list, including strings/numbers
as IDs. reverse=true reverses the episode list before numbering, and optional
episodeNameTemplate supplies missing titles using {index} (1-based), {index0}
(0-based), and {id}. Use episodeIdTemplate="{id:raw}" to preserve opaque IDs.
urlDecode reads current text or an input template and fails on malformed escapes.
For form POSTs, decode a percent-encoded token once, store it with setVar, then
use a raw placeholder in fetch.body; the host performs form encoding.
setMediaHeaders can select cookies for the resolved media URL by exact
cookieNames and/or cookiePrefixes. Unspecified selectors persist; [] clears
them. Cookie selection is independent of cookieSession serialization.
HTML sniffing has no default settle delay. Declare readyRegex/readyContains for
dynamic pages; set settleMs only when the site's protocol requires a delay.
''';
  }
}
