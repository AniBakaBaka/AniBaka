import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// Codec for the two share-link formats emitted by AniBaka.
class SourceCodec {
  SourceCodec._();

  static const String scheme = 'baka://';
  static const String encryptedScheme = 'bakax://';
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

  static String encode(Object data) {
    final compressed = _gzipEncoder.encode(utf8.encode(jsonEncode(data)));
    return '$scheme${_base64Url(compressed)}';
  }

  static String encrypt(Object data) {
    final iv = enc.IV.fromSecureRandom(16);
    final cipher = _encrypter.encryptBytes(
      _gzipEncoder.encode(utf8.encode(jsonEncode(data))),
      iv: iv,
    );
    final bytes = Uint8List(iv.bytes.length + cipher.bytes.length)
      ..setAll(0, iv.bytes)
      ..setAll(iv.bytes.length, cipher.bytes);
    return '$encryptedScheme${_base64Url(bytes)}';
  }

  static Object? decode(String input) {
    final value = input.trim();
    if (value.isEmpty) throw const FormatException('Empty source rule');
    if (value.startsWith(encryptedScheme)) {
      return jsonDecode(_decrypt(value.substring(encryptedScheme.length)));
    }
    if (value.startsWith(scheme)) {
      final bytes = base64Url.decode(
        base64Url.normalize(value.substring(scheme.length)),
      );
      return jsonDecode(utf8.decode(_gzipDecoder.decodeBytes(bytes)));
    }
    if (value.startsWith('{') || value.startsWith('[')) {
      return jsonDecode(value);
    }
    throw const FormatException('Unsupported source rule format');
  }

  static String _decrypt(String payload) {
    final bytes = base64Url.decode(base64Url.normalize(payload));
    if (bytes.length <= 16) {
      throw const FormatException('Invalid encrypted source rule');
    }
    final compressed = _encrypter.decryptBytes(
      enc.Encrypted(Uint8List.sublistView(bytes, 16)),
      iv: enc.IV(Uint8List.sublistView(bytes, 0, 16)),
    );
    return utf8.decode(_gzipDecoder.decodeBytes(compressed));
  }

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
