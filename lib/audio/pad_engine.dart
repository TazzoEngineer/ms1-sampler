import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'loop_sequencer.dart';
import 'pad_store.dart';
import 'sample.dart';
import 'tempo.dart';
import 'wav.dart';

/// パッドの鳴らし方。
enum PadMode {
  oneShot('ワンショット'),
  gate('押している間'),
  loop('ループ');

  const PadMode(this.label);
  final String label;
}

class Pad {
  /// 切り出し元の音（再トリミング用）と、その切り出し範囲。
  Sample? original;
  int start = 0, end = 0;

  /// 実際に鳴らす（トリミング済みの）音。
  Sample? sample;
  PadMode mode = PadMode.oneShot;

  /// ループのときの周期とオフセット（拍）。
  double periodBeats = beatsPerBar.toDouble();
  double offsetBeats = 0;

  AudioSource? source;
  SoundHandle? voice;
}

/// SoLoud を使った 16 パッドの発音エンジン。
///
/// ワンショット / 押している間のパッドは SoLoud で直接鳴らす（叩いてすぐ鳴る）。
/// ループのパッドは [sequencer] が全体のテンポに合わせて並べた音を、
/// SoLoud のバッファストリームに少し先まで流し込んで鳴らす。
class PadEngine {
  PadEngine({this.sampleRate = 44100})
    : sequencer = LoopSequencer(sampleRate: sampleRate);

  static const padCount = 16;

  /// ループの音を先に作っておく長さ。短いほどループのオン/オフが早く反映されるが、
  /// アプリが一瞬止まったときに音が途切れやすくなる。
  static const loopLeadSeconds = 0.15;

  /// 出力のサンプリングレート（端末に合わせる。[outputSampleRate]）。
  final int sampleRate;
  final LoopSequencer sequencer;
  final pads = List.generate(padCount, (_) => Pad());

  /// 割り当てを保存する先。null なら保存しない。
  PadStore? store;
  Future<void> _saving = Future.value();

  // テストではネイティブの SoLoud を使わないよう、使うときに初めて取りに行く
  SoLoud get _soloud => SoLoud.instance;
  AudioSource? _previewSource;
  SoundHandle? _previewVoice;
  int _loadCounter = 0;

  AudioSource? _loopStream;

  /// [sampleRate] が端末の出力と違うと、Android は低遅延の経路を使わず、
  /// 叩いてから鳴るまで数百 ms 遅れる。
  Future<void> init() async {
    if (!_soloud.isInitialized) {
      await _soloud.init(
        sampleRate: sampleRate,
        bufferSize: 512,
        channels: Channels.stereo,
      );
    }
    await _startLoopStream();
  }

  /// 端末の出力のサンプリングレート。分からなければ null。
  static Future<int?> outputSampleRate() async {
    if (!Platform.isAndroid) return null;
    try {
      return await const MethodChannel(
        'ms1/audio',
      ).invokeMethod<int>('outputSampleRate');
    } on PlatformException {
      return null;
    }
  }

  // ---------------------------------------------------------------- テンポ

  double get bpm => sequencer.bpm;

  set bpm(double v) {
    final b = v.clamp(30.0, 300.0);
    sequencer.bpm = b;
    store?.settings['bpm'] = b;
    save();
  }

  /// 今聞こえている位置（拍）。ループが何も鳴っていなければ null。
  double? get currentBeat {
    final src = _loopStream;
    if (src == null || !sequencer.anyActive) return null;
    final played =
        _soloud.getStreamTimeConsumed(src).inMicroseconds * sampleRate / 1e6;
    return sequencer.beatAt(played.round());
  }

  // ---------------------------------------------------------------- 割り当て

  Future<AudioSource> _load(Sample s) =>
      _soloud.loadMem('${s.name}#${_loadCounter++}.wav', encodeWav(s));

  Future<void> assign(
    int index,
    Sample original,
    int start,
    int end, {
    PadMode? mode,
    double? periodBeats,
    double? offsetBeats,
    bool persist = true,
  }) async {
    final pad = pads[index];
    await _unload(index);
    pad.original = original;
    pad.start = start;
    pad.end = end;
    pad.sample = original.trimmed(start, end);
    if (mode != null) pad.mode = mode;
    if (periodBeats != null) pad.periodBeats = periodBeats;
    if (offsetBeats != null) pad.offsetBeats = offsetBeats;
    pad.source = await loadSource(pad.sample!);
    _syncLoop(index);
    if (persist) await save();
  }

  /// 保存されていた割り当てを戻す。
  Future<void> restore(List<SavedPad?> saved) async {
    for (var i = 0; i < saved.length && i < padCount; i++) {
      final p = saved[i];
      if (p == null) continue;
      await assign(
        i,
        p.original,
        p.start,
        p.end,
        mode: p.mode,
        periodBeats: p.periodBeats,
        offsetBeats: p.offsetBeats,
        persist: false,
      );
    }
  }

  Future<void> clear(int index) async {
    await _unload(index);
    await save();
  }

  Future<void> setMode(int index, PadMode mode) async {
    final pad = pads[index];
    if (pad.mode == mode) return;
    await _stopVoice(pad);
    pad.mode = mode;
    _syncLoop(index);
    await save();
  }

