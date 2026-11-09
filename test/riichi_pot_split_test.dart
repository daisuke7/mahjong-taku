import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/score.dart';

/// Mリーグ 第6章第2条(持ち点・順位点)の要旨:
///
/// - 項目2: 順位は終了時の合計得点で決める。
/// - 項目5: 流局で終わったときの場のリーチ棒はトップ者に入る。
/// - 項目6: 同点なら順位点を分け、端数は起家に近い方が多く取る。流局終了時のリーチ棒も
///   同点者で均等に分ける(規定の例示: 3 名同点で 1000 点なら 400・300・300、
///   2000 点なら 800・600・600)。端数の優先も順位点と同じ。
void main() {
  group('splitRiichiPot: 同点トップでのリーチ棒の分配', () {
    test('トップが1人なら全額', () {
      expect(splitRiichiPot(1000, 1), [1000]);
      expect(splitRiichiPot(3000, 1), [3000]);
    });

    test('2名同点は均等(500ずつ)', () {
      expect(splitRiichiPot(1000, 2), [500, 500]);
      expect(splitRiichiPot(2000, 2), [1000, 1000]);
    });

    test('3名同点は400・300・300(原文が名指しで指定)', () {
      expect(splitRiichiPot(1000, 3), [400, 300, 300]);
    });

    test('3名同点で割り切れない場合は等倍する(2000点なら800・600・600)', () {
      expect(splitRiichiPot(2000, 3), [800, 600, 600]);
      expect(splitRiichiPot(3000, 3), [1200, 900, 900]);
    });

    test('4名同点は均等(供託2本なら500ずつ)', () {
      // 4名同点は供託が偶数本のときしか成立しない(下の不変条件テスト参照)
      expect(splitRiichiPot(2000, 4), [500, 500, 500, 500]);
      expect(splitRiichiPot(4000, 4), [1000, 1000, 1000, 1000]);
    });

    test('分配の合計は必ず場に出た額と一致する', () {
      for (final pot in [1000, 2000, 3000, 4000, 5000]) {
        for (var n = 1; n <= 4; n++) {
          if (n == 4 && (pot ~/ 1000).isOdd) continue; // 成立しない局面
          final shares = splitRiichiPot(pot, n);
          expect(shares.length, n);
          expect(
            shares.reduce((a, b) => a + b),
            pot,
            reason: '$pot点を$n人で分けた合計が合わない',
          );
        }
      }
    });

    // 麻雀の点棒は100点単位で、100点未満の授受は発生しない。
    // 原文が3名の場合だけ 400・300・300 を名指しするのはこの制約のためで、
    // 1000÷3 が100点単位に割り切れない。2名(500ずつ)は割り切れるので規定が要らない。
    test('分配はすべて100点単位(100点未満の授受は麻雀に存在しない)', () {
      for (var sticks = 1; sticks <= 6; sticks++) {
        final pot = sticks * 1000;
        for (var n = 1; n <= 4; n++) {
          if (n == 4 && sticks.isOdd) continue; // 成立しない局面(下記テスト)
          for (final share in splitRiichiPot(pot, n)) {
            expect(
              share % 100,
              0,
              reason: 'pot=$pot n=$n → $share は100点未満の端数を生む',
            );
          }
        }
      }
    });

    test('4名同点は供託が偶数本のときしか成立しない', () {
      // 全員の持ち点が等しいなら 各自 = (100000 - 1000N)/4 = 25000 - 250N。
      // 持ち点は100点単位なので、N が奇数だと成立しない。
      // → 供託1本での4人同点は起こり得ず、250点ずつという分配も現実には生じない。
      for (var sticks = 1; sticks <= 6; sticks++) {
        final each = 25000 - 250 * sticks;
        expect(
          each % 100 == 0,
          sticks.isEven,
          reason: '供託$sticks本で4人同点なら各自$each点 → 100点単位に反する',
        );
      }
    });

    test('端数は起家に近い方(先頭)が大きい', () {
      for (final pot in [1000, 2000, 3000]) {
        final shares = splitRiichiPot(pot, 3);
        // 先頭が最大で、以降は非増加
        for (var i = 1; i < shares.length; i++) {
          expect(
            shares[i - 1],
            greaterThanOrEqualTo(shares[i]),
            reason: '$pot点: 起家に近い方が大きくない',
          );
        }
        expect(shares.first, greaterThan(shares.last));
      }
    });
  });

  // settleGame は _finishGame の中身そのもの。バグの本体は「リーチ棒を配る前に
  // 順位・同点を判定する」という順序にあり、純粋関数に切り出して直接検証する。
  group('settleGame: 半荘終了時の精算', () {
    test('トップ2人同点+リーチ棒1本: 均等に分かれ、順位点も按分される', () {
      // 席0/席1 が30000で同点トップ、席2=20000、席3=19000
      final r = settleGame(scores: [30000, 30000, 20000, 19000], pot: 1000);

      // リーチ棒は500ずつ → 同点が保たれる
      expect(r.finalScores, [30500, 30500, 20000, 19000]);
      // 順位点は (50000+10000)/2 = 30000 ずつ → 最終ポイントも等しい
      expect(r.points[0], 30.5);
      expect(r.points[1], 30.5);
      expect(r.points[2], -20.0);
      expect(r.points[3], -41.0);
    });

    test('リーチ棒を先に配って同点を解消してはいけない(バグの再現防止)', () {
      // 先に配ると 席0=31000/1位(+51.0)、席1=30000/2位(+10.0) となり 41pt ずれる
      final r = settleGame(scores: [30000, 30000, 20000, 19000], pot: 1000);
      expect(r.points[0], isNot(51.0), reason: 'リーチ棒で同点を解消している');
      expect(r.points[1], isNot(10.0));
      expect(r.points[0], r.points[1], reason: '同点なら最終ポイントも等しいはず');
    });

    test('トップが1人ならリーチ棒は全額その人に乗る', () {
      final r = settleGame(scores: [31000, 30000, 20000, 18000], pot: 1000);
      expect(r.finalScores, [32000, 30000, 20000, 18000]);
      expect(r.points[0], 52.0, reason: '2.0(素点) + 50.0(順位点)');
      expect(r.points[1], 10.0);
    });

    test('トップ3人同点+リーチ棒1本: 400・300・300 で分かれる', () {
      // 供託1000が場に出ているので、持ち点の合計は 100000-1000 = 99000
      final r = settleGame(scores: [30000, 30000, 30000, 9000], pot: 1000);
      expect(r.finalScores, [30400, 30300, 30300, 9000], reason: '起家に近い方が大きい');
      // 順位点は (50000+10000-10000)/3 → 16700/16700/16600
      expect(r.points[0], closeTo(17.1, 1e-9)); // 0.4 + 16.7
      expect(r.points[1], closeTo(17.0, 1e-9)); // 0.3 + 16.7
      expect(r.points[2], closeTo(16.9, 1e-9)); // 0.3 + 16.6
      expect(r.points[3], closeTo(-51.0, 1e-9));
    });

    test('リーチ棒が無ければ従来どおり(和了で半荘が終わった場合)', () {
      final r = settleGame(scores: [30000, 30000, 20000, 20000], pot: 0);
      expect(r.finalScores, [30000, 30000, 20000, 20000]);
      expect(r.points[0], 30.0);
      expect(r.points[1], 30.0);
      expect(r.points[2], -30.0);
      expect(r.points[3], -30.0);
    });

    test('同点でないトップに対しては、下位の同点按分が普通に働く', () {
      // 2位/3位が同点。リーチ棒はトップ(席0)へ全額
      final r = settleGame(scores: [40000, 25000, 25000, 9000], pot: 1000);
      expect(r.finalScores, [41000, 25000, 25000, 9000]);
      expect(r.points[0], 61.0);
      // 2位3位の順位点は (10000 + -10000)/2 = 0 ずつ
      expect(r.points[1], -5.0);
      expect(r.points[2], -5.0);
      expect(r.points[3], -51.0);
    });

    test('4人同点+リーチ棒2本: 500ずつで全員が同ポイント', () {
      // 供託2000が出ているので持ち点合計は98000 → 24500ずつ。
      // (供託1本での4人同点は 24750点 となり100点単位に反するので成立しない)
      final r = settleGame(scores: [24500, 24500, 24500, 24500], pot: 2000);
      expect(r.finalScores, [25000, 25000, 25000, 25000]);
      // 順位点は (50000+10000-10000-30000)/4 = 5000 ずつ
      for (var i = 0; i < 4; i++) {
        expect(r.points[i], closeTo(0.0, 1e-9));
      }
    });

    test('どの分配でもポイントの合計は必ず0(ゼロサム)', () {
      // 局面として成立するテストデータの条件は2つある。片方だけでは足りない:
      //   (1) 持ち点の合計 + 供託 = 100000(25000×4) — 供託が場に出ているぶん持ち点は減る
      //   (2) 持ち点も分配後も100点単位 — 麻雀に100点未満は存在しない
      // (1)だけ満たして(2)を破るデータ(例: 24750点)は書けてしまうので、両方を検査する。
      final cases = [
        ([30000, 30000, 20000, 19000], 1000),
        ([30000, 30000, 30000, 9000], 1000),
        ([30000, 30000, 30000, 8000], 2000),
        ([24500, 24500, 24500, 24500], 2000),
        ([40000, 25000, 25000, 7000], 3000),
        ([31000, 30000, 20000, 19000], 0),
        ([30000, 30000, 20000, 20000], 0),
      ];
      for (final (scores, pot) in cases) {
        expect(
          scores.reduce((a, b) => a + b) + pot,
          100000,
          reason: 'テストデータが局面として成立していない: scores=$scores pot=$pot',
        );
        for (final v in scores) {
          expect(v % 100, 0, reason: '$v点は100点単位でない: scores=$scores');
        }

        final r = settleGame(scores: scores, pot: pot);
        expect(
          r.points.reduce((a, b) => a + b),
          closeTo(0.0, 1e-9),
          reason: 'scores=$scores pot=$pot',
        );
        // 点棒も保存されている(場に出た分が漏れなく誰かに渡る)
        expect(
          r.finalScores.reduce((a, b) => a + b),
          100000,
          reason: 'scores=$scores pot=$pot',
        );
        // 分配後も100点単位を保つ
        for (final v in r.finalScores) {
          expect(v % 100, 0, reason: '$v点は100点単位でない: scores=$scores pot=$pot');
        }
      }
    });
  });
}
