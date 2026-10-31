import '../support/app_dependencies.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:baka/app/watch_party_links.dart';
import 'package:baka/core/account_session.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/services/collection/collection_repository.dart';
import 'package:baka/services/playback/history_repository.dart';
import 'package:baka/services/playback/playback_content.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/services/source/source_repository.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class Party extends WatchPartyService {
  Party(AccountSession session) : super(session: session);
  final joined = <String>[];
  final joining = Completer<void>();
  @override
  Future<void> joinInvite(String code, {String? nickname}) async {
    joined.add(code);
    joining.complete();
  }
}

Map<String, dynamic> _snapshot({
  int revision = 1,
  bool canControl = true,
  int position = 0,
}) => <String, dynamic>{
  'v': 1,
  'type': 'room.snapshot',
  'revision': revision,
  'payload': <String, dynamic>{
    'roomId': 'room-1',
    'inviteCode': 'invite-1',
    'syncplayRoom': '1234567890',
    'ownerId': 'member-1',
    'selfId': 'member-1',
    'revision': revision,
    'serverTime': 0,
    'playback': <String, dynamic>{'position': position, 'paused': true},
    'media': const <String, dynamic>{
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
        'controller': canControl,
        'ready': false,
      },
    ],
    'chat': null,
  },
};

class _Player extends PlaybackController {
  _Player() {
    timeline.value = timeline.value.copyWith(
      duration: const Duration(hours: 1),
    );
  }

  int seeks = 0;
  bool failSeek = false;
  Completer<void>? seekGate;
  final seeking = Completer<void>();
  final permissions = <bool>[];

  @override
  Future<void> configureWatchParty({
    required bool connected,
    required bool canControl,
  }) async {
    permissions.add(canControl);
    await super.configureWatchParty(
      connected: connected,
      canControl: canControl,
    );
  }

  @override
  Future<void> play({bool remote = false}) async {
    core.value = core.value.copyWith(playing: true);
  }

  @override
  Future<void> pause({bool remote = false}) async {
    core.value = core.value.copyWith(playing: false);
  }

  @override
  Future<void> seek(
    Duration target, {
    bool fromSlider = false,
    bool remote = false,
  }) async {
    seeks++;
    if (!seeking.isCompleted) seeking.complete();
    await seekGate?.future;
    if (failSeek) throw StateError('test seek failed');
    await super.seek(target, remote: remote);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('room lifecycle', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
    });

    test(
      'snapshot identifies self, owner, controller, and external members',
      () {
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
      },
    );

    test(
      'snapshot normalizes nullable server collections once at the boundary',
      () {
        final snapshot = WatchPartySnapshot.fromJson({
          'roomId': 'room-1',
          'inviteCode': 'invite-1',
          'syncplayRoom': '1234567890',
          'revision': 1,
          'serverTime': 1700000000000,
          'playback': {'position': 0, 'paused': true},
          'media': {'episodeIndex': 0, 'title': 'Show', 'duration': 1440},
          'members': null,
          'chat': null,
        });

        expect(snapshot.members, isEmpty);
        expect(snapshot.chat, isEmpty);
      },
    );

    test('watch party QR values accept links, app links, and invite codes', () {
      expect(
        WatchPartyLinks.inviteCodeFromValue(
          'https://www.anibaka.com/watch/Abc_123-xyz?from=qr',
        ),
        'Abc_123-xyz',
      );
      expect(
        WatchPartyLinks.inviteCodeFromValue('anibaka://watch/1234567890'),
        '1234567890',
      );
      expect(WatchPartyLinks.inviteCodeFromValue('1234567890'), '1234567890');
      expect(
        WatchPartyLinks.inviteCodeFromValue('https://example.com/watch/x'),
        isNull,
      );
    });

