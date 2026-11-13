/// 手動で記録した牌譜の保存(「✍️ 記録した牌譜」タイルのデータ源)。
///
/// MyPaifuStore と同じ本家DBスキーマ互換JSON(1試合1ファイル)。ID接頭辞は
/// `REC_`。記録画面が局終了ごとに [save] で全体を書き直す(記録エンジンが
/// 全局を持っているため追記管理は不要)。読み出しは MyPaifuSource がそのまま
/// 使える(同じ形のJSONなので)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../paifu/own_paifu_format.dart';
import '../features.dart';

/// 一覧表示用の1試合の要約
class RecPaifuSummary {
  final String id; // 'REC_20260729_213045'
  final String date; // '2026-07-29'
  final List<String> names; // 席順(起家から)
  final List<int> lastScores;
  final int kyokuCount;
  final bool finished;

  const RecPaifuSummary({
    required this.id,
    required this.date,
    required this.names,
    required this.lastScores,
    required this.kyokuCount,
    required this.finished,
  });
}

class RecPaifuStore {
  RecPaifuStore._();

  /// テスト用の保存先上書き
  static Directory? dirOverride;

  static Future<Directory> _dir() async {
    if (dirOverride != null) return dirOverride!;
    final d = await getApplicationSupportDirectory();
    return Directory('${d.path}/rec_paifu');
  }

  static Future<File> _file(String id) async =>
      File('${(await _dir()).path}/$id.json');

  /// 新しい記録のIDを発行する(現在時刻ベース)
  static String newId() {
    final now = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return 'REC_${now.year}${p2(now.month)}${p2(now.day)}'
        '_${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
  }

  /// 1試合分を保存(全体上書き)。[game] は RecordEngine.buildGameJson の形。
  /// 保存失敗は記録の進行を止めない(false を返すだけ)。
  static Future<bool> save(String id, Map<String, dynamic> game) async {
    if (!Features.localFiles) return false;
    try {
      final now = DateTime.now();
      String p2(int v) => v.toString().padLeft(2, '0');
      final f = await _file(id);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode(
          stampOwnPaifuFormat({
            'id': id,
            'date': '${now.year}-${p2(now.month)}-${p2(now.day)}',
            ...game,
          }),
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 保存済みの一覧(新しい順)。壊れたファイルは読み飛ばす。
  static Future<List<RecPaifuSummary>> listGames() async {
    if (!Features.localFiles) return const [];
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    final summaries = <RecPaifuSummary>[];
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        final g = (jsonDecode(await e.readAsString()) as Map)
            .cast<String, dynamic>();
        final kyokus = (g['kyokus'] as List);
        if (kyokus.isEmpty) continue;
        final results = g['results'] as List?;
        final lastScores = results != null
            ? [for (final r in results) (r as Map)['score'] as int]
            : ((kyokus.last as Map)['end_scores'] as List).cast<int>();
        summaries.add(
          RecPaifuSummary(
            id: g['id'] as String,
            date: g['date'] as String,
            names: (g['names'] as List).cast<String>(),
            lastScores: lastScores,
            kyokuCount: kyokus.length,
            finished: g['finished'] as bool? ?? false,
          ),
        );
      } catch (_) {
        // 壊れたファイルは一覧に出さない
      }
    }
    summaries.sort((a, b) => b.id.compareTo(a.id)); // IDが日時なので新しい順
    return summaries;
  }

  /// 1試合の牌譜を読み込む(MyPaifuSource に渡す)。無ければ null。
  static Future<Map<String, dynamic>?> loadGame(String id) async {
    if (!Features.localFiles) return null;
    try {
      final f = await _file(id);
      if (!await f.exists()) return null;
      return migrateOwnPaifu(
        (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> deleteGame(String id) async {
    if (!Features.localFiles) return;
    try {
      final f = await _file(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
