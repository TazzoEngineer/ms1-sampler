import 'dart:math' as math;
import 'dart:typed_data';

import 'tempo.dart';

enum LoopState {
  off,

  /// 次の小節の頭から鳴り始める。
  starting,
  playing,

  /// 次の小節の頭で止まる。
  stopping,
}

/// ループの各パッドを全体のテンポに合わせて鳴らし、モノラルの PCM を作る。
///
/// 音声エンジンには、[render] で作った音を少し先まで流し込む。サンプル単位で
/// 自分で並べるので、パッドごとに周期やオフセットが違ってもずれない。
///
/// 位置は「拍」で持ち、テンポを変えたときは今の位置を起点に計算し直す。
/// 拍 → フレームは毎回起点から計算するので、何小節鳴らしても誤差は溜まらない。
class LoopSequencer {
  LoopSequencer({required this.sampleRate, double bpm = 120}) : _bpm = bpm {
    _spb = samplesPerBeat(bpm, sampleRate);
  }

  final int sampleRate;

  /// 止めるときのフェード（プチノイズ防止）。
  static const fadeSeconds = 0.005;

  double _bpm;
  late double _spb;
  int _frame = 0; // ここまで作ったフレーム数
  double _anchorBeat = 0;
  int _anchorFrame = 0;

  final _slots = <int, _Slot>{};
  final _voices = <_Voice>[];

  double get bpm => _bpm;

  set bpm(double v) {
    if (v == _bpm) return;
    // 今の位置を起点にして、これから先だけ新しいテンポで数える
    _anchorBeat = beatAt(_frame);
    _anchorFrame = _frame;
    _bpm = v;
    _spb = samplesPerBeat(v, sampleRate);
  }

  /// ここまで作ったフレーム数。
  int get renderedFrames => _frame;

  double beatAt(int frame) => _anchorBeat + (frame - _anchorFrame) / _spb;

  int frameAt(double beat) =>
      _anchorFrame + ((beat - _anchorBeat) * _spb).round();

  /// パッドの音と周期を設定する。鳴っている途中なら次の回から反映する。
  /// [pcm] はモノラルで [sampleRate] にしておく。
  void setSound(
    int pad,
    Float32List pcm, {
    required double periodBeats,
    double offsetBeats = 0,
  }) {
    final s = _slots.putIfAbsent(pad, () => _Slot(pcm));
    s.pcm = pcm;
    s.period = periodBeats;
    s.offset = offsetBeats;
  }

  void removeSound(int pad) {
    _slots.remove(pad);
    _cut(pad, _frame);
  }

  LoopState state(int pad) => _slots[pad]?.state ?? LoopState.off;

  bool get anyActive => _slots.values.any((s) => s.state != LoopState.off);

  /// 実際の周期（音がはみ出すときは延びる）。
  double effectivePeriod(int pad) {
    final s = _slots[pad];
    if (s == null) return 0;
    return effectivePeriodBeats(s.pcm.length / _spb, s.period, s.offset);
  }

  /// 鳴らす。他に何も鳴っていなければすぐ、鳴っていれば次の小節の頭から。
  void start(int pad) {
    final s = _slots[pad];
    if (s == null) return;
    switch (s.state) {
      case LoopState.playing || LoopState.starting:
        return;
      case LoopState.stopping:
        s.state = LoopState.playing;
        s.stopBeat = null;
        return;
      case LoopState.off:
        if (!anyActive) {
          // 何も鳴っていないので、今の位置を 1 小節目の頭にする
          _anchorBeat = 0;
          _anchorFrame = _frame;
          s.cycleStart = 0;
        } else {
          s.cycleStart = _nextBar(beatAt(_frame));
        }
        s.state = LoopState.starting;
    }
  }

  /// 止める。次の小節の頭で切る（鳴り始める前なら取り消すだけ）。
  void stop(int pad) {
    final s = _slots[pad];
    if (s == null) return;
    switch (s.state) {
      case LoopState.off || LoopState.stopping:
        return;
      case LoopState.starting:
        s.state = LoopState.off;
      case LoopState.playing:
        s.state = LoopState.stopping;
        s.stopBeat = _nextBar(beatAt(_frame));
    }
  }

  void toggle(int pad) {
    final st = state(pad);
    if (st == LoopState.off || st == LoopState.stopping) {
      start(pad);
    } else {
      stop(pad);
    }
  }

  /// 全部すぐに止める。
  void stopAll() {
    for (final s in _slots.values) {
      s.state = LoopState.off;
      s.stopBeat = null;
    }
    for (final v in _voices) {
      v.stopFrame ??= _frame;
    }
  }

  static double _nextBar(double beat) =>
      (beat / beatsPerBar - 1e-9).ceil() * beatsPerBar.toDouble();

  /// 次の [frames] フレームを作る。
  Float32List render(int frames) {
    final start = _frame, end = _frame + frames;
    _schedule(start, end);
    final out = Float32List(frames);
    final fade = math.max(1, (sampleRate * fadeSeconds).round());
    for (final v in _voices) {
      final pcm = v.pcm;
      final stop = v.stopFrame;
      final from = math.max(start, v.startFrame);
      final to = math.min(
        end,
        math.min(v.startFrame + pcm.length, stop ?? end),
      );
      for (var f = from; f < to; f++) {
        var x = pcm[f - v.startFrame];
        if (stop != null && stop - f < fade) x *= (stop - f) / fade;
        out[f - start] += x;
      }
    }
    _voices.removeWhere(
      (v) =>
          v.startFrame + v.pcm.length <= end ||
          (v.stopFrame != null && v.stopFrame! <= end),
    );
    _frame = end;
    return out;
  }

  void _schedule(int start, int end) {
    for (final e in _slots.entries) {
      final pad = e.key, s = e.value;
      if (s.state == LoopState.off) continue;
      final stopFrame = s.stopBeat == null ? null : frameAt(s.stopBeat!);
      while (true) {
        final trigger = frameAt(s.cycleStart + s.offset);
        if (trigger >= end) break;
        if (stopFrame != null && trigger >= stopFrame) break;
        if (s.state == LoopState.starting) s.state = LoopState.playing;
        _voices.add(_Voice(pad, s.pcm, trigger));
        s.cycleStart += effectivePeriodBeats(
          s.pcm.length / _spb,
          s.period,
          s.offset,
        );
      }
      if (stopFrame != null && stopFrame < end) {
        _cut(pad, stopFrame);
        s.state = LoopState.off;
        s.stopBeat = null;
      }
    }
  }

  /// [pad] の鳴っている音を [frame] で止める（短いフェード付き）。
  void _cut(int pad, int frame) {
    for (final v in _voices) {
      if (v.pad == pad) {
        // render でフェードの分だけ手前から下げ、ちょうど [frame] で無音にする
        v.stopFrame = math.min(v.stopFrame ?? frame, frame);
      }
    }
  }
}

class _Slot {
  _Slot(this.pcm);
  Float32List pcm;
  double period = beatsPerBar.toDouble();
  double offset = 0;
  LoopState state = LoopState.off;
  double cycleStart = 0; // 次の回の周期の頭（拍）
  double? stopBeat;
}

class _Voice {
  _Voice(this.pad, this.pcm, this.startFrame);
  final int pad;
  final Float32List pcm;
  final int startFrame;
  int? stopFrame;
}
