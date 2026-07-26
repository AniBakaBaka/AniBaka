import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:baka/source/html_parser.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/store/rule_migrator.dart';
import 'package:baka/models/custom_source_config.dart';

class AutoMatchResult {
  final bool success;
  final Map<String, dynamic>? pipeline;
  final String detectedType;
  final String log;
  final String? seriesUrl;
  final String? episodeUrl;
  final String? playUrl;

  const AutoMatchResult({
    required this.success,
    required this.detectedType,
    required this.log,
    this.pipeline,
    this.seriesUrl,
    this.episodeUrl,
    this.playUrl,
  });
}

/// Detects a site type and builds a verified pipeline from its base URL.
class AutoMatchService {
  AutoMatchService._();

  static const _searchUrlPatterns = [
    '/index.php/vod/search/wd/{keyword}.html',
    '/search?q={keyword}',
    '/vodsearch/{keyword}',
    '/s----------.html?wd={keyword}',
    '/index.php/vod/search.html?wd={keyword}',
  ];

  static final RegExp _trailingSlashPattern = RegExp(r'/+$');

  static Future<AutoMatchResult> autoMatch({
    required String baseUrl,
    List<String>? searchSelectors,
    List<String>? episodeSelectors,
    String testKeyword = '孤独摇滚',
  }) async {
    final cleanUrl = baseUrl.trim().replaceAll(_trailingSlashPattern, '');
    final log = StringBuffer();
    final dio = _createDio();

    try {
      log.writeln('[1/3] 尝试 MacCMS JSON API…');
      final suggestUrl =
          '$cleanUrl/index.php/ajax/suggest?mid=1&wd=${Uri.encodeComponent(testKeyword)}&limit=10';
      try {
        final resp = await dio.get(
          suggestUrl,
          options: Options(responseType: ResponseType.plain),
        );
        final raw = resp.data?.toString() ?? '';
        final data = raw.isNotEmpty ? jsonDecode(raw) : <String, dynamic>{};
        if (data is Map &&
            data['list'] is List &&
            (data['list'] as List).isNotEmpty) {
          final items = data['list'] as List;
          log.writeln('  ✅ MacCMS API 可用，返回 ${items.length} 条结果');
          final pipeline = _buildMaccmsPipeline(episodeSelectors);
          Map? first;
          for (final item in items) {
            if (item is Map &&
                (item['id']?.toString().isNotEmpty ?? false) &&
                (item['name']?.toString().isNotEmpty ?? false)) {
              first = item;
              break;
            }
          }
          final id = first?['id']?.toString() ?? '';
          final seriesUrl = Uri.parse(
            cleanUrl,
          ).resolve('/index.php/vod/detail/id/$id.html').toString();
          final test = id.isEmpty
              ? null
              : await _testFromSeries(
                  cleanUrl,
                  pipeline,
                  seriesUrl,
                  first?['name']?.toString() ?? '',
                  log,
                );
          if (test != null) {
            return AutoMatchResult(
              success: true,
              pipeline: pipeline,
              detectedType: 'maccms',
              log: log.toString(),
              seriesUrl: seriesUrl,
              episodeUrl: test.episodeUrl,
              playUrl: test.playUrl,
            );
          }
          log.writeln('  ⚠️ MacCMS 全链路测试未通过，尝试下一策略');
        }
      } catch (e) {
        log.writeln('  – MacCMS API 不可用: $e');
      }

      log.writeln('[2/3] 尝试 MacCMS HTML 搜索…');
      final maccmsHtmlUrl =
          '$cleanUrl/index.php/vod/search/wd/${Uri.encodeComponent(testKeyword)}.html';
      try {
        final resp = await dio.get(
          maccmsHtmlUrl,
          options: Options(responseType: ResponseType.plain),
        );
        final html = resp.data?.toString() ?? '';
        if (html.isNotEmpty) {
          final results = HtmlParser.parseSearchResults(
            html,
            baseUrl: cleanUrl,
            selectors: searchSelectors,
          );
          if (results.isNotEmpty) {
            log.writeln('  ✅ MacCMS HTML 搜索成功，找到 ${results.length} 条结果');
            final pipeline = _buildHtmlPipeline(
              '/index.php/vod/search/wd/{keyword}.html',
              searchSelectors,
              episodeSelectors,
              detailPattern: '/vod/detail/',
            );
            final test = await _testFromSeries(
              cleanUrl,
              pipeline,
              results.first.seriesId,
              results.first.name,
              log,
            );
            if (test != null) {
              return AutoMatchResult(
                success: true,
                pipeline: pipeline,
                detectedType: 'maccms-html',
                log: log.toString(),
                seriesUrl: results.first.seriesId,
                episodeUrl: test.episodeUrl,
                playUrl: test.playUrl,
              );
            }
          }
        }
      } catch (_) {}

      log.writeln('[3/3] 尝试通用 HTML 搜索…');
      for (final pattern in _searchUrlPatterns) {
        final searchUrl =
            '$cleanUrl${pattern.replaceAll('{keyword}', Uri.encodeComponent(testKeyword))}';
        try {
          final resp = await dio.get(
            searchUrl,
            options: Options(responseType: ResponseType.plain),
          );
          final html = resp.data?.toString() ?? '';
          if (html.isEmpty) continue;
          final results = HtmlParser.parseSearchResults(
            html,
            baseUrl: cleanUrl,
            selectors: searchSelectors,
          );
          if (results.isEmpty) continue;
          log.writeln('  ✅ HTML 搜索成功 ($pattern)，找到 ${results.length} 条结果');
          final pipeline = _buildHtmlPipeline(
            pattern,
            searchSelectors,
            episodeSelectors,
          );
          final test = await _testFromSeries(
            cleanUrl,
            pipeline,
            results.first.seriesId,
            results.first.name,
            log,
          );
          if (test != null) {
            return AutoMatchResult(
              success: true,
              pipeline: pipeline,
              detectedType: 'html',
              log: log.toString(),
              seriesUrl: results.first.seriesId,
              episodeUrl: test.episodeUrl,
              playUrl: test.playUrl,
            );
          }
        } catch (_) {
          continue;
        }
      }

      log.writeln('\n❌ 自动匹配失败，请手动填写 CSS 选择器或 XPath 后重试');
      return AutoMatchResult(
        success: false,
        detectedType: 'unknown',
        log: log.toString(),
      );
    } finally {
      dio.close();
    }
  }

