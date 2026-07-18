import 'dart:convert';

import 'package:baka/storage/storage_provider.dart';
import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:xml/xml_events.dart';

class WebDavStorageProvider extends StorageProvider {
  static const _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:getcontentlength/>
    <D:getlastmodified/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>''';

  final String _baseUrl;
  final String _rootPath;
  final Dio _dio;

  @override
  final String displayName;

  @override
  final Map<String, String>? httpHeaders;

  late final Uri _baseUri = Uri.parse(_baseUrl);
  late final String _basePath = StoragePath.trimTrailingSlash(_baseUri.path);

  WebDavStorageProvider({
    required String baseUrl,
    required String username,
    required String password,
    String rootPath = '/',
    String? name,
  }) : _baseUrl = StoragePath.trimTrailingSlash(baseUrl.trim()),
       _rootPath = rootPath,
       displayName = name ?? 'WebDAV',
       httpHeaders = username.isEmpty && password.isEmpty
           ? null
           : Map.unmodifiable({
               'Authorization': _basicAuth(username, password),
             }),
       _dio = Dio(
         BaseOptions(
           baseUrl: StoragePath.trimTrailingSlash(baseUrl.trim()),
           connectTimeout: const Duration(seconds: 15),
           receiveTimeout: const Duration(seconds: 30),
           headers: username.isEmpty && password.isEmpty
               ? null
               : {'Authorization': _basicAuth(username, password)},
           validateStatus: (status) => status != null && status < 600,
         ),
       );

  static String _basicAuth(String username, String password) =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Future<bool> testConnection() async {
    try {
      final response = await _dio.request<Object?>(
        _rootPath,
        options: Options(method: 'PROPFIND', headers: const {'Depth': '0'}),
      );
      return response.statusCode == 200 || response.statusCode == 207;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<StorageItem>> listDirectory(String path) async {
    final requestPath = path.endsWith('/') ? path : '$path/';
    try {
      final response = await _dio.request<Object?>(
        requestPath,
        data: _propfindBody,
        options: Options(
          method: 'PROPFIND',
          headers: const {'Depth': '1', 'Content-Type': 'application/xml'},
        ),
      );
      if (response.statusCode != 207) return const [];

      return _parseMultiStatus(response.data?.toString() ?? '', requestPath);
    } catch (_) {
      return const [];
    }
  }

  @override
  String playableUrl(String path) {
    final baseSegments = _baseUri.pathSegments.where((part) => part.isNotEmpty);
    final fileSegments = path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty);
    return _baseUri
        .replace(userInfo: '', pathSegments: [...baseSegments, ...fileSegments])
        .toString();
  }

  @override
  void dispose() => _dio.close();

  List<StorageItem> _parseMultiStatus(String xml, String requestPath) {
    final requestedPath = StoragePath.trimTrailingSlash(
      '$_basePath$requestPath',
    );
    final items = <StorageItem>[];

    var inResponse = false;
    var isDirectory = false;
    String? activeField;
    StringBuffer? text;
    String? href;
    String? displayName;
    String? sizeText;
    String? modifiedText;

    for (final event in parseEvents(xml, validateNesting: true)) {
      if (event is XmlStartElementEvent) {
        final tag = event.localName.toLowerCase();
        if (tag == 'response') {
          inResponse = true;
          isDirectory = false;
          href = null;
          displayName = null;
          sizeText = null;
          modifiedText = null;
        } else if (inResponse && tag == 'collection') {
          isDirectory = true;
        } else if (inResponse &&
            (tag == 'href' ||
                tag == 'displayname' ||
                tag == 'getcontentlength' ||
                tag == 'getlastmodified')) {
          activeField = tag;
          text = StringBuffer();
        }
        continue;
      }

      if (event is XmlTextEvent && text != null) {
        text.write(event.value);
        continue;
      }
      if (event is XmlCDATAEvent && text != null) {
        text.write(event.value);
        continue;
      }
      if (event is! XmlEndElementEvent) continue;

      final tag = event.localName.toLowerCase();
      if (activeField == tag) {
        final value = text.toString().trim();
        switch (tag) {
          case 'href':
            href = value;
          case 'displayname':
            displayName = value;
          case 'getcontentlength':
            sizeText = value;
          case 'getlastmodified':
            modifiedText = value;
        }
        activeField = null;
        text = null;
      }

      if (tag != 'response') continue;
      inResponse = false;

      final rawHref = href;
      if (rawHref == null || rawHref.isEmpty) continue;
      final hrefUri = Uri.tryParse(rawHref);
      var hrefPath = Uri.decodeFull(hrefUri?.path ?? rawHref);
      if (StoragePath.trimTrailingSlash(hrefPath) == requestedPath) continue;

      final name = displayName?.isNotEmpty == true
          ? displayName!
          : StoragePath.name(hrefPath);
      if (name.isEmpty || name.startsWith('.')) continue;

      if (_basePath.isNotEmpty &&
          _basePath != '/' &&
          (hrefPath == _basePath || hrefPath.startsWith('$_basePath/'))) {
        hrefPath = hrefPath.substring(_basePath.length);
        if (hrefPath.isEmpty) hrefPath = '/';
      }

      DateTime? modified;
      if (modifiedText?.isNotEmpty == true) {
        try {
          modified = parseHttpDate(modifiedText!);
        } on FormatException {
          modified = DateTime.tryParse(modifiedText!);
        }
      }

      items.add(
        StorageItem(
          name: name,
          path: hrefPath,
          type: isDirectory ? StorageItemType.directory : StorageItemType.file,
          size: int.tryParse(sizeText ?? ''),
          modified: modified,
        ),
      );
    }

    StoragePath.sort(items);
    return items;
  }
}
