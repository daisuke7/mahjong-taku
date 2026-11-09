import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/advisor.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'advisor_test.dart' show makeView;
import 'hand_test.dart' show tiles;

/// 手牌の現物ハイライトの2段階(濃い青=全脅威に通る/薄い青=リーチにのみ現物)。
/// 守備アドバイスの「青=現物」(全脅威基準)と手牌表示の食い違いを
/// 段階表示で示すための判定。
void main() {
  final m8 = Tile.normalize(tiles('8m')[0]);
  final p6 = Tile.normalize(tiles('6p')[0]);

  test('リーチ現物でも他の脅威に通らない牌は faint、全脅威に通る牌は strong', () {
    // 席1=リーチ(河に8萬と6筒 → 両方リーチには現物)
    // 席2=役牌(白)ポン(河に8萬のみ → 6筒はこの脅威に言い切れない)
    final v = makeView(
      hand: tiles('468m2456678p23s8m'),
      riichiSeats: {1},
      rivers: {1: tiles('8m6p'), 2: tiles('8m')},
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

    // 前提: どちらもリーチ者への現物ではある
    expect(genbutsuInHand(v), containsAll([m8, p6]));
    // 前提: 白ポンが脅威として立っている
    expect(buildAdvice(v).threats.map((t) => t.seat), contains(2));

    final tiers = genbutsuTiersInHand(v);
    expect(tiers.strong, contains(m8), reason: '8萬は両者の河にあり全脅威に通る');
    expect(tiers.faint, contains(p6), reason: '6筒はリーチにのみ現物');
    expect(tiers.strong.intersection(tiers.faint), isEmpty);

    // 守備アドバイスの「青=現物」と strong の基準が一致している
    final report = buildAdvice(v);
    expect(report.genbutsuKinds, contains(m8));
    expect(report.genbutsuKinds, isNot(contains(p6)));
  });

  test('脅威がリーチだけなら現物はすべて strong(従来と同じ見た目)', () {
    final v = makeView(
      hand: tiles('468m2456678p23s8m'),
      riichiSeats: {1},
      rivers: {1: tiles('8m6p')},
    );
    final tiers = genbutsuTiersInHand(v);
    expect(tiers.strong, containsAll([m8, p6]));
    expect(tiers.faint, isEmpty);
  });

  test('リーチ者がいなければどちらも空(鳴き脅威だけでは光らせない)', () {
    final v = makeView(
      hand: tiles('468m2456678p23s8m'),
      rivers: {2: tiles('8m6p')},
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
    final tiers = genbutsuTiersInHand(v);
    expect(tiers.strong, isEmpty);
    expect(tiers.faint, isEmpty);
  });
}
