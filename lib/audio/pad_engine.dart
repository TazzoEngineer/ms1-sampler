import 'package:flutter_soloud/flutter_soloud.dart';

import 'sample.dart';
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
  AudioSource? source;
  SoundHandle? voice;
}

/// SoLoud を使った 16 パッドの発音エンジン。
class PadEngine {
  static const padCount = 16;

  final pads = List.generate(padCount, (_) => Pad());
  final _soloud = SoLoud.instance;
  AudioSource? _previewSource;
  SoundHandle? _previewVoice;
  int _loadCounter = 0;

  Future<void> init() async {
    if (!_soloud.isInitialized) {
      // バッファを小さくしてパッドを叩いてから鳴るまでの遅れを減らす
      await _soloud.init(bufferSize: 512, channels: Channels.stereo);
    }
  }

  Future<AudioSource> _load(Sample s) =>
      _soloud.loadMem('${s.name}#${_loadCounter++}.wav', encodeWav(s));

  Future<void> assign(
    int index,
    Sample original,
    int start,
    int end, {
    PadMode? mode,
  }) async {
    final pad = pads[index];
    await clear(index);
    pad.original = original;
    pad.start = start;
    pad.end = end;
    pad.sample = original.trimmed(start, end);
    if (mode != null) pad.mode = mode;
    pad.source = await _load(pad.sample!);
  }

  Future<void> clear(int index) async {
    final pad = pads[index];
    await _stopVoice(pad);
    if (pad.source != null) await _soloud.disposeSource(pad.source!);
    pad.source = null;
    pad.sample = null;
    pad.original = null;
  }

  /// パッドを押した。同じパッドの前の音は止める（チョーク）。
  /// ループモードでは鳴っている状態でもう一度押すと止まる。
  Future<void> press(int index) async {
    final pad = pads[index];
    final src = pad.source;
    if (src == null) return;
    if (pad.mode == PadMode.loop && _isPlaying(pad)) {
      await _stopVoice(pad);
      return;
    }
    await _stopVoice(pad);
    pad.voice = await _soloud.play(src, looping: pad.mode == PadMode.loop);
  }

  Future<void> release(int index) async {
    final pad = pads[index];
    if (pad.mode == PadMode.gate) await _stopVoice(pad);
  }

  bool isPlaying(int index) => _isPlaying(pads[index]);

  bool _isPlaying(Pad pad) =>
      pad.voice != null && _soloud.getIsValidVoiceHandle(pad.voice!);

  Future<void> _stopVoice(Pad pad) async {
    if (_isPlaying(pad)) await _soloud.stop(pad.voice!);
    pad.voice = null;
  }

  Future<void> stopAll() async {
    for (final p in pads) {
      await _stopVoice(p);
    }
    await stopPreview();
  }

  /// トリミング画面での試聴。
  Future<void> preview(Sample s, {bool loop = false}) async {
    await stopPreview();
    _previewSource = await _load(s);
    _previewVoice = await _soloud.play(_previewSource!, looping: loop);
  }

  Future<void> stopPreview() async {
    if (_previewVoice != null &&
        _soloud.getIsValidVoiceHandle(_previewVoice!)) {
      await _soloud.stop(_previewVoice!);
    }
    _previewVoice = null;
    if (_previewSource != null) await _soloud.disposeSource(_previewSource!);
    _previewSource = null;
  }

  /// 試聴の再生位置（サンプル数）。鳴っていなければ null。
  int? previewPosition(int sampleRate) {
    final v = _previewVoice;
    if (v == null || !_soloud.getIsValidVoiceHandle(v)) return null;
    return (_soloud.getPosition(v).inMicroseconds * sampleRate / 1000000)
        .round();
  }
}
