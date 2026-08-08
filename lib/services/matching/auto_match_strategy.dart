
class AutoMatchStrategy {
  AutoMatchStrategy._();

  /// 与手动点选相同的「单候选」阶段划分。
  static const stageSearchOneSource = 'search_one_source';
  static const stageCatalog = 'catalog';
  static const stageMediaResolve = 'media_resolve';
  static const stageReachability = 'reachability';

  /// 自动匹配：高置信立刻探（≈ 手动点选门槛）
  static const double immediateProbeConfidence = 0.70;

  /// 更高置信插队到探针队首
  static const double priorityProbeConfidence = 0.82;

  /// final pass 放宽
  static const double finalProbeConfidence = 0.60;

  /// 竞速并发（同时按手动路径处理的候选数）
  static const int raceConcurrency = 5;

  /// 每候选最多线路
  static const int maxLinesPerCandidate = 2;

  /// 单候选预算（目录+媒体），对齐「用户耐心点一次」的体感
  static const Duration candidateBudget = Duration(milliseconds: 5500);

  /// 整轮墙钟
  static const Duration wallClock = Duration(seconds: 12);

  /// 自动匹配每源关键词：只主标题（别名留给 final / 手动）
  static const int keywordsPerSourceAuto = 1;

  /// 手动搜索每源关键词
  static const int keywordsPerSourceManual = 2;

  /// 模拟「首个就绪」耗时：并行取 min，而不是串行求和。
  ///
  /// [candidateTotals] 每个候选完整就绪耗时（搜索摊销后的剩余 + 目录 + 媒体）。
  static int firstReadyMs(List<int> candidateTotals) {
    if (candidateTotals.isEmpty) return 0;
    var best = candidateTotals.first;
    for (final t in candidateTotals.skip(1)) {
      if (t < best) best = t;
    }
    return best;
  }

  /// 旧模型近似：队列串行处理前 [concurrency] 路，批内取 max 再累加。
  ///
  /// 更贴近「固定 worker 吃队列」而不是真正的全并行 first-ready。
  static int queuedWorkerMs(List<int> candidateTotals, {int concurrency = 3}) {
    if (candidateTotals.isEmpty) return 0;
    final workers = List<int>.filled(concurrency.clamp(1, 16), 0);
    for (final t in candidateTotals) {
      // 派给当前最闲的 worker
      var minI = 0;
      for (var i = 1; i < workers.length; i++) {
        if (workers[i] < workers[minI]) minI = i;
      }
      workers[minI] += t;
    }
    var maxT = 0;
    for (final w in workers) {
      if (w > maxT) maxT = w;
    }
    return maxT;
  }

  /// 手动路径：已选定一条时的耗时 = 该候选自身（无排队）。
  static int manualClickMs(int singleCandidateTotal) => singleCandidateTotal;

  /// 搜索阶段：双关键词 wait-all vs 单关键词 first-success。
  static int dualKeywordWaitAllMs(int kw1, int kw2) => kw1 > kw2 ? kw1 : kw2;

  static int singleKeywordMs(int kw1) => kw1;
}
