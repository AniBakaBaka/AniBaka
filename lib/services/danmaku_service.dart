import 'dart:collection';
import 'dart:convert';

import 'package:baka/api/request_cache.dart';
import 'package:baka/api/post.dart';
import 'package:baka/instance.dart';
import 'package:baka/theme.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class DanmakuService {
  static const String _settingsKey = 'danmaku_settings';
  static const String _blockWordsKey = 'danmaku_block_words';
  static const String _blockRepeatKey = 'danmaku_block_repeat';
  static const String _blockColorKey = 'danmaku_block_color';
  static const int maxCachedEpisodes = 3;
  static const int maxCachedItems = 8000;
  static const int _workerDecodeThresholdBytes = 16 * 1024;

  static final LinkedHashMap<String, List<DanmakuItem>> _cache =
      LinkedHashMap<String, List<DanmakuItem>>();
  // Use a new field name after changing its type. During Flutter hot reload,
  // an existing static field retains its old value; reusing the old
  // `_loads` name after migrating it from Map to RequestDeduplicator makes the
  // generated getter try to return that stale Map as a RequestDeduplicator.
  static final RequestDeduplicator<String, List<DanmakuItem>> _inFlightLoads =
      RequestDeduplicator<String, List<DanmakuItem>>();
  static int _cachedItemCount = 0;

  static Future<List<DanmakuItem>> fetch({
    required int subjectId,
    required int episodeIndex,
    required Iterable<String> titles,
  }) {
    final cacheKey = '$subjectId-$episodeIndex';
    final cached = _readCache(cacheKey);
    if (cached != null) return SynchronousFuture(cached);

    return _inFlightLoads.run(cacheKey, () async {
      final items = await _fetchFirstAvailableDanmaku(
        subjectId,
        episodeIndex,
        titles,
      );
      if (items.isNotEmpty) _putCache(cacheKey, items);
      return items;
    });
  }

  static List<DanmakuItem>? _readCache(String key) {
    final value = _cache.remove(key);
    if (value != null) _cache[key] = value;
    return value;
  }

  static void _putCache(String key, List<DanmakuItem> items) {
    final previous = _cache.remove(key);
    if (previous != null) _cachedItemCount -= previous.length;
    if (items.length > maxCachedItems) return;

    _cache[key] = items;
    _cachedItemCount += items.length;
    while (_cache.length > maxCachedEpisodes ||
        _cachedItemCount > maxCachedItems) {
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey);
      if (removed != null) _cachedItemCount -= removed.length;
    }
  }

  static Future<List<DanmakuItem>> _fetchFirstAvailableDanmaku(
    int bgmId,
    int episodeIndex,
    Iterable<String> titles,
  ) async {
    for (final title in titles) {
      try {
        final response = await getDanmu(bgmId, episodeIndex, title);
        final items = await decode(response);
        if (items.isNotEmpty) return items;
      } catch (error) {
        debugPrint('fetch danmaku error: $error');
      }
    }
    return const [];
  }

  /// Decodes the API `{data: [...]}` payload and the local `[...]` file format.
  /// Small payloads stay on the UI isolate to avoid isolate startup/copy cost;
  /// larger payloads pass only the response text to a worker, avoiding a
  /// second dynamic object graph on the UI isolate.
  static Future<List<DanmakuItem>> decode(String raw) {
    if (raw.isEmpty) return SynchronousFuture(const []);
    if (raw.length < _workerDecodeThresholdBytes) {
      try {
        return SynchronousFuture(_decodeDanmakuItems(raw));
      } catch (error, stackTrace) {
        return Future.error(error, stackTrace);
      }
    }
    return compute(_decodeDanmakuItems, raw);
  }

  static void loadSettings(DanmakuController controller) {
    final preferences = Instances.sp;
    final option = _readOption();
    controller.blockWords = BgmUtils.parseJsonList(
      preferences.getString(_blockWordsKey),
    ).map((value) => value.toString()).toList();
    controller.blockRepeat = preferences.getBool(_blockRepeatKey) ?? false;
    controller.blockColor = preferences.getBool(_blockColorKey) ?? false;
    controller.updateOption(option);
  }

  static DanmakuOption _readOption() => _parseOption(
    BgmUtils.parseJsonMap(Instances.sp.getString(_settingsKey)) ?? const {},
  );

  static String getSavedFontFamily() => _readOption().fontFamily;

  static Future<void> setFontFamily(String fontFamily) {
    final normalized = fontFamily == AppFonts.systemFont
        ? AppFonts.systemFont
        : AppFonts.normalizeFont(fontFamily);
    final option = _readOption().copyWith(fontFamily: normalized);
    return Instances.sp.setString(
      _settingsKey,
      jsonEncode(_optionToJson(option)),
    );
  }

  static DanmakuOption _parseOption(Map<String, dynamic> settings) {
    final savedFont = settings['fontFamily'];
    final fontFamily = switch (savedFont) {
      null => AppFonts.defaultFont,
      AppFonts.systemFont => AppFonts.systemFont,
      final String value => AppFonts.normalizeFont(value),
      _ => AppFonts.defaultFont,
    };
    return DanmakuOption(
      fontSize:
          BgmUtils.toDouble(settings['fontSize']) ??
          DanmakuOption.defaultFontSize,
      fontFamily: fontFamily,
      area: BgmUtils.toDouble(settings['area']) ?? 1.0,
      opacity: BgmUtils.toDouble(settings['opacity']) ?? 1.0,
      duration: BgmUtils.toDouble(settings['duration']) ?? 8.0,
      hideTop: settings['hideTop'] == true,
      hideBottom: settings['hideBottom'] == true,
      hideScroll: settings['hideScroll'] == true,
      strokeWidth: BgmUtils.toDouble(settings['strokeWidth']) ?? 2.0,
    );
  }

  static Future<void> saveSettings(DanmakuController controller) async {
    final option = controller.option;
    final preferences = Instances.sp;
    await Future.wait([
      preferences.setString(_settingsKey, jsonEncode(_optionToJson(option))),
      preferences.setString(_blockWordsKey, jsonEncode(controller.blockWords)),
      preferences.setBool(_blockRepeatKey, controller.blockRepeat),
      preferences.setBool(_blockColorKey, controller.blockColor),
    ]);
  }

  static Map<String, dynamic> _optionToJson(DanmakuOption option) => {
    'fontSize': option.fontSize,
    'fontFamily': option.fontFamily,
    'area': option.area,
    'opacity': option.opacity,
    'duration': option.duration,
    'hideTop': option.hideTop,
    'hideBottom': option.hideBottom,
    'hideScroll': option.hideScroll,
    'strokeWidth': option.strokeWidth,
  };

  static String encode(List<DanmakuItem> items) {
    final output = StringBuffer('[');
    for (var index = 0; index < items.length; index++) {
      if (index != 0) output.write(',');
      final item = items[index];
      output
        ..write('{"m":')
        ..write(jsonEncode(item.text))
        ..write(',"p":"')
        ..write(item.time / 1000)
        ..write(',')
        ..write(item.type)
        ..write(',')
        ..write(item.color.toARGB32() & 0xFFFFFF)
        ..write('"}');
    }
    return (output..write(']')).toString();
  }

  @visibleForTesting
  static void clearCache() {
    _cache.clear();
    _inFlightLoads.clear();
    _cachedItemCount = 0;
  }

  @visibleForTesting
  static ({int episodes, int items}) get cacheSize =>
      (episodes: _cache.length, items: _cachedItemCount);

  @visibleForTesting
  static void cacheItems(String key, List<DanmakuItem> items) {
    _putCache(key, items);
  }

  @visibleForTesting
  static Iterable<String> get cachedKeys => _cache.keys;
}

