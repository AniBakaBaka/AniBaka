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
        episodeIndex: (json['episodeIndex'] as num).toInt(),
        title: json['title'] as String,
        episodeTitle: json['episodeTitle'] as String? ?? '',
        duration: (json['duration'] as num).toDouble(),
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
        position: (json['position'] as num).toDouble(),
        paused: json['paused'] as bool,
        setBy: json['setBy'] as String? ?? '',
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
        id: json['id'] as String,
        name: json['name'] as String,
        protocol: json['protocol'] as String,
        verified: json['verified'] as bool,
        controller: json['controller'] as bool,
        ready: json['ready'] as bool,
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
  });

  factory WatchPartyChatMessage.fromJson(Map<String, dynamic> json) =>
      WatchPartyChatMessage(
        id: json['id'] as String,
        memberId: json['memberId'] as String,
        username: json['username'] as String,
        message: json['message'] as String,
      );

  final String id;
  final String memberId;
  final String username;
  final String message;
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
    // Go encodes a nil slice as null. Normalize that wire representation at
    // the API boundary so the rest of the app owns one typed empty list.
    final rawMembers = json['members'] as List<dynamic>? ?? const <dynamic>[];
    final rawChat = json['chat'] as List<dynamic>? ?? const <dynamic>[];

    return WatchPartySnapshot(
      roomId: json['roomId'] as String,
      inviteCode: json['inviteCode'] as String,
      syncplayRoom: json['syncplayRoom'] as String,
      ownerId: json['ownerId'] as String? ?? '',
      selfId: json['selfId'] as String? ?? '',
      revision: (json['revision'] as num).toInt(),
      serverTime: (json['serverTime'] as num).toInt(),
      playback: WatchPartyPlayback.fromJson(
        json['playback'] as Map<String, dynamic>,
      ),
      media: WatchPartyMedia.fromJson(json['media'] as Map<String, dynamic>),
      members: List<WatchPartyMember>.generate(
        rawMembers.length,
        (index) => WatchPartyMember.fromJson(
          rawMembers[index] as Map<String, dynamic>,
        ),
        growable: false,
      ),
      chat: List<WatchPartyChatMessage>.generate(
        rawChat.length,
        (index) => WatchPartyChatMessage.fromJson(
          rawChat[index] as Map<String, dynamic>,
        ),
        growable: false,
      ),
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
    this.memberCount = 0,
    this.webSocketUrl = '',
    this.controllerPassword = '',
  });

  factory WatchPartyInvite.fromJson(Map<String, dynamic> json) =>
      WatchPartyInvite(
        roomId: json['roomId'] as String,
        inviteCode: json['inviteCode'] as String,
        inviteUrl: json['inviteUrl'] as String,
        syncplayHost: json['syncplayHost'] as String,
        syncplayPort: (json['syncplayPort'] as num).toInt(),
        syncplayRoom: json['syncplayRoom'] as String,
        title: json['title'] as String,
        episodeIndex: (json['episodeIndex'] as num).toInt(),
        memberCount: (json['memberCount'] as num).toInt(),
        webSocketUrl: json['websocketUrl'] as String? ?? '',
        controllerPassword: json['controllerPassword'] as String? ?? '',
      );

  final String roomId;
  final String inviteCode;
  final String inviteUrl;
  final String syncplayHost;
  final int syncplayPort;
  final String syncplayRoom;
  final String title;
  final int episodeIndex;
  final int memberCount;
  final String webSocketUrl;
  final String controllerPassword;
}
