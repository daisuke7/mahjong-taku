@Tags(['smoke'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/paifu/ghost.dart';
import 'package:mahjong_taku/paifu/paifu_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// 実DB(konoui/m-league-game-db)全局で山の再構成が通るかのスモーク。
/// SMOKE_DB=/path/to/database.sqlite3 を渡したときだけ動く。
void main() {
  const dbPath = String.fromEnvironment('SMOKE_DB');

  test('実DB全局: ゴースト用の山を再構成できる(欠損局のみ許容)', () async {
    if (dbPath.isEmpty || !File(dbPath).existsSync()) {
      markTestSkipped('SMOKE_DB が未指定のためスキップ');
      return;
    }
    final db = PaifuDb.open(dbPath);
    final raw = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    var kyokus = 0;
    var failures = 0;
    final reasons = <String, int>{};
    try {
      final gameIds = [
        for (final r in raw.select('SELECT id FROM game ORDER BY id'))
          r['id'] as int,
      ];
      for (final gameId in gameIds) {
        final players = db.gamePlayers(gameId);
        if (players.length != 4) continue;
        final seatOf = {for (var i = 0; i < 4; i++) players[i].id: i};
        for (final k in db.kyokus(gameId)) {
          kyokus++;
          final events = db.kyokuEvents(k.id);
          final dealer = seatOf[k.parentPlayerId] ?? 0;
          try {
            buildGhostWall(events: events, seatOf: seatOf, dealer: dealer);
          } on StateError catch (e) {
            failures++;
            reasons[e.message] = (reasons[e.message] ?? 0) + 1;
          }
        }
      }
    } finally {
      db.close();
      raw.dispose();
    }
    // 既知の欠損は「配牌欠落の反則局」のみ。それ以外の失敗は表記の
    // 取りこぼしなので落とす。
    // ignore: avoid_print
    print('kyokus=$kyokus failures=$failures reasons=$reasons');
    expect(kyokus, greaterThan(20000));
    expect(failures, lessThanOrEqualTo(2), reason: '$reasons');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
