import 'dart:async';
import 'dart:convert';

import 'package:baka/api/watch_party_api.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/watch_party.dart';
import 'package:baka/services/network_service.dart';
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
    bool clearSnapshot = false,
  }) => WatchPartyViewState(
    status: status ?? this.status,
    invite: invite ?? this.invite,
    snapshot: clearSnapshot ? null : (snapshot ?? this.snapshot),
    error: error ?? this.error,
    latencyMs: latencyMs ?? this.latencyMs,
  );
}

class WatchPartyService extends GetxService {
  static WatchPartyService get instance => Get.find<WatchPartyService>();

  final state = ValueNotifier<WatchPartyViewState>(const WatchPartyViewState());

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
  Completer<void>? _initialSnapshot;
  final Map<String, DateTime> _pendingPings = {};

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
    state.value = state.value.copyWith(
      status: WatchPartyConnectionStatus.connecting,
      error: '',
    );
    final invite = await WatchPartyApi.createRoom(_currentMedia(content));
    _inviteCode = invite.inviteCode;
    _nickname = _currentNickname();
    state.value = state.value.copyWith(invite: invite);
    await _connect(
      WatchPartyConnectionInfo(
        roomId: invite.roomId,
        ticket: invite.ticket,
        webSocketUrl: invite.webSocketUrl,
      ),
    );
  }

  Future<void> joinInvite(String code, {String? nickname}) async {
    final normalized = code.trim();
    if (normalized.isEmpty) throw StateError('请输入邀请码');
    _inviteCode = normalized;
    _nickname = (nickname ?? _currentNickname()).trim();
    if (_nickname.isEmpty) _nickname = 'AniBaka';
    state.value = state.value.copyWith(
      status: WatchPartyConnectionStatus.connecting,
      error: '',
    );
    final results = await Future.wait<Object>([
      WatchPartyApi.getInvite(normalized),
      WatchPartyApi.joinRoom(normalized, _nickname),
    ]);
    state.value = state.value.copyWith(invite: results[0] as WatchPartyInvite);
    await _connect(results[1] as WatchPartyConnectionInfo);
  }

  Future<void> _connect(WatchPartyConnectionInfo info) async {
    _intentionalDisconnect = false;
    await _channelSubscription?.cancel();
    await _channel?.sink.close();
    final channel = IOWebSocketChannel.connect(
      Uri.parse(info.webSocketUrl),
      connectTimeout: const Duration(seconds: 10),
      pingInterval: const Duration(seconds: 20),
    );
    _channel = channel;
    _initialSnapshot = Completer<void>();
    try {
      await channel.ready;
    } catch (error) {
      _setFailure('无法连接一起看房间');
      rethrow;
    }
    state.value = state.value.copyWith(
      status: WatchPartyConnectionStatus.connected,
      error: '',
    );
    _reconnectAttempt = 0;
    _channelSubscription = channel.stream.listen(
      _onMessage,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.instance.warning(
          'Watch-party socket error',
          tag: 'WatchParty',
          error: error,
          stackTrace: stackTrace,
        );
        _onDisconnected();
      },
      onDone: _onDisconnected,
      cancelOnError: true,
    );
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      final requestId = _send('ping', const <String, Object>{});
      if (requestId.isNotEmpty) {
        _pendingPings[requestId] = DateTime.now();
      }
    });
    await _initialSnapshot!.future.timeout(const Duration(seconds: 5));
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
        _remoteApplyChain = _remoteApplyChain.then(
          (_) => _applySnapshot(snapshot, null),
        );
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
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _heartbeat?.cancel();
    await _channelSubscription?.cancel();
    await _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
    _pendingPings.clear();
    state.value = const WatchPartyViewState();
    await _controller?.configureWatchParty(connected: false, canControl: true);
  }

  Future<void> closeRoom() async {
    final roomId = state.value.snapshot?.roomId ?? state.value.invite?.roomId;
    if (roomId == null || roomId.isEmpty) return;
    await WatchPartyApi.closeRoom(roomId);
    await leave();
  }

  void _onMessage(dynamic raw) {
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
            Map<String, dynamic>.from(payload),
          );
          final history = [...current.chat, message];
          state.value = state.value.copyWith(
            snapshot: current.copyWith(
              revision: (envelope['revision'] as num?)?.toInt(),
              chat: history.length > 100
                  ? history.sublist(history.length - 100)
                  : history,
            ),
            error: '',
          );
        }
        return;
      }
      if (type == 'pong') {
        final requestId = envelope['requestId']?.toString() ?? '';
        final sentAt = _pendingPings.remove(requestId);
        if (sentAt != null) {
          state.value = state.value.copyWith(
            latencyMs: DateTime.now().difference(sentAt).inMilliseconds,
          );
        }
        return;
      }
      if (envelope['payload'] is! Map) return;
      final snapshot = WatchPartySnapshot.fromJson(
        Map<String, dynamic>.from(envelope['payload'] as Map),
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
      _remoteApplyChain = _remoteApplyChain.then(
        (_) => _applySnapshot(snapshot, previous),
      );
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'Invalid watch-party message',
        tag: 'WatchParty',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _applySnapshot(
    WatchPartySnapshot snapshot,
    WatchPartySnapshot? previous,
  ) async {
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
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
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

  void _onDisconnected() {
    _heartbeat?.cancel();
    if (_intentionalDisconnect || _inviteCode.isEmpty) return;
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
        final connection = await WatchPartyApi.joinRoom(_inviteCode, _nickname);
        await _connect(connection);
      } catch (_) {
        _onDisconnected();
      }
    });
  }

  void _setFailure(String message) {
    state.value = state.value.copyWith(
      status: WatchPartyConnectionStatus.failed,
      error: message,
    );
  }

  WatchPartyMedia _currentMedia(PlayerService content) => WatchPartyMedia(
    bgmSubjectId: content.bgmInfo.subjectId,
    episodeIndex: content.currPlayIndex,
    title: content.title,
    episodeTitle: content.currentEpisodeTitle,
    duration: (_controller?.timeline.value.duration.inMilliseconds ?? 0) / 1000,
  );

  static String currentNickname() {
    final name = getUserInfo()['name']?.toString();
    return (name != null && name.isNotEmpty) ? name : 'AniBaka';
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
