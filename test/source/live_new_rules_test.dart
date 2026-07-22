// 内置源规则化后的真实站点冒烟验证（默认跳过）。
//
// 运行方式（需要可访问目标站点的网络）：
//   flutter test test/source/live_new_rules_test.dart --dart-define=LIVE=true
//
// 验证链路：搜索 → 详情（线路/剧集） → 播放直链解析（不含 WebView 嗅探）。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/engine/pipeline_interpreter.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/engine/torrent_records.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/store/rule_migrator.dart';
import 'package:baka/services/source/rule_repository_service.dart';
import 'package:baka/services/torrent/torrent_service.dart';

const bool _live = bool.fromEnvironment('LIVE');

const _interpreter = PipelineInterpreter();

Future<SourceRule> _loadRule(String file) async {
  final bundled = File('assets/rules/$file');
  late final String raw;
  if (await bundled.exists()) {
    raw = await bundled.readAsString();
  } else {
    if (!_live) {
      throw StateError('Remote rule tests require --dart-define=LIVE=true');
    }
    final uri = Uri.parse(
      RuleRepositoryService.resolveRuleUrl(
        RuleRepositoryService.remoteSubscription,
        file,
      ),
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Unable to fetch $file: HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      raw = await utf8.decoder.bind(response).join();
    } finally {
      client.close(force: true);
    }
  }
  final rule = SourceRule.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  final validation = RuleValidator.validate(rule);
  expect(validation.errors, isEmpty, reason: '规则静态校验失败: ${validation.errors}');
  return rule;
}

Future<void> _probe(
  String file,
  String keyword, {
  // WebView 嗅探在测试环境不可用；依赖嗅探兜底的规则播放解析仅告警不判失败。
  bool strictPlay = true,
  bool verifyMedia = false,
  bool verifyKeepAlive = false,
  int? verifySegmentIndex,
  bool roundTripCustomConfig = false,
  int seriesIndex = 0,
  int episodeIndex = 0,
}) async {
  var rule = await _loadRule(file);
  if (roundTripCustomConfig) {
    rule = RuleMigrator.ruleForConfig(
      CustomSourceConfig.fromJson(rule.toJson()),
    );
  }
  final adapter = PipelineSourceAdapter(rule);

  final series = await _interpreter.runSearch(rule, adapter, keyword);
  // ignore: avoid_print
  print('[$file] search "$keyword" -> ${series.length} 条');
  for (final s in series.take(3)) {
    // ignore: avoid_print
    print('  - ${s.name} | ${s.seriesId}');
  }
  expect(series, isNotEmpty, reason: '$file 搜索无结果');

  // 搜索结果里可能有未开播条目（剧集列表为空），向后多试几条。
  var sources = <dynamic>[];
  for (final candidate in series.skip(seriesIndex).take(5)) {
    final result = await _interpreter.runDetail(
      rule,
      adapter,
      candidate.seriesId,
    );
    // ignore: avoid_print
    print('[$file] detail ${candidate.seriesId} -> ${result.length} 条线路');
    if (result.isNotEmpty && result.first.episodes.isNotEmpty) {
      sources = result;
      for (final src in result.take(3)) {
        // ignore: avoid_print
        print(
          '  - ${src.sourceName}: ${src.episodes.length} 集，'
          '首集 ${src.episodes.first.episodeId}',
        );
      }
      break;
    }
  }
  expect(sources, isNotEmpty, reason: '$file 详情无线路');

  // 与 App 内换源行为一致：逐条线路尝试首集，任一线路可解析即视为可用。
  var url = '';
  var mediaHeaders = const <String, String>{};
  for (final source in sources) {
    if (source.episodes.isEmpty) continue;
    final selectedEpisodeIndex = episodeIndex
        .clamp(0, source.episodes.length - 1)
        .toInt();
    final episodeId = source.episodes[selectedEpisodeIndex].episodeId as String;
    final media = await adapter.resolvePlaybackMedia(episodeId);
    url = media.url;
    mediaHeaders = media.httpHeaders;
    // ignore: avoid_print
    print(
      '[$file] play [${source.sourceName}] $episodeId -> '
      '${url.length > 200
          ? '${url.substring(0, 200)}…'
          : url.isEmpty
          ? '(空)'
          : url}',
    );
    if (url.isNotEmpty) {
      if (verifyMedia) {
        await adapter.startPlaybackKeepAlive(url);
        try {
          if (verifyKeepAlive) {
            await Future<void>.delayed(const Duration(seconds: 11));
          }
          final prepared = await adapter.preparePlaybackMedia((
            url: url,
            httpHeaders: mediaHeaders,
          ));
          await _expectMediaReadable(
            prepared.url,
            prepared.httpHeaders,
            segmentIndex: verifySegmentIndex,
          );
        } finally {
          adapter.stopPlaybackKeepAlive();
        }
      }
      break;
    }
  }
  if (strictPlay) {
    expect(url, isNotEmpty, reason: '$file 所有线路播放解析均为空');
  } else if (url.isEmpty) {
    // ignore: avoid_print
    print('[$file] 播放静态解析为空（App 内由 WebView 嗅探兜底）');
  }
}

