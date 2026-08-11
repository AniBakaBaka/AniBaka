import 'package:baka/services/torrent/tracker_client.dart';
import 'package:test/test.dart';

void main() {
  test('torrent trackers are augmented with public fallbacks', () {
    final trackers = TrackerClient.normalizeTrackers(const [
      'http://legacy.example/announce',
      'HTTP://LEGACY.EXAMPLE/ANNOUNCE',
      'ftp://unsupported.example/announce',
    ]);

    expect(trackers.first, 'http://legacy.example/announce');
    expect(trackers, contains('udp://tracker.opentrackr.org:1337/announce'));
    expect(
      trackers.where(
        (tracker) => tracker.toLowerCase() == 'http://legacy.example/announce',
      ),
      hasLength(1),
    );
    expect(trackers, everyElement(isNot(startsWith('ftp://'))));
  });
}