  /// ループの周期とオフセットを変える。鳴っていれば次の回から反映する。
  Future<void> setLoopTiming(int index, double period, double offset) async {
    final pad = pads[index];
    pad.periodBeats = period;
    pad.offsetBeats = offset.clamp(0, period - offsetStep).toDouble();
    _syncLoop(index);
    await save();
  }

  /// パッドの設定をシーケンサーに反映する。
  void _syncLoop(int index) {
    final pad = pads[index];
    final s = pad.sample;
    if (pad.mode != PadMode.loop || s == null) {
      sequencer.removeSound(index);
      return;
    }
    sequencer.setSound(
      index,
      s.resampled(sampleRate).pcm,
      periodBeats: pad.periodBeats,
      offsetBeats: pad.offsetBeats,
    );
  }

  /// 保存は順番に行う（前の保存が終わる前に次を始めない）。
  Future<void> save() {
    final s = store;
    if (s == null) return Future.value();
    return _saving = _saving
        .then((_) => s.save(pads))
        .catchError((Object e) => debugPrint('パッドの保存に失敗: $e'));
  }

  Future<void> _unload(int index) async {
    final pad = pads[index];
    await _stopVoice(pad);
    sequencer.removeSound(index);
    if (pad.source != null) await _soloud.disposeSource(pad.source!);
    pad.source = null;
    pad.sample = null;
    pad.original = null;
  }

  /// 鳴らせる形にして読み込む（テストでは差し替える）。
  Future<AudioSource?> loadSource(Sample s) => _load(s);

  // ---------------------------------------------------------------- 演奏

  /// パッドを押した。同じパッドの前の音は止める（チョーク）。
  /// ループのパッドは、押すたびに鳴らす/止めるを切り替える（小節の頭に揃う）。
  Future<void> press(int index) async {
    final pad = pads[index];
    if (pad.sample == null) return;
    if (pad.mode == PadMode.loop) {
      sequencer.toggle(index);
      return;
    }
    final src = pad.source;
    if (src == null) return;
    await _stopVoice(pad);
    pad.voice = await _soloud.play(src);
  }

  Future<void> release(int index) async {
    final pad = pads[index];
    if (pad.mode == PadMode.gate) await _stopVoice(pad);
  }

  /// 鳴っている（ループなら鳴っている・鳴り始め待ち・止まり待ち）か。
  bool isPlaying(int index) {
    final pad = pads[index];
    if (pad.mode == PadMode.loop) return loopState(index) != LoopState.off;
    return pad.voice != null && _soloud.getIsValidVoiceHandle(pad.voice!);
  }

  LoopState loopState(int index) => sequencer.state(index);

  Future<void> _stopVoice(Pad pad) async {
    final v = pad.voice;
    pad.voice = null;
    // SoLoud の stop() は止めたあと「止まった」通知が来るまで待つ（最大 300ms）。
    // 止める処理はその場で終わるので、待たずに次の音を鳴らす
    if (v != null && _soloud.getIsValidVoiceHandle(v)) {
      unawaited(_soloud.stop(v));
    }
  }

  Future<void> stopAll() async {
    for (final p in pads) {
      await _stopVoice(p);
    }
    sequencer.stopAll();
    await stopPreview();
  }

  // ---------------------------------------------------------------- ループの出力

  Future<void> _startLoopStream() async {
    if (_loopStream != null) return;
    final src = _soloud.setBufferStream(
      maxBufferSizeDuration: const Duration(seconds: 10),
      // 再生した分は捨てる（何時間鳴らしてもメモリが増えない）
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0.02,
      sampleRate: sampleRate,
      channels: Channels.mono,
      format: BufferType.f32le,
    );
    _loopStream = src;
    _feedLoop();
    await _soloud.play(src);
    // エンジンはアプリが終わるまで使うので止めない
    Timer.periodic(const Duration(milliseconds: 10), (_) => _feedLoop());
  }

  /// 再生した位置から [loopLeadSeconds] 先まで、ループの音を作って流し込む。
  void _feedLoop() {
    final src = _loopStream;
    if (src == null) return;
    final played =
        (_soloud.getStreamTimeConsumed(src).inMicroseconds * sampleRate / 1e6)
            .round();
    final need =
        played +
        (sampleRate * loopLeadSeconds).round() -
        sequencer.renderedFrames;
    if (need <= 0) return;
    final pcm = sequencer.render(need);
    _soloud.addAudioDataStream(src, pcm.buffer.asUint8List());
  }

  // ---------------------------------------------------------------- 試聴

  /// トリミング画面での試聴。
  Future<void> preview(Sample s, {bool loop = false}) async {
    await stopPreview();
    _previewSource = await _load(s);
    _previewVoice = await _soloud.play(_previewSource!, looping: loop);
  }

  Future<void> stopPreview() async {
    final v = _previewVoice;
    _previewVoice = null;
    if (v != null && _soloud.getIsValidVoiceHandle(v)) {
      unawaited(_soloud.stop(v)); // 理由は _stopVoice と同じ
    }
    final src = _previewSource;
    _previewSource = null;
    if (src != null) await _soloud.disposeSource(src);
  }

  /// 試聴の再生位置（サンプル数）。鳴っていなければ null。
  int? previewPosition(int sampleRate) {
    final v = _previewVoice;
    if (v == null || !_soloud.getIsValidVoiceHandle(v)) return null;
    return (_soloud.getPosition(v).inMicroseconds * sampleRate / 1000000)
        .round();
  }
}
