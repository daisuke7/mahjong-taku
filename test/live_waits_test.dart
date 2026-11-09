import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/hand.dart';
import 'package:mahjong_taku/engine/tile.dart';

// 牌ID: 0-8=1m-9m / 9-17=1p-9p / 18-26=1s-9s / 27-33=東南西北白發中
const m1 = 0, m2 = 1, m3 = 2, m4 = 3, m5 = 4, m6 = 5;
const p1 = 9, p2 = 10, p3 = 11, p4 = 12, p5 = 13, p6 = 14;
const p7 = 15, p8 = 16, p9 = 17;

void main() {
  // Mリーグルール:「聴牌とはアガリが可能となった状態だが、自己の手牌・副露牌で
  // アガリ牌が消去されている場合は認められない。」
  group('calcLiveWaits: 自分で4枚使い切った待ちは認めない', () {
    test('中をポン+中単騎 → 中は自分で4枚使い切りなのでノーテン', () {
      // 手牌10枚: 123m 456m 789p 中(単騎) / 副露: 中ポン(3枚)
      final hand = toCounts([m1, m2, m3, m4, m5, m6, p7, p8, p9, Tile.chun]);
      final melds = toCounts([Tile.chun, Tile.chun, Tile.chun]);

      // 形の上では中単騎テンパイ
      expect(calcWaits(hand, meldCount: 1), [Tile.chun]);
      // しかし中は手牌1枚+副露3枚=4枚を自分で使い切っており場に残っていない
      expect(calcLiveWaits(hand, melds, meldCount: 1), isEmpty);
    });

    test('別の牌のポンなら中単騎は生きている', () {
      final hand = toCounts([m1, m2, m3, m4, m5, m6, p7, p8, p9, Tile.chun]);
      final melds = toCounts([Tile.east, Tile.east, Tile.east]);

      expect(calcLiveWaits(hand, melds, meldCount: 1), [Tile.chun]);
    });

    test('暗槓で4枚使い切った牌のカンチャン待ち → ノーテン', () {
      // 手牌10枚: 123p 456p 99p 4m6m(5m待ち) / 副露: 5m暗槓(4枚)
      final hand = toCounts([p1, p2, p3, p4, p5, p6, p9, p9, m4, m6]);
      final melds = toCounts([m5, m5, m5, m5]);

      expect(calcWaits(hand, meldCount: 1), [m5]);
      expect(calcLiveWaits(hand, melds, meldCount: 1), isEmpty);
    });

    test('両面待ちの片側だけが死んでいる場合、生きている側でテンパイ継続', () {
      // 手牌10枚: 123p 456p 99p 4m5m(3m/6m待ち) / 副露: 3m暗槓(4枚)
      final hand = toCounts([p1, p2, p3, p4, p5, p6, p9, p9, m4, m5]);
      final melds = toCounts([m3, m3, m3, m3]);

      expect(calcWaits(hand, meldCount: 1), [m3, m6]);
      // 3mは自分で4枚使い切り → 6m待ちのテンパイとして残る
      expect(calcLiveWaits(hand, melds, meldCount: 1), [m6]);
    });

    test('ポン3枚だけでは4枚に届かないので待ちは生きている', () {
      // 5mポン(3枚)+4m6mのカンチャン → 5mは場にまだ1枚残る
      final hand = toCounts([p1, p2, p3, p4, p5, p6, p9, p9, m4, m6]);
      final melds = toCounts([m5, m5, m5]);

      expect(calcLiveWaits(hand, melds, meldCount: 1), [m5]);
    });

    test('副露なしの通常のテンパイは影響を受けない', () {
      // 門前13枚: 123m 456m 789p 123p 9p(単騎ではなく通常の待ち)
      final hand = toCounts([
        m1,
        m2,
        m3,
        m4,
        m5,
        m6,
        p7,
        p8,
        p9,
        p1,
        p2,
        p3,
        p9,
      ]);
      final melds = List<int>.filled(Tile.kindCount, 0);

      expect(
        calcLiveWaits(hand, melds, meldCount: 0),
        calcWaits(hand, meldCount: 0),
      );
      expect(calcLiveWaits(hand, melds, meldCount: 0), isNotEmpty);
    });

    test('手牌だけで4枚使い切る形は calcWaits の時点で既に除かれている', () {
      // calcWaits は counts[t] >= 4 をスキップするため、手牌内4枚は元々対象外。
      // calcLiveWaits はそこに副露分の考慮を足したもの。
      final hand = toCounts([
        m1,
        m2,
        m3,
        m4,
        m5,
        m6,
        p7,
        p8,
        p9,
        p1,
        p1,
        p1,
        p1,
      ]);
      final melds = List<int>.filled(Tile.kindCount, 0);

      expect(calcWaits(hand, meldCount: 0).contains(p1), isFalse);
      expect(
        calcLiveWaits(hand, melds, meldCount: 0),
        calcWaits(hand, meldCount: 0),
      );
    });

    test('ノーテンの手はどちらでも空', () {
      final hand = toCounts([
        m1,
        m3,
        m5,
        p7,
        p9,
        p2,
        p4,
        p6,
        Tile.east,
        Tile.chun,
      ]);
      final melds = toCounts([Tile.haku, Tile.haku, Tile.haku]);

      expect(calcWaits(hand, meldCount: 1), isEmpty);
      expect(calcLiveWaits(hand, melds, meldCount: 1), isEmpty);
    });
  });
}
