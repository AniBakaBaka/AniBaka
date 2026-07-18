import 'package:baka/source/model/source_rule.dart';

/// 预置配方（管线宏）。
///
/// 规则可以声明 `"recipes": ["maccms"]`，安装/加载时由 [Recipes.expand] 展开为
/// 对应阶段的默认管线片段——**仅填充规则未显式提供的阶段**，规则里显式写的
/// 管线永远优先。这样常见站点（MacCMS / player_aaaa 播放器）一行配方即可复用，
/// 又不牺牲可覆盖性。
class Recipes {
  Recipes._();

  /// 已知配方名。
  static const Set<String> known = {'maccms', 'player_aaaa'};

  /// 展开规则中声明的配方，返回填充后的规则。
  static SourceRule expand(SourceRule rule) {
    if (rule.recipes.isEmpty) return rule;

    var search = rule.search;
    var detail = rule.detail;
    var play = rule.play;

    for (final recipe in rule.recipes) {
      final fragment = _fragmentsFor(recipe.toLowerCase());
      if (fragment == null) continue;
      if (search.isEmpty && fragment.search != null) search = fragment.search!;
      if (detail.isEmpty && fragment.detail != null) detail = fragment.detail!;
      if (play.isEmpty && fragment.play != null) play = fragment.play!;
    }

    return rule.copyWith(search: search, detail: detail, play: play);
  }

  static _RecipeFragment? _fragmentsFor(String recipe) {
    switch (recipe) {
      case 'maccms':
        return const _RecipeFragment(
          search: [
            PipelineStep('fetch', {
              'url': '/index.php/ajax/suggest?mid=1&wd={keyword}&limit=20',
              'headers': {'X-Requested-With': 'XMLHttpRequest'},
            }),
            PipelineStep('jsonSeries', {
              'listPath': 'list',
              'idKey': 'id',
              'nameKey': 'name',
              'imageKey': 'pic',
              'detailUrlTemplate': '/index.php/vod/detail/id/{id}.html',
            }),
          ],
          detail: [
            PipelineStep('follow', {}),
            PipelineStep('episodes', {
              'listSelectors': ['.module-play-list', '.play_list', '.playlist'],
            }),
          ],
          play: _playerAaaaPlay,
        );
      case 'player_aaaa':
        return const _RecipeFragment(play: _playerAaaaPlay);
    }
    return null;
  }

  static const List<PipelineStep> _playerAaaaPlay = [
    PipelineStep('follow', {}),
    PipelineStep.first([
      [
        PipelineStep('playerAaaa', {'var': 'player_aaaa', 'key': 'url'}),
      ],
      [PipelineStep('videoUrl', {})],
    ]),
  ];
}

class _RecipeFragment {
  final List<PipelineStep>? search;
  final List<PipelineStep>? detail;
  final List<PipelineStep>? play;
  const _RecipeFragment({this.search, this.detail, this.play});
}
