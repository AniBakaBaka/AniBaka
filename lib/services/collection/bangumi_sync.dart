import 'package:baka/api/bangumi_account_api.dart';
import 'dart:convert';
import 'package:baka/models/collection.dart';
import 'package:baka/services/account/bangumi_session.dart';
import 'package:baka/services/collection/collection_repository.dart';

class BangumiSyncReport {
  const BangumiSyncReport({
    required this.imported,
    required this.exported,
    required this.unchanged,
    required this.skippedDeletions,
    required this.conflicts,
    required this.failed,
  });

  final int imported;
  final int exported;
  final int unchanged;
  final int skippedDeletions;
  final int conflicts;
  final int failed;

  int get total => imported + exported + unchanged + skippedDeletions + failed;

  String get summary {
    final parts = <String>[
      if (imported > 0) '导入 $imported',
      if (exported > 0) '上传 $exported',
      if (unchanged > 0) '无需更新 $unchanged',
      if (skippedDeletions > 0) '保留单端删除 $skippedDeletions',
      if (conflicts > 0) '冲突 $conflicts（以 Bangumi 为准）',
      if (failed > 0) '失败 $failed',
    ];
    return parts.isEmpty ? '没有可同步的追番记录' : parts.join('，');
  }
}

late BangumiSyncService bangumiSync;

class BangumiSyncService {
  BangumiSyncService(this.session, this.collections);
  final BangumiSession session;
  final CollectionRepository collections;

  /// 本机记录缺的字段用远端补齐；本机有的以本机为准。
  AnimeCollection _withRemoteFallback(
    AnimeCollection local,
    AnimeCollection remote,
  ) => AnimeCollection(
    postId: local.postId,
    bgmId: local.bgmId,
    status: local.status,
    rating: local.rating > 0 ? local.rating : remote.rating,
    comment: local.comment ?? remote.comment,
    epTotal: local.epTotal ?? remote.epTotal,
    epWatched: local.epWatched ?? remote.epWatched,
    tags: local.tags.isNotEmpty ? local.tags : remote.tags,
    isPrivate: local.isPrivate || remote.isPrivate,
    nsfw: local.nsfw,
    postTitle: local.postTitle,
    postCover: local.postCover,
    bgmRating: local.bgmRating ?? remote.bgmRating,
    bgmImage: local.bgmImage ?? remote.bgmImage,
    bgmTitle: local.bgmTitle ?? remote.bgmTitle,
    bgmSynced: local.bgmSynced,
  );

