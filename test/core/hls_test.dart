import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:baka/source/hls/hls_ad_filter.dart';
import 'package:baka/source/hls/hls_ts_prefix.dart';
import 'package:baka/source/hls/hls_playlist.dart';
import 'package:baka/source/hls/mpeg_ts_fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:baka/source/runtime/source_operation.dart';
import 'package:baka/source/runtime/request_scheduler.dart';
import '../support/ts_prefix_fixtures.dart';

/// 正片指纹：1920x816、level 4.0、High profile。
const _content = HlsVideoFingerprint(
  width: 1920,
  height: 816,
  levelIdc: 40,
  profileIdc: 100,
);

/// 广告指纹：1920x1080、level 5.0、High profile（实测样本）。
const _ad = HlsVideoFingerprint(
  width: 1920,
  height: 1080,
  levelIdc: 50,
  profileIdc: 100,
);

final _manifestUri = Uri.parse('https://cdn.example/hls/index.m3u8');

/// 每个块是一个 `#EXT-X-DISCONTINUITY` 分组；块内每个名字生成一个 4 秒分片，
/// 分片名带指纹前缀，探测函数据此前缀返回指纹。
String _build(List<List<String>> blocks) {
  final lines = <String>[
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-TARGETDURATION:8',
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:VOD',
  ];
  var index = 0;
  for (final names in blocks) {
    lines.add('#EXT-X-DISCONTINUITY');
    for (final name in names) {
      lines.add('#EXTINF:4.000,');
      lines.add('${name}_$index.ts');
      index++;
    }
  }
  lines.add('#EXT-X-ENDLIST');
  return lines.join('\n');
}

List<String> _contentBlock([int count = 5]) =>
    List<String>.filled(count, 'content');

List<String> _adBlock(int count) => List<String>.filled(count, 'ad');

/// 分片名前缀决定指纹；[nullFor] 里的分片模拟探测失败。
Future<HlsVideoFingerprint?> Function(Uri) _probe({
  Set<String> nullFor = const {},
}) {
  return (uri) async {
    final name = uri.pathSegments.last;
    if (nullFor.contains(name)) return null;
    if (name.startsWith('content')) return _content;
    if (name.startsWith('ad')) return _ad;
    return null;
  };
}

int _segmentsOf(String manifest) =>
    manifest.split('\n').where((line) => line.endsWith('.ts')).length;

int _discontinuitiesOf(String manifest) => manifest
    .split('\n')
    .where((line) => line.trim() == '#EXT-X-DISCONTINUITY')
    .length;

const _multiVariant = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=640x360
360p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x816
1080p/index.m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=99000,URI="iframes/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=900000
540p/index.m3u8
''';

const _withAudioRendition = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="国语",URI="audio/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aac",RESOLUTION=1920x816
video/index.m3u8
''';

