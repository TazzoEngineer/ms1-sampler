import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/pad_engine.dart';
import '../audio/tempo.dart';

/// 全体のテンポ（BPM）と、今の拍の表示。
///
/// - −/＋ で 1 ずつ、数字をタップすると直接入力
/// - TAP を拍に合わせて数回叩くと、その間隔から BPM を決める
/// - ループが鳴っている間は、今が何拍目かを点で示す
class TempoBar extends StatefulWidget {
  const TempoBar({super.key, required this.engine, this.clock});

  final PadEngine engine;

  /// タップテンポ用の時計（テストで差し替える）。
  final Duration Function()? clock;

  @override
  State<TempoBar> createState() => _TempoBarState();
}

class _TempoBarState extends State<TempoBar> {
  final _tap = TapTempo();
  final _watch = Stopwatch()..start();
  Timer? _ticker;
  double? _beat;

  PadEngine get engine => widget.engine;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 40), (_) {
      final b = engine.currentBeat;
      if (b?.floor() != _beat?.floor() && mounted) setState(() => _beat = b);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _setBpm(double v) => setState(() => engine.bpm = v);

  void _onTap() {
    final now = widget.clock?.call() ?? _watch.elapsed;
    final bpm = _tap.tap(now);
    if (bpm != null) _setBpm((bpm * 10).round() / 10);
  }

  Future<void> _edit() async {
    final c = TextEditingController(text: _fmt(engine.bpm));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('BPM'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          onSubmitted: (t) => Navigator.pop(ctx, double.tryParse(t)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(c.text)),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (v != null) _setBpm(v);
  }

  static String _fmt(double bpm) =>
      bpm == bpm.roundToDouble() ? bpm.toInt().toString() : bpm.toString();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final beatInBar = _beat == null ? null : _beat!.floor() % beatsPerBar;
    return Row(
      children: [
        IconButton(
          tooltip: 'BPM を下げる',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove),
          onPressed: () => _setBpm(engine.bpm - 1),
        ),
        InkWell(
          onTap: _edit,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              'BPM ${_fmt(engine.bpm)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        IconButton(
          tooltip: 'BPM を上げる',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add),
          onPressed: () => _setBpm(engine.bpm + 1),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          onPressed: _onTap,
          child: const Text('TAP'),
        ),
        const Spacer(),
        for (var i = 0; i < beatsPerBar; i++)
          Container(
            key: ValueKey('beat$i'),
            width: 10,
            height: 10,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: beatInBar == i
                  ? (i == 0 ? scheme.tertiary : scheme.primary)
                  : scheme.surfaceContainerHighest,
            ),
          ),
      ],
    );
  }
}
