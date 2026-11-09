/// 喰い替え禁止の判定。鳴いた直後に打てない牌(牌種・正規化済)を返す。
/// - モロ(現物)喰い替え: チー/ポンした牌と同種。
/// - スジ喰い替え: 両面チー(鳴いた牌が順子の端)のとき反対側のスジ。
/// - 刻子喰い替え: ポン(刻子)した牌と同種。
library;

import 'tile.dart';

/// チーで作った順子 [run](牌種・昇順3枚)と鳴いた牌 [called] に対する禁止牌。
/// モロ(現物)+ 両面チーのスジ。嵌張・辺張チーはモロのみ。
List<int> chiKuikaeForbidden(List<int> run, int called) {
  final result = <int>{called}; // モロ(現物)喰い替え
  // 鳴いた牌が順子の下端(両面)→ 反対側の上スジを禁止(例: 5s6sで4s→7s)
  if (called == run[0] && Tile.number(run[2]) < 9) {
    result.add(run[2] + 1);
  }
  // 鳴いた牌が順子の上端(両面)→ 反対側の下スジを禁止(例: 5s6sで7s→4s)
  if (called == run[2] && Tile.number(run[0]) > 1) {
    result.add(run[0] - 1);
  }
  return result.toList();
}

/// ポン(刻子)の喰い替え禁止牌: 鳴いた牌と同種(刻子喰い替え)。
List<int> ponKuikaeForbidden(int kind) => [kind];
