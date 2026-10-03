import 'package:flutter/material.dart';

import 'audio/pad_engine.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final engine = PadEngine();
  await engine.init();
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
