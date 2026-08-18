enum WatchPartyConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

class WatchPartyMedia {
  const WatchPartyMedia({
    required this.episodeIndex,
    required this.title,
    this.bgmSubjectId,
    this.episodeTitle = '',
    this.duration = 0,
  });

  factory WatchPartyMedia.fromJson(Map<String, dynamic> json) =>
      WatchPartyMedia(
        bgmSubjectId: (json['bgmSubjectId'] as num?)?.toInt(),
        episodeIndex: (json['episodeIndex'] as num?)?.toInt() ?? 0,
        title: json['title']?.toString() ?? '',
        episodeTitle: json['episodeTitle']?.toString() ?? '',
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
      );

  final int? bgmSubjectId;
  final int episodeIndex;
  final String title;
  final String episodeTitle;
  final double duration;

  Map<String, dynamic> toJson() => {
    if (bgmSubjectId != null) 'bgmSubjectId': bgmSubjectId,
    'episodeIndex': episodeIndex,
    'title': title,
    if (episodeTitle.isNotEmpty) 'episodeTitle': episodeTitle,
    'duration': duration,
  };
}

class WatchPartyPlayback {
  const WatchPartyPlayback({
    this.position = 0,
    this.paused = true,
    this.setBy = '',
    this.doSeek = false,
  });

  factory WatchPartyPlayback.fromJson(Map<String, dynamic> json) =>
      WatchPartyPlayback(
        position: (json['position'] as num?)?.toDouble() ?? 0,
        paused: json['paused'] as bool? ?? true,
        setBy: json['setBy']?.toString() ?? '',
        doSeek: json['doSeek'] as bool? ?? false,
      );

  final double position;
  final bool paused;
  final String setBy;
  final bool doSeek;
}

class WatchPartyMember {
  const WatchPartyMember({
    required this.id,
    required this.name,
    required this.protocol,
    required this.verified,
    required this.controller,
    required this.ready,
  });

  factory WatchPartyMember.fromJson(Map<String, dynamic> json) =>
      WatchPartyMember(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        protocol: json['protocol']?.toString() ?? 'anibaka',
        verified: json['verified'] as bool? ?? false,
        controller: json['controller'] as bool? ?? false,
        ready: json['ready'] as bool? ?? false,
      );

  final String id;
  final String name;
  final String protocol;
  final bool verified;
  final bool controller;
  final bool ready;
}

class WatchPartyChatMessage {
  const WatchPartyChatMessage({
    required this.id,
    required this.memberId,
    required this.username,
    required this.message,
    required this.createdAt,
  });

  factory WatchPartyChatMessage.fromJson(Map<String, dynamic> json) =>
      WatchPartyChatMessage(
        id: json['id']?.toString() ?? '',
        memberId: json['memberId']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        message: json['message']?.toString() ?? '',
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.now(),
      );

  final String id;
  final String memberId;
  final String username;
  final String message;
  final DateTime createdAt;
}

class WatchPartySnapshot {
  const WatchPartySnapshot({
    required this.roomId,
    required this.inviteCode,
    required this.syncplayRoom,
    required this.ownerId,
    required this.selfId,
    required this.revision,
    required this.serverTime,
    required this.playback,
    required this.media,
    required this.members,
    required this.chat,
  });

  factory WatchPartySnapshot.fromJson(Map<String, dynamic> json) {
    final rawPlayback = json['playback'];
    final rawMedia = json['media'];
    final rawMembers = json['members'] as List?;
    final rawChat = json['chat'] as List?;

    return WatchPartySnapshot(
      roomId: json['roomId']?.toString() ?? '',
      inviteCode: json['inviteCode']?.toString() ?? '',
      syncplayRoom: json['syncplayRoom']?.toString() ?? '',
      ownerId: json['ownerId']?.toString() ?? '',
      selfId: json['selfId']?.toString() ?? '',
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      serverTime: (json['serverTime'] as num?)?.toInt() ?? 0,
      playback: rawPlayback is Map<String, dynamic>
          ? WatchPartyPlayback.fromJson(rawPlayback)
          : (rawPlayback is Map
              ? WatchPartyPlayback.fromJson(rawPlayback.cast<String, dynamic>())
              : const WatchPartyPlayback()),
      media: rawMedia is Map<String, dynamic>
          ? WatchPartyMedia.fromJson(rawMedia)
          : (rawMedia is Map
              ? WatchPartyMedia.fromJson(rawMedia.cast<String, dynamic>())
              : const WatchPartyMedia(episodeIndex: 0, title: '')),
      members: rawMembers == null
          ? const []
          : [
              for (final item in rawMembers)
                if (item is Map)
                  WatchPartyMember.fromJson(
                    item is Map<String, dynamic>
                        ? item
                        : item.cast<String, dynamic>(),
                  ),
            ],
      chat: rawChat == null
          ? const []
          : [
              for (final item in rawChat)
                if (item is Map)
                  WatchPartyChatMessage.fromJson(
                    item is Map<String, dynamic>
                        ? item
                        : item.cast<String, dynamic>(),
                  ),
            ],
    );
  }

