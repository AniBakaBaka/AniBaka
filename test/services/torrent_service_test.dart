import 'package:test/test.dart';

import 'package:baka/services/torrent/torrent_service.dart';
import 'package:baka/services/torrent/torrent_model.dart';

void main() {
  test('BT link detection accepts magnets and torrent URLs only', () {
    expect(TorrentService.isBtLink('magnet:?xt=urn:btih:abc'), isTrue);
    expect(
      TorrentService.isBtLink('https://cdn.example/a.TORRENT?token=1'),
      isTrue,
    );
    expect(
      TorrentService.isBtLink(
        'https://cdn.example/download?name=a.torrent&token=1',
      ),
      isTrue,
    );
    expect(TorrentService.isBtLink('bt://not-implemented'), isFalse);
    expect(TorrentService.isBtLink('https://cdn.example/video.mp4'), isFalse);
  });

  test(
    'non-BT playback URLs pass through without starting an engine',
    () async {
      const direct = 'https://cdn.example/video.mp4';
      final resolved = await TorrentService.instance.resolvePlaybackUrl(
        ' $direct ',
      );
      expect(resolved, direct);
      expect(TorrentService.instance.engine, isNull);
    },
  );

  test('torrent playback errors have a stable user-facing message', () {
    const error = TorrentPlaybackException('buffer timeout');
    expect(error.toString(), contains('buffer timeout'));
  });

  test('magnet parser keeps trackers and exact torrent sources', () {
    final magnet = MagnetLink.parse(
      'magnet:?xt=urn:btih:1111111111111111111111111111111111111111'
      '&tr=udp%3A%2F%2Ftracker.example%3A80%2Fannounce'
      '&xs=https%3A%2F%2Fcdn.example%2Ffile.torrent',
    );

    expect(magnet.trackers, ['udp://tracker.example:80/announce']);
    expect(magnet.exactSources, ['https://cdn.example/file.torrent']);
  });
}
