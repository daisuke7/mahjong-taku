import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/payout.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/engine/yaku.dart';

import 'hand_test.dart' show tiles;

/// 対戦・記録エンジンで共有する点数移動・状況判定の純粋関数(payout.dart)。
/// 両エンジンの既存テストが結合面を検証するので、ここでは関数単体の
/// 振る舞いを固定する。
void main() {
  test('kanAllowed: 4回まで・山が残っていること', () {
    expect(kanAllowed(kanCount: 0, wallRemaining: 1), isTrue);
    expect(kanAllowed(kanCount: 3, wallRemaining: 70), isTrue);
    expect(kanAllowed(kanCount: 4, wallRemaining: 70), isFalse);
    expect(kanAllowed(kanCount: 0, wallRemaining: 0), isFalse);
  });

  test('ryukyokuChanges: ノーテン罰符の分配', () {
    expect(ryukyokuChanges(const []), [0, 0, 0, 0]);
    expect(ryukyokuChanges(const [0, 1, 2, 3]), [0, 0, 0, 0]);
    expect(ryukyokuChanges(const [1]), [-1000, 3000, -1000, -1000]);
    expect(ryukyokuChanges(const [0, 2]), [1500, -1500, 1500, -1500]);
    expect(ryukyokuChanges(const [0, 1, 3]), [1000, 1000, -3000, 1000]);
  });

  test('paoMarks: 3つ目の三元牌・4つ目の風牌で包', () {
    Meld pon(String t) => Meld(
      type: MeldType.pon,
      tiles: tiles(t),
      fromSeat: 0,
      calledTile: tiles(t)[0],
    );
    final twoDragons = [pon('555z'), pon('666z')];
    expect(paoMarks(twoDragons, Tile.parse('6z').single).daisangen, isFalse);
    final threeDragons = [...twoDragons, pon('777z')];
    expect(paoMarks(threeDragons, Tile.parse('7z').single).daisangen, isTrue);
    final fourWinds = [pon('111z'), pon('222z'), pon('333z'), pon('444z')];
    expect(paoMarks(fourWinds, Tile.parse('4z').single).daisuushi, isTrue);
    expect(
      paoMarks(fourWinds.sublist(0, 3), Tile.parse('3z').single).daisuushi,
      isFalse,
    );
  });

  test('winPayout: 通常のツモ・ロン(供託・本場込み)', () {
    // 満貫クラスの WinScore を直接与える(30符5飜相当)
    const score = WinScore(
      yaku: [YakuItem('立直', 1)],
      han: 5,
      fu: 30,
      yakuman: 0,
    );
    // 子ツモ 2000-4000 + 本場1(100×3) + 供託1
    final tsumo = winPayout(
      score: score,
      seat: 1,
      dealer: 0,
      honba: 1,
      riichiSticks: 1,
    );
    expect(tsumo.changes, [-4100, 9300, -2100, -2100]);
    expect(tsumo.declared, 8300); // 申告点は本場込み(供託は除く)
    // 親ロン 12000 + 本場1(300) + 供託1
    final ron = winPayout(
      score: score,
      seat: 0,
      dealer: 0,
      fromSeat: 2,
      honba: 1,
      riichiSticks: 1,
    );
    expect(ron.changes, [13300, 0, -12300, 0]);
    expect(ron.declared, 12300); // 申告点は本場込み(供託は除く)
  });

  test('winPayout: 責任払い(ツモ全額・ロン折半)', () {
    const yakuman = WinScore(
      yaku: [YakuItem('大三元', 0)],
      han: 0,
      fu: 0,
      yakuman: 1,
    );
    // 子の役満ツモ32000を包(席3)が全額+本場300
    final tsumo = winPayout(
      score: yakuman,
      seat: 1,
      dealer: 0,
      honba: 1,
      riichiSticks: 0,
      paoSeat: 3,
      paoCount: 1,
    );
    expect(tsumo.changes, [0, 32300, 0, -32300]);
    // 親の役満ロン48000は包(席1)と放銃者(席2)で折半
    final ron = winPayout(
      score: yakuman,
      seat: 0,
      dealer: 0,
      fromSeat: 2,
      honba: 0,
      riichiSticks: 0,
      paoSeat: 1,
      paoCount: 1,
    );
    expect(ron.changes, [48000, -24000, -24000, 0]);
    // 包が放銃者自身なら折半は発動しない(全額放銃)
    final selfPao = winPayout(
      score: yakuman,
      seat: 0,
      dealer: 0,
      fromSeat: 1,
      honba: 0,
      riichiSticks: 0,
      paoSeat: 1,
      paoCount: 1,
    );
    expect(selfPao.changes, [48000, -48000, 0, 0]);
  });

  test('buildWinContext: 海底×嶺上の排他・天和/地和・自風', () {
    final concealed = tiles('234m567m345p78s66s6s');
    WinContext ctx({
      required bool isTsumo,
      bool rinshan = false,
      bool chankan = false,
      bool wallEmpty = false,
      bool firstTurn = false,
      int seat = 0,
    }) => buildWinContext(
      concealed: concealed,
      melds: const [],
      winTile: tiles('6s')[0],
      isTsumo: isTsumo,
      wallEmpty: wallEmpty,
      isRinshan: rinshan,
      isChankan: chankan,
      firstTurn: firstTurn,
      seat: seat,
      dealer: 0,
      roundWind: 0,
    );
    expect(ctx(isTsumo: true, wallEmpty: true).isHaitei, isTrue);
    expect(
      ctx(isTsumo: true, wallEmpty: true, rinshan: true).isHaitei,
      isFalse,
    ); // 嶺上は海底にならない
    expect(ctx(isTsumo: false, wallEmpty: true).isHoutei, isTrue);
    expect(
      ctx(isTsumo: false, wallEmpty: true, chankan: true).isHoutei,
      isFalse,
    ); // 搶槓は河底にならない
    expect(ctx(isTsumo: true, firstTurn: true).isTenhou, isTrue);
    expect(ctx(isTsumo: true, firstTurn: true, seat: 1).isChihou, isTrue);
    expect(ctx(isTsumo: false, firstTurn: true).isTenhou, isFalse);
    expect(ctx(isTsumo: true, seat: 2).seatWind, 2);
  });
}
