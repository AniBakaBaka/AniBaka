import 'dart:convert';

import 'package:crypto/crypto.dart';

const kDefaultImage =
    'https://image.planet.youku.com/img/100/12/59443/i_1716805259443_ca83ed260c207767fc7f5b695e4fd0ad_b_w400h400.jpg';

final _suoRe = RegExp(r'suo.. ?([^)]+)\)');
final _pureDigitsRe = RegExp(r'^[0-9]+$');

/// 从帖子内容提取图片 URL：直链原样返回，`suo(...)` 格式解码返回，否则返回默认占位图。
String getSuo(String? content) {
  if (content == null || content.isEmpty) return kDefaultImage;
  if (content.startsWith('http://') || content.startsWith('https://')) {
    return content;
  }
  final src = _suoRe.firstMatch(content)?.group(1);
  return src == null ? kDefaultImage : Uri.decodeComponent(src);
}

/// 纯数字视为 QQ 号走 QQ 头像，否则取 MD5 走 cravatar。
String getAvatar({String avatar = ''}) {
  if (_pureDigitsRe.hasMatch(avatar)) {
    return 'https://q1.qlogo.cn/g?b=qq&nk=$avatar&s=640';
  }
  final hash = md5.convert(utf8.encode(avatar));
  return 'https://cravatar.cn/avatar/$hash?d=wavatar';
}

class RegUtils {
  /// 标题尾部的季/篇/部标识（第X季、Season X、上篇、剧场版……）
  static const _seasonMarks =
      r'第[一二三四五六七八九十百千\d]+[季期]|Season\s*\d+|S\d+|Part\s*\d+'
      r'|[第上下][季期]|[上下前后]篇?|[一二三四五六七八九十\d]+章'
      r'|特别篇|总集篇|番外篇|剧场版';

  static final _seasonSuffixRe = RegExp(
    r'\s*(?:' + _seasonMarks + r')$',
    caseSensitive: false,
  );
  static final _seasonBracketRe = RegExp(
    r'\s*\((?:' + _seasonMarks + r')\)\s*$',
    caseSensitive: false,
  );

  /// 提取番剧核心标题：剥离尾部季/篇标识（含括号形式）。结果为空时回退原标题。
  static String extractBaseTitle(String fullTitle) {
    if (fullTitle.isEmpty) return '';
    final base = fullTitle
        .replaceFirst(_seasonSuffixRe, '')
        .replaceFirst(_seasonBracketRe, '')
        .trim();
    return base.isEmpty ? fullTitle : base;
  }

  static const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  static final _delayWeekdayRe = RegExp(
    r'(?:延迟|推迟)[到至](周[一二三四五六日])(\d{1,2})(?::|[点时])(\d{2})',
  );
  static final _delayDayRe = RegExp(
    r'(?:延迟|推迟)[到至](当日|次日)(\d{1,2})(?::|[点时])(\d{2})',
  );
  static final _delayHourRe = RegExp(r'(?:延迟|推迟)[到至](\d{1,2})[点时]');
  static final _suspendWeeksRe = RegExp(r'(?:停更|暂停更新|休息|停播)(\d+)[周星期]');
  static final _suspendRe = RegExp(r'停更|暂停更新|停播|休息');

  /// 解析简介中的延迟或停更信息，无匹配时返回 null。
  static String? parseDelayOrSuspensionInfo(String? content) {
    if (content == null || content.isEmpty) return null;

    final weekday = _delayWeekdayRe.firstMatch(content);
    if (weekday != null) {
      return '延迟到${weekday.group(1)}${weekday.group(2)}:${weekday.group(3)}';
    }

    final day = _delayDayRe.firstMatch(content);
    if (day != null) {
      final target = day.group(1) == '次日'
          ? _weekdays[DateTime.now().weekday % 7]
          : _weekdays[DateTime.now().weekday - 1];
      return '延迟到$target${day.group(2)}:${day.group(3)}';
    }

    final hour = _delayHourRe.firstMatch(content);
    if (hour != null) {
      return '延迟到${_weekdays[DateTime.now().weekday - 1]}${hour.group(1)}:00';
    }

    final weeks = _suspendWeeksRe.firstMatch(content);
    if (weeks != null) return '停更${weeks.group(1)}周';

    return _suspendRe.hasMatch(content) ? '停更' : null;
  }
}
