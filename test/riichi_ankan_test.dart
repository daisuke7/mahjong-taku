import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/hand.dart';
import 'package:mahjong_taku/engine/tile.dart';

// 牌ID: 0-8=1m-9m / 9-17=1p-9p / 18-26=1s-9s / 27-33=東南西北白發中
const m1 = 0, m2 = 1, m3 = 2, m4 = 3, m5 = 4, m6 = 5, m7 = 6, m8 = 7, m9 = 8;
const p1 = 9, p2 = 10, p3 = 11, p5 = 13, p9 = 17;
const s5 = 22;

void main() {
  // リーチ後の暗槓が認められるのは
  //   1. ツモ牌での暗槓であること(送り槓禁止)
  //   2. 待ちが変わらないこと
  //   3. 面子構成が変わらないこと
  // の3条件。ankanKeepsComposition は 3 を判定する。
  group('ankanKeepsComposition: リーチ後の暗槓で面子構成が変わらないか', () {
    test('三連刻/三順子の両方に解釈できる形は暗槓不可', () {
      // 聴牌手13枚: 222m 333m 444m 99p 55s → 9p/5s のシャンポン待ち
      // 「222m+333m+444m(三連刻)」とも「234m+234m+234m(三順子)」とも解釈できる。
      // 2m を暗槓すると後者の解釈が消える = 面子構成が変わる → 不可。
      final before = toCounts([
        m2, m2, m2, m3, m3, m3, m4, m4, m4, //
        p9, p9, s5, s5,
      ]);
      final waits = calcWaits(before, meldCount: 0);
      expect(waits, [p9, s5], reason: '9p/5sのシャンポン待ちであること');

      // 2m は待ちではない(4枚目を引いてもアガリではない)ので暗槓の候補になる
      expect(waits.contains(m2), isFalse);

      expect(
        ankanKeepsComposition(before, m2, waits),
        isFalse,
        reason: '234m×3 の解釈が消えるので暗槓は不可',
      );
    });

    test('三連刻/三順子の形は 3m・4m の暗槓も不可', () {
      final before = toCounts([
        m2, m2, m2, m3, m3, m3, m4, m4, m4, //
        p9, p9, s5, s5,
      ]);
      final waits = calcWaits(before, meldCount: 0);

      expect(ankanKeepsComposition(before, m3, waits), isFalse);
      expect(ankanKeepsComposition(before, m4, waits), isFalse);
    });

    test('孤立した暗刻の暗槓は可(四暗刻シャンポン)', () {
      // 聴牌手13枚: 555m 555p 555s 東東 西西 → 東/西 のシャンポン待ち
      // 5m は順子に使えないので、暗槓しても解釈は変わらない。
      final before = toCounts([
        m5, m5, m5, p5, p5, p5, s5, s5, s5, //
        Tile.east, Tile.east, Tile.west, Tile.west,
      ]);
      final waits = calcWaits(before, meldCount: 0);
      expect(waits, [Tile.east, Tile.west]);

      expect(ankanKeepsComposition(before, m5, waits), isTrue);
      expect(ankanKeepsComposition(before, p5, waits), isTrue);
      expect(ankanKeepsComposition(before, s5, waits), isTrue);
    });

    test('順子に使えない字牌の暗刻は暗槓可', () {
      // 聴牌手13枚: 東東東 123m 456m 789m 9p(単騎)
      final before = toCounts([
        Tile.east, Tile.east, Tile.east, //
        m1, m2, m3, m4, m5, m6, m7, m8, m9, p9,
      ]);
      final waits = calcWaits(before, meldCount: 0);
      expect(waits, [p9], reason: '9p単騎');

      expect(ankanKeepsComposition(before, Tile.east, waits), isTrue);
    });

    test('暗刻が順子とも解釈できる形は暗槓不可', () {
      // 聴牌手13枚: 111m 123m 456m 789m 9p(単騎)
      // 1m×4 相当ではなく 1m×3 + 23m。
      // 「111m + 23m…」と「123m + 11m…」の両解釈があり得るかを確認する。
      final before = toCounts([
        m1,
        m1,
        m1,
        m2,
        m3,
        m4,
        m5,
        m6,
        m7,
        m8,
        m9,
        p9,
        p9,
      ]);
      final waits = calcWaits(before, meldCount: 0);
      // 111m + 234m? ではなく: 111m + 456m + 789m + 99p + 23m → 1m/4m待ち
      expect(waits.isNotEmpty, isTrue);

      // 1m が順子(123m)としても使える解釈があるなら暗槓不可になる
      final keeps = ankanKeepsComposition(before, m1, waits);
      // この形では 1m を待ちに含むため、そもそも暗槓の場面にならないが、
      // 判定関数としては「暗刻に確定していない」を検出できること
      expect(keeps, isFalse);
    });

    test('待ちが複数でも、すべての和了形で暗刻ならば可', () {
      // 聴牌手13枚: 東東東 123p 456m 789m 12m → 3m待ち(単一)…を複数待ちに広げる
      // 東東東 + 456m + 789m + 123p + 9p 単騎 は上でテスト済みなので、
      // ここでは 中中中 + 234m + 567m + 88p + 9p の形を使う
      final before = toCounts([
        Tile.chun, Tile.chun, Tile.chun, //
        m2, m3, m4, m5, m6, m7, //
        p1, p1, p2, p3,
      ]);
      final waits = calcWaits(before, meldCount: 0);
      expect(waits.isNotEmpty, isTrue);

      expect(
        ankanKeepsComposition(before, Tile.chun, waits),
        isTrue,
        reason: '字牌の暗刻は順子に使えないので常に暗刻確定',
      );
    });
  });
}