List<DanmakuItem> _decodeDanmakuItems(String raw) {
  final decoded = jsonDecode(raw);
  final rawItems = decoded is List ? decoded : (decoded as Map)['data'] as List;
  final items = <DanmakuItem>[];
  var sorted = true;
  var previousTime = -1;
  for (final raw in rawItems) {
    if (raw is! Map) continue;
    final text = raw['m']?.toString();
    if (text == null || text.isEmpty) continue;
    final parameters = raw['p'];
    if (parameters is! String) continue;
    final firstComma = parameters.indexOf(',');
    final secondComma = parameters.indexOf(',', firstComma + 1);
    if (firstComma <= 0 || secondComma <= firstComma + 1) continue;
    final time = _parseMilliseconds(parameters, firstComma);
    if (time == null) continue;
    final type = _parseUnsignedInt(parameters, firstComma + 1, secondComma);
    if (type == null || (type != 1 && type != 3 && type != 4 && type != 5)) {
      continue;
    }

    final thirdComma = parameters.indexOf(',', secondComma + 1);
    final colorStart = thirdComma < 0 ? secondComma + 1 : thirdComma + 1;
    final fourthComma = thirdComma < 0
        ? -1
        : parameters.indexOf(',', thirdComma + 1);
    final color = _parseUnsignedInt(
      parameters,
      colorStart,
      fourthComma < 0 ? parameters.length : fourthComma,
    );
    if (color == null) continue;
    if (time < previousTime) sorted = false;
    previousTime = time;
    items.add(
      DanmakuItem(
        text,
        time: time,
        color: Color(0xFF000000 | color),
        type: type,
      ),
    );
  }
  if (!sorted) items.sort((left, right) => left.time.compareTo(right.time));
  return items;
}

int? _parseMilliseconds(String value, int end) {
  var whole = 0;
  var fraction = 0;
  var fractionDigits = 0;
  var decimal = false;
  for (var index = 0; index < end; index++) {
    final code = value.codeUnitAt(index);
    if (code == 46 && !decimal) {
      decimal = true;
      continue;
    }
    if (code < 48 || code > 57) return null;
    final digit = code - 48;
    if (!decimal) {
      whole = whole * 10 + digit;
    } else if (fractionDigits < 3) {
      fraction = fraction * 10 + digit;
      fractionDigits++;
    }
  }
  while (fractionDigits < 3) {
    fraction *= 10;
    fractionDigits++;
  }
  return whole * 1000 + fraction;
}

int? _parseUnsignedInt(String value, int start, int end) {
  if (start >= end) return null;
  var result = 0;
  for (var index = start; index < end; index++) {
    final code = value.codeUnitAt(index);
    if (code < 48 || code > 57) return null;
    result = result * 10 + code - 48;
  }
  return result;
}
