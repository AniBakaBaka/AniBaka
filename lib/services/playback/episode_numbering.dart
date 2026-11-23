/// 分集编号换算：源数组下标、标题里的集号、Bangumi 的集序是三套不同的编号。
///
/// 播放器内部用「源分集数组的下标」定位剧集，而 Bangumi 的收藏进度、弹幕分集、
/// OP/ED 跳过记录都按「第几集」计数。源缺集、倒序排版、混入 SP 或总集数少于
/// Bangumi 时，三者并不相等；把下标直接当集号会写错进度、错位弹幕、跳错集。
///
/// 这里只做纯计算，不碰网络与 widget，便于单测。
library;

/// 从分集标题里读出集号。
///
/// 只认明确的写法（`第9集` / `EP09` / `[09]` / ` - 09` / 纯 `09`），并且排除
/// 分辨率与年份这类数字，避免把 `1080p`、`2024` 当成集数。
int? parseEpisodeNumber(String title) {
  final text = title.trim();
  if (text.isEmpty) return null;
  for (final (pattern, explicit) in _patterns) {
    final match = pattern.firstMatch(text);
    if (match == null) continue;
    final value = int.tryParse(match.group(1)!);
    if (value == null || !_isPlausibleEpisode(value, explicit: explicit)) {
      continue;
    }
    return value;
  }
  return null;
}

/// 分集编号工具。构造时一次解析全部标题，之后的查询都是 O(n)。
class EpisodeNumbering {
  EpisodeNumbering(Iterable<String> titles)
    : _numbers = [for (final title in titles) parseEpisodeNumber(title)];

  final List<int?> _numbers;

  int get length => _numbers.length;

  int? numberAt(int index) =>
      index >= 0 && index < _numbers.length ? _numbers[index] : null;

  /// 集号是否恰好是 1..n。成立时下标 + 1 才等于集号。
  bool get isSequential {
    for (var i = 0; i < _numbers.length; i++) {
      if (_numbers[i] != i + 1) return false;
    }
    return true;
  }

  /// 是否至少读到过一个集号。
  bool get hasNumbers => _numbers.any((number) => number != null);

  /// 播放顺序上的下一集：按集号升序找比当前大的最小值。
  ///
  /// 源可能倒序排版或缺集，`index + 1` 会走到更早的一集，所以不能用下标推。
  /// 当前集号未知时返回 null，交给调用方决定是否退回下标。
  int? nextIndex(int index) {
    final current = numberAt(index);
    if (current == null) return null;
    int? best;
    int? bestNumber;
    for (var i = 0; i < _numbers.length; i++) {
      final number = _numbers[i];
      if (number == null || number <= current) continue;
      if (bestNumber == null || number < bestNumber) {
        best = i;
        bestNumber = number;
      }
    }
    return best;
  }

  /// 播放顺序上的上一集：按集号降序找比当前小的最大值。
  int? previousIndex(int index) {
    final current = numberAt(index);
    if (current == null) return null;
    int? best;
    int? bestNumber;
    for (var i = 0; i < _numbers.length; i++) {
      final number = _numbers[i];
      if (number == null || number >= current) continue;
      if (bestNumber == null || number > bestNumber) {
        best = i;
        bestNumber = number;
      }
    }
    return best;
  }

  /// 按集号反查源下标（用于「从 Bangumi 的第 N 集打开某个源」）。
  int? indexOfNumber(int number) {
    for (var i = 0; i < _numbers.length; i++) {
      if (_numbers[i] == number) return i;
    }
    return null;
  }
}

/// Bangumi 分集列表（`/v0/episodes?type=0`，已按 `sort` 升序）的集序工具。
class BgmEpisodeOrder {
  const BgmEpisodeOrder._();

  static double? sortOf(Map<String, dynamic> episode) {
    final sort = episode['sort'];
    return sort is num ? sort.toDouble() : null;
  }

  /// 按集号取分集条目。集号允许带小数（`9.5`）。
  static Map<String, dynamic>? byNumber(
    List<Map<String, dynamic>> episodes,
    num number,
  ) {
    final target = number.toDouble();
    for (final episode in episodes) {
      final sort = sortOf(episode);
      if (sort != null && (sort - target).abs() < 0.001) return episode;
    }
    return null;
  }

  /// 集号对应的「第几集」（1 起算，用于收藏进度里已看集数）。
  static int? ordinalOf(List<Map<String, dynamic>> episodes, num number) {
    final target = number.toDouble();
    for (var i = 0; i < episodes.length; i++) {
      final sort = sortOf(episodes[i]);
      if (sort != null && (sort - target).abs() < 0.001) return i + 1;
    }
    return null;
  }
}

const _implausibleNumbers = <int>{360, 480, 540, 576, 720, 1080, 1440, 2160};

bool _isPlausibleEpisode(int value, {required bool explicit}) {
  if (value < 1 || value > 999) return false;
  // 年份不是集号。
  if (value >= 1900 && value <= 2100) return false;
  // 「第1080集」确实是集数，但光秃秃的 1080 更可能是分辨率。
  if (!explicit && _implausibleNumbers.contains(value)) return false;
  return true;
}

/// 顺序敏感：越靠前的写法越可信，命中即返回。
/// 第二列表示「写法本身已经点明这是集号」，可以绕过分辨率黑名单。
final _patterns = <(RegExp, bool)>[
  // 第9集 / 第 12 话 / 第3話
  (RegExp(r'第\s*(\d{1,4})\s*[集话話回]'), true),
  // EP09 / EP.09 / Episode 9 / E09（前面不能紧贴字母，避免把名字里的数字当集号）
  (
    RegExp(
      r'(?:^|[^A-Za-z0-9])(?:episode|ep|e)\s*\.?\s*(\d{1,4})(?![0-9])',
      caseSensitive: false,
    ),
    true,
  ),
  // [09] / (09) / 【09】
  (RegExp(r'[\[\(【]\s*(\d{1,4})\s*[\]\)】]'), false),
  // 名字 - 09
  (RegExp(r'[-–—_]\s*(\d{1,4})(?:\s*[vV]\d)?\s*$'), false),
  // 09 / 09 标题 / 09.标题
  (RegExp(r'^\s*(\d{1,4})(?:\s*[vV]\d)?\s*(?:$|[\s.、:：])'), false),
];
