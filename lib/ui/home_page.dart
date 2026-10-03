import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../audio/pad_engine.dart';
import '../audio/recorder.dart';
import '../audio/sample.dart';
import '../audio/wav.dart';
import 'trim_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.engine});
  final PadEngine engine;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  PadEngine get engine => widget.engine;
  final recorder = MicRecorder();
  StreamSubscription<double>? _levelSub;
  Timer? _refresh;
  double level = 0;
  bool editMode = false;
  int _takeCount = 0;

  @override
  void initState() {
    super.initState();
    _levelSub = recorder.level.stream.listen((v) => setState(() => level = v));
    // ループ中のパッドの点灯を更新する
    _refresh = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _levelSub?.cancel();
    recorder.dispose();
    super.dispose();
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _toggleRecord() async {
    if (!recorder.isRecording) {
      if (!await recorder.start()) {
        _toast('マイクの権限がありません');
        return;
      }
      setState(() {});
      return;
    }
    final take = await recorder.stop(name: 'テイク ${++_takeCount}');
    setState(() => level = 0);
    if (take == null) return;
    await _openTrim(take);
  }

  Future<void> _import() async {
    final r = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav'],
      withData: true,
    );
    final f = r?.files.single;
    if (f == null) return;
    try {
      final bytes = f.bytes ?? await File(f.path!).readAsBytes();
      await _openTrim(decodeWav(bytes, name: f.name));
    } on FormatException catch (e) {
      _toast('読み込めませんでした: ${e.message}');
    }
  }

  Future<void> _openTrim(Sample s, {int? pad}) async {
    final p = pad == null ? null : engine.pads[pad];
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TrimPage(
          engine: engine,
          sample: s,
          targetPad: pad,
          initialStart: p?.start,
          initialEnd: p?.end,
        ),
      ),
    );
    setState(() {});
  }

  Future<void> _editPad(int i) async {
    final pad = engine.pads[i];
    if (pad.original == null) {
      _toast('空のパッドです。録音か読み込みで音を割り当ててください');
      return;
    }
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (ctx, setSheet) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(title: Text('パッド ${i + 1}: ${pad.sample!.name}')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<PadMode>(
                    segments: PadMode.values
                        .map(
                          (m) => ButtonSegment(value: m, label: Text(m.label)),
                        )
                        .toList(),
                    selected: {pad.mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) {
                      setSheet(() => pad.mode = v.first);
                      setState(() {});
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.content_cut),
                  title: const Text('トリミングし直す'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openTrim(pad.original!, pad: i);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('パッドを空にする'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await engine.clear(i);
                    setState(() {});
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rec = recorder.isRecording;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MS-1 Sampler'),
        actions: [
          IconButton(
            tooltip: 'WAV を読み込む',
            icon: const Icon(Icons.file_open),
            onPressed: rec ? null : _import,
          ),
          IconButton(
            tooltip: '全部止める',
            icon: const Icon(Icons.stop_circle_outlined),
            onPressed: engine.stopAll,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          icon: Icon(Icons.touch_app),
                          label: Text('演奏'),
                        ),
                        ButtonSegment(
                          value: true,
                          icon: Icon(Icons.tune),
                          label: Text('編集'),
                        ),
                      ],
                      selected: {editMode},
                      onSelectionChanged: (v) =>
                          setState(() => editMode = v.first),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: GridView.count(
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 4,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: List.generate(PadEngine.padCount, _buildPad),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: rec ? level : 0),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 64,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: rec ? scheme.error : scheme.primary,
                  ),
                  icon: Icon(rec ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(
                    rec ? '録音停止 → トリミングへ' : 'マイクで録音',
                    style: const TextStyle(fontSize: 18),
                  ),
                  onPressed: _toggleRecord,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPad(int i) {
    final pad = engine.pads[i];
    final scheme = Theme.of(context).colorScheme;
    final has = pad.sample != null;
    final playing = engine.isPlaying(i);
    final color = playing
        ? scheme.tertiary
        : has
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final fg = playing ? scheme.onTertiary : scheme.onPrimaryContainer;

    final body = AnimatedContainer(
      duration: const Duration(milliseconds: 60),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: editMode ? Border.all(color: scheme.outline, width: 2) : null,
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${i + 1}',
            style: TextStyle(color: fg, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          if (has)
            Text(
              pad.mode == PadMode.loop
                  ? '⟲ ループ'
                  : pad.mode == PadMode.gate
                  ? '▮ ゲート'
                  : '',
              style: TextStyle(color: fg, fontSize: 11),
            ),
        ],
      ),
    );

    if (editMode) {
      return GestureDetector(onTap: () => _editPad(i), child: body);
    }
    // onTap だと判定待ちで遅れるので、指が触れた瞬間に鳴らす
    return Listener(
      onPointerDown: (_) async {
        await engine.press(i);
        setState(() {});
      },
      onPointerUp: (_) => engine.release(i),
      onPointerCancel: (_) => engine.release(i),
      child: body,
    );
  }
}
