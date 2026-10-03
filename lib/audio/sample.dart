import 'dart:math' as math;
import 'dart:typed_data';

/// モノラルの PCM サンプル（-1.0〜1.0 の float）。
class Sample {
  Sample({required this.name, required this.pcm, required this.sampleRate});

  final String name;
  final Float32List pcm;
  final int sampleRate;

  int get length => pcm.length;
  Duration get duration =>
      Duration(microseconds: (length * 1000000 / sampleRate).round());

  /// [start, end) を切り出す。境界のプチノイズを防ぐため短いフェードをかける。
  Sample trimmed(int start, int end, {String? name, double fadeMs = 3}) {
    start = start.clamp(0, length);
    end = end.clamp(start, length);
    final out = Float32List.fromList(pcm.sublist(start, end));
    final fade = math.min(
      (sampleRate * fadeMs / 1000).round(),
      out.length ~/ 2,
    );
    for (var i = 0; i < fade; i++) {
      final g = i / fade;
      out[i] *= g;
      out[out.length - 1 - i] *= g;
    }
    return Sample(name: name ?? this.name, pcm: out, sampleRate: sampleRate);
  }

  /// [pos] 付近（±[windowMs]）で最も近いゼロクロス位置を返す。
  int nearestZeroCrossing(int pos, {double windowMs = 5}) {
    final w = (sampleRate * windowMs / 1000).round();
    for (var d = 0; d <= w; d++) {
      for (final p in [pos - d, pos + d]) {
        if (p <= 0 || p >= length) continue;
        final a = pcm[p - 1], b = pcm[p];
        if ((a <= 0 && b >= 0) || (a >= 0 && b <= 0)) return p;
      }
    }
    return pos;
  }

  /// 音の立ち上がり（しきい値を超える最初の位置）を [from] 以降で探す。
  int findOnset(int from, {double threshold = 0.05}) {
    for (var i = from.clamp(0, length); i < length; i++) {
      if (pcm[i].abs() >= threshold) return i;
    }
    return from;
  }
}
