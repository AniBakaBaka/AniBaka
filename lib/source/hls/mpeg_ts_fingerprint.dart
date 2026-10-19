import 'dart:typed_data';

/// 一路编码的视频指纹：从分片前缀里解出的编码参数。
///
/// 用于判断某个分片是否与清单主体来自同一次编码。拼接进来的广告通常与正片
/// 不是同一次编码，宽高、H.264 level、profile 至少有一项不同。
class HlsVideoFingerprint {
  const HlsVideoFingerprint({
    required this.width,
    required this.height,
    required this.levelIdc,
    required this.profileIdc,
  });

  /// 显示宽度（已扣除 SPS 里的 frame cropping）。
  final int width;

  /// 显示高度（已扣除 SPS 里的 frame cropping）。
  final int height;

  /// H.264 `level_idc`，如 40 = level 4.0、50 = level 5.0。
  final int levelIdc;

  /// H.264 `profile_idc`，如 100 = High。
  final int profileIdc;

  @override
  String toString() => '${width}x$height/L$levelIdc/P$profileIdc';

  @override
  bool operator ==(Object other) =>
      other is HlsVideoFingerprint &&
      other.width == width &&
      other.height == height &&
      other.levelIdc == levelIdc &&
      other.profileIdc == profileIdc;

  @override
  int get hashCode => Object.hash(width, height, levelIdc, profileIdc);
}

/// 从 MPEG-TS 分片前缀里读视频编码参数。
///
/// 只依赖分片开头的少量字节：PAT/PMT 通常在头几个包内，首个 SPS 一般也在
/// 前几 KB。实测 dytt-tvs / jimxtc 的分片里 PMT 在第 376 字节、首个 SPS 起始码
/// 在 601–1375 字节之间，16 KB 前缀足够。fMP4（EXT-X-MAP）不在此实现范围内。
class MpegTsFingerprint {
  static const int packetSize = 188;
  static const int probeBytes = 16 * 1024;
  static const int _syncByte = 0x47;

  /// 视频流类型：H.264。
  static const int _streamTypeH264 = 0x1B;

  /// 使用扩展 `seq_parameter_set_data` 语法的 profile。
  static const Set<int> _extendedProfiles = {
    100,
    110,
    122,
    244,
    44,
    83,
    86,
    118,
    128,
    138,
    139,
    134,
    135,
  };

  int _offset = 0;
  bool _synced = false;
  int _pmtPid = -1;
  int _videoPid = -1;
  int _zeros = 0;
  bool _nalHeader = false;
  bool _collecting = false;
  final _sps = <int>[];
  HlsVideoFingerprint? _fingerprint;

  /// Accepts a growing prefix. Packets already consumed are never read again.
  HlsVideoFingerprint? read(Uint8List bytes) {
    if (_fingerprint != null) return _fingerprint;
    if (!_synced) {
      final start = findPacketStart(bytes, from: _offset);
      if (start == null) {
        _offset = bytes.length > packetSize * 2
            ? bytes.length - packetSize * 2
            : 0;
        return null;
      }
      _offset = start;
      _synced = true;
    }
    while (_offset + packetSize <= bytes.length) {
      final offset = _offset;
      _offset += packetSize;
      if (bytes[offset] != _syncByte) return null;
      final pid = ((bytes[offset + 1] & 0x1F) << 8) | bytes[offset + 2];
      if (pid != 0 && pid != _pmtPid && pid != _videoPid) continue;
      final afc = (bytes[offset + 3] >> 4) & 3;
      if (afc == 0 || afc == 2) continue;
      var p = offset + 4;
      if (afc == 3) p += 1 + bytes[p];
      final end = offset + packetSize;
      if (p >= end) continue;
      final pusi = (bytes[offset + 1] & 0x40) != 0;
      if (pid == _videoPid) {
        // PSI uses a pointer field; video PES uses its own optional header.
        if (pusi && p + 9 <= end) p += 9 + bytes[p + 8];
        _fingerprint = _readSps(bytes, p, end);
        if (_fingerprint != null) return _fingerprint;
        continue;
      }
      if (!pusi) continue;
      p += 1 + bytes[p];
      if (p + 8 > end) continue;
      final sectionEnd =
          p + 3 + (((bytes[p + 1] & 15) << 8) | bytes[p + 2]) - 4;
      final limit = sectionEnd < end ? sectionEnd : end;
      if (pid == 0 && bytes[p] == 0) {
        for (var program = p + 8; program + 4 <= limit; program += 4) {
          if (bytes[program] == 0 && bytes[program + 1] == 0) continue;
          _pmtPid = ((bytes[program + 2] & 31) << 8) | bytes[program + 3];
          break;
        }
      } else if (pid == _pmtPid && bytes[p] == 2 && p + 12 <= limit) {
        var stream = p + 12 + (((bytes[p + 10] & 15) << 8) | bytes[p + 11]);
        while (stream + 5 <= limit) {
          if (bytes[stream] == _streamTypeH264) {
            _videoPid = ((bytes[stream + 1] & 31) << 8) | bytes[stream + 2];
            break;
          }
          stream += 5 + (((bytes[stream + 3] & 15) << 8) | bytes[stream + 4]);
        }
      }
    }
    return null;
  }

