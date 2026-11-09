/// 和了判定・面子分解・シャンテン数・待ち計算(純ロジック)
library;

import 'tile.dart';

/// 牌リスト → 34種カウント配列(赤牌は通常牌に正規化される)
List<int> toCounts(Iterable<int> tiles) {
  final counts = List<int>.filled(Tile.kindCount, 0);
  for (final t in tiles) {
    counts[Tile.normalize(t)]++;
  }
  return counts;
}

/// 面子(手の内での分解単位)
class SetUnit {
  final bool isRun; // true=順子 false=刻子
  final int tile; // 順子は開始牌、刻子は牌種

  const SetUnit.run(this.tile) : isRun = true;
  const SetUnit.triplet(this.tile) : isRun = false;

  List<int> get tiles =>
      isRun ? [tile, tile + 1, tile + 2] : [tile, tile, tile];

  bool contains(int t) => isRun ? (t >= tile && t <= tile + 2) : t == tile;
}

/// 通常形の面子分解(雀頭+面子リスト)
class Decomposition {
  final int pair;
  final List<SetUnit> units;
  const Decomposition(this.pair, this.units);
}

/// counts(3n+2枚)が通常形で和了しているかの判定と全分解の列挙
List<Decomposition> decompose(List<int> counts) {
  final results = <Decomposition>[];
  final work = List<int>.from(counts);
  for (var pair = 0; pair < Tile.kindCount; pair++) {
    if (work[pair] < 2) continue;
    work[pair] -= 2;
    final units = <SetUnit>[];
    _decomposeSets(work, 0, units, (found) {
      results.add(Decomposition(pair, List<SetUnit>.from(found)));
    });
    work[pair] += 2;
  }
  return results;
}

void _decomposeSets(
  List<int> counts,
  int idx,
  List<SetUnit> units,
  void Function(List<SetUnit>) onComplete,
) {
  while (idx < Tile.kindCount && counts[idx] == 0) {
    idx++;
  }
  if (idx == Tile.kindCount) {
    onComplete(units);
    return;
  }
  // 刻子
  if (counts[idx] >= 3) {
    counts[idx] -= 3;
    units.add(SetUnit.triplet(idx));
    _decomposeSets(counts, idx, units, onComplete);
    units.removeLast();
    counts[idx] += 3;
  }
  // 順子
  if (idx < 27 &&
      Tile.number(idx) <= 7 &&
      counts[idx + 1] > 0 &&
      counts[idx + 2] > 0) {
    counts[idx]--;
    counts[idx + 1]--;
    counts[idx + 2]--;
    units.add(SetUnit.run(idx));
    _decomposeSets(counts, idx, units, onComplete);
    units.removeLast();
    counts[idx]++;
    counts[idx + 1]++;
    counts[idx + 2]++;
  }
}

/// 七対子形か(門前14枚のみ)
bool isChiitoi(List<int> counts) {
  var pairs = 0;
  for (final c in counts) {
    if (c == 2) {
      pairs++;
    } else if (c != 0) {
      return false;
    }
  }
  return pairs == 7;
}

/// 国士無双形か(門前14枚のみ)
bool isKokushi(List<int> counts) {
  var hasPair = false;
  for (var t = 0; t < Tile.kindCount; t++) {
    final c = counts[t];
    if (Tile.isTerminalOrHonor(t)) {
      if (c == 0 || c > 2) return false;
      if (c == 2) {
        if (hasPair) return false;
        hasPair = true;
      }
    } else if (c != 0) {
      return false;
    }
  }
  return hasPair;
}

/// 和了形か(手の内counts: 14 - 3*副露数 枚)
bool isWinningHand(List<int> counts, {required int meldCount}) {
  final total = counts.fold(0, (a, b) => a + b);
  if (total != 14 - meldCount * 3) return false;
  if (meldCount == 0) {
    if (isChiitoi(counts) || isKokushi(counts)) return true;
  }
  final work = List<int>.from(counts);
  for (var pair = 0; pair < Tile.kindCount; pair++) {
    if (work[pair] < 2) continue;
    work[pair] -= 2;
    if (_canRemoveAllSets(work, 0)) {
      work[pair] += 2;
      return true;
    }
    work[pair] += 2;
  }
  return false;
}

bool _canRemoveAllSets(List<int> counts, int idx) {
  while (idx < Tile.kindCount && counts[idx] == 0) {
    idx++;
  }
  if (idx == Tile.kindCount) return true;
  if (counts[idx] >= 3) {
    counts[idx] -= 3;
    final ok = _canRemoveAllSets(counts, idx);
    counts[idx] += 3;
    if (ok) return true;
  }
  if (idx < 27 &&
      Tile.number(idx) <= 7 &&
      counts[idx + 1] > 0 &&
      counts[idx + 2] > 0) {
    counts[idx]--;
    counts[idx + 1]--;
    counts[idx + 2]--;
    final ok = _canRemoveAllSets(counts, idx);
    counts[idx]++;
    counts[idx + 1]++;
    counts[idx + 2]++;
    if (ok) return true;
  }
  return false;
}

