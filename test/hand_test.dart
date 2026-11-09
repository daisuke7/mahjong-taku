import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/hand.dart';
import 'package:mahjong_taku/engine/tile.dart';

/// 文字列表記から牌リストを作る: '123m456p789s11z' 形式
/// z: 1=東 2=南 3=西 4=北 5=白 6=發 7=中 / 0=赤5(例: 0m=赤5萬)
List<int> tiles(String notation) {
  final result = <int>[];
  final buffer = <int>[];
  for (final ch in notation.split('')) {
    if (ch == 'm' || ch == 'p' || ch == 's') {
      final base = {'m': 0, 'p': 9, 's': 18}[ch]!;
      final red = {'m': Tile.red5m, 'p': Tile.red5p, 's': Tile.red5s}[ch]!;
      result.addAll(buffer.map((n) => n == 0 ? red : base + n - 1));
      buffer.clear();
    } else if (ch == 'z') {
      result.addAll(buffer.map((n) => 26 + n));
      buffer.clear();
    } else {
      buffer.add(int.parse(ch));
    }
  }
  return result..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
}

void main() {
  group('和了判定', () {
    test('通常形の和了', () {
      expect(
        isWinningHand(toCounts(tiles('123456789m123p11s')), meldCount: 0),
        isTrue,
      );
      expect(
        isWinningHand(toCounts(tiles('111222333m44455p')), meldCount: 0),
        isTrue,
      );
    });

    test('副露込みの和了', () {
      // ポン1つ(手の内11枚)
      expect(
        isWinningHand(toCounts(tiles('123456m11p123s')), meldCount: 1),
        isTrue,
      );
    });

    test('ノーテン形は和了でない', () {
      expect(
        isWinningHand(toCounts(tiles('123456789m124p11s')), meldCount: 0),
        isFalse,
      );
    });

    test('七対子', () {
      expect(isChiitoi(toCounts(tiles('1122m3344p5566s77z'))), isTrue);
      // 同種4枚は七対子にならない
      expect(isChiitoi(toCounts(tiles('1111m3344p5566s77z'))), isFalse);
    });

    test('国士無双', () {
      expect(isKokushi(toCounts(tiles('19m19p19s1234567z1m'))), isTrue);
      expect(isKokushi(toCounts(tiles('19m19p19s1234567z2m'))), isFalse);
    });
  });

  group('待ち', () {
    test('多面待ち', () {
      final waits = calcWaits(
        toCounts(tiles('23456789m123p11s')),
        meldCount: 0,
      );
      expect(waits.toSet(), tiles('147m').toSet());
    });

    test('単騎待ち', () {
      final waits = calcWaits(
        toCounts(tiles('123456789m123p1s')),
        meldCount: 0,
      );
      expect(waits, equals(tiles('1s')));
    });
  });

  group('シャンテン数', () {
    test('和了形は -1', () {
      // 14枚の和了形から1枚除いた13枚はテンパイ(0)
      expect(calcShanten(toCounts(tiles('123456789m123p1s')), meldCount: 0), 0);
    });

    test('テンパイは 0', () {
      expect(calcShanten(toCounts(tiles('23456789m123p11s')), meldCount: 0), 0);
    });

    test('ブロック過剰でも正しい(雀頭なし5ブロック)', () {
      // 123m 456m 789m + 12p + 45p → 1シャンテン(雀頭がない)
      expect(calcShanten(toCounts(tiles('123456789m1245p')), meldCount: 0), 1);
    });

    test('雀頭ありの4ブロック目はテンパイ', () {
      // 123m 456m 789m + 11p + 45p → テンパイ(3p/6p待ち)
      expect(calcShanten(toCounts(tiles('123456789m1145p')), meldCount: 0), 0);
    });

    test('七対子のシャンテン', () {
      // 対子5つ+バラ3枚 → 七対子1シャンテン
      expect(
        calcShanten(toCounts(tiles('1122m3344p556s79s')), meldCount: 0),
        lessThanOrEqualTo(1),
      );
    });

    test('国士のシャンテン', () {
      expect(
        calcShanten(toCounts(tiles('19m19p19s123456z5m')), meldCount: 0),
        1,
      );
    });

    test('配牌級のバラバラ手', () {
      final s = calcShanten(toCounts(tiles('147m258p369s1234z')), meldCount: 0);
      expect(s, greaterThanOrEqualTo(4));
    });
  });

  group('ドラ', () {
    test('ドラ表示牌の次がドラ', () {
      expect(Tile.doraFromIndicator(tiles('1m')[0]), tiles('2m')[0]);
      expect(Tile.doraFromIndicator(tiles('9m')[0]), tiles('1m')[0]);
      expect(Tile.doraFromIndicator(tiles('4z')[0]), tiles('1z')[0]); // 北→東
      expect(Tile.doraFromIndicator(tiles('7z')[0]), tiles('5z')[0]); // 中→白
      // 赤5が表示牌でも次は6
      expect(Tile.doraFromIndicator(Tile.red5m), tiles('6m')[0]);
    });
  });

  group('赤ドラ(Mリーグルール)', () {
    test('山は136枚で赤5が各色1枚', () {
      final wall = Tile.fullWall();
      expect(wall.length, 136);
      expect(wall.where(Tile.isRed).length, 3);
      // 赤を含めて5は各色4枚
      for (final five in [4, 13, 22]) {
        expect(wall.where((t) => Tile.normalize(t) == five).length, 4);
      }
    });

    test('赤5は通常の5として和了判定される', () {
      // 345m(赤5) 678m 234p 55s 999s
      final hand = tiles('340m678m234p55999s');
      expect(isWinningHand(toCounts(hand), meldCount: 0), isTrue);
      expect(hand.where(Tile.isRed).length, 1);
    });

    test('赤5は手牌ソートで5の隣に並ぶ', () {
      final hand = tiles('905m')
        ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
      expect(hand[0], 4); // 5m
      expect(hand[1], Tile.red5m);
      expect(hand[2], 8); // 9m
    });
  });
}
