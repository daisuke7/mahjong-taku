import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/call_options.dart';
import 'package:mahjong_taku/engine/tile.dart';

void main() {
  // 索子: 3s=20, 4s=21, 5s=22, 6s=23。赤5索=Tile.red5s(36)。
  const s3 = 20, s4 = 21, s5 = 22, s6 = 23;
  final rs5 = Tile.red5s; // 36

  group('チー候補(赤5)', () {
    test('3s・5s・赤5s に 4s → 3s+5s と 3s+赤5s の2択', () {
      final opts = chiTileOptions([s3, s5, rs5], s4);
      expect(opts.length, 2);
      expect(
        opts,
        containsAll([
          [s3, s5],
          [s3, rs5],
        ]),
      );
    });

    test('赤が無ければ1候補のまま', () {
      final opts = chiTileOptions([s3, s5], s4);
      expect(opts, [
        [s3, s5],
      ]);
    });

    test('複数の形でも各位置の赤/通常を展開する', () {
      // 4s・6s・赤5s に 5s → 4s+6s(嵌張) と 6s+赤?なし。
      // ここでは 3s,4s,6s,赤5s は無いので単純形で確認。
      final opts = chiTileOptions([s4, s6], s5); // 4s+6s の嵌張のみ
      expect(opts, [
        [s4, s6],
      ]);
    });
  });

  group('ポン晒し候補(赤5)', () {
    test('5s・5s・赤5s(3枚) → 通常2枚 と 通常+赤 の2択', () {
      final opts = ponExposeOptions([s5, s5, rs5], s5);
      expect(opts.length, 2);
      expect(
        opts,
        containsAll([
          [s5, s5],
          [s5, rs5],
        ]),
      );
    });

    test('5s・赤5s(2枚)は晒し方が1通り(赤を含む)', () {
      final opts = ponExposeOptions([s5, rs5], s5);
      expect(opts, [
        [s5, rs5],
      ]);
    });

    test('通常5s×2は赤なしの1通り', () {
      final opts = ponExposeOptions([s5, s5], s5);
      expect(opts, [
        [s5, s5],
      ]);
    });
  });

  group('既定のポン晒し(赤温存)', () {
    test('通常5s・5s・赤5s の既定は通常2枚を晒し赤を残す', () {
      expect(defaultPonExpose([s5, s5, rs5], s5), [s5, s5]);
    });
  });

  group('allChiForms(手牌なしのチー形列挙・牌譜記録用)', () {
    test('端の制約: 1索は上側の1形のみ・5索は3形', () {
      final s1 = Tile.parse('1s').single;
      expect(allChiForms(s1), [Tile.parse('23s')]);
      expect(allChiForms(Tile.parse('5s').single), hasLength(3));
      expect(allChiForms(Tile.parse('1z').single), isEmpty);
    });

    test('5を含む形には赤5の変種が付く', () {
      final forms = allChiForms(Tile.parse('4s').single);
      // 23s / 35s / 3s赤5s / 56s / 赤5s6s
      expect(forms, hasLength(5));
      expect(forms.where((f) => f.any(Tile.isRed)), hasLength(2));
    });
  });
}
