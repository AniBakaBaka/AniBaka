import 'package:baka/utils/bgm_utils.dart';

/// 标题模糊匹配：归一化 + 字符 bigram Dice。
///
/// bigram 用 `codeUnit << 16 | codeUnit` 存成 `Set<int>`，
/// 避免为每个候选分配大量两字符 String。
class TitleFingerprint {
  TitleFingerprint(String raw) : normalized = normalize(raw) {
    final n = normalized;
    for (var i = 0; i + 1 < n.length; i++) {
      bigrams.add((n.codeUnitAt(i) << 16) | n.codeUnitAt(i + 1));
    }
  }

  final String normalized;
  final Set<int> bigrams = <int>{};

  bool get isEmpty => normalized.isEmpty;

  /// 小写并去掉所有非中英文数字字符。字符集与 [BgmUtils.normalizeTitle] 共用，
  /// 但保留季号——季度冲突由 SourceMatchEngine 单独判定。
  static String normalize(String title) => BgmUtils.keepTitleUnits(title);

  /// 相似度 ∈ [0,1]。
  double similarityTo(TitleFingerprint other) {
    if (isEmpty || other.isEmpty) return 0;
    if (normalized == other.normalized) return 1;

    final a = normalized;
    final b = other.normalized;
    final shorter = a.length <= b.length ? a : b;
    final longer = a.length > b.length ? a : b;
    if (longer.contains(shorter)) {
      return (0.78 + shorter.length / longer.length * 0.18).clamp(0.0, 0.96);
    }

    final total = bigrams.length + other.bigrams.length;
    if (total == 0) return 0;

    final small = bigrams.length <= other.bigrams.length
        ? bigrams
        : other.bigrams;
    final large = identical(small, bigrams) ? other.bigrams : bigrams;
    var overlap = 0;
    for (final g in small) {
      if (large.contains(g)) overlap++;
    }
    return 2 * overlap / total;
  }
}
