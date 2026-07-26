const _kEnDays = ['Mon', 'Tue', 'Wed', 'Thur', 'Fri', 'Sat', 'Sun'];
const _kEnMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'June',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _kZhDays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

extension DateTimeFormatting on DateTime {
  /// "Thur, 13 Nov 2023"
  String toEnDate() =>
      '${_kEnDays[weekday - 1]}, $day ${_kEnMonths[month - 1]} $year';

  /// "周三, 14:30"
  String toZhWeekTime() {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '${_kZhDays[weekday - 1]}, $h:$m';
  }

  /// "3分钟前" / "2天前" / "2023-11-13"（超过一年显示日期）
  String toRelativeTime() {
    final diff = DateTime.now().difference(this);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
    return '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
  }
}

extension DurationFormatting on Duration {
  /// "03:25" 或 "01:03:25"（有小时时自动带上）
  String toTimeString() {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final h = inHours;
    final m = inMinutes.remainder(60);
    final s = inSeconds.remainder(60);
    return h > 0
        ? '${twoDigits(h)}:${twoDigits(m)}:${twoDigits(s)}'
        : '${twoDigits(m)}:${twoDigits(s)}';
  }
}
