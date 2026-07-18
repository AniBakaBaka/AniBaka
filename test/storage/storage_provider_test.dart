import 'dart:async';
import 'dart:io';

import 'package:baka/storage/storage_config.dart';
import 'package:baka/storage/storage_provider.dart';
import 'package:baka/storage/webdav_storage_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classifies and sorts items without case-sensitive drift', () {
    final items = [
      StorageItem(name: 'z.MKV', path: '/z.MKV', type: StorageItemType.file),
      StorageItem(name: 'Beta', path: '/Beta', type: StorageItemType.directory),
      StorageItem(
        name: 'alpha',
        path: '/alpha',
        type: StorageItemType.directory,
      ),
      StorageItem(name: 'a.mp4', path: '/a.mp4', type: StorageItemType.file),
    ];

    StoragePath.sort(items);

    expect(items.map((item) => item.name), ['alpha', 'Beta', 'a.mp4', 'z.MKV']);
    expect(items.last.isVideo, isTrue);
    expect(items[2].isVideo, isTrue);
  });

  test('extracts names without splitting the whole path', () {
    expect(StoragePath.name(r'C:\Anime\Season 1\episode.mkv'), 'episode.mkv');
    expect(StoragePath.name('/Anime/Season 1/'), 'Season 1');
    expect(StoragePath.name('/'), isEmpty);
    expect(StoragePath.trimTrailingSlash('/Anime///'), '/Anime');
  });

  test(
    'reads legacy storage config fields without retaining unused metadata',
    () {
      final config = StorageConfig.fromJson({
        'id': 'dav',
        'name': 'NAS',
        'type': StorageProviderType.webdav.index,
        'path': 'https://example.test/dav',
        'rootPath': '/anime',
        'enabled': true,
        'createdAt': '2025-01-01T00:00:00.000Z',
        'updatedAt': '2025-01-02T00:00:00.000Z',
      });

      expect(config.rootPath, '/anime');
      expect(config.toJson(), isNot(contains('createdAt')));
      expect(config.toJson(), isNot(contains('updatedAt')));
      expect(config.toJson(), isNot(contains('enabled')));
    },
  );

  test('parses WebDAV responses in one pass across namespace prefixes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestCompleter = Completer<HttpRequest>();
    server.listen(requestCompleter.complete);
    final provider = WebDavStorageProvider(
      baseUrl: 'http://${server.address.host}:${server.port}/dav/',
      username: 'user',
      password: 'pass',
      rootPath: '/anime',
    );

    try {
      final resultFuture = provider.listDirectory('/anime');
      final request = await requestCompleter.future;
      expect(request.method, 'PROPFIND');
      expect(request.uri.path, '/dav/anime/');
      expect(request.headers.value('depth'), '1');
      await request.drain<void>();

      request.response
        ..statusCode = 207
        ..headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        )
        ..write('''<?xml version="1.0"?>
<x:multistatus xmlns:x="DAV:">
  <x:response>
    <x:href>/dav/anime/</x:href>
    <x:propstat><x:prop><x:resourcetype><x:collection/></x:resourcetype></x:prop></x:propstat>
  </x:response>
  <x:response>
    <x:href>/dav/anime/Season%201/</x:href>
    <x:propstat><x:prop>
      <x:displayname>Season 1</x:displayname>
      <x:resourcetype><x:collection/></x:resourcetype>
    </x:prop></x:propstat>
  </x:response>
  <x:response>
    <x:href>/dav/anime/Episode%2001.mkv</x:href>
    <x:propstat><x:prop>
      <x:displayname>Episode &amp; 01.mkv</x:displayname>
      <x:getcontentlength>2048</x:getcontentlength>
      <x:getlastmodified>Wed, 15 Nov 1995 04:58:08 GMT</x:getlastmodified>
      <x:resourcetype/>
    </x:prop></x:propstat>
  </x:response>
</x:multistatus>''');
      await request.response.close();

      final items = await resultFuture;
      expect(items, hasLength(2));
      expect(items.first.name, 'Season 1');
      expect(items.first.path, '/anime/Season 1/');
      expect(items.first.isDirectory, isTrue);
      expect(items.last.name, 'Episode & 01.mkv');
      expect(items.last.path, '/anime/Episode 01.mkv');
      expect(items.last.size, 2048);
      expect(items.last.modified, DateTime.utc(1995, 11, 15, 4, 58, 8));
      expect(
        provider.playableUrl(items.last.path),
        'http://${server.address.host}:${server.port}/dav/anime/Episode%2001.mkv',
      );
      expect(provider.httpHeaders, contains('Authorization'));
    } finally {
      provider.dispose();
      await server.close(force: true);
    }
  });
}
