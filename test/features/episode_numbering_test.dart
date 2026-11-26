import 'package:baka/services/playback/episode_numbering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseEpisodeNumber', () {
    test('识别常见的中日英写法', () {
      expect(parseEpisodeNumber('第9集'), 9);
      expect(parseEpisodeNumber('第 12 话 相遇'), 12);
      expect(parseEpisodeNumber('第3話'), 3);
      expect(parseEpisodeNumber('EP09'), 9);
      expect(parseEpisodeNumber('EP.09 标题'), 9);
      expect(parseEpisodeNumber('Episode 9'), 9);
      expect(parseEpisodeNumber('E09'), 9);
      expect(parseEpisodeNumber('[09] 标题'), 9);
      expect(parseEpisodeNumber('新乱马 - 09'), 9);
      expect(parseEpisodeNumber('09'), 9);
      expect(parseEpisodeNumber('09 标题'), 9);
      expect(parseEpisodeNumber('09.标题'), 9);
    });

    test('不把分辨率、年份、分辨率标签当成集号', () {
      expect(parseEpisodeNumber('1080p'), isNull);
      expect(parseEpisodeNumber('[1080p]'), isNull);
      // 写成「第720集」就明确是集号，不该被分辨率黑名单拦掉
      expect(parseEpisodeNumber('第720集'), 720);
      expect(parseEpisodeNumber('[720]'), isNull);
      // 超过三位数的集号按异常处理，不猜
      expect(parseEpisodeNumber('第1080集'), isNull);
      expect(parseEpisodeNumber('2024'), isNull);
      expect(parseEpisodeNumber('第2024集'), isNull);
      expect(parseEpisodeNumber('Remake07'), isNull);
      expect(parseEpisodeNumber(''), isNull);
      expect(parseEpisodeNumber('纯标题没有数字'), isNull);
    });

    test('半集不算整数集号', () {
      expect(parseEpisodeNumber('09.5'), isNull);
      expect(parseEpisodeNumber('EP9.5'), isNull);
      expect(parseEpisodeNumber('第9.5集'), isNull);
      expect(parseEpisodeNumber('[09].5'), isNull);
      // 标题里另带半集编号时，正经的集号写法仍然生效
      expect(parseEpisodeNumber('第9集 9.5'), 9);
      expect(parseEpisodeNumber('09.标题'), 9);
    });

    test('优先采用「第N集」而不是其他数字', () {
      expect(parseEpisodeNumber('第9集 [1080p]'), 9);
      expect(parseEpisodeNumber('第9集 2024年'), 9);
    });
  });

  group('EpisodeNumbering', () {
    test('顺序排版的下一集就是下标 + 1', () {
      final numbering = EpisodeNumbering(['第1集', '第2集', '第3集']);
      expect(numbering.nextIndex(0), 1);
      expect(numbering.previousIndex(2), 1);
      expect(numbering.nextIndex(2), isNull);
      expect(numbering.previousIndex(0), isNull);
    });

    test('倒序排版按集号走，而不是按下标走', () {
      // 源页面把最新一集放在最前面：下标 0 是第 3 集。
      final numbering = EpisodeNumbering(['第3集', '第2集', '第1集']);
      expect(numbering.numberAt(0), 3);
      expect(numbering.nextIndex(2), 1, reason: '第1集的下一集是第2集');
      expect(numbering.previousIndex(0), 1, reason: '第3集的上一集是第2集');
    });

    test('源缺集时跳过缺口', () {
      // 源只上到第 6 集，中间缺了第 3 集。
      final numbering = EpisodeNumbering(['第1集', '第2集', '第4集', '第6集']);
      expect(numbering.nextIndex(1), 2, reason: '第2集的下一集是第4集');
      expect(numbering.nextIndex(3), isNull);
      expect(numbering.indexOfNumber(4), 2);
      expect(numbering.indexOfNumber(3), isNull);
    });

    test('读不出集号时按顺序播放', () {
      final numbering = EpisodeNumbering(['第一话', '第二话', '第三话']);
      expect(numbering.isUsable, isFalse);
      expect(numbering.nextIndex(0), isNull);
    });

    test('集号重复时判定不可用', () {
      final numbering = EpisodeNumbering(['第1集', '第1集', '第1集']);
      expect(numbering.isUsable, isFalse);
    });
  });

  group('BgmEpisodeOrder', () {
    List<Map<String, dynamic>> episodes(List<num> sorts) => [
      for (final sort in sorts) {'id': sort.toInt() * 10, 'sort': sort},
    ];

    test('按集号取条目与集序', () {
      final list = episodes([1, 2, 3]);
      expect(BgmEpisodeOrder.byNumber(list, 2)?['id'], 20);
      expect(BgmEpisodeOrder.ordinalOf(list, 3), 3);
      expect(BgmEpisodeOrder.byNumber(list, 9), isNull);
    });

    test('集号有缺口时集序不等于集号', () {
      final list = episodes([1, 3, 5]);
      expect(BgmEpisodeOrder.ordinalOf(list, 5), 3, reason: '第 5 集是第三集');
      expect(BgmEpisodeOrder.ordinalOf(list, 4), isNull);
    });

    test('支持半集', () {
      final list = episodes([1, 1.5, 2]);
      expect(BgmEpisodeOrder.ordinalOf(list, 1.5), 2);
    });
  });
}