  Future<BangumiSyncReport>? _running;
  Future<BangumiSyncReport> sync({void Function(String)? onProgress}) =>
      _running ??= _sync(onProgress: onProgress).whenComplete(() {
        _running = null;
      });
  Future<BangumiSyncReport> _sync({void Function(String)? onProgress}) async {
    final revision = session.generation;
    final accountRevision = collections.session.generation;
    void checkAccount() {
      session.ensureCurrent(revision);
      if (accountRevision != collections.session.generation) {
        throw const BangumiSyncException('AniBaka 账号已变更');
      }
    }

    final token = await session.accessToken();
    if (token.isEmpty) {
      throw const BangumiSyncException('请先连接 Bangumi 账号');
    }
    onProgress?.call('正在读取 Bangumi 追番记录…');
    var user = session.account;
    if (user == null) {
      user = await session.api.getMe(token);
      await session.preferences.setString(
        BangumiSession.accountKey,
        jsonEncode(user.toJson()),
      );
    }
    final remote = await session.api.getAnimeCollections(token, user.username);
    onProgress?.call(
      collections.isLocalMode ? '正在读取本机追番记录…' : '正在读取 AniBaka 追番记录…',
    );
    final local = await collections.getAll(refreshBangumi: false);
    checkAccount();

    final items = <int, ({AnimeCollection? remote, AnimeCollection? local})>{
      for (final item in remote) item.bgmId!: (remote: item, local: null),
    };
    for (final item in local) {
      final id = item.bgmId;
      if (id == null || id <= 0) continue;
      items[id] = (remote: items[id]?.remote, local: item);
    }
    final ids = items.keys.toList()..sort();
    final imports = <AnimeCollection>[];
    var importedToServer = false;
    final snapshots = session.loadSnapshots();
    // 旧的第二张待补传清单做一次迁移。
    final legacyPending = session.loadPendingPush();
    if (legacyPending.isNotEmpty) {
      for (final id in legacyPending) {
        collections.markPendingSync(id);
      }
      await session.preferences.remove(session.pendingPushKey);
    }
    var imported = 0;
    var exported = 0;
    var unchanged = 0;
    var skippedDeletions = 0;
    var conflicts = 0;
    var failed = 0;
    Object? firstError;

    for (var index = 0; index < ids.length; index++) {
      checkAccount();
      final id = ids[index];
      final pair = items[id]!;
      final remoteItem = pair.remote;
      final localItem = pair.local;
      onProgress?.call('正在同步 ${index + 1}/${ids.length}…');

      final remoteFingerprint = remoteItem == null
          ? null
          : localCollectionFingerprint(remoteItem);
      final localFingerprint = localItem == null
          ? null
          : localCollectionFingerprint(localItem);
      final previous = snapshots['$id'];

      if (previous != null &&
          ((remoteItem == null && localFingerprint == previous) ||
              (localItem == null && remoteFingerprint == previous))) {
        collections.clearPendingSync(id);
        skippedDeletions++;
        continue;
      }

      // 两边已经一致，待补传标记可以划掉。
      if (remoteFingerprint == localFingerprint && remoteFingerprint != null) {
        snapshots['$id'] = remoteFingerprint;
        collections.clearPendingSync(id);
        unchanged++;
        continue;
      }

      // 改状态留下的待补传同样算本地更新。
      final preferLocal =
          collections.hasPendingSync(id) ||
          (previous != null &&
              localFingerprint != null &&
              localFingerprint != previous &&
              remoteFingerprint == previous);

      try {
        if (remoteItem == null || (localItem != null && preferLocal)) {
          if (localItem == null) continue;
          // 本机没带的字段沿用远端。
          final exportItem = remoteItem == null
              ? localItem
              : _withRemoteFallback(localItem, remoteItem);
          await session.api.putCollection(token, exportItem);
          if (localItem.epWatched != null) {
            await session.api.putEpisodeProgress(
              token,
              id,
              localItem.epWatched!,
            );
          }
          snapshots['$id'] = localFingerprint!;
          await collections.markSynced(id);
          collections.clearPendingSync(id);
          exported++;
        } else {
          final localChanged = previous != null && localFingerprint != previous;
          final remoteChanged =
              previous != null && remoteFingerprint != previous;
          if (localChanged && remoteChanged) conflicts++;
          final collection = remoteItem;
          if (collections.isLocalMode) {
            imports.add(collection);
          } else {
            await collections.importRemote([collection], notify: false);
            importedToServer = true;
          }
          snapshots['$id'] = remoteFingerprint!;
          collections.clearPendingSync(id);
          imported++;
        }
      } catch (error) {
        firstError ??= error;
        if (preferLocal || remoteItem == null) collections.markPendingSync(id);
        failed++;
      }
    }

    checkAccount();
    if (imports.isNotEmpty) await collections.importRemote(imports);
    if (importedToServer) collections.notifyChanged();
    await session.preferences.setString(
      session.snapshotKey,
      jsonEncode(snapshots),
    );
    if (failed > 0 &&
        imported == 0 &&
        exported == 0 &&
        unchanged == 0 &&
        skippedDeletions == 0) {
      if (firstError is BangumiSyncException) throw firstError;
      throw const BangumiSyncException('同步失败，请稍后重试');
    }
    final syncedAt = DateTime.now().toUtc();
    await session.preferences.setString(
      session.lastSyncKey,
      syncedAt.toIso8601String(),
    );
    return BangumiSyncReport(
      imported: imported,
      exported: exported,
      unchanged: unchanged,
      skippedDeletions: skippedDeletions,
      conflicts: conflicts,
      failed: failed,
    );
  }
}
