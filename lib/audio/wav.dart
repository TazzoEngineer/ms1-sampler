import 'dart:typed_data';

import 'sample.dart';

/// Sample を 16bit モノラル WAV にエンコードする。
Uint8List encodeWav(Sample s) {
  final dataLen = s.length * 2;
  final b = ByteData(44 + dataLen);
  void str(int off, String v) {
    for (var i = 0; i < v.length; i++) {
      b.setUint8(off + i, v.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, s.sampleRate, Endian.little);
  b.setUint32(28, s.sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < s.length; i++) {
    final v = (s.pcm[i].clamp(-1.0, 1.0) * 32767).round();
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}

/// WAV（PCM 8/16/24/32bit、float32）をデコードし、モノラルにミックスダウンする。
Sample decodeWav(Uint8List bytes, {required String name}) {
  final b = ByteData.sublistView(bytes);
  String str(int off, int len) =>
      String.fromCharCodes(bytes.sublist(off, off + len));
  if (bytes.length < 12 || str(0, 4) != 'RIFF' || str(8, 4) != 'WAVE') {
    throw const FormatException('WAV ファイルではありません');
  }
  int? format, channels, rate, bits;
  var off = 12;
  while (off + 8 <= bytes.length) {
    final id = str(off, 4);
    final size = b.getUint32(off + 4, Endian.little);
    final body = off + 8;
    if (id == 'fmt ') {
      format = b.getUint16(body, Endian.little);
      channels = b.getUint16(body + 2, Endian.little);
      rate = b.getUint32(body + 4, Endian.little);
      bits = b.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE && size >= 40) {
        format = b.getUint16(
          body + 24,
          Endian.little,
        ); // WAVE_FORMAT_EXTENSIBLE
      }
    } else if (id == 'data') {
      if (format == null) throw const FormatException('fmt チャンクがありません');
      final end = (body + size).clamp(0, bytes.length);
      return Sample(
        name: name,
        pcm: _toMono(b, body, end, format, channels!, bits!),
        sampleRate: rate!,
      );
    }
    off = body + size + (size & 1);
  }
  throw const FormatException('data チャンクがありません');
}

Float32List _toMono(
  ByteData b,
  int start,
  int end,
  int format,
  int ch,
  int bits,
) {
  final bps = bits ~/ 8;
  final frames = (end - start) ~/ (bps * ch);
  final out = Float32List(frames);
  double read(int p) {
    if (format == 3 && bits == 32) return b.getFloat32(p, Endian.little);
    switch (bits) {
      case 8:
        return (b.getUint8(p) - 128) / 128;
      case 16:
        return b.getInt16(p, Endian.little) / 32768;
      case 24:
        var v =
            b.getUint8(p) | b.getUint8(p + 1) << 8 | b.getUint8(p + 2) << 16;
        if (v & 0x800000 != 0) v -= 0x1000000;
        return v / 8388608;
      case 32:
        return b.getInt32(p, Endian.little) / 2147483648;
    }
    throw FormatException('未対応のビット深度: $bits');
  }

  for (var f = 0; f < frames; f++) {
    var sum = 0.0;
    for (var c = 0; c < ch; c++) {
      sum += read(start + (f * ch + c) * bps);
    }
    out[f] = sum / ch;
  }
  return out;
}

/// 16bit little-endian PCM のバイト列を float に変換する。
Float32List pcm16ToFloat(Uint8List bytes) {
  final b = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = b.getInt16(i * 2, Endian.little) / 32768;
  }
  return out;
}
