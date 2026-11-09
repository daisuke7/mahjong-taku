import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/bench/jev_bench.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/paifu/paifu_db.dart';

import 'paifu_fixture.dart';

/// Jev ベンチマークの局面抽出(設計文書(非公開) §5・§10-1)。
/// フィクスチャ(1局: A ツモ切り → B リーチ → C ポン → D ツモ切り → A ツモ和了)を
/// 実エンジンで再現し、レコードの中身を固定する。
void main() {
  late Directory tmp;
  late String dbPath;
  late List<Map<String, dynamic>> records;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('jev_bench');
    dbPath = '${tmp.path}/fixture.sqlite3';
    buildPaifuFixture(dbPath);
    final db = PaifuDb.open(dbPath);
    try {
      records = await extractGame(db, 1);
    } finally {
      db.close();
    }
  });

  tearDownAll(() async {
    await tmp.delete(recursive: true);
  });

  test('手番レコード: 記録どおりの打牌が候補に含まれ、CPUの選択も候補内', () {
    final turns = records.where((r) => r['kind'] == 'turn').toList();
    // A(ツモ切り)・B(リーチ宣言)・C(ポン後の打牌)・D(ツモ切り)の4手番
    expect(turns.map((r) => r['seat']), [0, 1, 2, 3]);
    for (final r in turns) {
      final criteria =
          ((r['request'] as Map)['questions'] as Map)['discard']['criteria']
              as Map;
      expect(criteria.keys, contains((r['pro'] as Map)['discard']));
      expect(criteria.keys, contains((r['cpu'] as Map)['discard']));
      expect(criteria.length, greaterThanOrEqualTo(2));
    }
    // B はリーチ宣言牌 9p を切っている → 選択肢は「リーチ_9p」
    final b = turns[1];
    expect((b['pro'] as Map)['discard'], '${riichiKeyPrefix}9p');
    expect((b['pro'] as Map)['riichi'], isTrue);
    final bCrit =
        ((b['request'] as Map)['questions'] as Map)['discard']['criteria']
            as Map;
    expect(bCrit.keys, containsAll(['9p', '${riichiKeyPrefix}9p']));
    expect((bCrit['${riichiKeyPrefix}9p'] as Map)['リーチ宣言'], isTrue);
    expect((bCrit['9p'] as Map)['待ち'], ['6s(残り3枚)', '9s(残り2枚)']);
    expect((bCrit['9p'] as Map)['受け入れ順位'], isA<int>());
    // A のツモ切り 5z には「ツモ切り」の印
    final a = turns[0];
    final aCrit =
        ((a['request'] as Map)['questions'] as Map)['discard']['criteria']
            as Map;
    expect((aCrit['5z'] as Map)['ツモ切り'], isTrue);
  });

  test('state は自分視点のみ: 他家の手牌・山・裏ドラを含まない', () {
    final hands = {
      101: '123m456p789s1122z',
      102: '23456m7899p7899s',
      103: '1122334m99p455s7z',
      104: '147m258p369s7z1234z',
    };
    for (final r in records) {
      final state = (r['request'] as Map)['state'] as Map;
      // 裏ドラ・山はキーとして存在しない(ルール説明文の語は除く)
      expect(state.keys, isNot(contains('裏ドラ')));
      expect(state.keys, isNot(contains('山')));
      expect(state.keys, contains('残り山')); // 枚数だけは公開情報
      // 他家エントリに手牌キーが無い
      for (final o in state['他家'] as List) {
        expect((o as Map).containsKey('手牌'), isFalse);
      }
      // 自分の手牌は自分の配牌由来(他家の配牌13枚がそのまま入っていない)
      final myHand = ((state['自分'] as Map)['手牌'] as List).cast<String>();
      final seat = r['seat'] as int;
      for (final e in hands.entries) {
        final pid = e.key;
        if (pid - 101 == seat) continue;
        final other = Tile.parse(e.value).map(Tile.dbNotation).toList()..sort();
        final mine = [...myHand]..sort();
        expect(mine, isNot(equals(other)));
      }
    }
  });

  test('反応レコード: C のポン局面が pass/pon の選択肢付きで記録される', () {
    final reacts = records.where((r) => r['kind'] == 'react').toList();
    expect(reacts, isNotEmpty);
    final c = reacts.firstWhere((r) => r['seat'] == 2);
    final criteria =
        ((c['request'] as Map)['questions'] as Map)['call']['criteria'] as Map;
    expect(criteria.keys, containsAll(['pass', 'pon']));
    expect((c['pro'] as Map)['call'], 'pon');
    final state = (c['request'] as Map)['state'] as Map;
    expect((state['他家の打牌'] as Map)['牌'], '9p');
    expect((state['他家の打牌'] as Map)['誰'], '上家');
  });

  test('レコードは JSON として往復できる(Jev に送る request をそのまま持つ)', () {
    for (final r in records) {
      final back = jsonDecode(jsonEncode(r)) as Map<String, dynamic>;
      expect(back['request']['model'], jevModel);
      expect(back['id'], r['id']);
    }
  });
}
