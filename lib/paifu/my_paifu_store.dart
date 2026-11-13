/// 自分の対局の牌譜保存(「自分の対局」タブのデータ源)。
///
/// エンジンの [PaifuRecorder] として動き、局終了ごとに1試合1JSONファイルへ
/// 追記保存する(途中で落ちても打ち終わった局までは残る)。イベントの中身は
/// 本家Mリーグ牌譜DBのスキーマの写し(paifu_record.dart 参照)。
/// 保存先はアプリサポートディレクトリの my_paifu/。保存失敗は対局進行に
/// 影響させない(すべて握りつぶす)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/paifu_record.dart';
import 'own_paifu_format.dart';
import '../features.dart';

/// 一覧表示用の1試合の要約
class MyPaifuSummary {
  final String id; // 'MY_20260727_213045'
  final String date; // '2026-07-27'
  final List<String> names; // 席順(1局目の東南西北)
  final List<int> lastScores; // 最終(または最新局終了時)の点数
  final int kyokuCount;
  final bool finished;

  const MyPaifuSummary({
    required this.id,
    required this.date,
    required this.names,
    required this.lastScores,
    required this.kyokuCount,
    required this.finished,
  });
}

class MyPaifuStore implements PaifuRecorder {
  MyPaifuStore._();

  /// エンジンに渡す共有インスタンス(ホスト側セッションが使う)
  static final MyPaifuStore instance = MyPaifuStore._();

  /// テスト用の保存先上書き
  static Directory? dirOverride;

  String? _currentId;
  Map<String, dynamic>? _currentGame;
  Future<void> _writes = Future.value(); // 書き込みの直列化
  String? _lastStamp; // 同一秒内の連戦でIDが衝突しないように
  int _stampSeq = 0;

  static Future<Directory> _dir() async {
    if (dirOverride != null) return dirOverride!;
    final d = await getApplicationSupportDirectory();
    return Directory('${d.path}/my_paifu');
  }

  static Future<File> _file(String id) async =>
      File('${(await _dir()).path}/$id.json');

  /// 進行中(保存先として開いている)試合のID。中断データに載せて、
  /// 復帰時に [reopen] で同じファイルへの追記を続ける。
  String? get currentGameId => _currentId;

  /// 復帰時: 中断前の試合ファイルへの追記を再開する
  void reopen(String? gameId) {
    _currentId = gameId;
    _currentGame = null; // 次の onKyoku でファイルから読み直す
  }

  /// テスト用: 進行状態を破棄する
  void resetForTest() {
    _currentId = null;
    _currentGame = null;
    _writes = Future.value();
  }

  @override
  void onKyoku(Map<String, dynamic> kyoku) {
    _enqueue(() => _appendKyoku(kyoku));
  }

  @override
  void onGameEnd(List<Map<String, dynamic>> results) {
    _enqueue(() => _finishGame(results));
  }

  /// 書き込みキューの完了を待つ(テスト用)
  Future<void> flush() => _writes;

  void _enqueue(Future<void> Function() job) {
    if (!Features.localFiles) return; // Web: 保存先が無いので記録しない
    _writes = _writes.then((_) => job()).catchError((_) {
      // 保存失敗(テスト環境の path_provider 不在など)は対局を止めない
    });
  }

  Future<void> _appendKyoku(Map<String, dynamic> kyoku) async {
    final names = (kyoku['names'] as List).cast<String>();
    if (_currentId != null && _currentGame == null) {
      // 復帰: 中断前のファイルを読み直す(無ければ新規に作り直す)
      _currentGame = await _load(_currentId!);
    }
    if (_currentId == null || _currentGame == null) {
      final now = DateTime.now();
      String p2(int v) => v.toString().padLeft(2, '0');
      var stamp =
          '${now.year}${p2(now.month)}${p2(now.day)}'
          '_${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
      if (stamp == _lastStamp) {
        stamp = '${stamp}_${++_stampSeq}';
      } else {
        _lastStamp = stamp;
        _stampSeq = 0;
      }
      _currentId = 'MY_$stamp';
      _currentGame = {
        'id': _currentId,
        'date': '${now.year}-${p2(now.month)}-${p2(now.day)}',
        'names': names,
        'kyokus': <Map<String, dynamic>>[],
        'finished': false,
      };
    }
    final game = _currentGame!;
    game['names'] = names;
    final kyokus = (game['kyokus'] as List);
    final record = {...kyoku}..remove('names');
    // 中断→復帰で同じ局がもう一度流れてくることがある(handEnd 中の中断)。
    // 局(round+本場)は1試合内で繰り返さないので、同じなら置き換える。
    if (kyokus.isNotEmpty) {
      final last = (kyokus.last as Map);
      if (last['round'] == record['round'] &&
          last['honba_count'] == record['honba_count']) {
        kyokus.removeLast();
      }
    }
    kyokus.add(record);
    await _persist();
  }

  Future<void> _finishGame(List<Map<String, dynamic>> results) async {
    final game = _currentGame;
    if (game == null) return;
    game['results'] = results;
    game['finished'] = true;
    await _persist();
    // 連戦の次の試合は新しいファイルになる
    _currentId = null;
    _currentGame = null;
  }

  Future<void> _persist() async {
    final game = _currentGame;
    final id = _currentId;
    if (game == null || id == null) return;
    final f = await _file(id);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(stampOwnPaifuFormat(game)));
  }

  static Future<Map<String, dynamic>?> _load(String id) async {
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

  /// 保存済みの試合一覧(新しい順)。壊れたファイルは読み飛ばす。
  static Future<List<MyPaifuSummary>> listGames() async {
    if (!Features.localFiles) return const [];
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    final summaries = <MyPaifuSummary>[];
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
          MyPaifuSummary(
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
  static Future<Map<String, dynamic>?> loadGame(String id) =>
      Features.localFiles ? _load(id) : Future.value(null);

  static Future<void> deleteGame(String id) async {
    try {
      final f = await _file(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
