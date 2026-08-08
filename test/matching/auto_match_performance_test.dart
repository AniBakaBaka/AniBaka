import 'package:flutter_test/flutter_test.dart';

import 'package:baka/services/matching/auto_match_strategy.dart';

/// 自动匹配 vs 手动点选 性能模型对比。
///
/// 数值为阶段耗时（ms）的合成场景，验证算法选择 first-ready 而不是
/// wait-all / 串行队列，从而在「好源不总是最慢」时接近手动路径。
void main() {
  group('keyword search model', () {
    test('single keyword is strictly faster than dual wait-all', () {
      const fast = 400;
      const slow = 2800;
      final dual = AutoMatchStrategy.dualKeywordWaitAllMs(fast, slow);
      final single = AutoMatchStrategy.singleKeywordMs(fast);

      expect(single, lessThan(dual));
      expect(dual, slow);
      expect(single, fast);

      // 相对加速：本场景 dual 被慢关键词拖到 2.8s，single 0.4s
      final speedup = dual / single;
      expect(speedup, greaterThanOrEqualTo(7));
    });
  });

  group('candidate race model', () {
    // 场景：3 个源先后完成「目录+媒体」
    // A 快好源 1.2s，B 中等 2.5s，C 死链拖满 5.5s
    const totals = [1200, 2500, 5500];

    test('first-ready auto-match equals best candidate (≈ manual on that item)',
        () {
      final auto = AutoMatchStrategy.firstReadyMs(totals);
      final manualOnBest = AutoMatchStrategy.manualClickMs(totals.first);

      expect(auto, manualOnBest);
      expect(auto, 1200);
    });

    test('old queued workers are slower when a dead candidate occupies a slot',
        () {
      final firstReady = AutoMatchStrategy.firstReadyMs(totals);
      // 旧模型：3 worker 并行吃队列，但若顺序是 [死链, 中, 快] 会被拖累；
      // 即使用当前顺序，queued 仍要等最忙 worker 完成其分到的任务之和。
      final queued = AutoMatchStrategy.queuedWorkerMs(
        // 坏顺序：死链先入队（旧逻辑按源返回顺序，慢源常先返回搜索）
        const [5500, 2500, 1200],
        concurrency: 3,
      );

      expect(firstReady, lessThan(queued));
      // first-ready 1.2s；坏顺序队列至少要消化 5.5s 那条
      expect(queued, greaterThanOrEqualTo(5500));
    });

    test('end-to-end path: new auto ≤ old auto and ≈ manual + search', () {
      // 搜索：新自动单关键词 600ms；旧 dual wait 600 vs 2500 → 2500
      const searchNew = 600;
      const searchOld = 2500;
      // 候选就绪（摊销搜索后剩余工作）
      const remain = [900, 2000, 5000];

      final newAuto =
          searchNew + AutoMatchStrategy.firstReadyMs(remain);
      final oldAuto =
          searchOld +
          AutoMatchStrategy.queuedWorkerMs(
            const [5000, 2000, 900],
            concurrency: 3,
          );
      final manual =
          searchNew + // 假设列表已在搜（用户点选前已付出）
          AutoMatchStrategy.manualClickMs(remain.first);

      // 用户体感：列表已出后点选，只有 remain.first
      final manualClickOnly = AutoMatchStrategy.manualClickMs(remain.first);

      expect(newAuto, lessThan(oldAuto));
      // 新自动从进页到开播应接近「搜 + 点最快那条」
      expect(newAuto, lessThanOrEqualTo(searchNew + remain.first + 50));
      // 纯点选（搜索已完成）仍最短——这是预期；自动多付搜索摊销
      expect(manualClickOnly, lessThanOrEqualTo(newAuto));
      // 但新自动不应比「搜完再点」慢一个数量级
      expect(newAuto / manual, lessThan(1.5));

      // 打印对比表（测试日志）
      // ignore: avoid_print
      print('''
╔══════════════════════════════════════════════╗
║  Auto-match vs Manual  (simulated ms)        ║
╠══════════════════════════════════════════════╣
║  Manual click only (list ready): $manualClickOnly
║  Manual search+click best:       $manual
║  NEW auto first-ready:           $newAuto
║  OLD auto dual-kw + queue:       $oldAuto
║  Speedup new/old:                ${(oldAuto / newAuto).toStringAsFixed(2)}x
╚══════════════════════════════════════════════╝
''');
    });
  });

  group('strategy constants align with manual prepare budget', () {
    test('candidate budget is within human click patience (~6s)', () {
      expect(
        AutoMatchStrategy.candidateBudget.inMilliseconds,
        lessThanOrEqualTo(6000),
      );
      expect(
        AutoMatchStrategy.candidateBudget.inMilliseconds,
        greaterThanOrEqualTo(3000),
      );
    });

    test('wall clock is hard-capped', () {
      expect(AutoMatchStrategy.wallClock.inSeconds, lessThanOrEqualTo(15));
    });

    test('auto uses fewer keywords than manual', () {
      expect(
        AutoMatchStrategy.keywordsPerSourceAuto,
        lessThan(AutoMatchStrategy.keywordsPerSourceManual),
      );
    });
  });
}
