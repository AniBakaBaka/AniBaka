import 'package:baka/source/model/source_rule.dart';
import 'package:baka/source/pipeline_source_adapter.dart';
import 'package:test/test.dart';

void main() {
  test(
    'ani_pekolove merges episode blocks without treating them as sources',
    () async {
      final rule = SourceRule(
        id: 'ani_pekolove',
        name: 'Ani Pekolove',
        baseUrl: 'https://ani.pekolove.net',
        detail: const [
          PipelineStep('episodes', {
            'roadsXPath': '//div[contains(@class, "entry-content")]',
            'itemsXPath':
                './/div[contains(@class, "wp-block-columns") and '
                'contains(@class, "is-not-stacked-on-mobile")]'
                '//a[contains(@class, "pbb-") and contains(text(), "集")]',
          }),
        ],
      );
      final episodeStep = rule.detail.firstWhere(
        (step) => step.op == 'episodes',
      );
      final adapter = PipelineSourceAdapter(rule);

      const html = '''
      <div class="entry-content">
        <div class="wp-block-columns is-not-stacked-on-mobile">
          <a class="pbb-b8f7c" href="/anime/54645/">上一季</a>
        </div>
        <div class="wp-block-columns is-not-stacked-on-mobile">
          <a class="pbb-b8f7c" href="/anime/show-1">第1集</a>
          <a class="pbb-b8f7c" href="/anime/show-2">第2集</a>
        </div>
        <div class="wp-block-columns is-not-stacked-on-mobile">
          <a class="pbb-b8f7c" href="/anime/show-3">第3集</a>
        </div>
      </div>
    ''';

      final sources = adapter.parseEpisodesXPath(
        html,
        roadsXPath: episodeStep.params['roadsXPath'] as String,
        itemsXPath: episodeStep.params['itemsXPath'] as String,
      );

      expect(sources, hasLength(1));
      expect(sources.single.episodes.map((episode) => episode.name), [
        '第1集',
        '第2集',
        '第3集',
      ]);
      expect(sources.single.episodes.map((episode) => episode.episodeId), [
        'https://ani.pekolove.net/anime/show-1',
        'https://ani.pekolove.net/anime/show-2',
        'https://ani.pekolove.net/anime/show-3',
      ]);
    },
  );
}
