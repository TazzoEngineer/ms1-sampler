/// 1 小節の拍数（4/4 拍子のみ）。
const beatsPerBar = 4;

/// ループの周期として選べる長さ（拍）。1/4 拍〜4 小節。
const loopPeriods = <double>[0.25, 0.5, 1, 2, 4, 8, 16];

/// オフセットの刻み（16 分音符 = 1/4 拍）。
const offsetStep = 0.25;

/// 周期の表示名。
String periodLabel(double beats) {
  if (beats >= beatsPerBar) {
    final bars = beats / beatsPerBar;
    return '${_num(bars)} 小節';
  }
  return switch (beats) {
    0.25 => '16分',
    0.5 => '8分',
    _ => '${_num(beats)} 拍',
  };
}

/// オフセットの表示名（例: 1.5 → "1 拍 + 2/4"）。
String offsetLabel(double beats) {
  final whole = beats.floor();
  final sixteenths = ((beats - whole) / offsetStep).round();
  if (sixteenths == 0) return '$whole 拍';
  if (whole == 0) return '$sixteenths/4 拍';
  return '$whole 拍 + $sixteenths/4';
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// 1 拍のサンプル数。
double samplesPerBeat(double bpm, int sampleRate) => sampleRate * 60 / bpm;

/// 音の長さ [lengthBeats] とオフセットから、実際の周期（拍）を求める。
///
/// 音がオフセットから周期内に収まればそのまま [periodBeats]。はみ出す場合は
/// 鳴り終わったあとの最初の小節の頭まで延ばす（次の回は重ならない）。
double effectivePeriodBeats(
  double lengthBeats,
  double periodBeats,
  double offsetBeats,
) {
  const eps = 1e-9;
  final end = offsetBeats + lengthBeats;
  if (end <= periodBeats + eps) return periodBeats;
  final bars = ((end - eps) / beatsPerBar).ceil();
  return (bars * beatsPerBar).toDouble();
}

/// 長さ [frames] を [unit] フレームの倍数（最低 1 つ分）に丸め、[max] を越えない
/// 最大の倍数にする。
int snapToGrid(int frames, double unit, {required int max}) {
  var n = (frames / unit).round();
  if (n < 1) n = 1;
  while (n > 1 && (n * unit).round() > max) {
    n--;
  }
  return (n * unit).round().clamp(1, max);
}

/// タップした間隔から BPM を求める。
class TapTempo {
  TapTempo({this.maxTaps = 6, this.resetAfter = const Duration(seconds: 2)});

  final int maxTaps;
  final Duration resetAfter;
  final _taps = <Duration>[];

  /// [at] にタップした。2 回目以降は BPM を返す。
  double? tap(Duration at) {
    if (_taps.isNotEmpty && at - _taps.last > resetAfter) _taps.clear();
    _taps.add(at);
    if (_taps.length > maxTaps) _taps.removeAt(0);
    if (_taps.length < 2) return null;
    final span = _taps.last - _taps.first;
    final interval = span.inMicroseconds / (_taps.length - 1);
    return 60e6 / interval;
  }
}
