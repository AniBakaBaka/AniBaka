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

  static final RegExp _noiseRe = RegExp(
    r'\[.*?\]|【.*?】|\(.*?\)|\（.*?\）|1080p?|720p?|4k|bdrip|webrip|无修|招募|字幕组|简日|繁日|国语|双语|全\d+集',
    caseSensitive: false,
  );

  static final RegExp _modifierRe = RegExp(
    r'剧场版|劇場版|映画|movie|ova|oad|special|特别篇|特別編|第二季|第三季|第四季|第[一二三四五六七八九十\d]+季|2nd|3rd|4th|season\s*\d+',
    caseSensitive: false,
  );

  /// 小写并去掉常见噪音字符与修饰短语。字符集与 [BgmUtils.normalizeTitle] 共用，
  /// 但保留季号——季度冲突由 SourceMatchEngine 单独判定。
  static String normalize(String title) {
    final cleaned = title.replaceAll(_noiseRe, ' ');
    return BgmUtils.keepTitleUnits(cleaned);
  }

  /// 相似度 ∈ [0,1]。
  double similarityTo(TitleFingerprint other) {
    if (isEmpty || other.isEmpty) return 0;
    if (normalized == other.normalized) return 1;

    final a = normalized;
    final b = other.normalized;
    final shorter = a.length <= b.length ? a : b;
    final longer = a.length > b.length ? a : b;

    // 检查是否有修饰词差异（如一方含剧场版/季号，另一方不含）
    final aHasMod = _modifierRe.hasMatch(a);
    final bHasMod = _modifierRe.hasMatch(b);
    final modMismatch = aHasMod != bHasMod;

    if (longer.contains(shorter)) {
      final ratio = shorter.length / longer.length;
      final base = 0.65 + ratio * 0.25;
      return (modMismatch ? base * 0.6 : base).clamp(0.0, 0.95);
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

    final score = 2 * overlap / total;
    return modMismatch ? (score * 0.7).clamp(0.0, 1.0) : score;
  }
}