  /// 找到连续三个同步字节对齐的位置，避开少数播放器在流前塞入的杂字节。
  static int? findPacketStart(Uint8List bytes, {int from = 0}) {
    final limit = bytes.length - packetSize * 2;
    for (var offset = from; offset < limit; offset++) {
      if (bytes[offset] != _syncByte) continue;
      if (bytes[offset + packetSize] != _syncByte) continue;
      if (bytes[offset + packetSize * 2] != _syncByte) continue;
      return offset;
    }
    return null;
  }

  HlsVideoFingerprint? _readSps(Uint8List bytes, int start, int end) {
    for (var i = start; i < end; i++) {
      final byte = bytes[i];
      if (byte == 1 && _zeros >= 2) {
        if (_collecting) {
          _sps.length -= _zeros;
          final result = _parseSps(_sps);
          if (result != null) return result;
          _sps.clear();
        }
        _collecting = false;
        _nalHeader = true;
      } else if (_nalHeader) {
        _collecting = (byte & 31) == 7;
        _nalHeader = false;
        if (_collecting) _sps.add(byte);
      } else if (_collecting) {
        _sps.add(byte);
      }
      _zeros = byte == 0 ? _zeros + 1 : 0;
    }
    return null;
  }

  /// 去掉防竞争字节（`00 00 03` → `00 00`）。
  static Uint8List _unescape(List<int> nal) {
    final out = Uint8List(nal.length);
    var n = 0;
    var zeros = 0;
    for (final byte in nal) {
      if (zeros >= 2 && byte == 0x03) {
        zeros = 0;
        continue;
      }
      out[n++] = byte;
      zeros = byte == 0 ? zeros + 1 : 0;
    }
    return Uint8List.sublistView(out, 0, n);
  }

