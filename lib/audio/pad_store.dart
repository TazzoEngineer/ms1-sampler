import 'dart:convert';
import 'dart:io';

import 'pad_engine.dart';
import 'sample.dart';
import 'wav.dart';

/// 保存されていたパッド 1 つ分。
class SavedPad {
  SavedPad(
    this.original,
    this.start,
    this.end,
    this.mode, {
    this.periodBeats,
    this.offsetBeats,
  });
  final Sample original;
  final int start, end;
  final PadMode mode;
  final double? periodBeats, offsetBeats;
}

/// パッドの割り当てと画面の設定を [dir] に保存する。
///
/// - `pads.json`: パッドごとの元音源ファイル名・切り出し範囲・鳴らし方と、[settings]
/// - `orig_*.wav`: 元音源（トリミングし直せるよう切り出す前の音を残す）
///
/// 同じ元音源（同一の [Sample]）は 1 ファイルを共有し、どのパッドからも参照されなく
/// なったファイルは保存時に消す。
class PadStore {
  PadStore(this.dir);

  final Directory dir;

  /// 画面の設定（音源の種類、取り込む秒数など）。値は JSON にできるもの。
  Map<String, Object?> settings = {};

  final _files = <Sample, String>{};
  int _counter = 0;

  File get _json => File('${dir.path}/pads.json');

  /// 保存内容を読む。ファイルがない・壊れているときは空として扱う。
  Future<List<SavedPad?>> load() async {
    final result = List<SavedPad?>.filled(PadEngine.padCount, null);
    if (!await _json.exists()) return result;
    Map<String, Object?> root;
    try {
      root = jsonDecode(await _json.readAsString()) as Map<String, Object?>;
    } on FormatException {
      return result;
    }
    settings = Map.of(
      (root['settings'] as Map?)?.cast<String, Object?>() ?? {},
    );
    final pads = (root['pads'] as List?) ?? const [];
    final byFile = <String, Sample>{};
    for (var i = 0; i < pads.length && i < PadEngine.padCount; i++) {
      final p = pads[i];
      if (p is! Map) continue;
      final file = p['file'] as String?;
      if (file == null) continue;
      var original = byFile[file];
      if (original == null) {
        final f = File('${dir.path}/$file');
        if (!await f.exists()) continue;
        try {
          original = decodeWav(
            await f.readAsBytes(),
            name: p['name'] as String? ?? file,
          );
        } on FormatException {
          continue;
        }
        byFile[file] = original;
        _files[original] = file;
      }
      final mode = PadMode.values.asNameMap()[p['mode']] ?? PadMode.oneShot;
      final start = (p['start'] as int? ?? 0).clamp(0, original.length);
      final end = (p['end'] as int? ?? original.length).clamp(
        start,
        original.length,
      );
      result[i] = SavedPad(
        original,
        start,
        end,
        mode,
        periodBeats: (p['period'] as num?)?.toDouble(),
        offsetBeats: (p['offset'] as num?)?.toDouble(),
      );
    }
    return result;
  }

  /// 今のパッドの状態を保存する。
  Future<void> save(List<Pad> pads) async {
    await dir.create(recursive: true);
    final entries = <Map<String, Object?>?>[];
    final used = <String>{};
    for (final pad in pads) {
      final original = pad.original;
      if (original == null) {
        entries.add(null);
        continue;
      }
      var file = _files[original];
      if (file == null) {
        file =
            'orig_${DateTime.now().microsecondsSinceEpoch}_${_counter++}.wav';
        await _writeAtomic(File('${dir.path}/$file'), encodeWav(original));
        _files[original] = file;
      }
      used.add(file);
      entries.add({
        'file': file,
        'name': original.name,
        'start': pad.start,
        'end': pad.end,
        'mode': pad.mode.name,
        'period': pad.periodBeats,
        'offset': pad.offsetBeats,
      });
    }
    await _writeAtomic(
      _json,
      utf8.encode(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'version': 1, 'pads': entries, 'settings': settings}),
      ),
    );
    // どのパッドからも使われなくなった元音源を消す
    _files.removeWhere((_, f) => !used.contains(f));
    await for (final e in dir.list()) {
      final name = e.uri.pathSegments.last;
      if (e is File &&
          name.startsWith('orig_') &&
          name.endsWith('.wav') &&
          !used.contains(name)) {
        await e.delete();
      }
    }
  }

  /// 途中で落ちても壊れたファイルが残らないよう、一時ファイルに書いてから置き換える。
  static Future<void> _writeAtomic(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }
}