/// 待ち牌の**素の計算**(13-3n枚の手に対して、加えると和了になる牌種の一覧)。
///
/// ⚠️ **これは [calcLiveWaits] の内部部品であって、聴牌の判定に使ってはいけない。**
///
/// 手牌の中で4枚使い切っている牌種は除くが、**副露牌は見ていない**ため、
/// Mリーグの聴牌定義「自己の手牌・**副露牌**でアガリ牌が消去されている場合は
/// 認められない」を満たさない。ポンした牌の単騎待ちのような「アガれない待ち」を
/// 返してしまう。
///
/// 聴牌・待ちを求めるときは必ず [calcLiveWaits] を使うこと
/// (`GameEngine` 内なら `_SeatState.calcMyWaits()`)。
/// 過去に2回、ここを直接呼んで聴牌の定義を破っている:
/// 鳴いた直後の待ち更新(❌10)と、アドバイスのピンフ・タンヤオ判定。
///
/// この関数を直接使ってよいのは、[calcLiveWaits] 自身と、
/// 「副露を見ない素の待ち」を意図的に比べるテストだけ。
List<int> calcWaits(List<int> counts, {required int meldCount}) {
  final waits = <int>[];
  for (var t = 0; t < Tile.kindCount; t++) {
    if (counts[t] >= 4) continue;
    counts[t]++;
    if (isWinningHand(counts, meldCount: meldCount)) waits.add(t);
    counts[t]--;
  }
  return waits;
}

/// 実際にアガれる待ち牌(Mリーグの聴牌定義に沿う)。
///
/// 規定の要旨: 聴牌は和了可能な状態を指すが、和了牌を自分の手牌・副露で
/// 使い切っている形は聴牌と認めない。
///
/// [calcWaits] の結果から、その牌を**自己の手牌と副露牌で4枚とも使い切って
/// いる**待ちを除く。戻り値が空ならノーテン。
///
/// 例: 中をポン(3枚)＋手牌に中1枚の単騎待ち → 中は自分で4枚使い切っており
/// 場に1枚も残らないためアガリ得ない。よって待ちから除き、ノーテンとなる。
///
/// - [handCounts] 手牌(副露を除く)の牌種カウント
/// - [meldCounts] 副露牌の牌種カウント(暗槓の4枚も含む)
List<int> calcLiveWaits(
  List<int> handCounts,
  List<int> meldCounts, {
  required int meldCount,
}) {
  final waits = calcWaits(handCounts, meldCount: meldCount);
  return [
    for (final w in waits)
      if (handCounts[w] + meldCounts[w] < 4) w,
  ];
}

/// リーチ後の暗槓で「面子構成が変わらない」か。
///
/// リーチ後の暗槓が認められるのは次の3条件をすべて満たす場合:
///   1. ツモ牌での暗槓であること(送り槓禁止)
///   2. 待ちが変わらないこと
///   3. **面子構成が変わらないこと**
/// 本関数は 3 のみを判定する(1・2 は呼び出し側)。
/// Mリーグ:「リーチ後の不正なカンは、発覚即時、または流局時チョンボとなる。」
///
/// [kind] の3枚が**すべての和了形で暗刻**として使われているなら、暗槓しても
/// 手の解釈は変わらない → true。順子の一部や雀頭としても使える分解が1つでも
/// あれば、暗槓はその解釈を消してしまう → false(暗槓不可)。
///
/// 典型例: 手牌に 222m 333m 444m があり 2m をツモった場合。
/// 「222m+333m+444m(三連刻)」とも「234m+234m+234m(三順子)」とも解釈できるため、
/// 2m の暗槓は後者の解釈を消す = 面子構成が変わる → 不可。
///
/// - [handBefore] ツモ牌を除いた聴牌手(13-3n枚)のカウント。[kind] を3枚含む。
/// - [waits] その手の待ち。
bool ankanKeepsComposition(List<int> handBefore, int kind, List<int> waits) {
  for (final w in waits) {
    final counts = List<int>.from(handBefore)..[w] += 1;
    final decs = decompose(counts);
    // 通常形で分解できない(七対子・国士)なら暗刻ではあり得ない。
    // kind を3枚持つ手では起こり得ないが、安全側に倒して不可とする。
    if (decs.isEmpty) return false;
    for (final d in decs) {
      final usesAsTriplet = d.units.any((u) => !u.isRun && u.tile == kind);
      if (!usesAsTriplet) return false; // 暗刻に使わない解釈が存在する
    }
  }
  return true;
}

