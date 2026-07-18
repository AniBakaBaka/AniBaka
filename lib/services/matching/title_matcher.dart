/// 标题模糊匹配。
///
/// 归一化与 bigram 整数指纹在构造时一次性算好。整数集合避免为
/// 每个候选分配大量两字符 String 和计数 Map，同时仍保持线性比较。
class TitleFingerprint {
  TitleFingerprint(String raw) : normalized = normalize(raw) {
    for (var i = 0; i + 1 < normalized.length; i++) {
      bigrams.add(
        (normalized.codeUnitAt(i) << 16) | normalized.codeUnitAt(i + 1),
      );
    }
  }

  final String normalized;
  final Set<int> bigrams = <int>{};

  bool get isEmpty => normalized.isEmpty;

  static final RegExp _nonTitleRe = RegExp(r'[^a-z0-9\u4e00-\u9fa5]+');

  /// 匹配用归一化：小写并去掉所有非中英文数字字符。
  static String normalize(String title) =>
      title.toLowerCase().replaceAll(_nonTitleRe, '');

  /// 相似度 ∈ [0,1]：全等 1.0，包含关系按长度比给 0.78~0.96，
  /// 其余用 bigram Dice 系数。
  double similarityTo(TitleFingerprint other) {
    if (isEmpty || other.isEmpty) return 0;
    if (normalized == other.normalized) return 1;

    final shorter = normalized.length <= other.normalized.length
        ? normalized
        : other.normalized;
    final longer = normalized.length > other.normalized.length
        ? normalized
        : other.normalized;
    if (longer.contains(shorter)) {
      return (0.78 + shorter.length / longer.length * 0.18).clamp(0.0, 0.96);
    }

    return _dice(other);
  }

  double _dice(TitleFingerprint other) {
    final total = bigrams.length + other.bigrams.length;
    if (total == 0) return 0;

    final (small, large) = bigrams.length <= other.bigrams.length
        ? (bigrams, other.bigrams)
        : (other.bigrams, bigrams);

    var overlap = 0;
    for (final bigram in small) {
      if (large.contains(bigram)) overlap++;
    }
    return 2 * overlap / total;
  }
}

/// 从文本中提取 4 位年份（1900-2099）。
int? extractYear(String text) {
  final match = _yearRe.firstMatch(text);
  return match == null ? null : int.tryParse(match.group(1) ?? '');
}

final RegExp _yearRe = RegExp(r'\b(19\d{2}|20\d{2})\b');
