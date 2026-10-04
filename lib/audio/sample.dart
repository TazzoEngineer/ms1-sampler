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

  /// 最大振幅（0〜1）。
  double get peak {
    var p = 0.0;
    for (final v in pcm) {
      if (v.abs() > p) p = v.abs();
    }
    return p;
  }

  /// 最大振幅が [target] になるよう音量を揃える（ノーマライズ）。
  /// 無音（[floor] 未満）のときは持ち上げると雑音だけになるのでそのまま返す。
  Sample normalized({double target = 0.89, double floor = 1e-4}) {
    final p = peak;
    if (p < floor) return this;
    final g = target / p;
    final out = Float32List(length);
    for (var i = 0; i < length; i++) {
      out[i] = pcm[i] * g;
    }
    return Sample(name: name, pcm: out, sampleRate: sampleRate);
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
