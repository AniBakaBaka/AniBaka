/// 集号解析：在源数组下标、标题里的集号与 Bangumi 的集序之间换算。
library;

/// 从分集标题里读集号；排除分辨率、年份这类数字。
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
    // 半集（`9.5`）不按整数集号处理。
    final digits = match.group(1)!;
    final whole = match.group(0)!;
    var end = match.start + whole.lastIndexOf(digits) + digits.length;
    while (end < text.length && ')]】'.contains(text[end])) {
      end++;
    }
    if (end + 1 < text.length &&
        text[end] == '.' &&
        _isAsciiDigit(text[end + 1])) {
      continue;
    }
    return value;
  }
  return null;
}

/// 解析好的分集集号，构造时一次算完。
class EpisodeNumbering {
  EpisodeNumbering(Iterable<String> titles)
    : _numbers = [for (final title in titles) parseEpisodeNumber(title)];

  final List<int?> _numbers;

  int? numberAt(int index) =>
      index >= 0 && index < _numbers.length ? _numbers[index] : null;

  /// 集号能否用来决定播放顺序；集号有重复或全部缺失时返回 false。
  bool get isUsable {
    final seen = <int>{};
    for (final number in _numbers) {
      if (number == null) continue;
      if (!seen.add(number)) return false;
    }
    return seen.isNotEmpty;
  }

  /// 播放顺序上的下一集：集号比当前大的最近一个。
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

  /// 播放顺序上的上一集：集号比当前小的最近一个。
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

  /// 按集号反查源下标。
  int? indexOfNumber(int number) {
    for (var i = 0; i < _numbers.length; i++) {
      if (_numbers[i] == number) return i;
    }
    return null;
  }
}

/// 已按 `sort` 升序的 Bangumi 分集列表。
class BgmEpisodeOrder {
  const BgmEpisodeOrder._();

  static double? _sortOf(Map<String, dynamic> episode) {
    final sort = episode['sort'];
    return sort is num ? sort.toDouble() : null;
  }

  /// 按集号取分集条目，允许小数（`9.5`）。
  static Map<String, dynamic>? byNumber(
    List<Map<String, dynamic>> episodes,
    num number,
  ) {
    final target = number.toDouble();
    for (final episode in episodes) {
      final sort = _sortOf(episode);
      if (sort != null && (sort - target).abs() < 0.001) return episode;
    }
    return null;
  }

  /// 集号对应的「第几集」（1 起算），用于收藏进度。
  static int? ordinalOf(List<Map<String, dynamic>> episodes, num number) {
    final target = number.toDouble();
    for (var i = 0; i < episodes.length; i++) {
      final sort = _sortOf(episodes[i]);
      if (sort != null && (sort - target).abs() < 0.001) return i + 1;
    }
    return null;
  }
}

const _implausibleNumbers = <int>{360, 480, 540, 576, 720, 1080, 1440, 2160};

bool _isAsciiDigit(String char) {
  final code = char.codeUnitAt(0);
  return code >= 0x30 && code <= 0x39;
}

bool _isPlausibleEpisode(int value, {required bool explicit}) {
  if (value < 1 || value > 999) return false;
  // 年份不是集号。
  if (value >= 1900 && value <= 2100) return false;
  // 分辨率数值不按集号处理。
  if (!explicit && _implausibleNumbers.contains(value)) return false;
  return true;
}

/// 正则按顺序尝试，命中即返回。
/// 第二列为 true 表示写法本身已点明是集号，可跳过分辨率黑名单。
final _patterns = <(RegExp, bool)>[
  // 第9集 / 第 12 话 / 第3話
  (RegExp(r'第\s*(\d{1,4})\s*[集话話回]'), true),
  // EP09 / EP.09 / Episode 9 / E09（前面不能紧贴字母）
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
