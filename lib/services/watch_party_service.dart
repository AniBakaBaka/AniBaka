import 'dart:async';
import 'dart:convert';

import 'package:baka/api/anibaka_api.dart';
import 'package:baka/app_state.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/services/player_service.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:baka/widgets/baka_player/controller.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

class WatchPartyViewState {
  const WatchPartyViewState({
    this.status = WatchPartyConnectionStatus.disconnected,
    this.invite,
    this.snapshot,
    this.error = '',
    this.latencyMs,
  });

  final WatchPartyConnectionStatus status;
  final WatchPartyInvite? invite;
  final WatchPartySnapshot? snapshot;
  final String error;
  final int? latencyMs;

  bool get connected => status == WatchPartyConnectionStatus.connected;

  WatchPartyViewState copyWith({
    WatchPartyConnectionStatus? status,
    WatchPartyInvite? invite,
    WatchPartySnapshot? snapshot,
    String? error,
    int? latencyMs,
    bool clearInvite = false,
    bool clearSnapshot = false,
  }) => WatchPartyViewState(
    status: status ?? this.status,
    invite: clearInvite ? null : (invite ?? this.invite),
    snapshot: clearSnapshot ? null : (snapshot ?? this.snapshot),
    error: error ?? this.error,
    latencyMs: latencyMs ?? this.latencyMs,
  );
}

class WatchPartyService extends GetxService {
  WatchPartyService({
    Future<WatchPartyInvite> Function(WatchPartyMedia media)? createRoomRequest,
    Future<WatchPartyInvite> Function(String code)? getInviteRequest,
    Future<String> Function(String code, String nickname)? joinRoomRequest,
  }) : _createRoomRequest = createRoomRequest ?? AniBakaApi.createWatchRoom,
       _getInviteRequest = getInviteRequest ?? AniBakaApi.getWatchInvite,
       _joinRoomRequest = joinRoomRequest ?? AniBakaApi.joinWatchRoom;

  static WatchPartyService get instance => Get.find<WatchPartyService>();

  final state = ValueNotifier<WatchPartyViewState>(const WatchPartyViewState());
  final Future<WatchPartyInvite> Function(WatchPartyMedia media)
  _createRoomRequest;
  final Future<WatchPartyInvite> Function(String code) _getInviteRequest;
  final Future<String> Function(String code, String nickname) _joinRoomRequest;

  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  StreamSubscription<Duration>? _seekSubscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  PlaybackController? _controller;
  PlayerService? _content;
  Future<void> Function(int episodeIndex)? _onEpisodeRequested;
  Future<void> _remoteApplyChain = Future<void>.value();
  String _inviteCode = '';
  String _nickname = '';
  bool _intentionalDisconnect = false;
  bool _applyingRemote = false;
  bool? _lastPlaying;
  int _reconnectAttempt = 0;
  int _requestSerial = 0;
  int _connectionGeneration = 0;
  Completer<void>? _initialSnapshot;
  String? _pendingPingId;
  final Stopwatch _pingClock = Stopwatch();

  @visibleForTesting
  bool get hasAttachedPlayer => _controller != null && _content != null;

  bool matchesAttachedMedia(WatchPartyMedia media) {
    final content = _content;
    return content != null &&
        media.bgmSubjectId != null &&
        content.bgmInfo.subjectId == media.bgmSubjectId;
  }

  Future<void> createRoom() async {
    final content = _content;
    if (content == null) throw StateError('请先打开要观看的视频');
    if (Instances.userToken.isEmpty) throw StateError('创建房间需要先登录 AniBaka');
    final generation = _beginConnection();
    try {
      final invite = await _createRoomRequest(_currentMedia(content));
      if (!_isCurrentConnection(generation)) return;
      _inviteCode = invite.inviteCode;
      _nickname = _currentNickname();
      state.value = state.value.copyWith(invite: invite);
      await _connect(invite.webSocketUrl, generation);
    } catch (error) {
      if (!_isCurrentConnection(generation)) return;
      if (state.value.status != WatchPartyConnectionStatus.failed) {
        _setFailure(_connectionError(error, '创建一起看房间失败'));
      }
      rethrow;
    }
  }

