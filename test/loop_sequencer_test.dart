import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms1_sampler/audio/loop_sequencer.dart';
import 'package:ms1_sampler/audio/tempo.dart';

// 120 BPM・1 拍 = 1000 フレームになるようにする（計算を読みやすくするため）
const rate = 2000;
const beat = 1000;
const bar = beat * beatsPerBar;

/// 先頭が 1.0、残りが 0.5 の音（鳴り始めの位置を見つけやすい）。
Float32List hit(int frames) => Float32List(frames)
  ..fillRange(0, frames, 0.5)
  ..[0] = 1.0;

/// [seq] を [frames] だけ回し、音の鳴り始め（1.0 の位置）を返す。
List<int> onsets(LoopSequencer seq, int frames, {int block = 333}) {
  final found = <int>[];
  var done = 0;
  while (done < frames) {
    final n = (frames - done).clamp(0, block);
    final base = seq.renderedFrames;
    final out = seq.render(n);
    for (var i = 0; i < n; i++) {
      if (out[i] >= 0.99) found.add(base + i);
    }
    done += n;
  }
  return found;
}

void main() {
  LoopSequencer make() => LoopSequencer(sampleRate: rate, bpm: 120);

  group('effectivePeriodBeats（音がはみ出すときの周期）', () {
    test('周期に収まればそのまま', () {
      expect(effectivePeriodBeats(1.5, 2, 0.5), 2);
      expect(effectivePeriodBeats(0.2, 0.25, 0), 0.25);
    });
    test('はみ出したら、鳴り終わった後の最初の小節の頭まで延ばす', () {
      expect(effectivePeriodBeats(6, 4, 0), 8); // 1 小節の周期に 6 拍 → 2 小節
      expect(effectivePeriodBeats(3, 2, 0), 4); // 2 拍の周期に 3 拍 → 1 小節
      expect(effectivePeriodBeats(1, 2, 1.5), 4); // オフセット込みではみ出す
      expect(effectivePeriodBeats(9, 8, 0), 12); // 2 小節に 9 拍 → 3 小節
    });
    test('ちょうど小節の長さなら延ばさない', () {
      expect(effectivePeriodBeats(8, 4, 0), 8);
    });
  });

  group('LoopSequencer', () {
    test('何も鳴っていなければすぐ鳴り始め、周期ごとに繰り返す', () {
      final seq = make()..render(123);
      seq.setSound(0, hit(100), periodBeats: 1);
      seq.start(0);
      expect(seq.state(0), LoopState.starting);
      expect(onsets(seq, bar), [123, 1123, 2123, 3123]);
      expect(seq.state(0), LoopState.playing);
    });

    test('オフセットの分だけ遅れて鳴る（2 拍目と 4 拍目のスネア）', () {
      final seq = make();
      seq.setSound(0, hit(100), periodBeats: 2, offsetBeats: 1);
      seq.start(0);
      expect(onsets(seq, bar * 2), [1000, 3000, 5000, 7000]);
    });

    test('他のループが鳴っていれば、次の小節の頭から鳴り始める', () {
      final seq = make();
      seq.setSound(0, hit(100), periodBeats: 4);
      seq.setSound(1, hit(50)..[0] = 1.0, periodBeats: 1);
      seq.start(0);
      seq.render(1500); // 2 拍目の途中
      seq.start(1);
      expect(seq.state(1), LoopState.starting);
      final o = onsets(seq, bar * 2 - 1500);
      // パッド 0 は 4000, 8000、パッド 1 は 4000 から毎拍（4000 は重なって 2.0）
      expect(o, containsAll([5000, 6000, 7000]));
      expect(o.where((f) => f < 4000), isEmpty);
    });

    test('音が周期より長いと、鳴り終わった後の小節の頭まで次を待つ', () {
      final seq = make();
      seq.setSound(0, hit(6 * beat), periodBeats: 4); // 1 小節の周期に 6 拍
      seq.start(0);
      expect(seq.effectivePeriod(0), 8);
      expect(onsets(seq, bar * 5), [0, 8000, 16000]);
    });

    test('止めると次の小節の頭で切れ、その後は鳴らない', () {
      final seq = make();
      seq.setSound(0, hit(3 * beat), periodBeats: 4);
      seq.start(0);
      seq.render(1500);
      seq.stop(0);
      expect(seq.state(0), LoopState.stopping);
      final rest = seq.render(bar * 2 - 1500);
      expect(seq.state(0), LoopState.off);
      // 4000 フレーム（次の小節の頭）以降は無音
      final after = rest.sublist(bar - 1500);
      expect(after.every((x) => x == 0), isTrue);
      // 切る直前はフェードしている
      expect(rest[bar - 1500 - 1].abs(), lessThan(0.05));
    });

    test('鳴り始める前に止めれば取り消すだけ', () {
      final seq = make();
      seq.setSound(0, hit(100), periodBeats: 4);
      seq.setSound(1, hit(100), periodBeats: 4);
      seq.start(0);
      seq.render(100);
      seq.start(1);
      seq.stop(1);
      expect(seq.state(1), LoopState.off);
      expect(onsets(seq, bar * 2), [4000, 8000]); // パッド 0 だけ
    });

    test('止める予約中にもう一度押すと、止めずに鳴り続ける', () {
      final seq = make();
      seq.setSound(0, hit(100), periodBeats: 1);
      seq.start(0);
      seq.render(500);
      seq.toggle(0);
      expect(seq.state(0), LoopState.stopping);
      seq.toggle(0);
      expect(seq.state(0), LoopState.playing);
      // 0 は最初の render で鳴った。その後も 1 拍ごとに鳴り続ける
      expect(onsets(seq, bar * 2 - 500), [
        1000,
        2000,
        3000,
        4000,
        5000,
        6000,
        7000,
      ]);
    });

    test('テンポを変えても、それまでの位置は保ったまま新しい間隔になる', () {
      final seq = make();
      seq.setSound(0, hit(100), periodBeats: 1);
      seq.start(0);
      expect(onsets(seq, 2500), [0, 1000, 2000]);
      seq.bpm = 60; // 2.5 拍目（2500）から 1 拍 = 2000 フレーム
      expect(onsets(seq, 6000), [3500, 5500, 7500]);
    });

    test('長く鳴らしても拍の位置がずれない（端数のあるテンポ）', () {
      final seq = LoopSequencer(sampleRate: 48000, bpm: 93.7);
      seq.setSound(0, hit(10), periodBeats: 1);
      seq.start(0);
      final spb = samplesPerBeat(93.7, 48000);
      final o = onsets(seq, (spb * 200).ceil() + 1, block: 960);
      expect(o, hasLength(201));
      for (var i = 0; i < o.length; i++) {
        expect((o[i] - i * spb).abs(), lessThanOrEqualTo(0.5));
      }
    });

    test('ブロックの区切り方を変えても同じ音になる', () {
      Float32List run(int block) {
        final seq = make();
        seq.setSound(0, hit(700), periodBeats: 0.5, offsetBeats: 0.25);
        seq.setSound(1, hit(2500), periodBeats: 2);
        seq.start(0);
        seq.start(1);
        final out = <double>[];
        while (out.length < bar * 2) {
          out.addAll(seq.render(block));
        }
        return Float32List.fromList(out.sublist(0, bar * 2));
      }

      expect(run(64), run(997));
    });

    test('鳴っている途中で音を差し替えると次の回から反映する', () {
      final seq = make();
      seq.setSound(0, hit(100), periodBeats: 1);
      seq.start(0);
      seq.render(500);
      seq.setSound(0, hit(100), periodBeats: 2);
      expect(onsets(seq, bar * 2 - 500), [1000, 3000, 5000, 7000]);
    });

    test('stopAll ですぐ全部止まる', () {
      final seq = make();
      seq.setSound(0, hit(3000), periodBeats: 4);
      seq.start(0);
      seq.render(500);
      seq.stopAll();
      expect(seq.anyActive, isFalse);
      final out = seq.render(1000);
      expect(out.every((x) => x == 0), isTrue);
    });
  });

  group('TapTempo', () {
    test('タップの間隔から BPM を出す', () {
      final t = TapTempo();
      expect(t.tap(Duration.zero), isNull);
      expect(t.tap(const Duration(milliseconds: 500)), closeTo(120, 1e-6));
      expect(t.tap(const Duration(milliseconds: 1000)), closeTo(120, 1e-6));
    });
    test('間が空いたら数え直す', () {
      final t = TapTempo();
      t.tap(Duration.zero);
      t.tap(const Duration(milliseconds: 500));
      expect(t.tap(const Duration(seconds: 5)), isNull);
      expect(
        t.tap(const Duration(seconds: 5, milliseconds: 750)),
        closeTo(80, 1e-6),
      );
    });
  });

  group('snapToGrid（トリムの長さを拍に揃える）', () {
    test('近い倍数に丸める', () {
      expect(snapToGrid(1100, 250, max: 10000), 1000);
      expect(snapToGrid(1130, 250, max: 10000), 1250);
    });
    test('最低 1 つ分', () {
      expect(snapToGrid(10, 250, max: 10000), 250);
    });
    test('音の残りより長くはしない', () {
      expect(snapToGrid(1240, 250, max: 1200), 1000);
    });
    test('端数のある単位でも丸めた結果は整数', () {
      expect(snapToGrid(7000, 7173.9, max: 100000), 7174);
    });
  });

  group('表示', () {
    test('周期とオフセットの表示名', () {
      expect(periodLabel(0.25), '16分');
      expect(periodLabel(1), '1 拍');
      expect(periodLabel(8), '2 小節');
      expect(offsetLabel(0), '0 拍');
      expect(offsetLabel(0.5), '2/4 拍');
      expect(offsetLabel(1.75), '1 拍 + 3/4');
    });
  });
}