    test('failed join request leaves connecting state retryable', () async {
      var ticketRequested = false;
      final service = WatchPartyService(
        session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
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
          session: AccountSession(
            Instances.sp,
            refreshTokens: (_) async => null,
          ),
          getInviteRequest: (_) => inviteCompleter.future,
          joinRoomRequest: (_, _) async {
            ticketRequests++;
            return 'ws://unused';
          },
        );

        final joining = service.joinInvite('invite-1', nickname: 'Tester');
        expect(
          service.state.value.status,
          WatchPartyConnectionStatus.connecting,
        );

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

    test('disposing an old player cannot detach its replacement', () async {
      configurePlaybackServices();
      final service = WatchPartyService(
        session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
      );
      final oldController = PlaybackController();
      final newController = PlaybackController();
      final oldContent = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: PlaybackRequest.fromMap(const <String, Object>{
          'source': '_local',
          'localFilePath': 'old.mp4',
        }),
      );
      final newContent = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: PlaybackRequest.fromMap(const <String, Object>{
          'source': '_local',
          'localFilePath': 'new.mp4',
        }),
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
      expect(service.currentMedia, isNotNull);

      service.detachPlayer(newController);
      expect(service.currentMedia, isNull);
      oldContent.dispose();
      newContent.dispose();
      await oldController.dispose();
      await newController.dispose();
    });
  });

  group('invite links', () {
    late Party party;
    late WatchPartyLinks links;
    late StreamController<Uri> stream;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      party = Party(AccountSession(prefs, refreshTokens: (_) async => null));
      stream = StreamController<Uri>(sync: true);
      links = WatchPartyLinks(party, incoming: stream.stream)
        ..initializeLinks();
    });
    tearDown(() async {
      await links.close();
      await stream.close();
      await party.dispose();
    });
    test('a cold link waits for navigation readiness', () async {
      stream.add(Uri.parse('anibaka://watch/invite-1'));
      expect(party.joined, isEmpty);
      links.markReady();
      await party.joining.future;
      expect(party.joined, ['invite-1']);
    });
    test('closing cancels queued and future links', () async {
      stream.add(Uri.parse('anibaka://watch/invite-1'));
      await links.close();
      links.markReady();
      stream.add(Uri.parse('anibaka://watch/invite-2'));
      expect(party.joined, isEmpty);
    });
  });

  group('socket', () {
    final testHttpOverrides = HttpOverrides.current;

    setUpAll(() async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
    });
    tearDownAll(() => HttpOverrides.global = testHttpOverrides);

    test(
      'permissions update only on change and restore after reconnect',
      () async {
        configurePlaybackServices();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final ready = [Completer<void>(), Completer<void>()];
        final sockets = <WebSocket>[];
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          final index = sockets.length;
          sockets.add(socket);
          socket.listen((raw) {
            final message = jsonDecode(raw as String);
            if (message['type'] == 'ping') {
              socket.add(jsonEncode(_snapshot()));
            }
            if (message['type'] == 'ready.set') ready[index].complete();
          });
        });
        final service = WatchPartyService(
          session: AccountSession(
            Instances.sp,
            refreshTokens: (_) async => null,
          ),
          getInviteRequest: (_) async => _invite,
          joinRoomRequest: (_, _) async =>
              'ws://${server.address.address}:${server.port}/room',
        );
        final player = _Player();
        final content = PlaybackContent(
          sources: sourceRepository,
          collections: collections,
          history: historyRepository,
          request: PlaybackRequest.fromMap({
            'source': '_local',
            'localFilePath': 'test.mp4',
          }),
        );
        service.attachPlayer(player, content, onEpisodeRequested: (_) async {});
        addTearDown(() async {
          await service.dispose();
          await player.dispose();
          await content.dispose();
        });
        await service.joinInvite('invite-1');
        await ready[0].future.timeout(const Duration(seconds: 5));
        expect(player.permissions, [true]);
        for (final (revision, canControl) in [
          (2, true),
          (3, false),
          (4, true),
        ]) {
          final received = Completer<void>();
          void onState() {
            if (service.state.value.snapshot?.revision == revision &&
                !received.isCompleted) {
              received.complete();
            }
          }

          service.state.addListener(onState);
          sockets[0].add(
            jsonEncode(_snapshot(revision: revision, canControl: canControl)),
          );
          await received.future.timeout(const Duration(seconds: 5));
          service.state.removeListener(onState);
        }
        expect(player.permissions, [true, false, true]);
        await sockets[0].close();
        await ready[1].future.timeout(const Duration(seconds: 5));
        expect(service.state.value.connected, isTrue);
        expect(player.permissions, [true, false, true, false, true]);
      },
    );

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
          session: AccountSession(
            Instances.sp,
            refreshTokens: (_) async => null,
          ),
          getInviteRequest: (_) async => _invite,
          joinRoomRequest: (_, _) async =>
              'ws://${server.address.address}:${server.port}/room',
        );
        addTearDown(service.leave);

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

        expect(service.state.value.status, WatchPartyConnectionStatus.failed);
      },
    );
  });

  group('playback sync', () {
    late WatchPartyService service;
    late PlaybackContent content;
    late _Player player;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Instances.sp = await SharedPreferences.getInstance();
      configurePlaybackServices();
      service = WatchPartyService(
        session: AccountSession(Instances.sp, refreshTokens: (_) async => null),
      );
      content = PlaybackContent(
        sources: sourceRepository,
        collections: collections,
        history: historyRepository,
        request: PlaybackRequest.fromMap({
          'source': '_local',
          'localFilePath': 'test.mp4',
        }),
      );
      player = _Player();
      addTearDown(() async {
        await service.dispose();
        await player.dispose();
        await content.dispose();
      });
    });

    void attach({
      double position = 10,
      bool paused = true,
      bool doSeek = false,
    }) {
      service.state.value = WatchPartyViewState(
        status: WatchPartyConnectionStatus.connected,
        snapshot: WatchPartySnapshot.fromJson({
          'roomId': 'room',
          'inviteCode': 'code',
          'syncplayRoom': 'room',
          'revision': 1,
          'serverTime': 0,
          'playback': {
            'position': position,
            'paused': paused,
            'doSeek': doSeek,
          },
          'media': {'title': 'Show', 'episodeIndex': 0, 'duration': 3600},
        }),
      );
      service.attachPlayer(player, content, onEpisodeRequested: (_) async {});
    }

    for (final seconds in [0.25, 0.3, 10.0]) {
      testWidgets('paused drift $seconds seeks at most once', (tester) async {
        attach(position: seconds);
        await tester.pump();
        expect(player.seeks, seconds > 0.25 ? 1 : 0);
        expect(player.core.value.playing, isFalse);
      });
    }
    testWidgets('explicit seek applies even below the drift threshold', (
      tester,
    ) async {
      attach(position: 0.1, doSeek: true);
      await tester.pump();
      expect(player.seeks, 1);
      expect(player.timeline.value.position.inMilliseconds, 100);
    });
    testWidgets(
      'hard seek resumes at normal speed instead of correcting stale drift',
      (tester) async {
        attach(paused: false);
        await tester.pump();
        expect(player.seeks, 1);
        expect(player.core.value.playing, isTrue);
        expect(player.core.value.playbackRate, 1.0);
      },
    );
    for (final localPosition in [0, 4]) {
      testWidgets(
        'small playing drift from $localPosition adjusts rate without seeking',
        (tester) async {
          player.timeline.value = player.timeline.value.copyWith(
            position: Duration(seconds: localPosition),
          );
          attach(position: 2, paused: false);
          await tester.pump();
          expect(player.seeks, 0);
          expect(
            player.core.value.playbackRate,
            localPosition == 0 ? 1.05 : 0.95,
          );
        },
      );
    }
    for (final leave in [false, true]) {
      test(
        '${leave ? 'leave' : 'detach'} during seek cancels remaining playback changes',
        () async {
          player.seekGate = Completer<void>();
          attach(paused: false);
          await player.seeking.future;
          if (leave) {
            await service.leave();
          } else {
            service.detachPlayer(player);
          }
          player.seekGate!.complete();
          await Future<void>.delayed(Duration.zero);
          expect(player.core.value.playing, isFalse);
          expect(player.core.value.playbackRate, 1.0);
        },
      );
    }
    test(
      'failed seek does not discard a pending replacement player snapshot',
      () async {
        final oldPlayer = player;
        oldPlayer.seekGate = Completer<void>();
        oldPlayer.failSeek = true;
        attach(paused: false);
        await oldPlayer.seeking.future;
        player = _Player();
        attach(position: 20);
        oldPlayer.seekGate!.complete();
        await Future<void>.delayed(Duration.zero);
        expect(player.timeline.value.position.inSeconds, 20);
        expect(player.seeks, 1);
        expect(oldPlayer.core.value.playing, isFalse);
        await oldPlayer.dispose();
      },
    );
  });

  group('queued snapshots', () {
    test(
      'queued snapshots reach the latest position after a blocked seek',
      () async {
        final overrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = overrides);
        SharedPreferences.setMockInitialValues({});
        Instances.sp = await SharedPreferences.getInstance();
        configurePlaybackServices();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final connected = Completer<WebSocket>();
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          connected.complete(socket);
          socket.listen((raw) {
            if (jsonDecode(raw as String)['type'] == 'ping') {
              socket.add(jsonEncode(_snapshot(position: 10)));
            }
          });
        });
        final service = WatchPartyService(
          session: AccountSession(
            Instances.sp,
            refreshTokens: (_) async => null,
          ),
          getInviteRequest: (_) async => _invite,
          joinRoomRequest: (_, _) async =>
              'ws://${server.address.address}:${server.port}',
        );
        final player = _Player()..seekGate = Completer<void>();
        final finished = Completer<void>();
        player.timeline.addListener(() {
          if (player.timeline.value.position.inSeconds == 30) {
            finished.complete();
          }
        });
        player.timeline.value = player.timeline.value.copyWith(
          duration: const Duration(hours: 2),
        );
        final content = PlaybackContent(
          sources: sourceRepository,
          collections: collections,
          history: historyRepository,
          request: PlaybackRequest.fromMap({
            'source': '_local',
            'localFilePath': 'test.mp4',
          }),
        );
        service.attachPlayer(player, content, onEpisodeRequested: (_) async {});
        addTearDown(() async {
          await service.dispose();
          await player.dispose();
          await content.dispose();
        });
        await service.joinInvite('code');
        await player.seeking.future;
        final received = Completer<void>();
        service.state.addListener(() {
          if (service.state.value.snapshot?.revision == 3 &&
              !received.isCompleted) {
            received.complete();
          }
        });
        final socket = await connected.future;
        for (var i = 2; i <= 3; i++) {
          socket.add(jsonEncode(_snapshot(revision: i, position: i * 10)));
        }
        await received.future.timeout(const Duration(seconds: 10));
        player.seekGate!.complete();
        await finished.future.timeout(const Duration(seconds: 10));
        expect(player.timeline.value.position.inSeconds, 30);
      },
    );
  });
}
