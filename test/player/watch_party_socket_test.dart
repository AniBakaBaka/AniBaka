import 'dart:convert';
import 'dart:io';

import 'package:baka/models/watch_party.dart';
import 'package:baka/services/watch_party_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _invite = WatchPartyInvite(
  roomId: 'room-1',
  inviteCode: 'invite-1',
  inviteUrl: 'https://www.anibaka.com/watch/invite-1',
  syncplayHost: 'sync.anibaka.com',
  syncplayPort: 8999,
  syncplayRoom: '1234567890',
  title: 'Show',
  episodeIndex: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final testHttpOverrides = HttpOverrides.current;

  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = testHttpOverrides);

  test('connection actively requests the initial room snapshot', () async {
    var pingRequests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        if (message['type'] != 'ping') return;
        pingRequests++;
        socket.add(jsonEncode(_snapshotEnvelope));
      });
    });

    final service = WatchPartyService(
      getInviteRequest: (_) async => _invite,
      joinRoomRequest: (_, _) async =>
          'ws://${server.address.address}:${server.port}/room',
    );
    addTearDown(service.leave);

    await service.joinInvite('invite-1', nickname: 'Tester');

    expect(pingRequests, 1);
    expect(service.state.value.connected, isTrue);
    expect(service.state.value.snapshot?.roomId, 'room-1');
  });

  test(
    'invalid initial snapshot fails immediately with a specific error',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((raw) {
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          if (message['type'] == 'ping') {
            socket.add(
              jsonEncode({
                'v': 1,
                'type': 'room.snapshot',
                'revision': 1,
                'payload': {'roomId': 'incomplete'},
              }),
            );
          }
        });
      });

      final service = WatchPartyService(
        getInviteRequest: (_) async => _invite,
        joinRoomRequest: (_, _) async =>
            'ws://${server.address.address}:${server.port}/room',
      );
      addTearDown(service.leave);
      final elapsed = Stopwatch()..start();

      await expectLater(
        service.joinInvite('invite-1', nickname: 'Tester'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '无法解析一起看房间状态',
          ),
        ),
      );

      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
      expect(service.state.value.status, WatchPartyConnectionStatus.failed);
    },
  );
}

const _snapshotEnvelope = <String, dynamic>{
  'v': 1,
  'type': 'room.snapshot',
  'revision': 1,
  'payload': <String, dynamic>{
    'roomId': 'room-1',
    'inviteCode': 'invite-1',
    'syncplayRoom': '1234567890',
    'ownerId': 'member-1',
    'selfId': 'member-1',
    'revision': 1,
    'serverTime': 1700000000000,
    'playback': <String, dynamic>{'position': 0, 'paused': true},
    'media': <String, dynamic>{
      'bgmSubjectId': 1,
      'episodeIndex': 0,
      'title': 'Show',
      'duration': 1440,
    },
    'members': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'member-1',
        'name': 'Tester',
        'protocol': 'anibaka',
        'verified': true,
        'controller': true,
        'ready': false,
      },
    ],
    'chat': null,
  },
};
