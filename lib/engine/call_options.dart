/// チー・ポンの副露候補生成。赤牌(赤5)が絡む場合に、赤/通常のどちらを
/// 使う(晒す)かを別候補として展開する。牌は実牌ID(赤=34..36)で扱う。
library;

import 'tile.dart';

/// 手牌中の指定牌種の実牌を、赤/通常で重複排除して返す(小ID=通常が先)。
List<int> uniqueTilesOfKind(List<int> hand, int kind) {
  final set = <int>{
    for (final t in hand)
      if (Tile.normalize(t) == kind) t,
  };
  return set.toList()..sort();
}

/// ポンで晒す2枚の候補。赤の有無で別候補にする(重複排除・通常が先)。
/// 例: 手牌に 5s,5s,赤5s → [[5s,5s],[5s,赤5s]] (赤を温存/晒すの2択)。
List<List<int>> ponExposeOptions(List<int> hand, int kind) {
  final owned = hand.where((t) => Tile.normalize(t) == kind).toList()..sort();
  final seen = <String>{};
  final out = <List<int>>[];
  for (var x = 0; x < owned.length; x++) {
    for (var y = x + 1; y < owned.length; y++) {
      final pair = [owned[x], owned[y]];
      if (seen.add('${pair[0]}_${pair[1]}')) out.add(pair);
    }
  }
  return out;
}

/// ポンで晒す2枚の既定(赤を温存=通常牌を優先)。
List<int> defaultPonExpose(List<int> hand, int kind) {
  final owned = hand.where((t) => Tile.normalize(t) == kind).toList()..sort();
  return owned.take(2).toList();
}

/// 手牌情報なしでのチーの形の列挙(牌譜記録用: 他人の手牌は見えない)。
/// [calledKind] を含む順子の「手から出す2枚」を、赤5の変種込みで返す。
/// 形の条件(端の制約)は [chiTileOptions] と同じ。
List<List<int>> allChiForms(int calledKind) {
  if (Tile.isHonor(calledKind)) return const [];
  final n = Tile.number(calledKind);
  final base = <List<int>>[
    if (n >= 3) [calledKind - 2, calledKind - 1],
    if (n >= 2 && n <= 8) [calledKind - 1, calledKind + 1],
    if (n <= 7) [calledKind + 1, calledKind + 2],
  ];
  final out = <List<int>>[];
  for (final f in base) {
    out.add(f);
    // 5を含む形は赤5を使う変種も出す(Mリーグ: 赤は各色1枚)
    final i5 = f.indexWhere((k) => Tile.number(k) == 5);
    if (i5 >= 0) {
      final v = List.of(f);
      v[i5] = switch (Tile.normalize(v[i5])) {
        4 => Tile.red5m,
        13 => Tile.red5p,
        _ => Tile.red5s,
      };
      out.add(v);
    }
  }
  return out;
}

/// チーで使う手牌2枚の候補(実牌)。上家からの数牌 [calledKind] 前提。
/// 各位置で手牌の赤/通常を候補に展開するため、赤5が絡むと候補が増える。
/// 例: 手牌 3s,5s,赤5s に 4s → [[3s,5s],[3s,赤5s]]。
List<List<int>> chiTileOptions(List<int> hand, int calledKind) {
  if (Tile.isHonor(calledKind)) return const [];
  final has = hand.map(Tile.normalize).toSet();
  final n = Tile.number(calledKind);
  final out = <List<int>>[];

  void addShape(int k1, int k2) {
    for (final a in uniqueTilesOfKind(hand, k1)) {
      for (final b in uniqueTilesOfKind(hand, k2)) {
        out.add([a, b]);
      }
    }
  }

  if (n >= 3 && has.contains(calledKind - 2) && has.contains(calledKind - 1)) {
    addShape(calledKind - 2, calledKind - 1);
  }
  if (n >= 2 &&
      n <= 8 &&
      has.contains(calledKind - 1) &&
      has.contains(calledKind + 1)) {
    addShape(calledKind - 1, calledKind + 1);
  }
  if (n <= 7 && has.contains(calledKind + 1) && has.contains(calledKind + 2)) {
    addShape(calledKind + 1, calledKind + 2);
  }
  return out;
}
