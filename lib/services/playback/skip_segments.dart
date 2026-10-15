import 'dart:convert';

import 'package:baka/api/api_config.dart';
import 'package:baka/core/api_transport.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/skip_segment.dart';

class SkipSegmentsService {
  static const _storageKey = 'player_skip_segments_v1';
  static const _suggestionsKey = 'player_skip_suggestions_v1';

  bool hasAnsweredSuggestion(String key) =>
      (Instances.sp.getStringList(_suggestionsKey) ?? const []).contains(key);

  Future<void> rememberSuggestion(String key) async {
    final keys = Instances.sp.getStringList(_suggestionsKey) ?? <String>[];
    keys.remove(key);
    keys.add(key);
    await Instances.sp.setStringList(
      _suggestionsKey,
      keys.length > 1000 ? keys.sublist(keys.length - 1000) : keys,
    );
  }

  Map<String, dynamic> _read() {
    try {
      return jsonDecode(Instances.sp.getString(_storageKey) ?? '{}')
          as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  SkipContext restoreBinding(SkipContext context) {
    final saved = _read()[context.sourceKey];
    if (saved is Map && saved['bgm_id'] is int && saved['episode_id'] is int) {
      return context.bind(saved['bgm_id'] as int, saved['episode_id'] as int);
    }
    return context;
  }

  Future<void> bind(SkipContext context) async {
    final data = _read();
    data[context.sourceKey] = {
      'bgm_id': context.subjectId,
      'episode_id': context.episodeId,
    };
    await _write(data);
  }

  Future<void> _write(Map<String, dynamic> data) async {
    // Keep a bounded set of personal corrections, not a growing history log.
    while (data.length > 1000) {
      data.remove(data.keys.first);
    }
    await Instances.sp.setString(_storageKey, jsonEncode(data));
  }

  Future<void> saveLocal(
    SkipContext context,
    SkipSegment segment, {
    bool allEpisodes = false,
  }) async {
    final key = allEpisodes ? context.seriesLocalKey : context.localKey;
    if (key == null) throw const FormatException('当前视频没有番剧信息');
    final data = _read();
    final local = data[key] as Map<String, dynamic>? ?? {};
    local[segment.type] = {
      ...segment.toJson(),
      'scope': allEpisodes ? 'series' : 'episode',
    };
    local.remove('disabled_${segment.type}');
    data.remove(key);
    data[key] = local;
    if (allEpisodes) {
      // Replace this episode's correction; other explicit corrections stay intact.
      final current = data[context.localKey] as Map<String, dynamic>?;
      current?.remove(segment.type);
      current?.remove('disabled_${segment.type}');
    }
    await _write(data);
  }

  Future<void> disable(SkipContext context, String type, bool disabled) async {
    final data = _read();
    final local = data[context.localKey] as Map<String, dynamic>? ?? {};
    if (disabled) {
      local['disabled_$type'] = true;
    } else {
      local.remove('disabled_$type');
    }
    data[context.localKey] = local;
    await _write(data);
  }

  SkipData mergeLocal(
    SkipContext context,
    int duration,
    Iterable<SkipSegment> remote, {
    required String message,
  }) {
    final stored = _read();
    final local = stored[context.localKey] as Map? ?? {};
    final series = stored[context.seriesLocalKey] as Map? ?? {};
    final available = <SkipSegment>[];
    final enabled = <SkipSegment>[];
    for (final type in const ['op', 'ed']) {
      final value = local[type] ?? series[type];
      final disabled = local['disabled_$type'] == true;
      if (value is Map) {
        final segment = SkipSegment.fromJson(value as Map<String, dynamic>);
        if (segment.fits(duration)) {
          available.add(segment);
          if (!disabled) enabled.add(segment);
        }
        // A saved correction for another cut must not fall back to public data.
        continue;
      }
      for (final segment in remote) {
        if (segment.type != type || !segment.canPreview(duration)) continue;
        available.add(segment);
        if (!disabled && segment.fits(duration)) enabled.add(segment);
      }
    }
    final segments = List<SkipSegment>.unmodifiable(enabled);
    return SkipData(
      context: context,
      disabled: (
        op: local['disabled_op'] == true,
        ed: local['disabled_ed'] == true,
      ),
      segments: segments,
      availableSegments: enabled.length == available.length
          ? null
          : List<SkipSegment>.unmodifiable(available),
      message: message,
    );
  }

  Future<SkipData> load(SkipContext context, int duration) async {
    var remote = <SkipSegment>[];
    var message = context.bound ? '暂无匹配区间，可手动标注' : '绑定 Bangumi 剧集后可查询和共享';
    if (context.bound) {
      try {
        final uri = Uri.parse('${ApiConfig.host}/api/v1/skip-segments').replace(
          queryParameters: context
              .toJson(duration)
              .map((key, value) => MapEntry(key, '$value')),
        );
        final json = await apiTransport.getData<Map<String, dynamic>>(
          uri.toString(),
          timeout: const Duration(seconds: 8),
          notifyOnError: false,
        );
        remote = [
          for (final value in json['segments'] as List)
            SkipSegment.fromJson(value as Map<String, dynamic>),
        ];
        if (json['upstream_unavailable'] == true) {
          message = '公共数据暂不可用，仍可使用已保存的标注';
        } else if (remote.isNotEmpty) {
          message = '已查询当前剧集；未确认或时长不符的区间仅支持手动试用';
        } else if (context.timelineKey != 'original') {
          message = '去广告后时间轴已变化，仅使用当前片源的标注';
        }
      } catch (_) {
        message = '服务器暂不支持或查询失败，仍可在本机标注';
      }
    }
    return mergeLocal(context, duration, remote, message: message);
  }

  Future<void> submit(
    SkipContext context,
    SkipSegment segment, {
    bool allEpisodes = false,
  }) async {
    if (!context.bound) throw const FormatException('请先绑定 Bangumi 剧集');
    if (allEpisodes && context.seriesKey == null) {
      throw const FormatException('当前视频没有番剧信息');
    }
    final result = await apiTransport.postData<Map<String, dynamic>>(
      '${ApiConfig.host}/api/v1/skip-segments',
      {
        ...context.toJson(segment.durationMs),
        'type': segment.type,
        'start_ms': segment.startMs,
        'end_ms': segment.endMs,
        'scope': allEpisodes ? 'series' : 'episode',
        if (allEpisodes) 'source_key': context.seriesKey,
      },
      notifyOnError: false,
    );
    if (allEpisodes && result['scope'] != 'series') {
      throw const FormatException('服务器尚不支持全集共享，请升级服务端');
    }
  }

  Future<void> feedback(
    SkipContext context,
    SkipSegment segment,
    bool accurate,
  ) async {
    await apiTransport.putData<Map<String, dynamic>>(
      '${ApiConfig.host}/api/v1/skip-segments/${Uri.encodeComponent(segment.id)}/feedback',
      {...context.toJson(segment.durationMs), 'accurate': accurate},
      notifyOnError: false,
    );
  }
}
