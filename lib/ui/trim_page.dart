import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../audio/pad_engine.dart';
import '../audio/sample.dart';

/// 波形を見ながら切り出し範囲を決め、パッドに割り当てる画面。
///
/// - 1本指で開始/終了ハンドルをドラッグ（ハンドル以外をドラッグすると表示を移動）
/// - 2本指ピンチで拡大縮小
/// - 離したときにゼロクロスへスナップ（ON/OFF 可）
class TrimPage extends StatefulWidget {
  const TrimPage({
    super.key,
    required this.engine,
    required this.sample,
    this.initialStart,
    this.initialEnd,
    this.targetPad,
  });

  final PadEngine engine;
  final Sample sample;
  final int? initialStart, initialEnd;

  /// パッドから編集に来た場合はそのパッドに割り当てる。
  final int? targetPad;

  @override
  State<TrimPage> createState() => _TrimPageState();
}

enum _Drag { none, start, end, view }

class _TrimPageState extends State<TrimPage> {
  Sample get s => widget.sample;

  late int selStart = widget.initialStart ?? 0;
  late int selEnd = widget.initialEnd ?? s.length;

  // 表示範囲: viewStart から 1px あたり spp サンプル
  double viewStart = 0;
  double spp = 1;
  double _width = 1;
  bool _fitted = false;

  bool snap = true;
  int beats = 4;
  bool loopPreview = false;
  int? playhead;
  Timer? _ticker;

  _Drag _drag = _Drag.none;
  double _dragSpp = 1, _dragFocalSample = 0;

  @override
  void dispose() {
    _ticker?.cancel();
    widget.engine.stopPreview();
    super.dispose();
  }

  double get _maxSpp => s.length / _width;

  void _fitAll() {
    spp = _maxSpp;
    viewStart = 0;
  }

  void _fitSelection() {
    final len = (selEnd - selStart).toDouble();
    spp = (len * 1.1 / _width).clamp(1.0, _maxSpp);
    viewStart = selStart - len * 0.05;
    _clampView();
  }

  void _clampView() {
    spp = spp.clamp(0.5, _maxSpp);
    viewStart = viewStart.clamp(0.0, math.max(0.0, s.length - _width * spp));
  }

  double _xOf(int sample) => (sample - viewStart) / spp;
  int _sampleAt(double x) => (viewStart + x * spp).round().clamp(0, s.length);

