import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/paifu/paifu_db.dart';
import 'package:mahjong_taku/paifu/replay_session.dart';
import 'package:mahjong_taku/ui/game_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'paifu_fixture.dart';

/// 牌譜ビューアの通常再生で、リーチ・ポンの発声バナーが画面に出ること。
/// (2026-09-15 ユーザー報告: 通常再生では出ず、巻き戻すと出る)
void main() {
  late Directory tmp;
  late String dbPath;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('paifu_banner');
    dbPath = '${tmp.path}/fixture.sqlite3';
    buildPaifuFixture(dbPath);
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  testWidgets('通常再生でリーチ・ポンのバナーが表示される', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(667, 375));
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      mLeagueGameId: 'L001_S001_0001_01A',
    );
    // ブラウザ画面と同じ順序: run() を先に始めてから画面を開く
    final runF = session.run();
    await tester.pumpWidget(MaterialApp(home: GameScreen(session: session)));

    final seen = <String>{};
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      for (final t in ['リーチ!', 'ポン!', 'ツモ!']) {
        if (find.text(t).evaluate().isNotEmpty) seen.add(t);
      }
      if (seen.length == 3) break;
    }
    // ignore: avoid_print
    print('見えたバナー: $seen');
    expect(seen, containsAll(['リーチ!', 'ポン!']), reason: '見えたバナー: $seen');
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    // 結果表示の待ち(9秒)やバナーのタイマーを流し切る
    await tester.pump(const Duration(seconds: 15));
  });
}
