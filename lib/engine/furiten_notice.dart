/// フリテン表示の判定(表示のみ・進行には一切影響しない)。
/// 他家が自分の当たり牌を捨てたが、自分がフリテンでロンできない瞬間かを返す。
library;

import 'models.dart';
import 'tile.dart';

/// [prevDiscardLens]: 前回ビュー時点の各席(0..3)の河の枚数。
/// 新しいビュー [v] で、自分以外の席が新たに捨てた牌が自分の当たり牌で、
/// かつ自分がフリテンなら true。局が変わって河がリセットされた場合は false。
bool furitenNotice({required List<int> prevDiscardLens, required GameView v}) {
  final lens = [for (final p in v.players) p.discards.length];
  // 河が減った=新しい局。基準更新のみで通知しない。
  final reset =
      prevDiscardLens.length != 4 ||
      List.generate(4, (i) => lens[i] < prevDiscardLens[i]).any((x) => x);
  if (reset || !v.myFuriten || v.myWaits.isEmpty) return false;
  for (var i = 0; i < 4; i++) {
    if (i == v.youSeat) continue;
    if (lens[i] > prevDiscardLens[i]) {
      final last = v.players[i].discards.last.tile;
      if (v.myWaits.contains(Tile.normalize(last))) return true;
    }
  }
  return false;
}
