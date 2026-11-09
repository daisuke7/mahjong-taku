import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/advisor.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'advisor_test.dart' show makeView;
import 'hand_test.dart' show tiles;

/// 守備アドバイスの「通ったスジ」(リーチが両面待ちと仮定したとき、
/// 捨牌から通ると読めるスジ。各色 1-4/2-5/3-6/4-7/5-8/6-9 の6本)。
void main() {
  test('河の牌からスジが通る(2s→2-5s、5m→2-5mと5-8mの両方)', () {
    final v = makeView(
      hand: tiles('123456789m123p1s'),
      riichiSeats: {1},
      rivers: {1: tiles('2s5m')},
    );
    final table = sujiTableVs(v, 1);
    expect(table.seat, 1);
    // 索子(suit=2): 2-5s(i=1)だけが通る
    expect(table.passed[2], [false, true, false, false, false, false]);
    // 萬子(suit=0): 5mは 2-5m(i=1) と 5-8m(i=4) の両スジを通す
    expect(table.passed[0], [false, true, false, false, true, false]);
    // 筒子(suit=1): 何も捨てられていないので全て未確認
    expect(table.passed[1], everyElement(isFalse));
    // 通った本数(18本中): 2-5s + 2-5m + 5-8m の3本
    expect(table.passedCount, 3);
  });

  test('リーチ後に他家が捨てて通った牌もスジに数える', () {
    final v = makeView(
      hand: tiles('123456789m123p1s'),
      riichiSeats: {1},
      riverInfos: {
        1: [DiscardInfo(tiles('1z')[0], riichi: true, order: 0)],
        2: [DiscardInfo(tiles('7p')[0], order: 5)],
      },
    );
    final table = sujiTableVs(v, 1);
    // 7pは 4-7p(i=3) を通す
    expect(table.passed[1], [false, false, false, true, false, false]);
  });

  test('リーチ宣言前に他家が捨てただけの牌はスジに数えない', () {
    final v = makeView(
      hand: tiles('123456789m123p1s'),
      riichiSeats: {1},
      riverInfos: {
        1: [DiscardInfo(tiles('1z')[0], riichi: true, order: 10)],
        2: [DiscardInfo(tiles('7p')[0], order: 5)],
      },
    );
    final table = sujiTableVs(v, 1);
    expect(table.passed[1], everyElement(isFalse));
  });

  test('buildAdvice: リーチ者ごとに表が付き、鳴き脅威だけなら空', () {
    final two = makeView(
      hand: tiles('123456789m123p1s'),
      riichiSeats: {1, 3},
      rivers: {1: tiles('2s'), 3: tiles('8p')},
    );
    final report = buildAdvice(two);
    expect(report.sujiTables.map((t) => t.seat), [1, 3]);

    // 鳴き脅威(白ポン)だけではスジ表を出さない
    final meldOnly = makeView(
      hand: tiles('123456789m123p1s'),
      otherMelds: {
        2: [
          Meld(
            type: MeldType.pon,
            tiles: [Tile.haku, Tile.haku, Tile.haku],
            fromSeat: 3,
            calledTile: Tile.haku,
          ),
        ],
      },
    );
    expect(buildAdvice(meldOnly).threats, isNotEmpty);
    expect(buildAdvice(meldOnly).sujiTables, isEmpty);
  });
}
