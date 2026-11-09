import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/kuikae.dart';

void main() {
  // 索子: 1s=18, 2s=19, 3s=20, 4s=21, 5s=22, 6s=23, 7s=24, 8s=25, 9s=26
  const s1 = 18,
      s2 = 19,
      s3 = 20,
      s4 = 21,
      s5 = 22,
      s6 = 23,
      s7 = 24,
      s8 = 25,
      s9 = 26;

  group('チーの喰い替え', () {
    test('モロ喰い替え: 鳴いた牌と同種は禁止(嵌張チーはモロのみ)', () {
      // 3s5s で 4s(嵌張)→ 4s のみ禁止(スジは無い)
      expect(chiKuikaeForbidden([s3, s4, s5], s4), [s4]);
    });

    test('スジ喰い替え(下端): 5s6sで4s → 4s と 7s', () {
      final f = chiKuikaeForbidden([s4, s5, s6], s4);
      expect(f.toSet(), {s4, s7});
    });

    test('スジ喰い替え(上端): 5s6sで7s → 7s と 4s', () {
      final f = chiKuikaeForbidden([s5, s6, s7], s7);
      expect(f.toSet(), {s7, s4});
    });

    test('辺張(1s2sで3s)はスジ無し=モロのみ', () {
      expect(chiKuikaeForbidden([s1, s2, s3], s3), [s3]);
    });

    test('辺張(8s9sで7s)はスジ無し=モロのみ', () {
      expect(chiKuikaeForbidden([s7, s8, s9], s7), [s7]); // 7s8s9s で 7s
    });

    test('端側の両面: 2s3sで1s → 1s と 4s', () {
      final f = chiKuikaeForbidden([s1, s2, s3], s1);
      expect(f.toSet(), {s1, s4});
    });
  });

  group('ポンの喰い替え(刻子喰い替え)', () {
    test('鳴いた牌と同種を禁止', () {
      expect(ponKuikaeForbidden(s5), [s5]);
    });
  });
}
