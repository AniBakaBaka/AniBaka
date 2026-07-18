import 'dart:convert';
import 'dart:typed_data';

/// Bencode 编解码器 — BitTorrent 元数据的标准序列化格式
///
/// 支持四种数据类型：
/// - 整数: `i<number>e`
/// - 字节串: `<length>:<data>`
/// - 列表: `l<items>e`
/// - 字典: `d<pairs>e`
class Bencode {
  const Bencode._();

  static dynamic decode(Uint8List data) => _Reader(data).read();

  /// 解码第一个 bencode 值，并返回该值在输入中的结束位置。
  ///
  /// BEP 9 的 data 消息是 bencode 字典后直接追加 metadata block，
  /// 因此不能要求整段 payload 都是 bencode。
  static ({dynamic value, int end}) decodePrefix(Uint8List data) {
    final reader = _Reader(data);
    final value = reader.read();
    return (value: value, end: reader.position);
  }

  /// 解码并返回**顶层**字典中指定键对应值在原始字节流中的范围。
  /// 用于对 `info` 子字典做 SHA1 计算 info_hash。
  static ({Map<String, dynamic> root, int start, int end}) decodeWithRange(
    Uint8List data,
    String topKey,
  ) {
    final reader = _Reader(data);
    final root = reader.read();
    if (root is! Map<String, dynamic>) {
      throw const FormatException('Bencode: 顶层必须是字典');
    }
    final range = reader.topRanges[topKey];
    if (range == null) {
      throw FormatException('Bencode: 顶层未找到键 "$topKey"');
    }
    return (root: root, start: range.$1, end: range.$2);
  }

  static Uint8List encode(dynamic value) {
    final builder = BytesBuilder(copy: false);
    _encodeValue(value, builder);
    return builder.toBytes();
  }

  static void _encodeValue(dynamic value, BytesBuilder builder) {
    if (value is int) {
      builder.add(utf8.encode('i${value}e'));
    } else if (value is Uint8List) {
      _encodeBytes(value, builder);
    } else if (value is List<int>) {
      _encodeBytes(Uint8List.fromList(value), builder);
    } else if (value is String) {
      _encodeBytes(Uint8List.fromList(utf8.encode(value)), builder);
    } else if (value is List) {
      builder.addByte(0x6c); // l
      for (final item in value) {
        _encodeValue(item, builder);
      }
      builder.addByte(0x65); // e
    } else if (value is Map) {
      builder.addByte(0x64); // d
      final entries = value.entries.toList()
        ..sort((a, b) => _compareBytes(_keyBytes(a.key), _keyBytes(b.key)));
      for (final entry in entries) {
        _encodeBytes(_keyBytes(entry.key), builder);
        _encodeValue(entry.value, builder);
      }
      builder.addByte(0x65); // e
    } else {
      throw ArgumentError('Bencode: 不支持的类型 ${value.runtimeType}');
    }
  }

  static Uint8List _keyBytes(dynamic key) {
    if (key is Uint8List) return key;
    if (key is List<int>) return Uint8List.fromList(key);
    return Uint8List.fromList(utf8.encode(key.toString()));
  }

  static void _encodeBytes(Uint8List bytes, BytesBuilder builder) {
    builder.add(utf8.encode('${bytes.length}:'));
    builder.add(bytes);
  }

  static int _compareBytes(Uint8List a, Uint8List b) {
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final diff = a[i] - b[i];
      if (diff != 0) return diff;
    }
    return a.length - b.length;
  }
}

class _Reader {
  final Uint8List data;
  int _pos = 0;
  int _depth = 0;

  /// 顶层字典中每个键 → (start, end)
  final Map<String, (int, int)> topRanges = {};

  _Reader(this.data);

  int get position => _pos;

  int get _byte => data[_pos];

  dynamic read() {
    if (_pos >= data.length) {
      throw const FormatException('Bencode: 意外的数据结尾');
    }
    final b = _byte;
    if (b == 0x69) return _readInt();
    if (b == 0x6C) return _readList();
    if (b == 0x64) return _readDict();
    if (b >= 0x30 && b <= 0x39) return _readBytes();
    throw FormatException('Bencode: 位置 $_pos 处的无效字符 0x${b.toRadixString(16)}');
  }

  int _readInt() {
    _pos++;
    final end = data.indexOf(0x65, _pos);
    if (end < 0) throw const FormatException('Bencode: 整数缺少结束符');
    final n = int.parse(utf8.decode(Uint8List.sublistView(data, _pos, end)));
    _pos = end + 1;
    return n;
  }

  Uint8List _readBytes() {
    final colon = data.indexOf(0x3A, _pos);
    if (colon < 0) throw const FormatException('Bencode: 字节串缺少冒号');
    final length = int.parse(
      utf8.decode(Uint8List.sublistView(data, _pos, colon)),
    );
    _pos = colon + 1;
    if (_pos + length > data.length) {
      throw const FormatException('Bencode: 字节串长度超出数据范围');
    }
    final bytes = Uint8List.sublistView(data, _pos, _pos + length);
    _pos += length;
    return bytes;
  }

  List<dynamic> _readList() {
    _pos++;
    final list = <dynamic>[];
    while (_byte != 0x65) {
      list.add(read());
      if (_pos >= data.length) {
        throw const FormatException('Bencode: 列表缺少结束符');
      }
    }
    _pos++;
    return list;
  }

  Map<String, dynamic> _readDict() {
    final isTop = _depth == 0;
    _depth++;
    _pos++;
    final dict = <String, dynamic>{};
    while (_byte != 0x65) {
      final key = utf8.decode(_readBytes(), allowMalformed: true);
      final start = _pos;
      dict[key] = read();
      if (isTop) topRanges[key] = (start, _pos);
      if (_pos >= data.length) {
        throw const FormatException('Bencode: 字典缺少结束符');
      }
    }
    _pos++;
    _depth--;
    return dict;
  }
}

/// 辅助：将 bencode 解码的值安全转为字符串
String bencodeString(dynamic value) {
  if (value is Uint8List) return utf8.decode(value, allowMalformed: true);
  if (value is String) return value;
  return value.toString();
}

/// 辅助：将 bencode 解码的值安全转为 int
int bencodeInt(dynamic value) {
  if (value is int) return value;
  if (value is String) return int.parse(value);
  if (value is Uint8List) return int.parse(utf8.decode(value));
  return 0;
}
