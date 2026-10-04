import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms1_sampler/audio/pad_engine.dart';
import 'package:ms1_sampler/audio/sample.dart';
import 'package:ms1_sampler/ui/trim_page.dart';

import 'support/fake_engine.dart';

const rate = 44100;

/// 1 秒の 440Hz。
Sample tone() => Sample(
  name: 'テイク',
  sampleRate: rate,
  pcm: Float32List.fromList(
    List.generate(rate, (i) => 0.5 * math.sin(2 * math.pi * 440 * i / rate)),
  ),
);

void main() {
  group('previewPlayhead（試聴カーソルの位置）', () {
    test('ループ中は先頭に戻り、範囲の外に出ない', () {
      expect(previewPlayhead(250, 1000, 100, loop: true), 1050);
      expect(previewPlayhead(100, 1000, 100, loop: true), 1000);
    });

    test('ループでなくても先読みで長さを越えた分は終端に止める', () {
      expect(previewPlayhead(130, 1000, 100, loop: false), 1100);
      expect(previewPlayhead(-5, 1000, 100, loop: false), 1000);
    });

    test('長さ 0 でも落ちない', () {
      expect(previewPlayhead(10, 1000, 0, loop: true), 1000);
    });
  });

  group('TrimPage', () {
    late FakeEngine engine;

    // 実機（1080x2220, 440dpi）と同じ論理サイズで描く。はみ出しがあればテストが落ちる
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2220);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      engine = FakeEngine();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TrimPage(engine: engine, sample: tone()),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> tick(WidgetTester tester) =>
        tester.pump(const Duration(milliseconds: 40));

    Future<void> close(WidgetTester tester) async {
      // 試聴のタイマーを止めるために画面を破棄する
      await tester.pumpWidget(const SizedBox());
    }

    testWidgets('試聴中に終了位置を微調整すると、新しい範囲で鳴らし直す', (tester) async {
      await open(tester);
      await tester.tap(find.text('試聴'));
      await tick(tester);
      expect(engine.previews, hasLength(1));
      expect(engine.previews.last.length, rate);

      await tester.tap(find.text('-100ms').last); // 終了の行
      await tick(tester);
      expect(engine.previews, hasLength(2));
      expect(engine.previews.last.length, rate - rate ~/ 10);
      await close(tester);
    });

    testWidgets('試聴中に終了ハンドルをドラッグで縮めると、新しい範囲で鳴らし直す', (tester) async {
      await open(tester);
      await tester.tap(find.text('試聴'));
      await tick(tester);

      final wave = tester.getRect(find.byKey(const ValueKey('waveform')));
      await tester.timedDragFrom(
        Offset(wave.right - 2, wave.center.dy),
        Offset(-wave.width / 2, 0),
        const Duration(milliseconds: 300),
      );
      await tick(tester);
      expect(engine.previews, hasLength(2));
      final len = engine.previews.last.length;
      expect(len, inInclusiveRange(rate * 0.4, rate * 0.6));
      await close(tester);
    });

    testWidgets('試聴していないときは範囲を変えても鳴らさない', (tester) async {
      await open(tester);
      await tester.tap(find.text('-100ms').last);
      await tester.tap(find.text('頭を音の立ち上がりへ'));
      await tick(tester);
      expect(engine.previews, isEmpty);
      await close(tester);
    });

    testWidgets('ループ試聴に切り替えると鳴らし直す', (tester) async {
      await open(tester);
      await tester.tap(find.text('試聴'));
      await tick(tester);
      expect(engine.previewLoop, isFalse);
      await tester.tap(find.text('ループで試聴'));
      await tick(tester);
      expect(engine.previews, hasLength(2));
      expect(engine.previewLoop, isTrue);
      await close(tester);
    });

    testWidgets('鳴り終わったら「試聴」に戻り、もう一度押すと鳴る', (tester) async {
      await open(tester);
      await tester.tap(find.text('試聴'));
      await tick(tester);
      expect(find.text('停止'), findsOneWidget);

      engine.previewStopped = true; // 最後まで鳴った
      await tick(tester);
      expect(find.text('試聴'), findsOneWidget);

      await tester.tap(find.text('試聴'));
      await tick(tester);
      expect(engine.previews, hasLength(2));
      await close(tester);
    });

    testWidgets('「試聴」を素早く 2 回押すと止まる（二重に鳴らない）', (tester) async {
      await open(tester);
      await tester.tap(find.text('試聴'));
      await tester.pump();
      await tester.tap(find.text('停止'));
      await tick(tester);
      expect(engine.previews, hasLength(1));
      expect(engine.previewStopped, isTrue);
      await close(tester);
    });

    testWidgets('割り当て: 選んだパッドに範囲と鳴らし方が入り、画面が閉じる', (tester) async {
      await open(tester);
      await tester.tap(find.text('-100ms').last);
      await tester.tap(find.text('割り当て'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ループ'));
      await tester.pump();
      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();

      final pad = engine.pads[2];
      expect(pad.mode, PadMode.loop);
      expect(pad.start, 0);
      expect(pad.end, rate - rate ~/ 10);
      expect(find.text('open'), findsOneWidget); // トリミング画面は閉じた
    });
  });
}
