import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'audio/pad_engine.dart';
import 'audio/pad_store.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final engine = PadEngine(
    sampleRate: await PadEngine.outputSampleRate() ?? 44100,
  );
  await engine.init();
  final docs = await getApplicationDocumentsDirectory();
  final store = PadStore(Directory('${docs.path}/pads'));
  await engine.restore(await store.load());
  final bpm = store.settings['bpm'];
  if (bpm is num) engine.sequencer.bpm = bpm.toDouble();
  engine.store = store;
  runApp(Ms1App(engine: engine));
}

class Ms1App extends StatelessWidget {
  const Ms1App({super.key, required this.engine});
  final PadEngine engine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MS-1 Sampler',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepOrange,
          brightness: Brightness.dark,
        ),
      ),
      home: HomePage(engine: engine),
    );
  }
}
