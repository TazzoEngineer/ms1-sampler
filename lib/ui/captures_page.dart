import 'dart:io';

import 'package:flutter/material.dart';

import '../audio/playback_capture.dart';

/// 取り込んだ再生音の一覧。選ぶとそのファイルを返す。
class CapturesPage extends StatefulWidget {
  const CapturesPage({super.key});

  @override
  State<CapturesPage> createState() => _CapturesPageState();
}

class _CapturesPageState extends State<CapturesPage> {
  List<File> files = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final f = await PlaybackCapture.listCaptures();
    if (mounted) setState(() => files = f);
  }

  String _len(File f) {
    final d = PlaybackCapture.durationOf(f);
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} 秒';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('取り込み一覧')),
      body: files.isEmpty
          ? const Center(child: Text('まだ取り込んだ音はありません'))
          : ListView.builder(
              itemCount: files.length,
              itemBuilder: (context, i) {
                final f = files[i];
                return Dismissible(
                  key: ValueKey(f.path),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Theme.of(context).colorScheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete),
                  ),
                  onDismissed: (_) {
                    f.deleteSync();
                    setState(() => files.removeAt(i));
                  },
                  child: ListTile(
                    leading: const Icon(Icons.graphic_eq),
                    title: Text(PlaybackCapture.captureName(f)),
                    subtitle: Text(_len(f)),
                    trailing: const Icon(Icons.content_cut),
                    onTap: () => Navigator.pop(context, f),
                  ),
                );
              },
            ),
    );
  }
}