  /// 读 SPS：宽高 + frame cropping + level_idc。
  ///
  /// [nal] 从 NAL 头字节（`0x67`）开始，因此先跳过 1 字节头。
  static HlsVideoFingerprint? _parseSps(List<int> nal) {
    final reader = _BitReader(_unescape(nal));
    try {
      reader.readBits(8); // NAL 头：forbidden_zero_bit/nal_ref_idc/nal_unit_type
      final profileIdc = reader.readBits(8);
      reader.readBits(8); // constraint flags + reserved bits
      final levelIdc = reader.readBits(8);
      reader.readUnsignedExpGolomb(); // seq_parameter_set_id

      var chromaFormatIdc = 1;
      if (_extendedProfiles.contains(profileIdc)) {
        chromaFormatIdc = reader.readUnsignedExpGolomb();
        if (chromaFormatIdc == 3) reader.readBit(); // separate_colour_plane
        reader.readUnsignedExpGolomb(); // bit_depth_luma_minus8
        reader.readUnsignedExpGolomb(); // bit_depth_chroma_minus8
        reader.readBit(); // qpprime_y_zero_transform_bypass_flag
        if (reader.readBit() == 1) {
          final count = chromaFormatIdc == 3 ? 12 : 8;
          for (var i = 0; i < count; i++) {
            if (reader.readBit() == 1) {
              _skipScalingList(reader, i < 6 ? 16 : 64);
            }
          }
        }
      }

      reader.readUnsignedExpGolomb(); // log2_max_frame_num_minus4
      final pocType = reader.readUnsignedExpGolomb();
      if (pocType == 0) {
        reader.readUnsignedExpGolomb(); // log2_max_pic_order_cnt_lsb_minus4
      } else if (pocType == 1) {
        reader.readBit(); // delta_pic_order_always_zero_flag
        reader.readSignedExpGolomb();
        reader.readSignedExpGolomb();
        final cycle = reader.readUnsignedExpGolomb();
        for (var i = 0; i < cycle; i++) {
          reader.readSignedExpGolomb();
        }
      }

      reader.readUnsignedExpGolomb(); // max_num_ref_frames
      reader.readBit(); // gaps_in_frame_num_value_allowed_flag
      final widthInMbs = reader.readUnsignedExpGolomb() + 1;
      final heightInMapUnits = reader.readUnsignedExpGolomb() + 1;
      final frameMbsOnly = reader.readBit();
      if (frameMbsOnly == 0) reader.readBit(); // mb_adaptive_frame_field_flag
      reader.readBit(); // direct_8x8_inference_flag

      var cropLeft = 0;
      var cropRight = 0;
      var cropTop = 0;
      var cropBottom = 0;
      if (reader.readBit() == 1) {
        cropLeft = reader.readUnsignedExpGolomb();
        cropRight = reader.readUnsignedExpGolomb();
        cropTop = reader.readUnsignedExpGolomb();
        cropBottom = reader.readUnsignedExpGolomb();
      }

      final subWidthC = chromaFormatIdc == 1 || chromaFormatIdc == 2 ? 2 : 1;
      final subHeightC = chromaFormatIdc == 1 ? 2 : 1;
      final cropUnitX = subWidthC;
      final cropUnitY = subHeightC * (2 - frameMbsOnly);
      final width = widthInMbs * 16 - cropUnitX * (cropLeft + cropRight);
      final height =
          (2 - frameMbsOnly) * heightInMapUnits * 16 -
          cropUnitY * (cropTop + cropBottom);
      if (width <= 0 || height <= 0) return null;
      return HlsVideoFingerprint(
        width: width,
        height: height,
        levelIdc: levelIdc,
        profileIdc: profileIdc,
      );
    } on StateError {
      return null;
    }
  }

  /// `scaling_list()`：只关心长度，读完即弃。
  static void _skipScalingList(_BitReader reader, int size) {
    var lastScale = 8;
    var nextScale = 8;
    for (var i = 0; i < size; i++) {
      if (nextScale != 0) {
        final delta = reader.readSignedExpGolomb();
        nextScale = (lastScale + delta + 256) % 256;
      }
      lastScale = nextScale == 0 ? lastScale : nextScale;
    }
  }
}

class _BitReader {
  _BitReader(this._data);

  final Uint8List _data;
  int _bitOffset = 0;

  int readBit() {
    if (_bitOffset >= _data.length * 8) {
      throw StateError('bit reader overflow');
    }
    final byte = _data[_bitOffset >> 3];
    final bit = (byte >> (7 - (_bitOffset & 7))) & 0x01;
    _bitOffset++;
    return bit;
  }

  int readBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 1) | readBit();
    }
    return value;
  }

  int readUnsignedExpGolomb() {
    var zeros = 0;
    while (readBit() == 0) {
      zeros++;
      if (zeros > 31) throw StateError('invalid exp golomb');
    }
    if (zeros == 0) return 0;
    return (1 << zeros) - 1 + readBits(zeros);
  }

  int readSignedExpGolomb() {
    final value = readUnsignedExpGolomb();
    return (value & 1) == 1 ? (value + 1) >> 1 : -(value >> 1);
  }
}