  void _onScaleStart(ScaleStartDetails d) {
    final x = d.localFocalPoint.dx;
    const grab = 28.0;
    if (d.pointerCount == 1 && (x - _xOf(selStart)).abs() < grab) {
      _drag = _Drag.start;
    } else if (d.pointerCount == 1 && (x - _xOf(selEnd)).abs() < grab) {
      _drag = _Drag.end;
    } else {
      _drag = _Drag.view;
      _dragSpp = spp;
      _dragFocalSample = viewStart + x * spp;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final x = d.localFocalPoint.dx;
    setState(() {
      switch (_drag) {
        case _Drag.start:
          selStart = _sampleAt(x).clamp(0, selEnd - 1);
        case _Drag.end:
          selEnd = _sampleAt(x).clamp(selStart + 1, s.length);
        case _Drag.view:
          spp = _dragSpp / d.scale;
          _clampView();
          viewStart = _dragFocalSample - x * spp;
          _clampView();
        case _Drag.none:
          break;
      }
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (snap) {
      setState(() {
        if (_drag == _Drag.start) selStart = s.nearestZeroCrossing(selStart);
        if (_drag == _Drag.end) selEnd = s.nearestZeroCrossing(selEnd);
      });
    }
    _drag = _Drag.none;
  }

  Future<void> _togglePreview() async {
    if (playhead != null) {
      await _stopPreview();
      return;
    }
    await widget.engine.preview(s.trimmed(selStart, selEnd), loop: loopPreview);
    _ticker = Timer.periodic(const Duration(milliseconds: 30), (_) {
      final pos = widget.engine.previewPosition(s.sampleRate);
      if (!mounted) return;
      setState(() => playhead = pos == null ? null : selStart + pos);
      if (pos == null) _ticker?.cancel();
    });
  }

  Future<void> _stopPreview() async {
    _ticker?.cancel();
    await widget.engine.stopPreview();
    if (mounted) setState(() => playhead = null);
  }

  void _nudge(bool isStart, int ms) {
    final d = (s.sampleRate * ms / 1000).round();
    setState(() {
      if (isStart) {
        selStart = (selStart + d).clamp(0, selEnd - 1);
      } else {
        selEnd = (selEnd + d).clamp(selStart + 1, s.length);
      }
    });
  }

  void _startToOnset() {
    setState(() {
      final p = s.findOnset(selStart);
      selStart = snap ? s.nearestZeroCrossing(p) : p;
      if (selStart >= selEnd) selEnd = s.length;
    });
  }

  Future<void> _assign() async {
    var pad = widget.targetPad;
    var mode = pad != null ? widget.engine.pads[pad].mode : PadMode.oneShot;
    if (pad == null) {
      final r = await showModalBottomSheet<(int, PadMode)>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _PadPicker(engine: widget.engine),
      );
      if (r == null) return;
      (pad, mode) = r;
    }
    await _stopPreview();
    await widget.engine.assign(pad, s, selStart, selEnd, mode: mode);
    if (mounted) Navigator.pop(context, true);
  }

  String _fmt(int samples) => '${(samples / s.sampleRate).toStringAsFixed(3)}s';

  @override
  Widget build(BuildContext context) {
    final selLen = selEnd - selStart;
    final bpm = beats * 60 / (selLen / s.sampleRate);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.name),
        actions: [
          IconButton(
            tooltip: '全体表示',
            icon: const Icon(Icons.zoom_out_map),
            onPressed: () => setState(_fitAll),
          ),
          IconButton(
            tooltip: '選択範囲に拡大',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: () => setState(_fitSelection),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            // 画面端は Android の「戻る」ジェスチャーと競合するので余白を取る
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: LayoutBuilder(
                builder: (context, c) {
                  _width = c.maxWidth;
                  if (!_fitted) {
                    _fitted = true;
                    _fitAll();
                  }
                  return GestureDetector(
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onScaleEnd: _onScaleEnd,
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _WavePainter(
                        s: s,
                        viewStart: viewStart,
                        spp: spp,
                        selStart: selStart,
                        selEnd: selEnd,
                        playhead: playhead,
                        scheme: Theme.of(context).colorScheme,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '開始 ${_fmt(selStart)}  /  終了 ${_fmt(selEnd)}  /  長さ ${_fmt(selLen)}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                _NudgeGroup(label: '開始', onNudge: (ms) => _nudge(true, ms)),
                _NudgeGroup(label: '終了', onNudge: (ms) => _nudge(false, ms)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(
                      label: const Text('ゼロクロス吸着'),
                      selected: snap,
                      onSelected: (v) => setState(() => snap = v),
                    ),
                    ActionChip(
                      avatar: const Icon(Icons.graphic_eq, size: 18),
                      label: const Text('頭を音の立ち上がりへ'),
                      onPressed: _startToOnset,
                    ),
                    FilterChip(
                      label: const Text('ループで試聴'),
                      selected: loopPreview,
                      onSelected: (v) => setState(() => loopPreview = v),
                    ),
                    DropdownButton<int>(
                      value: beats,
                      items: [1, 2, 4, 8, 16]
                          .map(
                            (b) =>
                                DropdownMenuItem(value: b, child: Text('$b 拍')),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => beats = v!),
                    ),
                    Text('≈ ${bpm.toStringAsFixed(1)} BPM'),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: Icon(
                          playhead != null ? Icons.stop : Icons.play_arrow,
                        ),
                        label: Text(playhead != null ? '停止' : '試聴'),
                        onPressed: _togglePreview,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.grid_view),
                        label: Text(
                          widget.targetPad != null
                              ? 'パッド ${widget.targetPad! + 1} に保存'
                              : '割り当て',
                        ),
                        onPressed: _assign,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NudgeGroup extends StatelessWidget {
  const _NudgeGroup({required this.label, required this.onNudge});
  final String label;
  final void Function(int ms) onNudge;

  @override
  Widget build(BuildContext context) {
    Widget b(String t, int ms) => Expanded(
      child: TextButton(
        style: TextButton.styleFrom(padding: EdgeInsets.zero),
        onPressed: () => onNudge(ms),
        child: Text(t),
      ),
    );
    return Row(
      children: [
        SizedBox(width: 40, child: Text(label)),
        b('-100ms', -100),
        b('-10', -10),
        b('-1', -1),
        b('+1', 1),
        b('+10', 10),
        b('+100ms', 100),
      ],
    );
  }
}

class _PadPicker extends StatefulWidget {
  const _PadPicker({required this.engine});
  final PadEngine engine;

  @override
  State<_PadPicker> createState() => _PadPickerState();
}

class _PadPickerState extends State<_PadPicker> {
  PadMode mode = PadMode.oneShot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<PadMode>(
              segments: PadMode.values
                  .map((m) => ButtonSegment(value: m, label: Text(m.label)))
                  .toList(),
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => mode = v.first),
            ),
            const SizedBox(height: 16),
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.4,
              children: List.generate(PadEngine.padCount, (i) {
                final used = widget.engine.pads[i].sample != null;
                return FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    backgroundColor: used
                        ? scheme.secondaryContainer
                        : scheme.surfaceContainerHighest,
                  ),
                  onPressed: () => Navigator.pop(context, (i, mode)),
                  child: Text(
                    '${i + 1}${used ? '\n(上書き)' : ''}',
                    textAlign: TextAlign.center,
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.s,
    required this.viewStart,
    required this.spp,
    required this.selStart,
    required this.selEnd,
    required this.playhead,
    required this.scheme,
  });

  final Sample s;
  final double viewStart, spp;
  final int selStart, selEnd;
  final int? playhead;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    double x(int smp) => (smp - viewStart) / spp;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = scheme.surfaceContainerLow,
    );

    // 選択範囲の外側を暗く
    final sx = x(selStart), ex = x(selEnd);
    canvas.drawRect(
      Rect.fromLTRB(sx, 0, ex, size.height),
      Paint()..color = scheme.primaryContainer.withValues(alpha: 0.5),
    );

    // 波形（1px ごとに min/max。間引いて計算量を抑える）
    final wave = Paint()
      ..color = scheme.primary
      ..strokeWidth = 1;
    final stride = math.max(1, (spp / 64).floor());
    for (var px = 0; px < size.width; px++) {
      final a = (viewStart + px * spp).floor();
      final b = math.min(s.length, (viewStart + (px + 1) * spp).ceil());
      if (a >= s.length) break;
      var lo = 0.0, hi = 0.0;
      for (var i = math.max(0, a); i < b; i += stride) {
        final v = s.pcm[i];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      canvas.drawLine(
        Offset(px + 0.5, mid - hi * mid),
        Offset(px + 0.5, mid - lo * mid + 1),
        wave,
      );
    }

    // ハンドル
    void handle(double hx, bool isStart) {
      final p = Paint()
        ..color = scheme.tertiary
        ..strokeWidth = 2;
      canvas.drawLine(Offset(hx, 0), Offset(hx, size.height), p);
      final tab = Rect.fromCenter(
        center: Offset(hx + (isStart ? 10 : -10), 18),
        width: 20,
        height: 36,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(tab, const Radius.circular(4)),
        p,
      );
    }

    handle(sx, true);
    handle(ex, false);

    if (playhead != null) {
      final px = x(playhead!);
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()
          ..color = scheme.error
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter o) =>
      o.viewStart != viewStart ||
      o.spp != spp ||
      o.selStart != selStart ||
      o.selEnd != selEnd ||
      o.playhead != playhead ||
      o.s != s;
}
