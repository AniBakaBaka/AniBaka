import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:baka/app/navigation.dart';
import 'package:baka/core/app_logger.dart';
import 'package:baka/instance.dart';
import 'package:baka/models/playback_request.dart';
import 'package:baka/services/playback/watch_party.dart';
import 'package:baka/widgets/watch_party/watch_party_sheet.dart';
import 'package:flutter/material.dart';
import 'package:win32_registry/win32_registry.dart';

class WatchPartyLinks {
  WatchPartyLinks(this.party, {Stream<Uri>? incoming}) {
    _linkSubscription = (incoming ?? AppLinks().uriLinkStream).listen(
      (uri) {
        final code = _inviteCodeFromUri(uri);
        if (code != null) unawaited(joinInviteLink(code));
      },
      onError: (Object error, StackTrace stackTrace) {
        Log.w('WatchParty', 'Unable to process app link', error, stackTrace);
      },
    );
  }

  final WatchPartyService party;
  static final _inviteCodePattern = RegExp(r'^[A-Za-z0-9_-]{6,128}$');
  final _ready = Completer<void>();
  bool _closed = false;

  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> close() async {
    _closed = true;
    markReady();
    await _linkSubscription.cancel();
  }

  late final StreamSubscription<Uri> _linkSubscription;
  bool _handlingLink = false;

  /// 从字符串解析邀请码（支持 URL、URI 或纯邀请码）
  static String? inviteCodeFromValue(String value) {
    final normalized = value.trim();
    if (_inviteCodePattern.hasMatch(normalized)) return normalized;
    final uri = Uri.tryParse(normalized);
    return uri == null ? null : _inviteCodeFromUri(uri);
  }

  /// 通过邀请码加入房间并自动引导播放器与弹窗
  Future<void> joinInviteLink(String code) async {
    final normalized = code.trim();
    if (_closed || normalized.isEmpty || _handlingLink) return;
    _handlingLink = true;
    try {
      await _ready.future;
      if (_closed) return;
      await party.joinInvite(normalized);
      if (_closed) return;
      final context = Instances.navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      final media = party.state.value.snapshot?.media;
      if (media != null &&
          media.bgmSubjectId != null &&
          !party.matchesAttachedMedia(media)) {
        NavigationService.toPlayback(
          context,
          PlaybackRequest(
            source: 'bgm',
            episodeIndex: media.episodeIndex,
            metadata: {
              'id': media.bgmSubjectId,
              'bgmId': media.bgmSubjectId,
              'title': media.title,
            },
          ),
        );
      }
      WatchPartySheet.show(context, party);
    } catch (error, stackTrace) {
      if (_closed) return;
      Log.w('WatchParty', 'Unable to join watch party', error, stackTrace);
      final context = Instances.navigatorKey.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    } finally {
      _handlingLink = false;
    }
  }

  static String? _inviteCodeFromUri(Uri uri) {
    if (uri.scheme == 'anibaka' &&
        uri.host.toLowerCase() == 'watch' &&
        uri.pathSegments.isNotEmpty) {
      return _validInviteCode(uri.pathSegments.first);
    }
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        (uri.host.toLowerCase() == 'www.anibaka.com' ||
            uri.host.toLowerCase() == 'anibaka.com') &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments.first == 'watch') {
      return _validInviteCode(uri.pathSegments[1]);
    }
    return null;
  }

  static String? _validInviteCode(String value) =>
      _inviteCodePattern.hasMatch(value) ? value : null;

  static void registerWindowsScheme() {
    RegistryKey? root;
    RegistryKey? scheme;
    RegistryKey? command;
    try {
      root = Registry.currentUser;
      scheme = root.createKey(r'Software\Classes\anibaka');
      scheme.createValue(
        const RegistryValue.string('', 'URL:AniBaka Watch Party'),
      );
      scheme.createValue(const RegistryValue.string('URL Protocol', ''));
      command = scheme.createKey(r'shell\open\command');
      command.createValue(
        RegistryValue.string('', '"${Platform.resolvedExecutable}" "%1"'),
      );
    } catch (error, stackTrace) {
      Log.w(
        'WatchParty',
        'Unable to register anibaka:// protocol',
        error,
        stackTrace,
      );
    } finally {
      command?.close();
      scheme?.close();
      root?.close();
    }
  }
}
