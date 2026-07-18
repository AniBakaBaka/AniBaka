import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// 图源配置编解码器。
///
/// 当前格式：
/// - `baka://`：gzip + 无填充 base64Url。
/// - `bakax://`：gzip + AES-256-CBC + 无填充 base64Url。
///
/// 解码同时兼容旧版 `baka://base64(JSON)`、JSON 包装和裸 JSON。
class SourceCodec {
  SourceCodec._();

  static const String scheme = 'baka://';
  static const String encryptedScheme = 'bakax://';
  static const String packField = 'pack';

  static const _gzipEncoder = GZipEncoder();
  static const _gzipDecoder = GZipDecoder();
  static const _passphrase = 'AniBaka::rule-hub::v1::do-not-share';

  static final enc.Encrypter _encrypter = enc.Encrypter(
    enc.AES(
      enc.Key(
        Uint8List.fromList(sha256.convert(utf8.encode(_passphrase)).bytes),
      ),
      mode: enc.AESMode.cbc,
    ),
  );

  static String encode(Object data) => encodeJsonString(jsonEncode(data));

  static String encodeJsonString(String json) {
    final compressed = _gzipEncoder.encode(utf8.encode(json));
    return '$scheme${_base64Url(compressed)}';
  }

  static String encrypt(Object data) => encryptJsonString(jsonEncode(data));

  static String encryptJsonString(String json) {
    final iv = enc.IV.fromSecureRandom(16);
    final cipher = _encrypter.encryptBytes(
      _gzipEncoder.encode(utf8.encode(json)),
      iv: iv,
    );
    final bytes = Uint8List(iv.bytes.length + cipher.bytes.length)
      ..setAll(0, iv.bytes)
      ..setAll(iv.bytes.length, cipher.bytes);
    return '$encryptedScheme${_base64Url(bytes)}';
  }

  static dynamic decode(String input) => jsonDecode(decodeToJsonString(input));

  static String decodeToJsonString(String input) {
    var payload = input.trim();
    if (payload.isEmpty) {
      throw const FormatException('图源配置为空');
    }

    if (_startsWithScheme(payload, encryptedScheme)) {
      return _decodeEncrypted(payload.substring(encryptedScheme.length).trim());
    }

    if (_looksLikeJson(payload)) {
      final decoded = jsonDecode(payload);
      if (decoded case final Map map when map[packField] is String) {
        final packed = (map[packField] as String).trim();
        if (packed.isNotEmpty) return decodeToJsonString(packed);
      }
      return payload;
    }

    if (_startsWithScheme(payload, scheme)) {
      payload = payload.substring(scheme.length).trim();
    }

    final bytes = _tryBase64(payload);
    if (bytes == null) {
      throw const FormatException('图源配置格式无效');
    }

    final decodedBytes = _isGzip(bytes)
        ? _gzipDecoder.decodeBytes(bytes)
        : bytes;
    final json = utf8.decode(decodedBytes);
    jsonDecode(json);
    return json;
  }

  static String _decodeEncrypted(String payload) {
    final bytes = _tryBase64(payload);
    if (bytes == null || bytes.length <= 16) {
      throw const FormatException('加密图源配置格式无效');
    }

    final iv = enc.IV(Uint8List.sublistView(bytes, 0, 16));
    final cipher = enc.Encrypted(Uint8List.sublistView(bytes, 16));
    final compressed = _encrypter.decryptBytes(cipher, iv: iv);
    return utf8.decode(_gzipDecoder.decodeBytes(compressed));
  }

  static Uint8List? _tryBase64(String input) {
    try {
      return base64Url.decode(base64Url.normalize(input));
    } on FormatException {
      try {
        return base64.decode(base64.normalize(input));
      } on FormatException {
        return null;
      }
    }
  }

  static bool _startsWithScheme(String value, String valueScheme) =>
      value.length >= valueScheme.length &&
      value.substring(0, valueScheme.length).toLowerCase() == valueScheme;

  static bool _looksLikeJson(String value) {
    final first = value.codeUnitAt(0);
    return first == 0x7B || first == 0x5B;
  }

  static bool _isGzip(Uint8List bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B;

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
