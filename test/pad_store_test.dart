import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms1_sampler/audio/pad_engine.dart';
import 'package:ms1_sampler/audio/pad_store.dart';
import 'package:ms1_sampler/audio/sample.dart';

import 'support/fake_engine.dart';

Sample tone(String name, {int n = 2000, double freq = 440}) => Sample(
  name: name,
  sampleRate: 44100,
  pcm: Float32List.fromList(
    List.generate(n, (i) => 0.5 * math.sin(2 * math.pi * freq * i / 44100)),
  ),
);

List<String> origFiles(Directory d) =>
    d
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .where((n) => n.startsWith('orig_'))
        .toList()
      ..sort();

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('pads'));
  tearDown(() => dir.delete(recursive: true));

  /// アプリの起動をまねる: 保存先から読み込んだエンジンを作る。
  Future<FakeEngine> launch() async {
    final store = PadStore(dir);
    final engine = FakeEngine();
    await engine.restore(await store.load());
    engine.store = store;
    return engine;
  }

  test('割り当て・範囲・鳴らし方が再起動後も残る', () async {
    final e1 = await launch();
    final a = tone('ドラム');
    await e1.assign(0, a, 100, 900, mode: PadMode.loop);
    await e1.assign(5, tone('ベース', freq: 110), 0, 1500);
    await e1.setMode(5, PadMode.gate);

    final e2 = await launch();
    final p0 = e2.pads[0];
    expect(p0.original!.name, 'ドラム');
    expect(p0.original!.length, a.length);
    expect((p0.start, p0.end, p0.mode), (100, 900, PadMode.loop));
    expect(p0.sample!.length, 800);
    expect(p0.original!.pcm[123], closeTo(a.pcm[123], 1 / 16000));

    expect(e2.pads[5].mode, PadMode.gate);
    expect(e2.pads[5].end, 1500);
    for (final i in [1, 2, 3, 4, 6, 15]) {
      expect(e2.pads[i].original, isNull, reason: 'パッド $i は空のはず');
    }
  });

  test('空にしたパッドは再起動後も空で、元音源ファイルも消える', () async {
    final e1 = await launch();
    await e1.assign(2, tone('a'), 0, 1000);
    expect(origFiles(dir), hasLength(1));
    await e1.clear(2);
    expect(origFiles(dir), isEmpty);

    final e2 = await launch();
    expect(e2.pads[2].original, isNull);
  });

  test('同じ元音源を複数のパッドに割り当ててもファイルは 1 つ', () async {
    final e1 = await launch();
    final take = tone('テイク');
    await e1.assign(0, take, 0, 500);
    await e1.assign(1, take, 500, 1500);
    expect(origFiles(dir), hasLength(1));

    // 再起動後にトリミングし直しても増えない
    final e2 = await launch();
    await e2.assign(1, e2.pads[1].original!, 600, 1400);
    expect(origFiles(dir), hasLength(1));
    expect(identical(e2.pads[0].original, e2.pads[1].original), isTrue);
  });

  test('上書きした古い元音源は消える', () async {
    final e1 = await launch();
    await e1.assign(0, tone('old'), 0, 100);
    final before = origFiles(dir);
    await e1.assign(0, tone('new'), 0, 100);
    final after = origFiles(dir);
    expect(after, hasLength(1));
    expect(after, isNot(before));
  });

  test('ループの周期・オフセットも残る', () async {
    final e1 = await launch();
    await e1.assign(3, tone('snare'), 0, 1000, mode: PadMode.loop);
    await e1.setLoopTiming(3, 2, 1);

    final e2 = await launch();
    expect(e2.pads[3].periodBeats, 2);
    expect(e2.pads[3].offsetBeats, 1);
    // 戻したときにシーケンサーにも入っている
    expect(e2.sequencer.effectivePeriod(3), 2);
  });

  test('画面の設定も残る', () async {
    final e1 = await launch();
    e1.store!.settings['snapshotSeconds'] = 30;
    e1.store!.settings['source'] = 'mic';
    await e1.save();

    final e2 = await launch();
    expect(e2.store!.settings, {'snapshotSeconds': 30, 'source': 'mic'});
  });

  test('pads.json が壊れていても起動できる（空として扱う）', () async {
    File('${dir.path}/pads.json').writeAsStringSync('{壊れた');
    final e = await launch();
    expect(e.pads.every((p) => p.original == null), isTrue);
  });

  test('元音源ファイルが消えていたらそのパッドだけ空になる', () async {
    final e1 = await launch();
    await e1.assign(0, tone('a'), 0, 100);
    await e1.assign(1, tone('b'), 0, 100);
    File('${dir.path}/${origFiles(dir).first}').deleteSync();

    final e2 = await launch();
    expect(e2.pads.where((p) => p.original != null), hasLength(1));
  });

  test('保存先がまだないときも保存できる', () async {
    final store = PadStore(Directory('${dir.path}/sub/pads'));
    final engine = FakeEngine()..store = store;
    await engine.assign(0, tone('a'), 0, 100);
    expect(File('${dir.path}/sub/pads/pads.json').existsSync(), isTrue);
  });
}