  Future<void> joinInvite(String code, {String? nickname}) async {
    final normalized = code.trim();
    if (normalized.isEmpty) throw StateError('请输入邀请码');
    final generation = _beginConnection();
    _inviteCode = normalized;
    _nickname = (nickname ?? _currentNickname()).trim();
    if (_nickname.isEmpty) _nickname = 'AniBaka';
    try {
      // Fetch public room metadata before issuing the one-time join ticket. A
      // failed metadata request must not leave an unused ticket behind.
      final invite = await _getInviteRequest(normalized);
      if (!_isCurrentConnection(generation)) return;
      final webSocketUrl = await _joinRoomRequest(normalized, _nickname);
      if (!_isCurrentConnection(generation)) return;
      state.value = state.value.copyWith(invite: invite);
      await _connect(webSocketUrl, generation);
    } catch (error) {
      if (!_isCurrentConnection(generation)) return;
      if (state.value.status != WatchPartyConnectionStatus.failed) {
        _setFailure(_connectionError(error, '加入一起看房间失败'));
      }
      rethrow;
    }
  }

  int _beginConnection() {
    final generation = ++_connectionGeneration;
    _intentionalDisconnect = false;
    _reconnectTimer?.cancel();
    _heartbeat?.cancel();
    final previousSubscription = _channelSubscription;
    final previousChannel = _channel;
    _channelSubscription = null;
    _channel = null;
    _pendingPingId = null;
    _pingClock.stop();
    unawaited(previousSubscription?.cancel());
    unawaited(previousChannel?.sink.close(ws_status.goingAway));
    state.value = state.value.copyWith(
      status: WatchPartyConnectionStatus.connecting,
      error: '',
      clearInvite: true,
      clearSnapshot: true,
    );
    return generation;
  }

  bool _isCurrentConnection(int generation, [IOWebSocketChannel? channel]) =>
      generation == _connectionGeneration &&
      (channel == null || identical(channel, _channel));