  static Map<String, dynamic> _buildMaccmsPipeline(
    List<String>? episodeSelectors,
  ) {
    return {
      'search': [
        {
          'op': 'fetch',
          'url': '/index.php/ajax/suggest?mid=1&wd={keyword}&limit=20',
          'headers': {'X-Requested-With': 'XMLHttpRequest'},
        },
        {
          'op': 'jsonSeries',
          'listPath': 'list',
          'idKey': 'id',
          'nameKey': 'name',
          'imageKey': 'pic',
          'detailUrlTemplate': '/index.php/vod/detail/id/{id}.html',
        },
      ],
      'detail': [
        {'op': 'follow'},
        {
          'op': 'episodes',
          if (episodeSelectors?.isNotEmpty ?? false)
            'listSelectors': episodeSelectors,
        },
      ],
      'play': _defaultPlayPipeline,
    };
  }

  static Map<String, dynamic> _buildHtmlPipeline(
    String searchUrlPattern,
    List<String>? searchSelectors,
    List<String>? episodeSelectors, {
    String? detailPattern,
  }) {
    return {
      'search': [
        {'op': 'fetch', 'url': searchUrlPattern},
        {
          'op': 'searchList',
          if (searchSelectors?.isNotEmpty ?? false)
            'selectors': searchSelectors,
          'detailPattern': ?detailPattern,
        },
      ],
      'detail': [
        {'op': 'follow'},
        {
          'op': 'episodes',
          if (episodeSelectors?.isNotEmpty ?? false)
            'listSelectors': episodeSelectors,
        },
      ],
      'play': _defaultPlayPipeline,
    };
  }

  static const _defaultPlayPipeline = [
    {'op': 'follow'},
    {
      'op': 'first',
      'branches': [
        [
          {'op': 'playerAaaa', 'var': 'player_aaaa', 'key': 'url'},
        ],
        [
          {'op': 'videoUrl'},
        ],
        [
          {'op': 'sniff'},
        ],
      ],
    },
  ];

  static Future<({String episodeUrl, String playUrl})?> _testFromSeries(
    String baseUrl,
    Map<String, dynamic> pipeline,
    String seriesUrl,
    String seriesName,
    StringBuffer log,
  ) async {
    final config = CustomSourceConfig(
      id: '_auto_test',
      name: 'Auto Test',
      baseUrl: baseUrl,
      pipeline: pipeline,
    );
    final adapter = PipelineSourceAdapter(RuleMigrator.ruleForConfig(config));
    try {
      log.writeln('  ✅ 搜索成功: $seriesName → $seriesUrl');
      log.writeln('  [测试] 获取剧集列表…');
      final sources = await adapter.getSources(seriesUrl);
      if (sources.isEmpty || sources.first.episodes.isEmpty) {
        log.writeln('  ❌ 未找到播放源/剧集');
        return null;
      }
      final episodeUrl = sources.first.episodes.first.episodeId;
      log.writeln('  ✅ 找到 ${sources.length} 条线路，首集: $episodeUrl');

      log.writeln('  [测试] 提取播放直链…');
      final playUrl = await adapter.resolveDownloadUrl(
        episodeUrl,
        forceRefresh: true,
      );
      if (playUrl.isEmpty) {
        log.writeln('  ❌ 未能提取播放直链');
        return null;
      }
      log.writeln('  ✅ 直链提取成功: $playUrl');

      return (episodeUrl: episodeUrl, playUrl: playUrl);
    } finally {
      adapter.dispose();
    }
  }

  static Dio _createDio() {
    return Dio(
      BaseOptions(
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (s) => s != null && s < 600,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
  }
}
