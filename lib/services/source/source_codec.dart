import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// Imports baka/bakax rules and exports baka share links.
class SourceCodec {
  SourceCodec._();

  static const String scheme = 'baka://';
  static const String encryptedScheme = 'bakax://';
  static const _gzipEncoder = GZipEncoder();
  static const _gzipDecoder = GZipDecoder();
  static final _jsonUtf8 = json.fuse(utf8);
  static const _passphrase = 'AniBaka::rule-hub::v1::do-not-share';

  static final _aes = enc.AES(
    enc.Key(Uint8List.fromList(sha256.convert(utf8.encode(_passphrase)).bytes)),
    mode: enc.AESMode.cbc,
  );

  static String encode(Object data) {
    final bytes = _gzipEncoder.encodeBytes(_jsonUtf8.encode(data));
    return '$scheme${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  static Object? decode(String input) {
    final value = input.trim();
    if (value.isEmpty) throw const FormatException('Empty source rule');
    if (value.startsWith('{') || value.startsWith('[')) {
      return jsonDecode(value);
    }
    final encrypted = value.startsWith(encryptedScheme);
    if (!encrypted && !value.startsWith(scheme)) {
      throw const FormatException('Unsupported source rule format');
    }
    var bytes = base64Url.decode(
      base64Url.normalize(
        value.substring(encrypted ? encryptedScheme.length : scheme.length),
      ),
    );
    if (encrypted) {
      if (bytes.length <= 16) {
        throw const FormatException('Invalid encrypted source rule');
      }
      bytes = _aes.decrypt(
        enc.Encrypted(Uint8List.sublistView(bytes, 16)),
        iv: enc.IV(Uint8List.sublistView(bytes, 0, 16)),
      );
    }
    return _jsonUtf8.decode(_gzipDecoder.decodeBytes(bytes));
  }
}
