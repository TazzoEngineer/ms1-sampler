import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms1_sampler/audio/pad_engine.dart';
import 'package:ms1_sampler/audio/sample.dart';
import 'package:ms1_sampler/ui/loop_timing_editor.dart';
import 'package:ms1_sampler/ui/tempo_bar.dart';

import 'support/fake_engine.dart';

/// 実機と同じ論理サイズで描く（はみ出しがあれば落ちる）。
Future<void> pumpPhone(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1080, 2220);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(padding: const EdgeInsets.all(12), child: child),
        ),
      ),
    ),
  );
}

void main() {
  group('TempoBar', () {
    testWidgets('−/＋ で 1 ずつ変わる', (tester) async {
      final e = FakeEngine();
      await pumpPhone(tester, TempoBar(engine: e));
      expect(find.text('BPM 120'), findsOneWidget);
      await tester.tap(find.byTooltip('BPM を上げる'));
      await tester.pump();
      expect(e.bpm, 121);
      expect(find.text('BPM 121'), findsOneWidget);
      await tester.tap(find.byTooltip('BPM を下げる'));
      await tester.tap(find.byTooltip('BPM を下げる'));
      await tester.pump();
      expect(e.bpm, 119);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('TAP を 0.6 秒間隔で叩くと 100 BPM', (tester) async {
      final e = FakeEngine();
      var now = Duration.zero;
      await pumpPhone(tester, TempoBar(engine: e, clock: () => now));
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('TAP'));
        now += const Duration(milliseconds: 600);
      }
      await tester.pump();
      expect(e.bpm, 100);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('数字をタップして直接入力できる', (tester) async {
      final e = FakeEngine();
      await pumpPhone(tester, TempoBar(engine: e));
      await tester.tap(find.text('BPM 120'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '92.5');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(e.bpm, 92.5);
      expect(find.text('BPM 92.5'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('LoopTimingEditor', () {
    Future<FakeEngine> loopPad({required int frames}) async {
      final e = FakeEngine(sampleRate: 44100);
      // 120 BPM: 1 拍 = 22050 フレーム
      await e.assign(
        0,
        Sample(name: 's', sampleRate: 44100, pcm: Float32List(frames)),
        0,
        frames,
        mode: PadMode.loop,
      );
      return e;
    }

    testWidgets('周期を選ぶと反映され、オフセットは周期の中に収まる', (tester) async {
      final e = await loopPad(frames: 11025); // 0.5 拍
      await e.setLoopTiming(0, 4, 3);
      await pumpPhone(tester, LoopTimingEditor(engine: e, index: 0));
      expect(find.text('オフセット: 3 拍'), findsOneWidget);

      await tester.tap(find.text('1 拍'));
      await tester.pump();
      expect(e.pads[0].periodBeats, 1);
      expect(e.pads[0].offsetBeats, 0.75);
      expect(find.text('オフセット: 3/4 拍'), findsOneWidget);
    });

    testWidgets('オフセットのスライダーは 16 分音符単位', (tester) async {
      final e = await loopPad(frames: 11025);
      await e.setLoopTiming(0, 2, 0);
      await pumpPhone(tester, LoopTimingEditor(engine: e, index: 0));
      final slider = find.byKey(const ValueKey('offset'));
      final r = tester.getRect(slider);
      // 8 段階（0〜7）の真ん中あたりを押す
      await tester.tapAt(Offset(r.left + r.width * 0.5, r.center.dy));
      await tester.pump();
      final off = e.pads[0].offsetBeats;
      expect(off % 0.25, 0);
      expect(off, inInclusiveRange(0.75, 1.0));
    });

    testWidgets('音が周期より長いと、実際の周期を知らせる', (tester) async {
      final e = await loopPad(frames: 22050 * 6); // 6 拍
      await e.setLoopTiming(0, 4, 0);
      await pumpPhone(tester, LoopTimingEditor(engine: e, index: 0));
      expect(find.textContaining('実際は 2 小節ごと'), findsOneWidget);

      await tester.tap(find.text('2 小節'));
      await tester.pump();
      expect(find.textContaining('実際は'), findsNothing);
    });
  });
}
