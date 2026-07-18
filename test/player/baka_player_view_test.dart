import 'package:baka/widgets/baka_player/controller.dart';
import 'package:baka/widgets/baka_player/view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fullscreen view receives the existing player arguments', () async {
    final controller = PlaybackController();
    const header = SizedBox(key: Key('header'));
    const danmaku = SizedBox(key: Key('danmaku'));
    final detail = <String, Object>{'id': 1};
    void pickEpisode() {}
    void nextEpisode() {}
    void fullscreenChanged(bool value) {}

    final source = BakaPlayer(
      controller: controller,
      detail: detail,
      headerControl: header,
      danmuWidget: danmaku,
      onPickEpisode: pickEpisode,
      hasNextEpisode: true,
      onNextEpisode: nextEpisode,
      onFullScreenChanged: fullscreenChanged,
    );
    final fullscreen = source.fullscreenView();

    expect(fullscreen.full, isTrue);
    expect(fullscreen.controller, same(controller));
    expect(fullscreen.detail, same(detail));
    expect(fullscreen.headerControl, same(header));
    expect(fullscreen.danmuWidget, same(danmaku));
    expect(fullscreen.onPickEpisode, same(pickEpisode));
    expect(fullscreen.hasNextEpisode, isTrue);
    expect(fullscreen.onNextEpisode, same(nextEpisode));
    expect(fullscreen.onFullScreenChanged, same(fullscreenChanged));
    await controller.dispose();
  });
}
