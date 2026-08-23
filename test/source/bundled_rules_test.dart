import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:baka/models/custom_source_config.dart';
import 'package:baka/services/source/source_codec.dart';
import 'package:baka/source/engine/rule_validator.dart';
import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:baka/source/store/bundled_rule_store.dart';
import 'package:baka/source/store/rule_migrator.dart';

void main() {
  final assetDirectory = Directory('assets/rules');
  final assetFiles = assetDirectory
      .listSync()
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.json'))
      .toList(growable: false);

  test('only registered built-in rules are stored locally', () {
    expect(assetDirectory.existsSync(), isTrue);
    expect(
      assetFiles.map((file) => file.path.replaceAll(r'\', '/')).toSet(),
      BundledRuleStore.builtinAssets.values.toSet(),
    );
    final oldRuleDirectory = Directory('rule');
    expect(
      !oldRuleDirectory.existsSync() || oldRuleDirectory.listSync().isEmpty,
      isTrue,
    );
  });

  test('all built-in assets contain valid v2 pipeline rules', () {
    for (final file in assetFiles) {
      final name = file.uri.pathSegments.last;
      final decoded = SourceCodec.decode(file.readAsStringSync().trim());
      expect(decoded, isA<Map>(), reason: '$name must contain a JSON object');

      final config = CustomSourceConfig.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      );
      expect(config.id, isNotEmpty, reason: '$name missing id');
      expect(config.baseUrl, isNotEmpty, reason: '$name missing baseUrl');
      expect(config.iconUrl, isNotEmpty, reason: '$name missing iconUrl');

      final validation = RuleValidator.validate(
        RuleMigrator.ruleForConfig(config),
      );
      expect(
        validation.isValid,
        isTrue,
        reason: '$name invalid: ${validation.errors.join('; ')}',
      );
    }
  });

  test('each bundled asset decodes to a rule id matching its registry key', () {
    BundledRuleStore.builtinAssets.forEach((key, path) {
      final decoded = jsonDecode(File(path).readAsStringSync());
      final rule = SourceRule.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      );
      expect(rule.id, key, reason: '$path id must match registry key $key');
    });
  });

  test('pubspec bundles the built-in asset directory only', () {
    final pubspec = File(
      'pubspec.yaml',
    ).readAsLinesSync().map((line) => line.trim());
    expect(pubspec, contains('- assets/rules/'));
    expect(pubspec.any((line) => line.startsWith('- rule/')), isFalse);
  });

  test('tvtfun rule uses the current JSON search, detail, and play APIs', () {
    final path = BundledRuleStore.builtinAssets['tvtfun']!;
    final rule = SourceRule.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(File(path).readAsStringSync()) as Map,
      ),
    );

    expect(rule.search.map((step) => step.op), ['fetch', 'jsonSeries']);
    expect(rule.search.first.str('url'), '/api/videos/search?q={keyword}');
    expect(rule.search.last.str('listPath'), 'data.videos');
    expect(rule.search.last.str('detailUrlTemplate'), '/api/videos/{id}');

    expect(rule.detail.map((step) => step.op), [
      'follow',
      'setVar',
      'json',
      'setVar',
      'template',
      'jsonEpisodes',
    ]);
    expect(rule.detail.last.str('sourcesPath'), 'data.playSources');
    expect(
      rule.detail.last.str('episodeIdTemplate'),
      '{id:raw}|{tvtVideoSlug:raw}',
    );

    expect(rule.play.map((step) => step.op), [
      'setVar',
      'regex',
      'setVar',
      'template',
      'regex',
      'setVar',
      'fetch',
      'fetch',
      'setMediaHeaders',
      'json',
    ]);
    expect(
      rule.play[6].str('url'),
      '/video/{tvtVideoSlug}/play?source=0&episode=0',
    );
    expect(
      rule.play[7].str('url'),
      '/api/videos/resolve-play-url?episodeId={tvtEpisodeId}',
    );
    expect((rule.play[7].params['headers'] as Map)['X-Play-Ctx'], isNotEmpty);
    expect(rule.play[8].str('jsonPath'), 'data.headers');
    expect(rule.play.last.str('path'), 'data.url');
  });

  test('silisili rule parses gated search results and playback lines', () {
    final path = BundledRuleStore.builtinAssets['silisili']!;
    final rule = SourceRule.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(File(path).readAsStringSync()) as Map,
      ),
    );
    final adapter = PipelineSourceAdapter(rule);

    expect(rule.headers['Cookie'], 'silisili=on');
    expect(rule.useWebview, isTrue);
    expect(rule.play.map((step) => step.op), ['setMediaHeaders', 'sniff']);

    final results = adapter.parseSearchList(
      '''
      <main id="content">
        <article>
          <a href="/voddetail/h077777Z/" title="无职转生 第二季">
            <img data-original="/upload/wuzhi.jpg" alt="无职转生 第二季">
          </a>
        </article>
      </main>
      ''',
      selectors: rule.search[1].strList('selectors'),
      detailPattern: rule.search[1].str('detailPattern'),
    );
    expect(results, hasLength(1));
    expect(results.single.name, '无职转生 第二季');
    expect(
      results.single.seriesId,
      'https://www.silisilifun.com/voddetail/h077777Z/',
    );

    final sources = adapter.parseEpisodes(
      '''
      <section class="play-pannel-box">
        <div class="play-pannel_hd"><h3 class="widget-title">No.X</h3></div>
        <div class="play-pannel-list">
          <ul class="stui-content__playlist">
            <li><a href="/vodplay/h077777Z/3/1/">第1话</a></li>
            <li><a href="/vodplay/h077777Z/3/2/">第2话</a></li>
          </ul>
        </div>
      </section>
      <section class="play-pannel-box">
        <div class="play-pannel_hd"><h3 class="widget-title">NO.F</h3></div>
        <div class="play-pannel-list">
          <ul class="stui-content__playlist">
            <li><a href="/vodplay/h077777Z/2/1/">第1话</a></li>
          </ul>
        </div>
      </section>
      ''',
      listSelectors: rule.detail[1].strList('listSelectors'),
      tabSelectors: rule.detail[1].strList('tabSelectors'),
    );
    expect(sources, hasLength(2));
    expect(sources.map((source) => source.sourceName), ['No.X', 'NO.F']);
    expect(sources.first.episodes, hasLength(2));
    expect(
      sources.first.episodes.first.episodeId,
      'https://www.silisilifun.com/vodplay/h077777Z/3/1/',
    );

    adapter.dispose();
  });
}
