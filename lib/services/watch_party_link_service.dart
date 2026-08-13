import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:baka/instance.dart';
import 'package:baka/services/navigation_service.dart';
import 'package:baka/services/watch_party_service.dart';
import 'package:baka/utils/app_logger.dart';
import 'package:baka/widgets/watch_party/watch_party_sheet.dart';
import 'package:flutter/material.dart';
import 'package:win32_registry/win32_registry.dart';

final class WatchPartyLinkService {
  WatchPartyLinkService._();

  static final AppLinks _links = AppLinks();
  static StreamSubscription<Uri>? _subscription;
  static bool _handling = false;

  static void initialize() {
    if (_subscription != null) return;
    if (Platform.isWindows) _registerWindowsScheme();
    _subscription = _links.uriLinkStream.listen(
      _handle,
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.instance.warning(
          'Unable to process app link',
          tag: 'WatchParty',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  static Future<void> _handle(Uri uri) async {
    final code = _inviteCodeFromUri(uri);
    if (code == null) return;
    await joinInvite(code);
  }

  static String? inviteCodeFromValue(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    final uri = Uri.tryParse(normalized);
    final fromUri = uri == null ? null : _inviteCodeFromUri(uri);
    if (fromUri != null) return fromUri;
    return RegExp(r'^[A-Za-z0-9_-]{6,128}$').hasMatch(normalized)
        ? normalized
        : null;
  }

  static Future<void> joinInvite(String code) async {
    final normalized = code.trim();
    if (normalized.isEmpty || _handling) return;
    _handling = true;
    try {
      await WatchPartyService.instance.joinInvite(normalized);
      await _openMatchingPlayerWhenNeeded();
      await _showRoomWhenReady();
    } catch (error, stackTrace) {
      AppLogger.instance.warning(
        'Unable to join watch party',
        tag: 'WatchParty',
        error: error,
        stackTrace: stackTrace,
      );
      await _showErrorWhenReady(
        error.toString().replaceFirst('Bad state: ', ''),
      );
    } finally {
      _handling = false;
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
      RegExp(r'^[A-Za-z0-9_-]{6,128}$').hasMatch(value) ? value : null;

  static Future<void> _openMatchingPlayerWhenNeeded() async {
    final service = WatchPartyService.instance;
    final media = service.state.value.snapshot?.media;
    if (media == null ||
        media.bgmSubjectId == null ||
        service.matchesAttachedMedia(media)) {
      return;
    }
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) return;
    NavigationService.toPlayer(
      context,
      <String, dynamic>{
        'id': media.bgmSubjectId,
        'bgmId': media.bgmSubjectId,
        'title': media.title,
        'source': 'bgm',
        'currPlayIndex': media.episodeIndex,
      },
      posIndex: media.episodeIndex,
      autoMatch: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  static Future<BuildContext?> _contextWhenReady() async {
    for (var attempt = 0; attempt < 50; attempt++) {
      final context = Instances.navigatorKey.currentContext;
      if (context != null && context.mounted) return context;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  static Future<void> _showRoomWhenReady() async {
    final context = await _contextWhenReady();
    if (context != null && context.mounted) {
      await WatchPartySheet.show(context, WatchPartyService.instance);
    }
  }

  static Future<void> _showErrorWhenReady(String message) async {
    final context = await _contextWhenReady();
    if (context != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  static void _registerWindowsScheme() {
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
      AppLogger.instance.warning(
        'Unable to register anibaka:// protocol',
        tag: 'WatchParty',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      command?.close();
      scheme?.close();
      root?.close();
    }
  }
}
