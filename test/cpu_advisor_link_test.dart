import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'advisor_test.dart' show makeView;
import 'hand_test.dart' show tiles;

/// CPUがアドバイザーの知識(待ちの打点期待・鳴き脅威)を使うことの検証。
void main() {
  test('リーチ宣言牌: 待ち枚数が同じならドラ側の待ちを選ぶ', () async {
    // 234m 678m 345p 567s 99s の和了形から1枚切ってリーチする場面。
    // 2m切り(2m5m待ち)・8m切り(5m8m待ち)・3p切り(3p6p待ち)はどれも
    // 待ち7枚だが、ドラ表示4m(ドラ5m)なので5mを含む待ちの打点が上。
    final cpu = CpuAgent(seed: 1, thinkMillis: 0);
    cpu.onView(
      makeView(
        hand: tiles('234m678m345p567s9s'),
        drawn: tiles('9s')[0],
        doraIndicators: tiles('4m'),
      ),
    );
    final action = await cpu.onTurn(
      TurnPrompt(drawnTile: tiles('9s')[0], riichiTiles: tiles('2m8m3p')),
    );
    expect(action.riichi, isTrue);
    // ドラ受けを持つ 2m切り・8m切りのうち、牌順で 2m
    expect(Tile.normalize(action.tile), Tile.normalize(tiles('2m')[0]));
  });

  test('鳴き脅威(染め手2副露)にはリーチ同様に降りて安全牌を切る', () async {
    // 席1が筒子のホンイツ気配(ポン2つ)+ドラをさらしている警戒レベル2。
    // 自分はバラバラの3シャンテンなので降り、席1の現物 9s を切るはず。
    Meld pon(String t) => Meld(
      type: MeldType.pon,
      tiles: tiles(t),
      fromSeat: 0,
      calledTile: tiles(t)[0],
    );
    final cpu = CpuAgent(seed: 1, thinkMillis: 0);
    cpu.onView(
      makeView(
        hand: tiles('2358m258p13589s9s'),
        drawn: tiles('2z')[0],
        otherMelds: {
          1: [pon('111p'), pon('999p')],
        },
        rivers: {1: tiles('9s1m')},
        doraIndicators: tiles('8p'), // ドラ9p → 999pポンでドラ3枚さらし
      ),
    );
    final action = await cpu.onTurn(TurnPrompt(drawnTile: tiles('2z')[0]));
    expect(action.riichi, isFalse);
    expect(
      Tile.normalize(action.tile),
      Tile.normalize(tiles('9s')[0]),
      reason: '鳴き脅威に対して現物を切っていない',
    );
  });

  test('鳴きが注意レベル(1副露のみ)なら降りずに手を進める', () async {
    // 席1は役牌ポン1つだけ(レベル1)。3シャンテンでも降り対象ではないので
    // 現物切りに固定されない(攻め側のロジックで打牌が決まる)。
    Meld pon(String t) => Meld(
      type: MeldType.pon,
      tiles: tiles(t),
      fromSeat: 0,
      calledTile: tiles(t)[0],
    );
    final cpu = CpuAgent(seed: 1, thinkMillis: 0);
    cpu.onView(
      makeView(
        hand: tiles('2358m258p13589s9s'),
        drawn: tiles('2z')[0],
        otherMelds: {
          1: [pon('777z')],
        },
        rivers: {1: tiles('9s1m')},
      ),
    );
    final action = await cpu.onTurn(TurnPrompt(drawnTile: tiles('2z')[0]));
    // 孤立字牌の2z(ツモ牌)が最も不要 → 攻めの打牌になっている
    expect(Tile.normalize(action.tile), Tile.normalize(tiles('2z')[0]));
  });
}
