/// 公開情報(河・鳴き・ドラ表示)と自分の手牌から計算する安全度・残り枚数。
/// CPUの押し引きとアドバイス機能で共用する。
library;

import 'models.dart';
import 'tile.dart';

/// 見えている範囲(全員の河・副露・ドラ表示・自分の手牌)からの残り枚数
int remainingOf(int kind, GameView? view, List<int> myHand) {
  var visible = myHand.where((t) => Tile.normalize(t) == kind).length;
  if (view != null) {
    for (final p in view.players) {
      for (final d in p.discards) {
        if (Tile.normalize(d.tile) == kind) visible++;
      }
      for (final m in p.melds) {
        visible += m.tiles.where((t) => Tile.normalize(t) == kind).length;
      }
    }
    for (final d in view.doraIndicators) {
      if (Tile.normalize(d) == kind) visible++;
    }
  }
  final left = 4 - visible;
  return left < 0 ? 0 : left;
}

/// リーチ者1人に対する安全度(高いほど安全、100=現物)
int safetyVs(int kind, int threat, List<int> myHand, GameView view) {
  final tp = view.players[threat];
  final river = tp.discards.map((d) => Tile.normalize(d.tile)).toSet();
  if (river.contains(kind)) return 100; // 現物

  // リーチ者は見逃すと永久フリテンになるため、
  // リーチ宣言後に誰かが捨てて通った牌も現物同様に安全
  if (tp.riichi) {
    var riichiOrder = 1 << 30;
    for (final d in tp.discards) {
      if (d.riichi) {
        riichiOrder = d.order;
        break;
      }
    }
    for (final p in view.players) {
      for (final d in p.discards) {
        if (d.order > riichiOrder && Tile.normalize(d.tile) == kind) {
          return 100;
        }
      }
    }
  }
  if (Tile.isHonor(kind)) {
    // 場に見えている枚数(自分の手牌込み)が多い字牌ほど安全
    final visible = 4 - remainingOf(kind, view, myHand);
    if (visible >= 3) return 90;
    if (visible == 2) return 70;
    return 45;
  }
  final n = Tile.number(kind);
  // スジ(4-6は両スジ、端寄りは片スジ)
  final suji = n >= 4 && n <= 6
      ? river.contains(kind - 3) && river.contains(kind + 3)
      : (n <= 3 ? river.contains(kind + 3) : river.contains(kind - 3));
  if (suji) return n >= 4 && n <= 6 ? 60 : 55;
  if (n == 1 || n == 9) return 35;
  if (n == 2 || n == 8) return 25;
  return 15;
}
