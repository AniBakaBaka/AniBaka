import 'dart:collection';
import 'dart:convert';

import 'package:baka/api/post.dart';
import 'package:baka/services/bgm_service.dart';
import 'package:baka/utils/bgm_utils.dart';
import 'package:baka/widgets/danmaku/controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DanmakuService {
  static const String _settingsKey = 'danmaku_settings';
  static const String _blockWordsKey = 'danmaku_block_words';
  static const String _blockRepeatKey = 'danmaku_block_repeat';
  static const String _blockColorKey = 'danmaku_block_color';
  static const int maxCachedEpisodes = 8;
  static const int maxCachedItems = 20000;

  static final LinkedHashMap<String, List<DanmakuItem>> _cache =
      LinkedHashMap<String, List<DanmakuItem>>();
  static int _cachedItemCount = 0;

  static Future<List<DanmakuItem>> getDanmakuItems({
    required String bgmId,
    required int episodeIndex,
    required String originalTitle,
  }) async {
    final cacheKey = '$bgmId-$episodeIndex';
    final cached = _readCache(cacheKey);
    if (cached != null) return cached;

    final subjectId = int.tryParse(bgmId);
    if (subjectId == null || subjectId <= 0) return const [];
    final subject = await BgmService.resolveSubject(
      bgmId: bgmId,
      title: originalTitle,
      withDetail: true,
    );
    final titles =
        subject?.searchTitles ?? BgmUtils.buildSearchTitles([originalTitle]);
    if (titles.isEmpty) return const [];

    final raw = await _fetchFirstAvailableDanmaku(
      subjectId,
      episodeIndex,
      titles,
    );
    if (raw == null) return const [];
    final parsed = await parseItems(raw);
    if (parsed.isNotEmpty) _putCache(cacheKey, parsed);
    return parsed;
  }

  static Future<List<DanmakuItem>> fetchDanmakuBySubjectAndEpisode({
    required int subjectId,
    required int episodeIndex,
    String? title,
  }) async {
    final cacheKey = '$subjectId-$episodeIndex';
    final cached = _readCache(cacheKey);
    if (cached != null) return cached;

    final subject = await BgmService.resolveSubject(
      bgmId: subjectId.toString(),
      title: title ?? '',
      withDetail: true,
    );
    final searchTitles =
        subject?.searchTitles ??
        (title != null && title.isNotEmpty
            ? BgmUtils.buildSearchTitles([title])
            : const []);

    final raw = await _fetchFirstAvailableDanmaku(
      subjectId,
      episodeIndex,
      searchTitles.isNotEmpty ? searchTitles : [''],
    );
    if (raw == null) return const [];
    final parsed = await parseItems(raw);
    if (parsed.isNotEmpty) _putCache(cacheKey, parsed);
    return parsed;
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

  static Future<List<dynamic>?> _fetchFirstAvailableDanmaku(
    int bgmId,
    int episodeIndex,
    List<String> titles,
  ) async {
    for (final title in titles) {
      try {
        final parsed = _parseResponse(
          await getDanmu(bgmId, episodeIndex, title),
        );
        if (parsed != null && parsed.isNotEmpty) return parsed;
      } catch (error) {
        debugPrint('fetch danmaku error: $error');
      }
    }
    return null;
  }

  static List<dynamic>? _parseResponse(dynamic response) {
    final rawData = response?.data;
    if (rawData is! String || rawData.isEmpty) return null;
    try {
      final decoded = jsonDecode(rawData);
      final data = decoded is Map ? decoded['data'] : null;
      return data is List ? List<dynamic>.from(data) : null;
    } catch (error) {
      debugPrint('parse danmaku response failed: $error');
      return null;
    }
  }

  static Future<List<DanmakuItem>> parseItems(List<dynamic> rawItems) {
    if (rawItems.isEmpty) return SynchronousFuture(const []);
    return compute(_parseDanmakuItems, rawItems);
  }

  static Future<void> loadSettings(DanmakuController controller) async {
    final preferences = await SharedPreferences.getInstance();
    final option = _parseOption(
      BgmUtils.parseJsonMap(preferences.getString(_settingsKey)) ?? const {},
    );
    controller.blockWords = BgmUtils.parseJsonList(
      preferences.getString(_blockWordsKey),
    ).map((value) => value.toString()).toList();
    controller.blockRepeat = preferences.getBool(_blockRepeatKey) ?? false;
    controller.blockColor = preferences.getBool(_blockColorKey) ?? false;
    controller.updateOption(option);
  }

  static DanmakuOption _parseOption(Map<String, dynamic> settings) {
    return DanmakuOption(
      fontSize:
          BgmUtils.toDouble(settings['fontSize']) ??
          DanmakuOption.defaultFontSize,
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
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setString(
        _settingsKey,
        jsonEncode({
          'fontSize': option.fontSize,
          'area': option.area,
          'opacity': option.opacity,
          'duration': option.duration,
          'hideTop': option.hideTop,
          'hideBottom': option.hideBottom,
          'hideScroll': option.hideScroll,
          'strokeWidth': option.strokeWidth,
        }),
      ),
      preferences.setString(_blockWordsKey, jsonEncode(controller.blockWords)),
      preferences.setBool(_blockRepeatKey, controller.blockRepeat),
      preferences.setBool(_blockColorKey, controller.blockColor),
    ]);
  }

  static void startPlay({
    required DanmakuController controller,
    required List<DanmakuItem> items,
  }) {
    controller.reset();
    if (items.isNotEmpty) controller.setItems(items);
  }

  static List<Map<String, String>> serializeItems(List<DanmakuItem> items) {
    return items
        .map(
          (item) => <String, String>{
            'm': item.text,
            'p':
                '${item.time / 1000},${item.type},${item.color.toARGB32() & 0xFFFFFF}',
          },
        )
        .toList(growable: false);
  }

  @visibleForTesting
  static void clearCache() {
    _cache.clear();
    _cachedItemCount = 0;
  }

  @visibleForTesting
  static ({int episodes, int items}) get cacheSize =>
      (episodes: _cache.length, items: _cachedItemCount);

  @visibleForTesting
  static void cacheItems(String key, List<DanmakuItem> items) {
    _putCache(key, List<DanmakuItem>.unmodifiable(items));
  }

  @visibleForTesting
  static List<String> get cachedKeys => List<String>.unmodifiable(_cache.keys);
}

List<DanmakuItem> _parseDanmakuItems(List<dynamic> rawItems) {
  final items = <DanmakuItem>[];
  var sorted = true;
  var previousTime = -1;
  for (final raw in rawItems) {
    if (raw is! Map) continue;
    final text = raw['m']?.toString();
    if (text == null || text.isEmpty) continue;
    final parameters = raw['p']?.toString().split(',');
    if (parameters == null || parameters.length < 3) continue;
    final seconds = double.tryParse(parameters[0]);
    if (seconds == null) continue;
    final type = int.tryParse(parameters[1]) ?? 1;
    if (type != 1 && type != 3 && type != 4 && type != 5) continue;
    final time = (seconds * 1000).round();
    if (time < previousTime) sorted = false;
    previousTime = time;
    items.add(
      DanmakuItem(
        text,
        time: time,
        color: Color(0xFF000000 | (int.tryParse(parameters[2]) ?? 0xFFFFFF)),
        type: type,
      ),
    );
  }
  if (!sorted) items.sort((left, right) => left.time.compareTo(right.time));
  return List<DanmakuItem>.unmodifiable(items);
}