  final String roomId;
  final String inviteCode;
  final String syncplayRoom;
  final String ownerId;
  final String selfId;
  final int revision;
  final int serverTime;
  final WatchPartyPlayback playback;
  final WatchPartyMedia media;
  final List<WatchPartyMember> members;
  final List<WatchPartyChatMessage> chat;

  WatchPartyMember? get self {
    for (final member in members) {
      if (member.id == selfId) return member;
    }
    return null;
  }

  bool get canControl => self?.controller ?? false;
  bool get isOwner => selfId.isNotEmpty && selfId == ownerId;

  WatchPartySnapshot copyWith({
    int? revision,
    int? serverTime,
    List<WatchPartyChatMessage>? chat,
  }) => WatchPartySnapshot(
    roomId: roomId,
    inviteCode: inviteCode,
    syncplayRoom: syncplayRoom,
    ownerId: ownerId,
    selfId: selfId,
    revision: revision ?? this.revision,
    serverTime: serverTime ?? this.serverTime,
    playback: playback,
    media: media,
    members: members,
    chat: chat ?? this.chat,
  );
}

class WatchPartyInvite {
  const WatchPartyInvite({
    required this.roomId,
    required this.inviteCode,
    required this.inviteUrl,
    required this.syncplayHost,
    required this.syncplayPort,
    required this.syncplayRoom,
    required this.title,
    required this.episodeIndex,
    this.mediaSource = '',
    this.memberCount = 0,
    this.expiresAt,
    this.ticket = '',
    this.webSocketUrl = '',
    this.controllerPassword = '',
  });

  factory WatchPartyInvite.fromJson(Map<String, dynamic> json) =>
      WatchPartyInvite(
        roomId: json['roomId']?.toString() ?? '',
        inviteCode: json['inviteCode']?.toString() ?? '',
        inviteUrl: json['inviteUrl']?.toString() ?? '',
        syncplayHost: json['syncplayHost']?.toString() ?? '',
        syncplayPort: (json['syncplayPort'] as num?)?.toInt() ?? 8999,
        syncplayRoom: json['syncplayRoom']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        episodeIndex: (json['episodeIndex'] as num?)?.toInt() ?? 0,
        mediaSource: json['mediaSource']?.toString() ?? '',
        memberCount: (json['memberCount'] as num?)?.toInt() ?? 0,
        expiresAt: DateTime.tryParse(json['expiresAt']?.toString() ?? ''),
        ticket: json['ticket']?.toString() ?? '',
        webSocketUrl: json['websocketUrl']?.toString() ?? '',
        controllerPassword: json['controllerPassword']?.toString() ?? '',
      );

  final String roomId;
  final String inviteCode;
  final String inviteUrl;
  final String syncplayHost;
  final int syncplayPort;
  final String syncplayRoom;
  final String title;
  final int episodeIndex;
  final String mediaSource;
  final int memberCount;
  final DateTime? expiresAt;
  final String ticket;
  final String webSocketUrl;
  final String controllerPassword;
}

class WatchPartyConnectionInfo {
  const WatchPartyConnectionInfo({
    required this.roomId,
    required this.ticket,
    required this.webSocketUrl,
  });

  factory WatchPartyConnectionInfo.fromJson(Map<String, dynamic> json) =>
      WatchPartyConnectionInfo(
        roomId: json['roomId']?.toString() ?? '',
        ticket: json['ticket']?.toString() ?? '',
        webSocketUrl: json['websocketUrl']?.toString() ?? '',
      );

  final String roomId;
  final String ticket;
  final String webSocketUrl;
}
