import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'sample.dart';
import 'wav.dart';

/// マイクから PCM をストリームで受け取り、メモリに貯める録音器。
///
/// 段階2で Android の再生音キャプチャを足すときも、同じく PCM ストリームを
/// 受け取る形にしてこのクラスと差し替えられるようにする。
class MicRecorder {
  static const sampleRate = 44100;

  final _rec = AudioRecorder();
  final _chunks = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;

  /// 録音中の入力レベル（0〜1）。
  final level = StreamController<double>.broadcast();

  bool get isRecording => _sub != null;

  Future<bool> start() async {
    if (!await _rec.hasPermission()) return false;
    _chunks.clear();
    final stream = await _rec.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        // 音楽を録るので音声向けの加工は全部切る
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.unprocessed,
        ),
      ),
    );
    _sub = stream.listen((chunk) {
      _chunks.add(chunk);
      final pcm = pcm16ToFloat(chunk);
      var peak = 0.0;
      for (final v in pcm) {
        if (v.abs() > peak) peak = v.abs();
      }
      level.add(peak);
    });
    return true;
  }

  Future<Sample?> stop({required String name}) async {
    if (_sub == null) return null;
    await _rec.stop();
    await _sub!.cancel();
    _sub = null;
    final bytes = _chunks.takeBytes();
    if (bytes.isEmpty) return null;
    return Sample(name: name, pcm: pcm16ToFloat(bytes), sampleRate: sampleRate);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _rec.dispose();
    await level.close();
  }
}
