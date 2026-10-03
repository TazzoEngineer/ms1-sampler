import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'sample.dart';
import 'wav.dart';

/// Android の再生音キャプチャ（ネイティブ側は CaptureService.kt）。
///
/// 接続すると直近 60 秒を聴き続け、「直前を取り込む」でその末尾を WAV に保存する。
/// 取り込んだファイルは capturesDir に溜まり、[listCaptures] で一覧できる。
class PlaybackCapture {
  static const _m = MethodChannel('ms1/capture');
  static const _e = EventChannel('ms1/capture/events');

  static final events = _e.receiveBroadcastStream().map(
    (e) => Map<String, Object?>.from(e as Map),
  );

  static Future<bool> isSupported() async =>
      Platform.isAndroid &&
      (await _m.invokeMethod<bool>('isSupported') ?? false);

  static Future<bool> isConnected() async =>
      Platform.isAndroid &&
      (await _m.invokeMethod<bool>('isConnected') ?? false);

  static Future<bool> isRecording() async =>
      Platform.isAndroid &&
      (await _m.invokeMethod<bool>('isRecording') ?? false);

  /// 許可ダイアログを出して聴き始める。拒否されたら false。
  static Future<bool> connect() async =>
      await _m.invokeMethod<bool>('connect') ?? false;

  static Future<void> disconnect() => _m.invokeMethod('disconnect');

  static Future<void> setSnapshotSeconds(int s) =>
      _m.invokeMethod('setSnapshotSeconds', s);

  /// 直近 [seconds] 秒を保存してそのファイルを返す。
  static Future<File?> snapshot(int seconds) async {
    final p = await _m.invokeMethod<String>('snapshot', seconds);
    return p == null ? null : File(p);
  }

  static Future<bool> startTake() async =>
      await _m.invokeMethod<bool>('startTake') ?? false;

  static Future<File?> stopTake() async {
    final p = await _m.invokeMethod<String>('stopTake');
    return p == null ? null : File(p);
  }

  /// 取り込んだファイル（新しい順）。
  static Future<List<File>> listCaptures() async {
    if (!Platform.isAndroid) return [];
    final dir = await _m.invokeMethod<String>('capturesDir');
    if (dir == null) return [];
    final d = Directory(dir);
    if (!d.existsSync()) return [];
    final files =
        d
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.wav'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  static Future<Sample> load(File f) async =>
      decodeWav(await f.readAsBytes(), name: captureName(f));

  /// "20261003-114205-直前20秒.wav" → "10/03 11:42:05 直前20秒"
  static String captureName(File f) {
    final base = f.uri.pathSegments.last.replaceAll('.wav', '');
    final m = RegExp(
      r'^\d{4}(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)-(.*)$',
    ).firstMatch(base);
    if (m == null) return base;
    return '${m[1]}/${m[2]} ${m[3]}:${m[4]}:${m[5]} ${m[6]}';
  }

  /// WAV（16bit モノラル、ヘッダ 44 バイト）の長さ。レートはヘッダから読む。
  static Duration durationOf(File f) {
    final raf = f.openSync();
    try {
      final h = raf.readSync(44);
      if (h.length < 44) return Duration.zero;
      final rate = ByteData.sublistView(h).getUint32(24, Endian.little);
      final frames = (f.lengthSync() - 44) / 2;
      return Duration(microseconds: (frames / rate * 1e6).round());
    } finally {
      raf.closeSync();
    }
  }
}
