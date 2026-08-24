import 'dart:async';

import 'package:baka/instance.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/services/watch_party_link_service.dart';
import 'package:baka/services/watch_party_service.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_playback_backend.dart';

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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Instances.sp = await SharedPreferences.getInstance();
  });

  test('snapshot identifies self, owner, controller, and external members', () {
    final snapshot = WatchPartySnapshot.fromJson({
      'roomId': 'room-1',
      'inviteCode': 'invite-1',
      'syncplayRoom': '+AniBaka-room:ABCDEF123456',
      'ownerId': 'owner',
      'selfId': 'owner',
      'revision': 8,
      'serverTime': 1700000000000,
      'playback': {'position': 42.5, 'paused': false, 'setBy': 'Owner'},
      'media': {
        'bgmSubjectId': 123,
        'episodeIndex': 2,
        'title': 'Show',
        'duration': 1440,
      },
      'members': [
        {
          'id': 'owner',
          'name': 'Owner',
          'protocol': 'anibaka',
          'verified': true,
          'controller': true,
          'ready': true,
        },
        {
          'id': 'external',
          'name': 'mpv-user',
          'protocol': 'syncplay',
          'verified': false,
          'controller': false,
          'ready': false,
        },
      ],
      'chat': const [],
    });

    expect(snapshot.isOwner, isTrue);
    expect(snapshot.canControl, isTrue);
    expect(snapshot.media.bgmSubjectId, 123);
    expect(snapshot.members.last.protocol, 'syncplay');
    expect(snapshot.members.last.verified, isFalse);
  });

  test('invite parses active room list metadata', () {
    final invite = WatchPartyInvite.fromJson({
      'roomId': 'room-1',
      'inviteCode': 'invite-1',
      'inviteUrl': 'https://www.anibaka.com/watch/invite-1',
      'syncplayHost': 'sync.anibaka.com',
      'syncplayPort': 8999,
      'syncplayRoom': '1234567890',
      'title': 'Show',
      'episodeIndex': 2,
      'memberCount': 4,
    });

    expect(invite.memberCount, 4);
    expect(invite.syncplayRoom, '1234567890');
  });

  test('watch party QR values accept links, app links, and invite codes', () {
    expect(
      WatchPartyLinkService.inviteCodeFromValue(
        'https://www.anibaka.com/watch/Abc_123-xyz?from=qr',
      ),
      'Abc_123-xyz',
    );
    expect(
      WatchPartyLinkService.inviteCodeFromValue('anibaka://watch/1234567890'),
      '1234567890',
    );
    expect(
      WatchPartyLinkService.inviteCodeFromValue('1234567890'),
      '1234567890',
    );
    expect(
      WatchPartyLinkService.inviteCodeFromValue('https://example.com/watch/x'),
      isNull,
    );
  });

  test('failed join request leaves connecting state retryable', () async {
    var ticketRequested = false;
    final service = WatchPartyService(
      getInviteRequest: (_) async => throw StateError('房间不存在'),
      joinRoomRequest: (_, _) async {
        ticketRequested = true;
        return 'ws://unused';
      },
    );

    await expectLater(
      service.joinInvite('missing-room', nickname: 'Tester'),
      throwsA(isA<StateError>()),
    );

    expect(service.state.value.status, WatchPartyConnectionStatus.failed);
    expect(service.state.value.error, '房间不存在');
    expect(ticketRequested, isFalse);
    await service.leave();
  });

  test(
    'leaving invalidates an in-flight join before it requests a ticket',
    () async {
      final inviteCompleter = Completer<WatchPartyInvite>();
      var ticketRequests = 0;
      final service = WatchPartyService(
        getInviteRequest: (_) => inviteCompleter.future,
        joinRoomRequest: (_, _) async {
          ticketRequests++;
          return 'ws://unused';
        },
      );

      final joining = service.joinInvite('invite-1', nickname: 'Tester');
      await Future<void>.delayed(Duration.zero);
      expect(service.state.value.status, WatchPartyConnectionStatus.connecting);

      await service.leave();
      inviteCompleter.complete(_invite);
      await joining;

      expect(ticketRequests, 0);
      expect(
        service.state.value.status,
        WatchPartyConnectionStatus.disconnected,
      );
    },
  );

  test(
    'viewer controls are blocked while remote room updates still apply',
    () async {
      final backend = FakePlaybackBackend();
      final controller = PlaybackController(backend: backend);
      await controller.open('https://example.test/video.mp4');
      backend.emitDuration(const Duration(minutes: 10));
      await controller.configureWatchParty(connected: true, canControl: false);

      await controller.play();
      await controller.pause();
      await controller.seek(const Duration(seconds: 50));
      await controller.setRate(2);
      expect(backend.playCount, 0);
      expect(backend.pauseCount, 0);
      expect(backend.lastSeek, isNull);
      expect(backend.lastRate, isNot(2));

      await controller.play(remote: true);
      await controller.pause(remote: true);
      await controller.seek(const Duration(seconds: 50), remote: true);
      await controller.setRate(0.95, roomCorrection: true);
      expect(backend.playCount, 1);
      expect(backend.pauseCount, 1);
      expect(backend.lastSeek, const Duration(seconds: 50));
      expect(backend.lastRate, 0.95);

      await controller.dispose();
    },
  );

  test('disposing an old player cannot detach its replacement', () async {
    final service = WatchPartyService();
    final oldController = PlaybackController(backend: FakePlaybackBackend());
    final newController = PlaybackController(backend: FakePlaybackBackend());
    final oldContent = PlayerService(
      data: const <String, Object>{
        'source': '_local',
        'localFilePath': 'old.mp4',
      },
    );
    final newContent = PlayerService(
      data: const <String, Object>{
        'source': '_local',
        'localFilePath': 'new.mp4',
      },
    );

    service.attachPlayer(
      oldController,
      oldContent,
      onEpisodeRequested: (_) async {},
    );
    service.attachPlayer(
      newController,
      newContent,
      onEpisodeRequested: (_) async {},
    );

    service.detachPlayer(oldController);
    expect(service.hasAttachedPlayer, isTrue);

    service.detachPlayer(newController);
    expect(service.hasAttachedPlayer, isFalse);
    oldContent.dispose();
    newContent.dispose();
    await oldController.dispose();
    await newController.dispose();
  });
}
