import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/advisor.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'advisor_test.dart' show makeView;
import 'hand_test.dart' show tiles;

/// 最攻撃打牌(赤グロー)の同率首位タイブレーク。
/// 受け枚数が同じ打牌候補は くっつき見込み → 残す価値(ドラ・役牌・中寄り)
/// の順で決める。makeView は 席0=北家・東場(1z=場風、2z3z=客風)。
void main() {
  // 基本形: 234m 567m 88p 45s 99s + 字牌浮き2枚 → 字牌切り2択が
  // 同ウケ(3s6s8p9s)で同率首位になる。
  test('くっつき見込み: 対子になる見込みの薄い(枯れた)字牌から切る', () {
    // 7z が場に2枚見えている → 1z(残り3枚)の方が対子になりやすい
    final view = makeView(
      hand: tiles('234m567m88p45s99s1z'),
      drawn: tiles('7z')[0],
      rivers: {1: tiles('7z7z')},
    );
    final options = ukeireOptions(view);
    expect(options.first.total, options[1].total, reason: '前提: 同率首位');
    expect(attackGlowTile(view), tiles('7z')[0]);
  });

  test('くっつき見込み: 見え枚数が同じなら順序は既存どおり(牌順)', () {
    final view = makeView(
      hand: tiles('234m567m88p45s99s1z'),
      drawn: tiles('7z')[0],
    );
    // 1z(場風)と7z(中)は価値も同点なので牌順で1z
    expect(attackGlowTile(view), tiles('1z')[0]);
  });

  test('くっつき見込み: 周辺が枯れた数牌の浮き牌から切る', () {
    // 234m 567m 88p 99p 12s(ブロック5つ)+ 浮き牌 5p・ツモ5s。
    // 5p切り・5s切りはどちらも1シャンテン維持で同ウケ(3s8p9p)だが、
    // 4s6s が場に2枚ずつ見えていて 5s のくっつきは見込み薄。
    final view = makeView(
      hand: tiles('234m567m88p99p12s5p'),
      drawn: tiles('5s')[0],
      rivers: {1: tiles('4s4s6s6s')},
    );
    final options = ukeireOptions(view);
    expect(options.first.total, options[1].total, reason: '前提: 同率首位');
    expect(attackGlowTile(view), tiles('5s')[0]);
  });

  test('価値: ドラの字牌は残して、もう片方を切る', () {
    // ドラ表示2z → ドラ3z。河の3zで残り枚数を2枚ずつにそろえ、
    // 2段階ウケも同点にする(価値だけで決まる状況)。
    final view = makeView(
      hand: tiles('234m567m88p45s99s2z'),
      drawn: tiles('3z')[0],
      doraIndicators: tiles('2z'),
      rivers: {1: tiles('3z')},
    );
    expect(attackGlowTile(view), tiles('2z')[0]);
  });

  test('価値: 役牌(中)は残して、客風を切る', () {
    final view = makeView(
      hand: tiles('234m567m88p45s99s2z'),
      drawn: tiles('7z')[0],
    );
    expect(attackGlowTile(view), tiles('2z')[0]);
  });

  test('テンパイ: 待ち枚数が同じならドラ側の待ちを選ぶ', () {
    // 234m 678m 345p 567s 99s の和了形から1枚切る場面。
    // 2m切り(34m→2m5m待ち)・8m切り(67m→5m8m待ち)・3p切り(45p→3p6p待ち)は
    // どれも待ち7枚だが、ドラ表示4m(ドラ5m)で 5m を含む待ちの打点が上。
    final view = makeView(
      hand: tiles('234m678m345p567s9s'),
      drawn: tiles('9s')[0],
      doraIndicators: tiles('4m'),
    );
    final waits = tenpaiWaits(view);
    final m2 = Tile.normalize(tiles('2m')[0]);
    final m8 = Tile.normalize(tiles('8m')[0]);
    final p3 = Tile.normalize(tiles('3p')[0]);
    final order = [for (final o in waits) Tile.normalize(o.discard!)];
    // 同率(7枚)グループの先頭2つがドラ受けの 2m切り・8m切り
    expect(order.indexOf(m2), lessThan(order.indexOf(p3)));
    expect(order.indexOf(m8), lessThan(order.indexOf(p3)));
    expect(attackGlowTile(view), tiles('2m')[0]);
  });

  test('テンパイ: ドラそのものを切る候補は後回しになる', () {
    // ドラ表示2p → ドラ3p。3p切りだけは手からドラが消え、
    // 3p和了のときしかドラが乗らない。他の切り方は 345p を残すので
    // どの和了でもドラ1が付き、打点期待で上回る。
    final view = makeView(
      hand: tiles('234m678m345p567s9s'),
      drawn: tiles('9s')[0],
      doraIndicators: tiles('2p'),
    );
    final waits = tenpaiWaits(view);
    expect(
      Tile.normalize(waits.first.discard!),
      isNot(Tile.normalize(tiles('3p')[0])),
    );
  });
}
