import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms1_sampler/audio/sample.dart';
import 'package:ms1_sampler/audio/wav.dart';

Sample sine({int n = 4410, int rate = 44100}) => Sample(
  name: 'sine',
  sampleRate: rate,
  pcm: Float32List.fromList(
    List.generate(n, (i) => 0.5 * math.sin(2 * math.pi * 440 * i / rate)),
  ),
);

void main() {
  test('WAV encode → decode round trip', () {
    final s = sine();
    final d = decodeWav(encodeWav(s), name: 'x');
    expect(d.sampleRate, 44100);
    expect(d.length, s.length);
    for (var i = 0; i < s.length; i += 97) {
      expect(d.pcm[i], closeTo(s.pcm[i], 1 / 16000));
    }
  });

  test('trimmed cuts range and fades edges', () {
    final s = sine();
    final t = s.trimmed(100, 1100);
    expect(t.length, 1000);
    expect(t.pcm.first, 0);
    expect(t.pcm.last.abs(), lessThan(0.01));
  });

  test('nearestZeroCrossing lands on a sign change', () {
    final s = sine();
    final p = s.nearestZeroCrossing(30);
    expect(s.pcm[p - 1].sign != s.pcm[p].sign || s.pcm[p] == 0, isTrue);
  });

  group('normalized (マイク録音のゲイン)', () {
    test('小さな音を最大振幅 0.89 まで持ち上げる', () {
      final quiet = Sample(
        name: 'q',
        sampleRate: 44100,
        pcm: Float32List.fromList([0.01, -0.02, 0.005]),
      );
      final n = quiet.normalized();
      expect(n.peak, closeTo(0.89, 1e-6));
      // 波形の形（比率）は変わらない
      expect(n.pcm[0] / n.pcm[1], closeTo(-0.5, 1e-6));
    });

    test('大きすぎる音は下げる', () {
      final loud = Sample(
        name: 'l',
        sampleRate: 44100,
        pcm: Float32List.fromList([1.0, -0.5]),
      );
      expect(loud.normalized().peak, closeTo(0.89, 1e-6));
    });

    test('無音は持ち上げない（雑音だけになるため）', () {
      final silent = Sample(
        name: 's',
        sampleRate: 44100,
        pcm: Float32List.fromList([0, 0.00001, -0.00001]),
      );
      expect(silent.normalized().peak, silent.peak);
    });
  });

  test('resampled: 44.1kHz → 48kHz で長さと波形が保たれる', () {
    final s = sine(n: 44100);
    final r = s.resampled(48000);
    expect(r.sampleRate, 48000);
    expect(r.length, 48000);
    // 同じ時刻の値がほぼ同じ（0.5 秒の位置）
    expect(r.pcm[24000], closeTo(s.pcm[22050], 0.01));
    expect(identical(s.resampled(44100), s), isTrue);
  });

  test('findOnset skips silence', () {
    final pcm = Float32List(1000)..[600] = 0.5;
    final s = Sample(name: 'x', pcm: pcm, sampleRate: 44100);
    expect(s.findOnset(0), 600);
  });
}