  Future<void> _connect(String webSocketUrl, int generation) async {
    if (!_isCurrentConnection(generation)) return;
    _intentionalDisconnect = false;
    final previousSubscription = _channelSubscription;
    final previousChannel = _channel;
    _channelSubscription = null;
    _channel = null;
    await previousSubscription?.cancel();
    await previousChannel?.sink.close();
    if (!_isCurrentConnection(generation)) return;
    final channel = IOWebSocketChannel.connect(
      Uri.parse(webSocketUrl),
      connectTimeout: const Duration(seconds: 10),
      pingInterval: const Duration(seconds: 20),
    );
    _channel = channel;
    final initialSnapshot = Completer<void>();
    _initialSnapshot = initialSnapshot;
    try {
      await channel.ready;
    } catch (error) {
      if (_isCurrentConnection(generation, channel)) {
        _channel = null;
        _setFailure('无法连接一起看房间');
      }
      await channel.sink.close(ws_status.goingAway);
      rethrow;
    }
    if (!_isCurrentConnection(generation, channel)) {
      await channel.sink.close(ws_status.goingAway);
      return;
    }
    _channelSubscription = channel.stream.listen(
      (raw) => _onMessage(generation, channel, raw),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.instance.warning(
          'Watch-party socket error',
          tag: 'WatchParty',
          error: error,
          stackTrace: stackTrace,
        );
        _onDisconnected(generation, channel);
      },
      onDone: () => _onDisconnected(generation, channel),
      cancelOnError: true,
    );
    state.value = state.value.copyWith(
      status: WatchPartyConnectionStatus.connected,
      error: '',
    );
    _reconnectAttempt = 0;
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_pendingPingId != null && _pingClock.elapsed.inSeconds < 45) return;
      final requestId = _send('ping', const <String, Object>{});
      if (requestId.isNotEmpty) {
        _pendingPingId = requestId;
        _pingClock
          ..reset()
          ..start();
      }
    });
    try {
      await initialSnapshot.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (_isCurrentConnection(generation, channel)) {
        _setFailure('连接成功，但未收到房间状态');
        _heartbeat?.cancel();
        await _channelSubscription?.cancel();
        _channelSubscription = null;
        await channel.sink.close(ws_status.goingAway);
        if (identical(_channel, channel)) _channel = null;
      }
      rethrow;
    }
    if (!_isCurrentConnection(generation, channel)) return;
    await _controller?.configureWatchParty(
      connected: true,
      canControl: state.value.snapshot?.canControl ?? false,
    );
    _send('ready.set', const {'ready': true});
  }

  void attachPlayer(
    PlaybackController controller,
    PlayerService content, {
    required Future<void> Function(int episodeIndex) onEpisodeRequested,
  }) {
    detachPlayer();
    _controller = controller;
    _content = content;
    _onEpisodeRequested = onEpisodeRequested;
    _lastPlaying = controller.core.value.playing;
    controller.core.addListener(_onCoreChanged);
    _seekSubscription = controller.seekEvents.listen(_onLocalSeek);
    if (state.value.connected) {
      unawaited(
        controller.configureWatchParty(
          connected: true,
          canControl: state.value.snapshot?.canControl ?? false,
        ),
      );
      final snapshot = state.value.snapshot;
      if (snapshot != null) {
        _queueRemoteApply(_connectionGeneration, snapshot, null);
      }
    }
  }

  void detachPlayer([PlaybackController? owner]) {
    if (owner != null && !identical(_controller, owner)) return;
    final controller = _controller;
    if (controller != null) {
      controller.core.removeListener(_onCoreChanged);
      unawaited(
        controller.configureWatchParty(connected: false, canControl: true),
      );
    }
    unawaited(_seekSubscription?.cancel());
    _seekSubscription = null;
    _controller = null;
    _content = null;
    _onEpisodeRequested = null;
    _lastPlaying = null;
  }

  void publishCurrentMedia() {
    final content = _content;
    if (!state.value.connected ||
        _applyingRemote ||
        content == null ||
        !(state.value.snapshot?.canControl ?? false)) {
      return;
    }
    _send('media.update', _currentMedia(content).toJson());
  }

  void sendChat(String message) {
    final text = message.trim();
    if (!state.value.connected || text.isEmpty) return;
    _send('chat.send', {'message': text});
  }

  void setController(String memberId, bool controller) {
    if (!(state.value.snapshot?.isOwner ?? false)) return;
    _send('controller.set', {'memberId': memberId, 'controller': controller});
  }

  Future<void> leave() async {
    final generation = ++_connectionGeneration;
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _heartbeat?.cancel();
    final subscription = _channelSubscription;
    final channel = _channel;
    _channelSubscription = null;
    _channel = null;
    _pendingPingId = null;
    _pingClock.stop();
    state.value = const WatchPartyViewState();
    await subscription?.cancel();
    await channel?.sink.close(ws_status.normalClosure);
    if (!_isCurrentConnection(generation)) return;
    await _controller?.configureWatchParty(connected: false, canControl: true);
  }

  Future<void> closeRoom() async {
    final generation = _connectionGeneration;
    final roomId = state.value.snapshot?.roomId ?? state.value.invite?.roomId;
    if (roomId == null || roomId.isEmpty) return;
    await AniBakaApi.closeWatchRoom(roomId);
    if (!_isCurrentConnection(generation)) return;
    await leave();
  }

  void _onMessage(int generation, IOWebSocketChannel channel, dynamic raw) {
    if (!_isCurrentConnection(generation, channel)) return;
    if (raw is! String) return;
    try {
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final type = envelope['type']?.toString() ?? '';
      if (type == 'error') {
        final payload = envelope['payload'];
        final message = payload is Map ? payload['message']?.toString() : null;
        if (message != null && message.isNotEmpty) {
          state.value = state.value.copyWith(error: message);
        }
        return;
      }
      if (type == 'room.closed') {
        _setFailure('房间已结束');
        unawaited(leave());
        return;
      }
      if (type == 'chat.message') {
        final current = state.value.snapshot;
        final payload = envelope['payload'];
        if (current != null && payload is Map) {
          final message = WatchPartyChatMessage.fromJson(
            payload as Map<String, dynamic>,
          );
          final history = current.chat.length < 100
              ? [...current.chat, message]
              : <WatchPartyChatMessage>[
                  for (var index = 1; index < current.chat.length; index++)
                    current.chat[index],
                  message,
                ];
          state.value = state.value.copyWith(
            snapshot: current.copyWith(
              revision: (envelope['revision'] as num?)?.toInt(),
              chat: history,
            ),
            error: '',
          );
        }
        return;
      }
      if (type == 'pong') {
        final requestId = envelope['requestId']?.toString() ?? '';
        if (requestId == _pendingPingId) {
          _pendingPingId = null;
          _pingClock.stop();
          state.value = state.value.copyWith(
            latencyMs: _pingClock.elapsedMilliseconds,
          );
        }
        return;
      }
      if (envelope['payload'] is! Map) return;
      final snapshot = WatchPartySnapshot.fromJson(
        envelope['payload'] as Map<String, dynamic>,
      );
      final previous = state.value.snapshot;
      state.value = state.value.copyWith(snapshot: snapshot, error: '');
      final initialSnapshot = _initialSnapshot;
      if (initialSnapshot != null && !initialSnapshot.isCompleted) {
        initialSnapshot.complete();
      }
      unawaited(
        _controller?.configureWatchParty(
          connected: true,
          canControl: snapshot.canControl,
        ),
      );
      _queueRemoteApply(generation, snapshot, previous);
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'Invalid watch-party message',
        tag: 'WatchParty',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _queueRemoteApply(
    int generation,
    WatchPartySnapshot snapshot,
    WatchPartySnapshot? previous,
  ) {
    _remoteApplyChain = _remoteApplyChain
        .then((_) async {
          if (!_isCurrentConnection(generation) || !state.value.connected) {
            return;
          }
          await _applySnapshot(generation, snapshot, previous);
        })
        .catchError((Object error, StackTrace stackTrace) {
          // A transient seek/episode-switch failure must not poison every
          // later room update in the serialized apply chain.
          AppLogger.instance.warning(
            'Unable to apply watch-party snapshot',
            tag: 'WatchParty',
            error: error,
            stackTrace: stackTrace,
          );
        });
  }

  Future<void> _applySnapshot(
    int generation,
    WatchPartySnapshot snapshot,
    WatchPartySnapshot? previous,
  ) async {
    if (!_isCurrentConnection(generation) || !state.value.connected) return;
    final controller = _controller;
    final content = _content;
    if (controller == null || content == null) return;
    final remoteMedia = snapshot.media;
    final localSubject = content.bgmInfo.subjectId;
    if (remoteMedia.bgmSubjectId != null &&
        remoteMedia.bgmSubjectId == localSubject &&
        remoteMedia.episodeIndex != content.currPlayIndex &&
        remoteMedia.episodeIndex >= 0 &&
        remoteMedia.episodeIndex < content.videoList.length) {
      await _onEpisodeRequested?.call(remoteMedia.episodeIndex);
      if (!_isCurrentConnection(generation) || !state.value.connected) return;
    }
    final selfName = snapshot.self?.name;
    if (selfName != null &&
        snapshot.playback.setBy == selfName &&
        previous != null) {
      return;
    }
    final playback = snapshot.playback;
    var targetSeconds = playback.position;
    if (!playback.paused && snapshot.serverTime > 0) {
      targetSeconds +=
          (DateTime.now().millisecondsSinceEpoch - snapshot.serverTime).clamp(
            0,
            5000,
          ) /
          1000;
    }
    final currentSeconds =
        controller.timeline.value.position.inMilliseconds / 1000;
    final delta = targetSeconds - currentSeconds;
    _applyingRemote = true;
    try {
      if (playback.doSeek || delta.abs() >= 4) {
        await controller.seek(
          Duration(milliseconds: (targetSeconds * 1000).round()),
          remote: true,
        );
      }
      if (playback.paused) {
        if (delta.abs() > 0.25 && !playback.doSeek) {
          await controller.seek(
            Duration(milliseconds: (targetSeconds * 1000).round()),
            remote: true,
          );
        }
        if (controller.core.value.playing) await controller.pause(remote: true);
        await controller.setRate(1.0, roomCorrection: true);
      } else {
        if (!controller.core.value.playing) await controller.play(remote: true);
        if (delta < -1.5) {
          await controller.setRate(0.95, roomCorrection: true);
        } else if (delta > 1.5) {
          await controller.setRate(1.05, roomCorrection: true);
        } else if (delta.abs() < 0.1 ||
            controller.core.value.playbackRate != 1.0) {
          await controller.setRate(1.0, roomCorrection: true);
        }
      }
    } finally {
      _applyingRemote = false;
      _lastPlaying = controller.core.value.playing;
    }
  }

  void _onCoreChanged() {
    final controller = _controller;
    if (controller == null ||
        _applyingRemote ||
        !state.value.connected ||
        !(state.value.snapshot?.canControl ?? false)) {
      return;
    }
    final playing = controller.core.value.playing;
    if (_lastPlaying == playing) return;
    _lastPlaying = playing;
    _sendPlayback(doSeek: false);
  }

  void _onLocalSeek(Duration _) {
    if (_applyingRemote || !(state.value.snapshot?.canControl ?? false)) return;
    _sendPlayback(doSeek: true);
  }

  void _sendPlayback({required bool doSeek}) {
    final controller = _controller;
    if (controller == null || !state.value.connected) return;
    _send('playback.update', {
      'position': controller.timeline.value.position.inMilliseconds / 1000,
      'paused': !controller.core.value.playing,
      'doSeek': doSeek,
    });
  }

  String _send(String type, Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null || !state.value.connected) return '';
    final requestId = (++_requestSerial).toString();
    channel.sink.add(
      jsonEncode({
        'v': 1,
        'type': type,
        'requestId': requestId,
        'payload': payload,
      }),
    );
    return requestId;
  }

  void _onDisconnected(int generation, IOWebSocketChannel channel) {
    if (!_isCurrentConnection(generation, channel)) return;
    _channel = null;
    _channelSubscription = null;
    _scheduleReconnect(generation);
  }

  void _scheduleReconnect(int generation) {
    _heartbeat?.cancel();
    if (!_isCurrentConnection(generation) ||
        _intentionalDisconnect ||
        _inviteCode.isEmpty) {
      return;
    }
    state.value = state.value.copyWith(
      status: WatchPartyConnectionStatus.reconnecting,
      error: '连接已断开，正在重连',
    );
    unawaited(
      _controller?.configureWatchParty(connected: true, canControl: false),
    );
    _reconnectTimer?.cancel();
    final delaySeconds = 1 << _reconnectAttempt.clamp(0, 5);
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      try {
        final webSocketUrl = await _joinRoomRequest(_inviteCode, _nickname);
        if (!_isCurrentConnection(generation)) return;
        await _connect(webSocketUrl, generation);
      } catch (error, stackTrace) {
        if (!_isCurrentConnection(generation)) return;
        AppLogger.instance.warning(
          'Unable to reconnect watch party',
          tag: 'WatchParty',
          error: error,
          stackTrace: stackTrace,
        );
        _scheduleReconnect(generation);
      }
    });
  }

  void _setFailure(String message) {
    state.value = state.value.copyWith(
      status: WatchPartyConnectionStatus.failed,
      error: message,
    );
  }

  String _connectionError(Object error, String fallback) {
    final message = error.toString().replaceFirst('Bad state: ', '').trim();
    return message.isEmpty ? fallback : message;
  }

  WatchPartyMedia _currentMedia(PlayerService content) => WatchPartyMedia(
    bgmSubjectId: content.bgmInfo.subjectId,
    episodeIndex: content.currPlayIndex,
    title: content.title,
    episodeTitle: content.currentEpisodeTitle,
    duration: (_controller?.timeline.value.duration.inMilliseconds ?? 0) / 1000,
  );

  static String currentNickname() {
    final user = Get.find<AppState>().user.value;
    return user.isLoggedIn && user.name.isNotEmpty ? user.name : 'AniBaka';
  }

  String _currentNickname() => currentNickname();

  @override
  void onClose() {
    unawaited(leave());
    detachPlayer();
    state.dispose();
    super.onClose();
  }
}
