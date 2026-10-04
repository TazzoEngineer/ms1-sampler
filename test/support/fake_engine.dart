import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:ms1_sampler/audio/pad_engine.dart';
import 'package:ms1_sampler/audio/sample.dart';

/// SoLoud（ネイティブ）を使わない PadEngine。試聴の呼び出しを記録する。
class FakeEngine extends PadEngine {
  /// preview() に渡された音（長さを確かめる用）。
  final previews = <Sample>[];
  bool previewLoop = false;
  bool previewStopped = true;

  /// previewPosition() が返す値。null なら「鳴り終わった」。
  int? position = 0;

  @override
  Future<AudioSource?> loadSource(Sample s) async => null;

  @override
  Future<void> preview(Sample s, {bool loop = false}) async {
    previews.add(s);
    previewLoop = loop;
    previewStopped = false;
  }

  @override
  Future<void> stopPreview() async => previewStopped = true;

  @override
  int? previewPosition(int sampleRate) => previewStopped ? null : position;
}
