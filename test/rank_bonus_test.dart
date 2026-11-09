import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/score.dart';

/// [scores] は席番号順の持ち点。ranking は点数降順・同点は起家(席0)に近い順。
List<int> _bonusFor(List<int> scores) {
  final ranking = List.generate(scores.length, (i) => i)
    ..sort((a, b) {
      final d = scores[b] - scores[a];
      return d != 0 ? d : a - b;
    });
  return splitRankBonus(ranking: ranking, scores: scores);
}

void main() {
  group('順位点の按分(Mリーグ: 同点で終わった場合、順位点を分ける)', () {
    test('同点なしなら従来どおり +50/+10/▲10/▲30', () {
      final b = _bonusFor([40000, 30000, 20000, 10000]);
      expect(b, [50000, 10000, -10000, -30000]);
    });

    test('2・3位が同点 → (10 + ▲10) / 2 = ±0 ずつ', () {
      final b = _bonusFor([40000, 25000, 25000, 10000]);
      expect(b, [50000, 0, 0, -30000]);
    });

    test('1・2位が同点 → (50 + 10) / 2 = +30 ずつ', () {
      final b = _bonusFor([35000, 35000, 20000, 10000]);
      expect(b, [30000, 30000, -10000, -30000]);
    });

    test('3・4位が同点 → (▲10 + ▲30) / 2 = ▲20 ずつ', () {
      final b = _bonusFor([40000, 30000, 15000, 15000]);
      expect(b, [50000, 10000, -20000, -20000]);
    });

    test('2〜4位が同点 → (10 ▲10 ▲30) / 3 = ▲10 ずつ', () {
      final b = _bonusFor([40000, 20000, 20000, 20000]);
      expect(b, [50000, -10000, -10000, -10000]);
    });

    test('全員同点 → (50 + 10 ▲10 ▲30) / 4 = +5 ずつ', () {
      final b = _bonusFor([25000, 25000, 25000, 25000]);
      expect(b, [5000, 5000, 5000, 5000]);
    });

    test('1〜3位が同点(端数あり) → 端数は起家に近い方が大きく取る', () {
      // (50000 + 10000 - 10000) / 3 = 16666.7 → 100点単位で 16700/16700/16600
      final b = _bonusFor([30000, 30000, 30000, 10000]);
      expect(b, [16700, 16700, 16600, -30000]);
      // 合計は分ける前と一致する(ゼロサムが崩れない)
      expect(b.reduce((a, c) => a + c), 50000 + 10000 - 10000 - 30000);
    });

    test('端数配分は ranking の並び順に従う(席番号ではない)', () {
      // 席1,2,3 が同点1〜3位。ranking は [1,2,3,0] になる。
      final scores = [10000, 30000, 30000, 30000];
      final ranking = [1, 2, 3, 0];
      final b = splitRankBonus(ranking: ranking, scores: scores);
      // 戻り値は「順位順」なので、先頭2つが端数の恩恵を受ける
      expect(b, [16700, 16700, 16600, -30000]);
    });

    test('どの同点パターンでも順位点の合計は +20000 で不変', () {
      const patterns = [
        [40000, 30000, 20000, 10000],
        [40000, 25000, 25000, 10000],
        [35000, 35000, 20000, 10000],
        [40000, 30000, 15000, 15000],
        [40000, 20000, 20000, 20000],
        [30000, 30000, 30000, 10000],
        [25000, 25000, 25000, 25000],
        [30000, 30000, 20000, 20000],
      ];
      for (final p in patterns) {
        final b = _bonusFor(p);
        expect(b.reduce((a, c) => a + c), 20000, reason: '$p');
      }
    });

    test('2位と3位が同点でも、点差のある1位・4位の順位点は変わらない', () {
      final b = _bonusFor([50000, 25000, 25000, 0]);
      expect(b[0], 50000);
      expect(b[3], -30000);
    });
  });
}
