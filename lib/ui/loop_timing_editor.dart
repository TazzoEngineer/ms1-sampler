import 'package:flutter/material.dart';

import '../audio/pad_engine.dart';
import '../audio/tempo.dart';

/// ループのパッドの周期とオフセットを決める。
///
/// 周期: 16 分〜4 小節。オフセット: 周期の頭から 16 分音符単位でずらす。
/// 音が周期からはみ出す場合は、実際の周期（鳴り終わった後の小節の頭まで）も示す。
class LoopTimingEditor extends StatefulWidget {
  const LoopTimingEditor({
    super.key,
    required this.engine,
    required this.index,
    this.onChanged,
  });

  final PadEngine engine;
  final int index;
  final VoidCallback? onChanged;

  @override
  State<LoopTimingEditor> createState() => _LoopTimingEditorState();
}

class _LoopTimingEditorState extends State<LoopTimingEditor> {
  Pad get pad => widget.engine.pads[widget.index];

  Future<void> _set(double period, double offset) async {
    await widget.engine.setLoopTiming(widget.index, period, offset);
    if (mounted) setState(() {});
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final period = pad.periodBeats;
    final offset = pad.offsetBeats;
    final steps = (period / offsetStep).round();
    final effective = widget.engine.sequencer.effectivePeriod(widget.index);
    final lengthBeats = pad.sample == null
        ? 0.0
        : pad.sample!.duration.inMicroseconds / 1e6 * widget.engine.bpm / 60;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text('周期（音の長さ: ${lengthBeats.toStringAsFixed(2)} 拍）'),
          Wrap(
            spacing: 6,
            children: [
              for (final p in loopPeriods)
                ChoiceChip(
                  label: Text(periodLabel(p)),
                  selected: p == period,
                  onSelected: (_) =>
                      _set(p, offset.clamp(0, p - offsetStep).toDouble()),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text('オフセット: ${offsetLabel(offset)}'),
          if (steps > 1)
            Slider(
              key: const ValueKey('offset'),
              value: offset / offsetStep,
              min: 0,
              max: (steps - 1).toDouble(),
              divisions: steps - 1,
              label: offsetLabel(offset),
              onChanged: (v) => _set(period, v.round() * offsetStep),
            ),
          if (effective > period)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '音が周期より長いので、実際は ${periodLabel(effective)}ごとに鳴ります',
                style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
              ),
            ),
        ],
      ),
    );
  }
}
