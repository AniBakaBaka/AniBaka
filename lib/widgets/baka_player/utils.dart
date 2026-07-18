extension DurationExtension on Duration {
  Duration clamp(Duration min, Duration max) {
    if (this < min) return min;
    if (this > max) return max;
    return this;
  }

  String label({Duration? reference}) {
    reference ??= this;
    if (reference > const Duration(days: 1)) {
      final days = inDays.toString().padLeft(3, '0');
      final hours = (inHours - inDays * 24).toString().padLeft(2, '0');
      final minutes = (inMinutes - inHours * 60).toString().padLeft(2, '0');
      final seconds = (inSeconds - inMinutes * 60).toString().padLeft(2, '0');
      return '$days:$hours:$minutes:$seconds';
    }
    if (reference > const Duration(hours: 1)) {
      final hours = inHours.toString().padLeft(2, '0');
      final minutes = (inMinutes - inHours * 60).toString().padLeft(2, '0');
      final seconds = (inSeconds - inMinutes * 60).toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    final minutes = inMinutes.toString().padLeft(2, '0');
    final seconds = (inSeconds - inMinutes * 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
