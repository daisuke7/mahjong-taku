import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/tile.dart';

/// 牌表記の読み取り。牌譜DBは 2026-10-01 リリースから手牌が ',' 区切りになった
/// (配布元 DB_CHANGELOG「牌の並べ方をそろえた」)。連結形と同じ結果になること。
void main() {
  test('連結形と , 区切り形は同じ牌列になる(赤5・字牌含む)', () {
    final compact = Tile.parse('1459m18p309s1355z');
    final comma = Tile.parse('1m,4m,5m,9m,1p,8p,3s,0s,9s,1z,3z,5z,5z');
    expect(comma, compact);
    expect(comma.length, 13);
    expect(comma.where(Tile.isRed).length, 1);
    expect(Tile.parse('3m,3m,6m,3p,8p,4s,0s,9s,3z,5z,5z,5z,7z').length, 13);
  });

  test('空文字と空白は無視する', () {
    expect(Tile.parse(''), isEmpty);
    expect(Tile.parse('1m, 2m'), Tile.parse('12m'));
  });
}
