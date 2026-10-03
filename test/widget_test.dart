import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms1_sampler/audio/sample.dart';
import 'package:ms1_sampler/audio/wav.dart';

Sample sine({int n = 4410, int rate = 44100}) => Sample(
      name: 'sine',
      sampleRate: rate,
      pcm: Float32List.fromList(
          List.generate(n, (i) => 0.5 * math.sin(2 * math.pi * 440 * i / rate))),
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

  test('findOnset skips silence', () {
    final pcm = Float32List(1000)..[600] = 0.5;
    final s = Sample(name: 'x', pcm: pcm, sampleRate: 44100);
    expect(s.findOnset(0), 600);
  });
}
