import 'skip_segment.dart';

typedef SkipRange = ({int startMs, int endMs});

/// Drafts stay with their video while the controls move between screen layouts.
class SkipSelection {
  const SkipSelection({
    required this.context,
    required this.durationMs,
    required this.type,
    this.ranges = (op: null, ed: null),
    this.changed = (op: false, ed: false),
    this.saving = false,
  });

  final SkipContext context;
  final int durationMs;
  final String type;
  final ({SkipRange? op, SkipRange? ed}) ranges;
  final ({bool op, bool ed}) changed;
  final bool saving;
  SkipRange? _rangeOf(String type) => type == 'op' ? ranges.op : ranges.ed;
  SkipRange get range => _rangeOf(type)!;
  String get label => type == 'op' ? '片头' : '片尾';

  SkipSelection copyWith({
    String? type,
    ({SkipRange? op, SkipRange? ed})? ranges,
    ({bool op, bool ed})? changed,
    bool? saving,
  }) => SkipSelection(
    context: context,
    durationMs: durationMs,
    type: type ?? this.type,
    ranges: ranges ?? this.ranges,
    changed: changed ?? this.changed,
    saving: saving ?? this.saving,
  );

  SkipSegment segment(String type) {
    final range = _rangeOf(type)!;
    return SkipSegment(
      id: 'local:$type',
      type: type,
      startMs: range.startMs,
      endMs: range.endMs,
      durationMs: durationMs,
      origin: 'local',
      automatic: true,
      status: 'personal',
    );
  }
}