const _mediaPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:8
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:4.000,
seg0.ts
#EXT-X-ENDLIST
''';

final _baseUri = Uri.parse('https://vip.example/20260906/35899/index.m3u8');

void main() {
  group('HLS TS prefix', () {
    test('removes an image prefix split across network chunks', () async {
      final wrapped = Uint8List.fromList([
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        ...List.filled(459, 0),
        ...contentPrefixBytes,
      ]);
      final offsets = <int>[];
      final output = await HlsTsPrefix.strip(
        Stream.fromIterable([
          wrapped.sublist(0, 3),
          wrapped.sublist(3, 800),
          wrapped.sublist(800, 1000),
          wrapped.sublist(1000),
        ]),
        onTransportStream: offsets.add,
      ).expand((bytes) => bytes).toList();
      expect(offsets, [467]);
      expect(output, contentPrefixBytes);
    });

    test('plain transport streams retain every byte', () async {
      final offsets = <int>[];
      final output = await HlsTsPrefix.strip(
        Stream.value(contentPrefixBytes),
        onTransportStream: offsets.add,
      ).expand((bytes) => bytes).toList();
      expect(offsets, [0]);
      expect(output, contentPrefixBytes);
    });

    test(
      'short and unknown responses pass through without truncation',
      () async {
        for (final size in [0, 16, MpegTsFingerprint.probeBytes * 2]) {
          final bytes = Uint8List(size);
          final output = await HlsTsPrefix.strip(
            Stream.value(bytes),
            onTransportStream: (_) => fail('not a transport stream'),
          ).expand((bytes) => bytes).toList();
          expect(output, bytes);
        }
      },
    );

    test(
      'stops probing at the limit and streams later chunks unchanged',
      () async {
        final prefix = Uint8List(MpegTsFingerprint.probeBytes);
        final stream = HlsTsPrefix.strip(
          Stream.fromIterable([prefix, contentPrefixBytes]),
          onTransportStream: (_) => fail('must not search the entire segment'),
        );
        expect(await stream.expand((bytes) => bytes).toList(), [
          ...prefix,
          ...contentPrefixBytes,
        ]);
      },
    );

    test('cancelling downstream cancels the upstream stream', () async {
      final cancelled = Completer<void>();
      final source = StreamController<Uint8List>(onCancel: cancelled.complete);
      source.add(contentPrefixBytes);
      await HlsTsPrefix.strip(source.stream, onTransportStream: (_) {}).first;
      await cancelled.future;
      await source.close();
    });
  });

  group('ad filtering', () {
    test(
      'suspect groups share all probe slots and reuse their heads',
      () async {
        final playlist = HlsPlaylist.parse(
          _build([
            _contentBlock(20),
            _adBlock(3),
            _contentBlock(20),
            _adBlock(3),
            _contentBlock(20),
          ]),
          _manifestUri,
        );
        final calls = <Uri, int>{};
        final held = <Completer<HlsVideoFingerprint?>>[];
        var holding = true;
        final filtering = HlsAdFilter.apply(
          playlist,
          probe: (uri) async {
            calls.update(uri, (count) => count + 1, ifAbsent: () => 1);
            final name = uri.pathSegments.last;
            if (!name.startsWith('ad')) return _content;
            if (!holding || name == 'ad_20.ts' || name == 'ad_43.ts') {
              return _ad;
            }
            final pending = Completer<HlsVideoFingerprint?>();
            held.add(pending);
            return pending.future;
          },
        );
        await Future<void>.delayed(Duration.zero);
        try {
          expect(held, hasLength(4));
        } finally {
          holding = false;
          for (final pending in held) {
            pending.complete(_ad);
          }
        }
        final outcome = await filtering;
        expect(outcome.removedSegments, 6);
        expect(calls.values, everyElement(1));
        expect(calls, hasLength(9)); // Five heads, four confirmations.
      },
    );

    test(
      'unknown group heads are retained without serial replacement probes',
      () async {
        final playlist = HlsPlaylist.parse(
          _build([_contentBlock(20), _adBlock(3), _contentBlock(20)]),
          _manifestUri,
        );
        final calls = <Uri>[];
        final outcome = await HlsAdFilter.apply(
          playlist,
          probe: (uri) async {
            calls.add(uri);
            return uri.pathSegments.last.startsWith('ad') ? null : _content;
          },
        );
        expect(outcome.changed, isFalse);
        expect(calls, hasLength(3));
        expect(identical(playlist.render(), playlist.body), isTrue);
      },
    );

    test(
      'cancelled filtering does not start queued probes or change the playlist',
      () async {
        final playlist = HlsPlaylist.parse(
          _build([for (var i = 0; i < 10; i++) _contentBlock()]),
          _manifestUri,
        );
        final operation = SourceOperation();
        addTearDown(operation.close);
        var calls = 0;
        final release = Completer<HlsVideoFingerprint?>();
        final filtering = operation.run(
          () => HlsAdFilter.apply(
            playlist,
            probe: (_) {
              calls++;
              return release.future;
            },
          ),
        );
        final failed = expectLater(
          filtering,
          throwsA(isA<RequestCancelledException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(calls, 4);
        operation.cancel();
        release.complete(_content);
        await failed;
        await Future<void>.delayed(Duration.zero);
        expect(calls, 4);
        expect(playlist.removed, isNull);
      },
    );

    test('删除整组异编码分片，保留其余分片与清单结构', () async {
      final manifest = _build([
        _contentBlock(),
        _contentBlock(),
        _adBlock(3), // 广告段：正片 100s / 广告 12s
        _contentBlock(),
        _contentBlock(),
        _contentBlock(),
      ]);
      expect(_segmentsOf(manifest), 28);
      expect(_discontinuitiesOf(manifest), 6);

      final playlist = HlsPlaylist.parse(manifest, _manifestUri);

      final outcome = await HlsAdFilter.apply(playlist, probe: _probe());

      expect(outcome.changed, isTrue);
      expect(outcome.removedSegments, 3);
      expect(outcome.removedSeconds, closeTo(12, 1e-9));
      expect(
        outcome.timelineKey,
        'hls:${sha256.convert(utf8.encode(jsonEncode([
          for (var i = 0; i < 28; i++) [4000, i >= 10 && i < 13],
        ])))}',
      );
      expect(outcome.detail, contains('1920x816/L40/P100'));
      expect(playlist.render(), isNot(contains('ad_')));
      expect(_segmentsOf(playlist.render()), 25);
      // 广告组的 discontinuity 标记随整组一起删除，不留空标记。
      expect(_discontinuitiesOf(playlist.render()), 5);
      expect(playlist.render(), startsWith('#EXTM3U'));
      expect(playlist.render(), contains('#EXT-X-ENDLIST'));

      // 剩余的 EXTINF 与 URI 仍一一对应。
      final lines = playlist.render().split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith('#EXTINF:')) continue;
        expect(lines[i + 1].endsWith('.ts'), isTrue);
      }
    });

    test('全部指纹一致时原样返回，不复制清单', () async {
      final manifest = _build([
        _contentBlock(),
        _contentBlock(),
        _contentBlock(),
      ]);

      final playlist = HlsPlaylist.parse(manifest, _manifestUri);

      final outcome = await HlsAdFilter.apply(playlist, probe: _probe());

      expect(outcome.changed, isFalse);
      expect(identical(playlist.render(), manifest), isTrue);
      expect(outcome.detail, contains('未发现异编码片段'));
    });

    test('连续异编码片段超过 60s 上限时放弃过滤', () async {
      // 20 片 x 4s = 80s 的连续异编码片段，更像多段不同编码的正片而不是广告。
      final manifest = _build([
        ...List.generate(6, (_) => _contentBlock()),
        _adBlock(20),
        ...List.generate(6, (_) => _contentBlock()),
      ]);

      final playlist = HlsPlaylist.parse(manifest, _manifestUri);

      final outcome = await HlsAdFilter.apply(playlist, probe: _probe());

      expect(outcome.changed, isFalse);
      expect(playlist.render(), manifest);
      expect(outcome.detail, contains('超过 60s 上限'));
    });

    test('异编码片段占多数时不会反过来把正片当广告删掉', () async {
      // 广告 80s 比正片 40s 还长：多数票会落在“广告”指纹上，占比上限兜住。
      final manifest = _build([
        _adBlock(20),
        _contentBlock(5),
        _contentBlock(5),
      ]);

      final playlist = HlsPlaylist.parse(manifest, _manifestUri);

      final outcome = await HlsAdFilter.apply(playlist, probe: _probe());

      expect(outcome.changed, isFalse);
      expect(playlist.render(), manifest);
      expect(playlist.render(), contains('content_20.ts'));
      expect(outcome.detail, contains('15% 上限'));
    });

    test('删除总量超过整条清单 15% 时放弃过滤', () async {
      // 正片 24s / 广告 12s = 33%，超过占比上限。
      final manifest = _build([
        _contentBlock(3),
        _adBlock(3),
        _contentBlock(3),
      ]);

      final playlist = HlsPlaylist.parse(manifest, _manifestUri);

      final outcome = await HlsAdFilter.apply(playlist, probe: _probe());

      expect(outcome.changed, isFalse);
      expect(playlist.render(), manifest);
      expect(outcome.detail, contains('15% 上限'));
    });

    test('探测失败的分片按正片保留', () async {
      final manifest = _build([
        _contentBlock(),
        _contentBlock(),
        _adBlock(3),
        _contentBlock(),
        _contentBlock(),
      ]);

      final playlist = HlsPlaylist.parse(manifest, _manifestUri);

      final outcome = await HlsAdFilter.apply(
        playlist,
        probe: _probe(nullFor: {'ad_11.ts'}),
      );

      expect(outcome.changed, isTrue);
      expect(outcome.removedSegments, 2);
      expect(playlist.render(), contains('ad_11.ts'));
      expect(playlist.render(), isNot(contains('ad_10.ts')));
      expect(playlist.render(), isNot(contains('ad_12.ts')));
      expect(
        playlist.render(),
        contains('#EXT-X-DISCONTINUITY\n#EXTINF:4.000,\nad_11.ts'),
      );
    });

    test('分片太少时不做任何探测', () async {
      final manifest = _build([_contentBlock(2)]);
      var probes = 0;

      final playlist = HlsPlaylist.parse(manifest, _manifestUri);

      final outcome = await HlsAdFilter.apply(
        playlist,
        probe: (uri) async {
          probes++;
          return _content;
        },
      );

      expect(probes, 0);
      expect(outcome.changed, isFalse);
    });

    test('加密清单原文保留，不做不安全的分片删除', () async {
      final manifest =
          _build([
            _adBlock(3),
            _contentBlock(),
            _contentBlock(),
            _contentBlock(),
            _contentBlock(),
            _contentBlock(),
          ]).replaceFirst(
            '#EXT-X-DISCONTINUITY\n#EXTINF:4.000,\nad_0.ts',
            '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
                '#EXT-X-DISCONTINUITY\n#EXTINF:4.000,\nad_0.ts',
          );

      final playlist = HlsPlaylist.parse(manifest, _manifestUri);

      final outcome = await HlsAdFilter.apply(playlist, probe: _probe());

      expect(outcome.changed, isFalse);
      expect(playlist.render(), manifest);
      expect(playlist.render(), contains('#EXT-X-KEY:METHOD=AES-128'));
      expect(playlist.render(), contains('#EXT-X-TARGETDURATION:8'));
      expect(playlist.render(), contains('ad_'));
    });
  });

  for (final tag in [
    '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"',
    '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x01',
    '#EXT-X-MAP:URI="init.mp4"',
    '#EXT-X-BYTERANGE:100',
    '#EXT-X-BYTERANGE:100@200',
  ]) {
    for (final afterBoundary in [false, true]) {
      test(
        'complex HLS is unchanged with zero probes: $tag after=$afterBoundary',
        () async {
          final original = _build([
            _contentBlock(),
            _adBlock(1),
            _contentBlock(),
          ]);
          final manifest = original.replaceFirst(
            '#EXT-X-DISCONTINUITY',
            afterBoundary
                ? '#EXT-X-DISCONTINUITY\n$tag'
                : '$tag\n#EXT-X-DISCONTINUITY',
          );
          var probes = 0;
          final playlist = HlsPlaylist.parse(manifest, _manifestUri);
          final outcome = await HlsAdFilter.apply(
            playlist,
            probe: (_) async {
              probes++;
              return _content;
            },
          );
          expect(outcome.changed, isFalse);
          expect(playlist.render(), manifest);
          expect(probes, 0);
        },
      );
    }
  }
  test('DISCONTINUITY-SEQUENCE survives removing the first group', () async {
    final manifest = _build([
      _adBlock(1),
      _contentBlock(),
      _contentBlock(),
      _contentBlock(),
    ]).replaceFirst('#EXTM3U', '#EXTM3U\n#EXT-X-DISCONTINUITY-SEQUENCE:8');
    final playlist = HlsPlaylist.parse(manifest, _manifestUri);
    final outcome = await HlsAdFilter.apply(playlist, probe: _probe());
    expect(outcome.changed, isTrue);
    expect(playlist.render(), contains('#EXT-X-DISCONTINUITY-SEQUENCE:8'));
  });

  group('master playlists', () {
    test('选定变体取最高 BANDWIDTH', () {
      final playlist = HlsPlaylist.parse(_multiVariant, _baseUri);
      final selected = playlist.variant;

      expect(playlist.isMaster, isTrue);
      expect(playlist.segments, isEmpty);
      expect(selected, isNotNull);
      expect(
        selected!.uri.toString(),
        'https://vip.example/20260906/35899/1080p/index.m3u8',
      );
      expect(selected.resolution, '1920x816');
      expect(selected.bandwidth, 2000000);
    });

    test('BANDWIDTH is distinct from AVERAGE-BANDWIDTH', () {
      const manifest =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=100000,BANDWIDTH=2000000\n'
          'high.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
          'low.m3u8\n';
      expect(
        HlsPlaylist.parse(manifest, _baseUri).variant!.uri.path,
        endsWith('/high.m3u8'),
      );
    });

    test('a missing variant URI is not borrowed from a later variant', () {
      const manifest =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2000000\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
          'low.m3u8\n';
      final selected = HlsPlaylist.parse(manifest, _baseUri).variant!;
      expect(selected.bandwidth, 1000000);
    });

    test('带独立音轨的清单不接管，返回 null', () {
      expect(HlsPlaylist.parse(_withAudioRendition, _baseUri).variant, isNull);
    });

    test('没有变体时返回 null', () {
      final playlist = HlsPlaylist.parse(_mediaPlaylist, _baseUri);
      expect(playlist.variant, isNull);
      expect(playlist.isMaster, isFalse);
    });
  });

  test(
    'CRLF filtering preserves tags, URI attributes and retained boundaries',
    () async {
      final body = _build([
        _contentBlock(20),
        _adBlock(3),
        _contentBlock(20),
      ]).replaceAll('\n', '\r\n');
      final playlist = HlsPlaylist.parse(body, _manifestUri);
      final outcome = await HlsAdFilter.apply(playlist, probe: _probe());
      expect(outcome.removedSegments, 3);
      expect(
        playlist.render(),
        body.replaceFirst(
          '#EXT-X-DISCONTINUITY\r\n#EXTINF:4.000,\r\nad_20.ts\r\n'
              '#EXTINF:4.000,\r\nad_21.ts\r\n#EXTINF:4.000,\r\nad_22.ts\r\n',
          '',
        ),
      );
      final encrypted = HlsPlaylist.parse(
        '#EXTM3U\r\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\r\n'
        '#EXT-X-MAP:URI="init.mp4"\r\n#EXTINF:4,\r\nsegment.ts\r\n#EXT-X-ENDLIST\r\n',
        _manifestUri,
      );
      final resources = <({Uri uri, bool segment})>[];
      final rendered = encrypted.render(
        rewrite: (uri, segment) {
          resources.add((uri: uri, segment: segment));
          return 'http://localhost/${resources.length}';
        },
      );
      expect(resources.map((r) => r.segment), [false, false, true]);
      expect(resources.map((r) => r.uri.toString()), [
        'https://cdn.example/hls/key.bin',
        'https://cdn.example/hls/init.mp4',
        'https://cdn.example/hls/segment.ts',
      ]);
      expect(rendered, contains('URI="http://localhost/1"\r\n'));
      expect(rendered, contains('http://localhost/3\r\n#EXT-X-ENDLIST'));
    },
  );

  group('TS fingerprints', () {
    test('growing prefixes decode across arbitrary chunk boundaries', () {
      for (final fixture in [contentPrefixBytes, adPrefixBytes]) {
        final expected = MpegTsFingerprint().read(fixture);
        for (final step in [1, 17, 187, 188, 189]) {
          final reader = MpegTsFingerprint();
          HlsVideoFingerprint? result;
          for (var end = step; end < fixture.length; end += step) {
            result = reader.read(Uint8List.sublistView(fixture, 0, end));
            if (result != null) break;
          }
          expect(result ?? reader.read(fixture), expected);
        }
      }
    });

    test('TS alignment needs three sync bytes, not three complete packets', () {
      final prefix = Uint8List(MpegTsFingerprint.packetSize * 2 + 1);
      for (var i = 0; i < prefix.length; i += MpegTsFingerprint.packetSize) {
        prefix[i] = 0x47;
      }
      expect(MpegTsFingerprint.findPacketStart(prefix), 0);
    });

    test('正片前缀读出 1920x816 / level 4.0 / High profile', () {
      final fingerprint = MpegTsFingerprint().read(contentPrefixBytes);

      expect(fingerprint, isNotNull);
      expect(fingerprint!.width, 1920);
      expect(fingerprint.height, 816);
      expect(fingerprint.levelIdc, 40);
      expect(fingerprint.profileIdc, 100);
      expect(fingerprint.toString(), '1920x816/L40/P100');
    });

    test('广告前缀读出 1920x1080 / level 5.0（已扣除 frame cropping）', () {
      final fingerprint = MpegTsFingerprint().read(adPrefixBytes);

      expect(fingerprint, isNotNull);
      expect(fingerprint!.width, 1920);
      // SPS 编码高度 1088 行，crop_bottom_offset=4、crop_unit_y=2，显示高度 1080。
      expect(fingerprint.height, 1080);
      expect(fingerprint.levelIdc, 50);
      expect(fingerprint.profileIdc, 100);
    });

    test('正片与广告互不匹配', () {
      final content = MpegTsFingerprint().read(contentPrefixBytes);
      final ad = MpegTsFingerprint().read(adPrefixBytes);

      expect(content == ad, isFalse);
      expect(content == content, isTrue);
      expect(content, isNot(equals(ad)));
    });

    test('前缀被截断、非 TS 内容或空输入都返回 null', () {
      expect(MpegTsFingerprint().read(Uint8List(0)), isNull);
      expect(
        MpegTsFingerprint().read(Uint8List.fromList(List<int>.filled(4096, 0))),
        isNull,
      );
      expect(
        MpegTsFingerprint().read(Uint8List.fromList(utf8.encode('plain text'))),
        isNull,
      );
      // 512 字节还读不到 SPS，应放弃而不是猜。
      expect(
        MpegTsFingerprint().read(
          Uint8List.sublistView(contentPrefixBytes, 0, 512),
        ),
        isNull,
      );
    });
  });
}
