import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../audio/pad_engine.dart';
import '../audio/playback_capture.dart';
import '../audio/recorder.dart';
import '../audio/sample.dart';
import '../audio/wav.dart';
import 'captures_page.dart';
import 'trim_page.dart';

enum _Source { playback, mic }

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.engine});
  final PadEngine engine;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  PadEngine get engine => widget.engine;
  final recorder = MicRecorder();
  StreamSubscription<double>? _levelSub;
  StreamSubscription<Map<String, Object?>>? _captureSub;
  Timer? _refresh;
  double level = 0;
  bool editMode = false;
  int _takeCount = 0;

  // 再生音の取り込み（Android 10 以降）
  bool captureSupported = false;
  _Source source = _Source.mic;
  bool connected = false;
  bool capturing = false; // 開始〜停止の録音中
  double captureLevel = 0;
  int snapshotSeconds = 20;
  int inboxCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _levelSub = recorder.level.stream.listen((v) => setState(() => level = v));
    // ループ中のパッドの点灯を更新する
    _refresh = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => mounted ? setState(() {}) : null,
    );
    _initCapture();
  }

  Future<void> _initCapture() async {
    if (!await PlaybackCapture.isSupported()) return;
    _captureSub = PlaybackCapture.events.listen(_onCaptureEvent);
    setState(() {
      captureSupported = true;
      source = _Source.playback;
    });
    await _syncCapture();
  }

  Future<void> _syncCapture() async {
    if (!captureSupported) return;
    final c = await PlaybackCapture.isConnected();
    final r = await PlaybackCapture.isRecording();
    final n = (await PlaybackCapture.listCaptures()).length;
    if (!mounted) return;
    setState(() {
      connected = c;
      capturing = r;
      inboxCount = n;
    });
  }

  void _onCaptureEvent(Map<String, Object?> e) {
    switch (e['type']) {
      case 'level':
        setState(() => captureLevel = (e['value'] as num).toDouble());
      case 'state':
        setState(() {
          connected = e['connected'] == true;
          if (!connected) {
            capturing = false;
            captureLevel = 0;
          }
        });
      case 'capture': // 通知のボタンで取り込んだ
        _syncCapture();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncCapture();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refresh?.cancel();
    _levelSub?.cancel();
    _captureSub?.cancel();
    recorder.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      if (!await PlaybackCapture.connect()) {
        _toast('取り込みが許可されませんでした');
        return;
      }
      await PlaybackCapture.setSnapshotSeconds(snapshotSeconds);
      setState(() => connected = true);
    } on PlatformException catch (e) {
      _toast('開始できませんでした: ${e.message}');
    }
  }

  Future<void> _snapshot() async {
    final f = await PlaybackCapture.snapshot(snapshotSeconds);
    if (f == null) {
      _toast('まだ音を受け取っていません');
      return;
    }
    await _openCapture(f);
  }

  Future<void> _toggleCaptureTake() async {
    if (!capturing) {
      if (await PlaybackCapture.startTake()) setState(() => capturing = true);
      return;
    }
    final f = await PlaybackCapture.stopTake();
    setState(() => capturing = false);
    if (f != null) await _openCapture(f);
  }

  Future<void> _openInbox() async {
    final f = await Navigator.push<File>(
      context,
      MaterialPageRoute(builder: (_) => const CapturesPage()),
    );
    await _syncCapture();
    if (f != null) await _openCapture(f);
  }

  Future<void> _openCapture(File f) async {
    await _syncCapture();
    final s = await PlaybackCapture.load(f);
    if (_isSilent(s)) {
      _toast('無音でした。再生元のアプリが録音を許可していない可能性があります');
    }
    await _openTrim(s);
  }

  bool _isSilent(Sample s) {
    for (final v in s.pcm) {
      if (v.abs() > 0.001) return false;
    }
    return true;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('MS-1 Sampler'),
        actions: [
          if (captureSupported)
            IconButton(
              tooltip: '取り込み一覧',
              icon: Badge(
                isLabelVisible: inboxCount > 0,
                label: Text('$inboxCount'),
                child: const Icon(Icons.inbox),
              ),
              onPressed: _openInbox,
            ),
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
              if (captureSupported) ...[
                SegmentedButton<_Source>(
                  segments: const [
                    ButtonSegment(
                      value: _Source.playback,
                      icon: Icon(Icons.speaker),
                      label: Text('再生音'),
                    ),
                    ButtonSegment(
                      value: _Source.mic,
                      icon: Icon(Icons.mic),
                      label: Text('マイク'),
                    ),
                  ],
                  selected: {source},
                  showSelectedIcon: false,
                  onSelectionChanged: rec || capturing
                      ? null
                      : (v) => setState(() => source = v.first),
                ),
                const SizedBox(height: 12),
              ],
              if (source == _Source.mic) ..._micControls(rec),
              if (source == _Source.playback) ..._playbackControls(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _micControls(bool rec) {
    final scheme = Theme.of(context).colorScheme;
    return [
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
    ];
  }

  List<Widget> _playbackControls() {
    final scheme = Theme.of(context).colorScheme;
    if (!connected) {
      return [
        const Text(
          '他のアプリで流している音を取り込みます。\n'
          '開始すると画面の録画の確認が出ますが、録るのは音だけです。',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 64,
          child: FilledButton.icon(
            icon: const Icon(Icons.hearing),
            label: const Text('再生音を聴き始める', style: TextStyle(fontSize: 18)),
            onPressed: _connect,
          ),
        ),
      ];
    }
    return [
      Row(
        children: [
          Expanded(child: LinearProgressIndicator(value: captureLevel)),
          IconButton(
            tooltip: '聴くのをやめる',
            icon: const Icon(Icons.hearing_disabled),
            onPressed: capturing ? null : PlaybackCapture.disconnect,
          ),
        ],
      ),
      Row(
        children: [
          const Text('直前'),
          const SizedBox(width: 8),
          Expanded(
            child: SegmentedButton<int>(
              segments: [
                5,
                10,
                20,
                30,
                60,
              ].map((s) => ButtonSegment(value: s, label: Text('$s'))).toList(),
              selected: {snapshotSeconds},
              showSelectedIcon: false,
              onSelectionChanged: (v) {
                setState(() => snapshotSeconds = v.first);
                PlaybackCapture.setSnapshotSeconds(v.first);
              },
            ),
          ),
          const SizedBox(width: 8),
          const Text('秒'),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            flex: 3,
            child: SizedBox(
              height: 64,
              child: FilledButton.icon(
                icon: const Icon(Icons.history),
                label: Text(
                  '直前 $snapshotSeconds 秒を取り込む',
                  style: const TextStyle(fontSize: 16),
                ),
                onPressed: capturing ? null : _snapshot,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 64,
              child: FilledButton.tonalIcon(
                style: capturing
                    ? FilledButton.styleFrom(
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                      )
                    : null,
                icon: Icon(capturing ? Icons.stop : Icons.fiber_manual_record),
                label: Text(capturing ? '停止' : '録音'),
                onPressed: _toggleCaptureTake,
              ),
            ),
          ),
        ],
      ),
    ];
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
