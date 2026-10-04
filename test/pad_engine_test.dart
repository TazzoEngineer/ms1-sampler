import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms1_sampler/audio/loop_sequencer.dart';
import 'package:ms1_sampler/audio/pad_engine.dart';
import 'package:ms1_sampler/audio/sample.dart';

import 'support/fake_engine.dart';

Sample clip({int n = 4800, int rate = 48000}) => Sample(
  name: 'c',
  sampleRate: rate,
  pcm: Float32List(n)..fillRange(0, n, 0.3),
);

void main() {
  test('ループのパッドは押すたびに鳴らす/止めるが切り替わる', () async {
    final e = FakeEngine();
    await e.assign(0, clip(), 0, 4800, mode: PadMode.loop);
    expect(e.loopState(0), LoopState.off);
    await e.press(0);
    expect(e.loopState(0), LoopState.starting);
    e.sequencer.render(100);
    expect(e.loopState(0), LoopState.playing);
    expect(e.isPlaying(0), isTrue);
    await e.press(0);
    expect(e.loopState(0), LoopState.stopping);
  });

  test('ループの音は出力のレートに変換してシーケンサーに渡す', () async {
    final e = FakeEngine(sampleRate: 44100);
    await e.assign(0, clip(n: 48000), 0, 48000, mode: PadMode.loop);
    e.bpm = 60; // 1 拍 = 44100 フレーム → 1 秒の音はちょうど 1 拍
    await e.setLoopTiming(0, 1, 0);
    expect(e.sequencer.effectivePeriod(0), 1);
  });

  test('ループ以外にするとシーケンサーから外れる', () async {
    final e = FakeEngine();
    await e.assign(0, clip(), 0, 4800, mode: PadMode.loop);
    await e.press(0);
    await e.setMode(0, PadMode.oneShot);
    expect(e.loopState(0), LoopState.off);
    expect(e.sequencer.anyActive, isFalse);
  });

  test('空にするとループも止まる', () async {
    final e = FakeEngine();
    await e.assign(0, clip(), 0, 4800, mode: PadMode.loop);
    await e.press(0);
    await e.clear(0);
    expect(e.sequencer.anyActive, isFalse);
  });

  test('オフセットは周期の中に収める', () async {
    final e = FakeEngine();
    await e.assign(0, clip(), 0, 4800, mode: PadMode.loop);
    await e.setLoopTiming(0, 1, 3);
    expect(e.pads[0].offsetBeats, 0.75);
  });

  test('BPM は 30〜300 に収める', () {
    final e = FakeEngine();
    e.bpm = 1000;
    expect(e.bpm, 300);
    e.bpm = 1;
    expect(e.bpm, 30);
  });
}