Future<void> _expectMediaReadable(
  String mediaUrl,
  Map<String, String> headers, {
  int? segmentIndex,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final isRemote =
        mediaUrl.startsWith('http://') || mediaUrl.startsWith('https://');
    late Uri manifestUri;
    late String manifest;
    if (isRemote) {
      manifestUri = Uri.parse(mediaUrl);
      final request = await client.getUrl(manifestUri);
      headers.forEach(request.headers.set);
      final response = await request.close();
      expect(
        response.statusCode,
        anyOf(HttpStatus.ok, HttpStatus.partialContent),
        reason: '媒体清单不可访问: $mediaUrl',
      );
      if (!manifestUri.path.toLowerCase().endsWith('.m3u8')) {
        await response.drain<void>();
        return;
      }
      manifest = await utf8.decoder.bind(response).join();
    } else {
      final file = File(mediaUrl);
      expect(await file.exists(), isTrue, reason: '本地媒体清单不存在: $mediaUrl');
      manifestUri = file.uri;
      manifest = await file.readAsString();
    }
    for (var depth = 0; depth < 3; depth++) {
      if (manifest.contains('#EXT-X-MEDIA-SEQUENCE:')) break;
      if (!manifest.contains('#EXT-X-STREAM-INF:')) break;
      final variants = const LineSplitter()
          .convert(manifest)
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .toList(growable: false);
      expect(variants, isNotEmpty, reason: 'HLS 主清单没有子清单');
      manifestUri = manifestUri.resolve(variants.first);
      final request = await client.getUrl(manifestUri);
      headers.forEach(request.headers.set);
      final response = await request.close();
      expect(
        response.statusCode,
        anyOf(HttpStatus.ok, HttpStatus.partialContent),
        reason: 'HLS 子清单不可访问: $manifestUri',
      );
      manifest = await utf8.decoder.bind(response).join();
    }
    expect(manifest, contains('#EXT-X-MEDIA-SEQUENCE:0'));
    expect(manifest, contains('#EXT-X-ENDLIST'));
    final segmentLines = const LineSplitter()
        .convert(manifest)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList(growable: false);
    expect(segmentLines, isNotEmpty, reason: 'm3u8 中没有媒体分片');
    final selectedIndexes = <int>{
      0,
      if (segmentIndex != null)
        segmentIndex.clamp(0, segmentLines.length - 1).toInt(),
    };
    for (final selectedIndex in selectedIndexes) {
      final segmentLine = segmentLines[selectedIndex];
      final segmentUri = Uri.parse(segmentLine).hasScheme
          ? Uri.parse(segmentLine)
          : manifestUri.resolve(segmentLine);
      final segmentRequest = await client.getUrl(segmentUri);
      headers.forEach(segmentRequest.headers.set);
      segmentRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
      final segmentResponse = await segmentRequest.close();
      expect(
        segmentResponse.statusCode,
        anyOf(HttpStatus.ok, HttpStatus.partialContent),
        reason: '媒体分片不可访问: $segmentUri',
      );
      await segmentResponse.drain<void>();
    }
  } finally {
    client.close(force: true);
  }
}

