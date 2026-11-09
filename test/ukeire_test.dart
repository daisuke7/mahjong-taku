import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/advisor.dart';
import 'package:mahjong_taku/engine/hand.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'advisor_test.dart' show makeView;
import 'hand_test.dart' show tiles;

/// 牌効率アドバイザー(ウケ計算)。
/// CPUの受け入れ計算と共有する ukeireMap と、アドバイス表示用の
/// ukeireOptions(最良シャンテン維持のみ・受け広い順)を検証する。
void main() {
  test('ukeireMap: テンパイ手の受け入れはシャンテンが進む牌だけ数える', () {
    // 123m 456p 789s 11z 22z(シャンポン待ち 1z/2z のテンパイ)
    final counts = toCounts(tiles('123m456p789s1122z'));
    final shanten = calcShanten(counts, meldCount: 0);
    expect(shanten, 0);
    final map = ukeireMap(
      counts,
      meldCount: 0,
      shanten: shanten,
      remainingOf: (k) => 4 - counts[k],
    );
    final z1 = Tile.normalize(tiles('1z')[0]);
    final z2 = Tile.normalize(tiles('2z')[0]);
    expect(map.keys, unorderedEquals([z1, z2]));
    expect(map[z1], 2); // 自分で2枚使っているので残り2枚
    expect(map[z2], 2);
  });

  test('ukeireMap: 残り0枚(枯れ)の牌種は載せない', () {
    final counts = toCounts(tiles('123m456p789s1122z'));
    final z1 = Tile.normalize(tiles('1z')[0]);
    final map = ukeireMap(
      counts,
      meldCount: 0,
      shanten: 0,
      remainingOf: (k) => k == z1 ? 0 : 4 - counts[k], // 1z は全部見えている
    );
    expect(map.containsKey(z1), isFalse);
    expect(map.values.every((v) => v > 0), isTrue);
  });

  test('ukeireOptions: 最良シャンテンを保つ打牌だけが受け広い順で返る', () {
    // 234m 567m / 88p 99s(雀頭候補2つ)/ 45s / 1z 7z(浮き牌2つ)+ ツモ7z
    // → 字牌切りだけが1シャンテン維持。ウケは 3s6s(45s埋まり)+ 8p9s(暗刻化)
    final view = makeView(
      hand: tiles('234m567m88p45s99s1z'),
      drawn: tiles('7z')[0],
    );
    final options = ukeireOptions(view);
    expect(options.length, 2); // 1z切り・7z切りのみ(数牌切りは2シャンテンに落ちる)
    expect(
      options.map((o) => Tile.normalize(o.discard)),
      unorderedEquals([
        Tile.normalize(tiles('1z')[0]),
        Tile.normalize(tiles('7z')[0]),
      ]),
    );
    for (final o in options) {
      expect(
        o.tiles,
        unorderedEquals([
          Tile.normalize(tiles('3s')[0]),
          Tile.normalize(tiles('6s')[0]),
          Tile.normalize(tiles('8p')[0]),
          Tile.normalize(tiles('9s')[0]),
        ]),
      );
      expect(o.total, 12); // 3s:4 + 6s:4 + 8p:2 + 9s:2
      // 残り多い順(4枚の3s/6sが2枚の8p/9sより先)
      expect(o.remaining[o.tiles.first], 4);
      expect(o.remaining[o.tiles.last], 2);
    }
  });

  test('ukeireOptions: 見えている牌(河・ドラ表示)を引いて数える', () {
    final view = makeView(
      hand: tiles('234m567m88p45s99s1z'),
      drawn: tiles('7z')[0],
      rivers: {
        1: tiles('3s3s'), // 3s が2枚見えている
      },
      doraIndicators: tiles('6s'), // 6s が1枚見えている
    );
    final best = ukeireOptions(view).first;
    expect(best.remaining[Tile.normalize(tiles('3s')[0])], 2);
    expect(best.remaining[Tile.normalize(tiles('6s')[0])], 3);
    expect(best.total, 9); // 2+3+2+2
  });

  test('ukeireOptions: 赤5と通常5があれば通常牌を切る代表にする(赤温存)', () {
    // 234m 567m / 34p / 88p 99s 55m(赤込み) + ツモ1z
    // 5m切りは1シャンテン維持の候補に入る
    final view = makeView(
      hand: [...tiles('234m567m3p88p99s5m'), Tile.red5m],
      drawn: tiles('4p')[0],
    );
    final options = ukeireOptions(view);
    final fiveCut = options.where(
      (o) => Tile.normalize(o.discard) == Tile.normalize(tiles('5m')[0]),
    );
    expect(fiveCut, isNotEmpty);
    expect(Tile.isRed(fiveCut.first.discard), isFalse);
  });

  test('attackGlowTile: 非テンパイはウケ最大、テンパイは待ち最広の打牌', () {
    // 非テンパイ: 1z切り・7z切りが同ウケ12枚 → 牌順で1z
    final notTenpai = makeView(
      hand: tiles('234m567m88p45s99s1z'),
      drawn: tiles('7z')[0],
    );
    expect(attackGlowTile(notTenpai), tiles('1z')[0]);

    // テンパイ: 1z切りだけがテンパイ維持
    final tenpai = makeView(
      hand: tiles('234567m88p45699s'),
      drawn: tiles('1z')[0],
    );
    expect(attackGlowTile(tenpai), tiles('1z')[0]);

    // リーチ中はウケ側が空 → テンパイ待ち側から返る(UI側で抑制する)
    // 打牌選択が無い形(3n+1枚)は null
    final noChoice = makeView(hand: tiles('234567m88p45699s'));
    expect(attackGlowTile(noChoice), isNull);
  });

  test('buildAdvice: 非テンパイならウケが入り、テンパイ・リーチ中は空', () {
    final notTenpai = buildAdvice(
      makeView(hand: tiles('234m567m88p45s99s1z'), drawn: tiles('7z')[0]),
    );
    expect(notTenpai.shanten, 1);
    expect(notTenpai.ukeire, isNotEmpty);
    // 先頭が最も攻撃的(受け最大)な打牌
    expect(
      notTenpai.ukeire.first.total,
      notTenpai.ukeire.map((o) => o.total).reduce((a, b) => a > b ? a : b),
    );

    final tenpai = buildAdvice(
      makeView(hand: tiles('234567m88p45699s'), drawn: tiles('1z')[0]),
    );
    expect(tenpai.shanten, 0);
    expect(tenpai.ukeire, isEmpty); // テンパイは waits の担当
    expect(tenpai.waits, isNotEmpty);

    final riichi = buildAdvice(
      makeView(
        hand: tiles('234m567m88p45s99s1z'),
        drawn: tiles('7z')[0],
        riichiSeats: {0},
      ),
    );
    expect(riichi.ukeire, isEmpty);
  });
}