/// 3n+2枚の手から1枚切ったときの最良シャンテン数(CPU の押し引き・鳴き判断と
/// ベンチマークの特徴量が共有する)
int bestShantenAfterDiscard(List<int> hand, {required int meldCount}) {
  var best = 99;
  for (final t in hand.map(Tile.normalize).toSet()) {
    final counts = toCounts(hand)..[t] -= 1;
    final s = calcShanten(counts, meldCount: meldCount);
    if (s < best) best = s;
  }
  return best;
}

/// シャンテン数(3n+1枚の手)。0=テンパイ、-1=和了形
int calcShanten(List<int> counts, {required int meldCount}) {
  var best = _standardShanten(counts, meldCount);
  if (meldCount == 0) {
    best = best < _chiitoiShanten(counts) ? best : _chiitoiShanten(counts);
    best = best < _kokushiShanten(counts) ? best : _kokushiShanten(counts);
  }
  return best;
}

int _chiitoiShanten(List<int> counts) {
  var pairs = 0;
  var kinds = 0;
  for (final c in counts) {
    if (c > 0) kinds++;
    if (c >= 2) pairs++;
  }
  var shanten = 6 - pairs;
  if (kinds < 7) shanten += 7 - kinds;
  return shanten;
}

int _kokushiShanten(List<int> counts) {
  var kinds = 0;
  var hasPair = false;
  for (var t = 0; t < Tile.kindCount; t++) {
    if (!Tile.isTerminalOrHonor(t)) continue;
    if (counts[t] > 0) kinds++;
    if (counts[t] >= 2) hasPair = true;
  }
  return 13 - kinds - (hasPair ? 1 : 0);
}

int _standardShanten(List<int> counts, int meldCount) {
  var best = 8;
  final work = List<int>.from(counts);

  void search(bool hasPair) {
    final result = _searchSets(work, 0, 0, 0, meldCount, hasPair);
    if (result < best) best = result;
  }

  // 雀頭を先に選ぶ場合と選ばない場合の両方を試す
  search(false);
  for (var t = 0; t < Tile.kindCount; t++) {
    if (work[t] >= 2) {
      work[t] -= 2;
      search(true);
      work[t] += 2;
    }
  }
  return best;
}

int _searchSets(
  List<int> counts,
  int idx,
  int sets,
  int partials,
  int meldCount,
  bool hasPair,
) {
  while (idx < Tile.kindCount && counts[idx] == 0) {
    idx++;
  }
  final maxBlocks = 4 - meldCount;
  if (idx == Tile.kindCount || sets + partials >= maxBlocks) {
    final effPartials = (sets + partials > maxBlocks)
        ? maxBlocks - sets
        : partials;
    return 8 - 2 * (sets + meldCount) - effPartials - (hasPair ? 1 : 0);
  }

  var best = 99;

  // この牌を使わない
  final skip = _searchSets(counts, idx + 1, sets, partials, meldCount, hasPair);
  if (skip < best) best = skip;

  // 刻子
  if (counts[idx] >= 3) {
    counts[idx] -= 3;
    final r = _searchSets(counts, idx, sets + 1, partials, meldCount, hasPair);
    counts[idx] += 3;
    if (r < best) best = r;
  }
  // 順子
  if (idx < 27 &&
      Tile.number(idx) <= 7 &&
      counts[idx + 1] > 0 &&
      counts[idx + 2] > 0) {
    counts[idx]--;
    counts[idx + 1]--;
    counts[idx + 2]--;
    final r = _searchSets(counts, idx, sets + 1, partials, meldCount, hasPair);
    counts[idx]++;
    counts[idx + 1]++;
    counts[idx + 2]++;
    if (r < best) best = r;
  }
  // 対子(刻子候補)
  if (counts[idx] >= 2) {
    counts[idx] -= 2;
    final r = _searchSets(counts, idx, sets, partials + 1, meldCount, hasPair);
    counts[idx] += 2;
    if (r < best) best = r;
  }
  // 両面・辺張ターツ
  if (idx < 27 && Tile.number(idx) <= 8 && counts[idx + 1] > 0) {
    counts[idx]--;
    counts[idx + 1]--;
    final r = _searchSets(counts, idx, sets, partials + 1, meldCount, hasPair);
    counts[idx]++;
    counts[idx + 1]++;
    if (r < best) best = r;
  }
  // 嵌張ターツ
  if (idx < 27 && Tile.number(idx) <= 7 && counts[idx + 2] > 0) {
    counts[idx]--;
    counts[idx + 2]--;
    final r = _searchSets(counts, idx, sets, partials + 1, meldCount, hasPair);
    counts[idx]++;
    counts[idx + 2]++;
    if (r < best) best = r;
  }
  return best;
}