void main() {
  group(
    'live probe (target rules)',
    () {
      test(
        '2kdm',
        () => _probe('2kdm.json', '我独自升级', verifyMedia: true, seriesIndex: 1),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        '7sefun',
        () => _probe('7sefun.json', '死神'),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        'ani_pekolove',
        () => _probe(
          'ani_pekolove.json',
          '\u6211\u72ec\u81ea\u5347\u7ea7',
          verifyMedia: true,
          verifyKeepAlive: true,
          verifySegmentIndex: 145,
          roundTripCustomConfig: true,
          seriesIndex: 1,
          episodeIndex: 1,
        ),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        'cyfz',
        () => _probe('cyfz.json', '\u6211\u72ec\u81ea\u5347\u7ea7'),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test('cyfz detail 1194', () async {
        final rule = await _loadRule('cyfz.json');
        final adapter = PipelineSourceAdapter(rule);
        final sources = await _interpreter.runDetail(
          rule,
          adapter,
          'https://www.cyfz.top/pages/1194.html',
        );
        expect(sources, hasLength(2));
        expect(sources.every((source) => source.episodes.length == 12), isTrue);
      }, timeout: const Timeout(Duration(minutes: 2)));
      test(
        'dalvdm',
        () => _probe('dalvdm.json', '\u6d77\u8d3c\u738b', strictPlay: false),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        'didahd',
        () => _probe('didahd.json', '海贼王', strictPlay: false),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        'ios_mifun',
        () => _probe('ios_mifun.json', '海贼王'),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        'agekkkk',
        () => _probe('agekkkk.json', '\u6d77\u8d3c\u738b', verifyMedia: true),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        'gugu',
        () => _probe('gugu.json', '海贼王'),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        'sorani',
        () => _probe('sorani.json', '海贼王', verifyMedia: true),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        'jcydmz',
        () => _probe('jcydmz.json', '\u6d77\u8d3c\u738b', verifyMedia: true),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test(
        'fsdm02',
        () => _probe('fsdm02.json', '咔嗒咔嗒', verifyMedia: true),
        timeout: const Timeout(Duration(minutes: 4)),
      );
      test(
        'mikan',
        () => _probe('mikan.json', '莉可丽丝'),
        timeout: const Timeout(Duration(minutes: 2)),
      );
      test('mikan BT stream', () async {
        final rule = await _loadRule('mikan.json');
        final adapter = PipelineSourceAdapter(rule);
        final html = await adapter.fetch(
          '${rule.baseUrl}/Home/Search?searchstr=${Uri.encodeQueryComponent('海贼王')}',
        );
        final torrentStep = rule.detail.firstWhere(
          (step) => step.op == 'torrentRecords',
        );
        final records = TorrentRecordParser.parseRecords(
          html: html,
          params: torrentStep.params,
          baseUrl: rule.baseUrl,
        );
        final episodeId = records
            .firstWhere(
              (record) =>
                  !record.excluded &&
                  record.episode != null &&
                  record.resourceId.isNotEmpty,
            )
            .resourceId;
        try {
          final streamUrl = await TorrentService.instance.resolvePlaybackUrl(
            episodeId,
            bufferTimeout: const Duration(seconds: 60),
          );
          expect(streamUrl, startsWith('http://127.0.0.1:'));
        } finally {
          await TorrentService.instance.stopStream();
        }
      }, timeout: const Timeout(Duration(minutes: 2)));
    },
    skip: _live ? false : '仅在 --dart-define=LIVE=true 时执行',
  );

  group('live probe (原内置源规则)', () {
    test(
      'girigirilove',
      () => _probe('girigirilove.json', '死神', strictPlay: false),
      timeout: const Timeout(Duration(minutes: 2)),
    );
    test(
      'xifanacg',
      () => _probe('xifanacg.json', '死神'),
      timeout: const Timeout(Duration(minutes: 2)),
    );
    test(
      'age',
      () => _probe('age.json', '死神', strictPlay: false),
      timeout: const Timeout(Duration(minutes: 2)),
    );
    test(
      'xigua',
      () => _probe('xigua.json', '死神'),
      timeout: const Timeout(Duration(minutes: 2)),
    );
    test(
      'gugu',
      () => _probe('gugu.json', '碧蓝之海'),
      timeout: const Timeout(Duration(minutes: 2)),
    );
    test(
      'cycani',
      () => _probe('cycani.json', '鬼灭', strictPlay: false),
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }, skip: _live ? false : '仅在 --dart-define=LIVE=true 时执行');
}
