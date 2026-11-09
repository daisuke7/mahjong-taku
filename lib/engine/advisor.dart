/// ツモ時のアドバイス(攻撃・守備)。
///
/// 入力は GameView のみ。GameView は「自分の手牌+全員の河+さらされた副露+
/// ドラ表示牌」という各席に公開されている情報だけを含む構造なので、
/// 他家の手の内や山を参照できないことが構造的に保証される。
library;

import 'dart:math';

import 'hand.dart';
import 'meld.dart';
import 'models.dart';
import 'safety.dart';
import 'score.dart';
import 'tile.dart';
import 'yaku.dart';

/// 役の種類(推奨打牌の計算に使う)
enum YakuShape { standard, chiitoi }

/// 狙える役の組み合わせ候補
class YakuCandidate {
  final List<String> parts; // 例: ['リーチ', 'タンヤオ', 'ドラ2']
  final int han;
  final int points; // ロン和了の想定点
  final String label; // 満貫 等(なければ空)

  /// この役へまっすぐ向かうとき最も不要な牌(raw)。無ければ null
  final int? discard;

  /// この役に限定したときのシャンテン数。手なりのシャンテン数より遠い場合が
  /// あるため、遠回りかどうかを利用者に示すのに使う。未計算なら null。
  final int? shanten;

  /// 役満か(翻数を数えないので [han] は0)。役満は「夢」として、他の候補より
  /// 遠くても必ず表示する。
  final bool isYakuman;

  const YakuCandidate({
    required this.parts,
    required this.han,
    required this.points,
    required this.label,
    this.discard,
    this.shanten,
    this.isYakuman = false,
  });
}

/// 他家の脅威
class ThreatInfo {
  final int seat;
  final String description;
  final int level; // 1=注意 2=警戒

  const ThreatInfo({
    required this.seat,
    required this.description,
    required this.level,
  });
}

/// リーチ者1人に対する「通ったスジ」(3色×6本)。
///
/// リーチの待ちが両面だと仮定すると、待ちの片方が通っているスジは
/// もう片方も出ないと読める(例: 2sが通っていれば3s4sの両面は無いので
/// 2s-5sのスジが通る)。スジは各色 1-4/2-5/3-6/4-7/5-8/6-9 の6本。
class SujiTable {
  final int seat;

  /// passed[色][i] = (i+1)-(i+4) のスジが通っているか(i=0..5)
  final List<List<bool>> passed;

  const SujiTable({required this.seat, required this.passed});

  /// 通った本数(全18本中)
  int get passedCount =>
      passed.fold(0, (a, row) => a + row.where((p) => p).length);
}

/// リーチ者 [seat] に対する通ったスジ。
/// 「通っている」の基準は現物(safetyVs >= 100)なので、リーチ者の河に加えて
/// リーチ後に他家が捨てて通った牌も数える。
SujiTable sujiTableVs(GameView view, int seat) {
  // スジは数牌のみなので手牌(字牌の見え枚数にしか使わない)は不要
  bool safe(int kind) => safetyVs(kind, seat, const [], view) >= 100;
  return SujiTable(
    seat: seat,
    passed: [
      for (var suit = 0; suit < 3; suit++)
        [
          for (var i = 0; i < 6; i++)
            safe(suit * 9 + i) || safe(suit * 9 + i + 3),
        ],
    ],
  );
}

/// 聴牌時、ある打牌に対する待ち。
///
/// 切る牌によって待ちが変わるので、打牌ごとに1つ持つ。
class WaitOption {
  /// この牌(raw)を切ると下記の待ちになる。打牌済み(3n+1枚)なら null。
  final int? discard;

  /// 待ち牌の牌種(正規化済)。残り枚数の多い順。
  final List<int> tiles;

  /// 牌種 → 場に残っている枚数(自分の手牌・副露・全員の河・ドラ表示牌を除いた数)
  final Map<int, int> remaining;

  /// 待ち牌の残り合計枚数
  int get total => remaining.values.fold(0, (a, b) => a + b);

  const WaitOption({
    this.discard,
    required this.tiles,
    required this.remaining,
  });
}

class AdviceReport {
  final int shanten; // 0=テンパイ
  final List<YakuCandidate> offense;
  final List<ThreatInfo> threats;
  final List<int> dangerTiles; // 手牌中の危険牌(raw)
  final List<int> safeTiles; // 手牌中の比較的安全な牌(raw)

  /// safeTiles のうち、全脅威に対して100%通る現物の牌種(正規化済)
  final Set<int> genbutsuKinds;

  /// 聴牌時の待ち。切る牌ごとに1つ(受けの広い順)。テンパイでなければ空。
  /// 打牌済み(鳴き直後など)なら要素1つで `discard == null`。
  final List<WaitOption> waits;

  /// リーチ者ごとの通ったスジ。リーチ者がいなければ空。
  final List<SujiTable> sujiTables;

  /// 非テンパイ時のウケ一覧(最良シャンテン維持の打牌のみ・受け広い順)。
  /// テンパイ時は [waits] が同じ役割を果たすので空。
  final List<UkeireOption> ukeire;

  const AdviceReport({
    required this.shanten,
    required this.offense,
    required this.threats,
    required this.dangerTiles,
    required this.safeTiles,
    this.genbutsuKinds = const {},
    this.waits = const [],
    this.sujiTables = const [],
    this.ukeire = const [],
  });
}

const List<String> _suitNames = ['萬子', '筒子', '索子'];

/// 非テンパイ時のウケ(受け入れ)1候補。「この牌を切ると、これらの牌で
/// シャンテンが進む」を残り枚数付きで表す。
class UkeireOption {
  /// 切る牌(raw)。同種に赤と通常があれば通常牌を代表にする(赤温存)。
  final int discard;

  /// シャンテンが進む牌種(正規化済)。残り枚数の多い順。
  final List<int> tiles;

  /// 牌種 → 場に残っている枚数([remainingOf] と同じ基準)
  final Map<int, int> remaining;

  /// 受け入れ合計枚数
  int get total => remaining.values.fold(0, (a, b) => a + b);

  const UkeireOption({
    required this.discard,
    required this.tiles,
    required this.remaining,
  });
}

/// 3n+1枚(打牌後)の手の受け入れ: シャンテンが進む牌種ごとの残り枚数。
/// [shanten] はその手のシャンテン数(呼び出し側が計算済みのものを渡す)。
/// 残り0枚(枯れ)の牌種は載せない。
/// CPUの受け入れ最大打牌(ai.dart)とウケ表示が同じ計算を共有する。
Map<int, int> ukeireMap(
  List<int> counts, {
  required int meldCount,
  required int shanten,
  required int Function(int kind) remainingOf,
}) {
  // シャンテンが進む牌種を先に集め、counts を元に戻してから残り枚数を
  // 数える(remainingOf が counts を参照しても正しく数えられるように)。
  final advancing = <int>[];
  for (var k = 0; k < Tile.kindCount; k++) {
    if (counts[k] >= 4) continue;
    counts[k]++;
    if (calcShanten(counts, meldCount: meldCount) < shanten) advancing.add(k);
    counts[k]--;
  }
  final out = <int, int>{};
  for (final k in advancing) {
    final r = remainingOf(k);
    if (r > 0) out[k] = r;
  }
  return out;
}

/// 牌種 [kind] の「くっつき見込み」(受け枚数が同率のときのタイブレーク)。
/// その牌の周辺ツモ(対子化と同色±2)の残り枚数を距離で重み付けした合計。
///
/// 同率首位は「浮き牌のどちらを切るか」がほとんどで、切った後の手は
/// シャンテンが進むツモに関して完全対称になる。差が出るのは浮き牌周辺の
/// 改良ツモ(くっつき)だけなので、そこだけを数えれば足りる。枯れている・
/// 端に寄っている浮き牌が自然と先に切られる。
int stickPotential(GameView view, List<int> hand14, int kind) {
  var v = remainingOf(kind, view, hand14) * 2; // 対子化
  if (!Tile.isHonor(kind)) {
    final n = Tile.number(kind);
    for (final d in const [-2, -1, 1, 2]) {
      if (n + d < 1 || n + d > 9) continue;
      v += remainingOf(kind + d, view, hand14) * (d.abs() == 1 ? 4 : 1);
    }
  }
  return v;
}

/// 牌種 [kind] を手に残す価値(打点寄与+汎用性)。受け枚数も2段階ウケも
/// 同率のとき「価値の低い方を切る」ために使う。
/// [representative] は実際に切る牌(raw)。赤しか持っていなければ赤を失う。
int keepTileValue(
  GameView view,
  List<int> counts,
  int kind,
  int representative,
) {
  var v = 0;
  if (Tile.doraKinds(view.doraIndicators).contains(kind)) v += 40;
  if (Tile.isRed(representative)) v += 40;
  final han = yakuhaiHan(
    kind,
    windTile(view.seatWind(view.youSeat)),
    windTile(view.roundWind),
  );
  if (han > 0) v += (counts[kind] >= 2 ? 30 : 8) * han;
  if (!Tile.isHonor(kind)) {
    final n = Tile.number(kind);
    v += min(n, 10 - n); // 中寄りほど汎用性が高い(1..5)
    for (final d in Tile.doraKinds(view.doraIndicators)) {
      if (!Tile.isHonor(d) && Tile.suit(d) == Tile.suit(kind)) {
        final dist = (Tile.number(d) - n).abs();
        if (dist == 1) v += 4;
        if (dist == 2) v += 2;
      }
    }
  }
  return v;
}

/// 受け枚数が同率のグループ内を「くっつき見込みが低い順 → 残す価値が
/// 低い順」に並べ替える(先頭ほど先に切るべき牌)。
void _breakUkeireTies(GameView view, List<int> hand14, List<UkeireOption> out) {
  final counts = toCounts(hand14);
  var i = 0;
  while (i < out.length) {
    var j = i + 1;
    while (j < out.length && out[j].total == out[i].total) {
      j++;
    }
    if (j - i >= 2) {
      final stick = <int, int>{};
      final keep = <int, int>{};
      for (var x = i; x < j; x++) {
        final k = Tile.normalize(out[x].discard);
        stick[k] = stickPotential(view, hand14, k);
        keep[k] = keepTileValue(view, counts, k, out[x].discard);
      }
      final sub = out.sublist(i, j)
        ..sort((a, b) {
          final ka = Tile.normalize(a.discard);
          final kb = Tile.normalize(b.discard);
          final ds = stick[ka]! - stick[kb]!; // 見込みの低い方を先に切る
          if (ds != 0) return ds;
          final dv = keep[ka]! - keep[kb]!; // 価値の低い方を先に切る
          if (dv != 0) return dv;
          return Tile.sortKey(a.discard) - Tile.sortKey(b.discard);
        });
      out.setRange(i, j, sub);
    }
    i = j;
  }
}

// ukeireOptions は自分の手番のたびに(グロー表示で)UIから何度も呼ばれる
// ので、同じ GameView への結果を持ち回す。GameView はエンジンイベント
// ごとに作り直されるので identical で十分。
GameView? _ukeireCacheView;
List<UkeireOption>? _ukeireCache;

/// 1シャンテン以上の手のウケ一覧。**最良シャンテンを保つ打牌だけ**を
/// 受けの広い順に並べて返す(先頭が最も攻撃的な打牌)。
/// 受け枚数が同率なら くっつき見込み → 残す価値(ドラ・赤・役牌・中寄り)
/// の順で決める。
/// テンパイ([tenpaiWaits] の担当)・リーチ中・打牌選択の無い形なら空。
List<UkeireOption> ukeireOptions(GameView view) {
  final hand = [...view.hand, ?view.drawnTile];
  if (hand.length % 3 != 2) return const [];
  final me = view.players[view.youSeat];
  if (me.riichi) return const []; // ツモ切りしか選べない
  if (identical(view, _ukeireCacheView)) return _ukeireCache!;
  final meldCount = me.melds.length;

  // 切る牌の代表 raw(赤より通常牌を優先して赤温存を勧める)
  final rawOf = <int, int>{};
  for (final t in hand) {
    final k = Tile.normalize(t);
    final cur = rawOf[k];
    if (cur == null || (Tile.isRed(cur) && !Tile.isRed(t))) rawOf[k] = t;
  }

  final kinds = hand.map(Tile.normalize).toSet();
  final shantens = <int, int>{};
  var best = 99;
  for (final k in kinds) {
    final counts = toCounts(hand)..[k] -= 1;
    final s = calcShanten(counts, meldCount: meldCount);
    shantens[k] = s;
    if (s < best) best = s;
  }
  if (best <= 0) return const [];

  final out = <UkeireOption>[];
  for (final k in kinds) {
    if (shantens[k] != best) continue;
    final counts = toCounts(hand)..[k] -= 1;
    final map = ukeireMap(
      counts,
      meldCount: meldCount,
      shanten: best,
      remainingOf: (t) => remainingOf(t, view, hand),
    );
    final sorted = map.keys.toList()
      ..sort((a, b) {
        final d = map[b]! - map[a]!; // 残り多い順
        return d != 0 ? d : a - b;
      });
    out.add(UkeireOption(discard: rawOf[k]!, tiles: sorted, remaining: map));
  }
  out.sort((a, b) {
    final d = b.total - a.total; // 受け広い順
    return d != 0 ? d : Tile.sortKey(a.discard) - Tile.sortKey(b.discard);
  });
  _breakUkeireTies(view, hand, out);
  _ukeireCacheView = view;
  _ukeireCache = out;
  return out;
}

/// 手牌で赤く光らせる「最も攻撃的な打牌」(raw)。
/// 非テンパイなら最良シャンテン維持でウケ最大([ukeireOptions] の先頭)、
/// テンパイなら待ちが最も広い打牌([tenpaiWaits] の先頭)。
/// 該当なし(リーチ中・打牌選択の無い形)は null。
/// リーチ宣言の選択中などの抑制は呼び出し側(UI)が行う。
int? attackGlowTile(GameView view) {
  final ukeire = ukeireOptions(view);
  if (ukeire.isNotEmpty) return ukeire.first.discard;
  for (final o in tenpaiWaits(view)) {
    if (o.discard != null) return o.discard;
  }
  return null;
}

/// 聴牌時の待ちを、切る牌ごとに求める。テンパイでなければ空。
///
/// 打牌前(3n+2枚)なら、テンパイを保てる打牌それぞれの待ちを**受けの広い順**に
/// 並べて返す(切る牌で待ちが変わるため)。3n+1枚(鳴き直後など)なら打牌の選択が
/// 無いので、`discard == null` の要素を1つだけ返す。
/// 待ちは Mリーグの聴牌定義に沿う `calcLiveWaits`(自分で4枚使い切った待ちは除く)。
List<WaitOption> tenpaiWaits(GameView view) {
  final hand = [...view.hand, ?view.drawnTile];
  final me = view.players[view.youSeat];
  final meldCount = me.melds.length;
  final meldCounts = toCounts([for (final m in me.melds) ...m.tiles]);

  WaitOption? optFor(int? discard, List<int> counts) {
    final waits = calcLiveWaits(counts, meldCounts, meldCount: meldCount);
    if (waits.isEmpty) return null;
    final remaining = {for (final w in waits) w: remainingOf(w, view, hand)};
    final tiles = waits.toList()
      ..sort((a, b) {
        final d = remaining[b]! - remaining[a]!; // 残り多い順
        return d != 0 ? d : a - b;
      });
    return WaitOption(discard: discard, tiles: tiles, remaining: remaining);
  }

  if (hand.length % 3 == 1) {
    final o = optFor(null, toCounts(hand));
    return o == null ? const [] : [o];
  }

  // 打牌前: 牌種ごとに1つ切って、テンパイを保つものを列挙。
  // 切る牌の代表 raw は手牌中の実物(赤牌が絡んでも TileWidget が正しく描ける)。
  final rawOf = <int, int>{};
  for (final t in hand) {
    rawOf.putIfAbsent(Tile.normalize(t), () => t);
  }
  final out = <WaitOption>[];
  for (final kind in hand.map(Tile.normalize).toSet()) {
    final counts = toCounts(hand)..[kind] -= 1;
    final o = optFor(rawOf[kind], counts);
    if (o != null) out.add(o);
  }
  // 受けの広い順。同率は打点期待の高い待ちを先頭に(遅延計算: 同率が
  // 出たときだけ _waitValue を評価する)
  final values = <int, int>{};
  int valueOf(WaitOption o) => values.putIfAbsent(
    Tile.normalize(o.discard!),
    () => _waitValue(view, hand, o),
  );
  out.sort((a, b) {
    final d = b.total - a.total;
    if (d != 0) return d;
    final dv = valueOf(b) - valueOf(a);
    if (dv != 0) return dv;
    return Tile.sortKey(a.discard!) - Tile.sortKey(b.discard!);
  });
  return out;
}

/// 待ちの打点期待: 各待ち牌でロン和了したときの点数感(飜×100+符)を
/// 残り枚数で重み付けした合計。門前ならリーチを見込む。役の付かない待ちは
/// 和了れない(0)ので自然と大きく割り引かれる。
int _waitValue(GameView view, List<int> hand14, WaitOption o) {
  final me = view.players[view.youSeat];
  final menzen = me.melds.every((m) => m.keepsConcealed);
  final concealed13 = [...hand14];
  if (o.discard != null) concealed13.remove(o.discard);
  var v = 0;
  for (final w in o.tiles) {
    final ws = evaluateWin(
      WinContext(
        concealed: [...concealed13, w],
        melds: me.melds,
        winTile: w,
        isTsumo: false,
        isRiichi: menzen,
        seatWind: view.seatWind(view.youSeat),
        roundWind: view.roundWind,
        doraIndicators: view.doraIndicators,
      ),
    );
    if (ws == null) continue;
    final han = ws.isYakuman ? 13 * ws.yakuman : ws.han;
    v += o.remaining[w]! * (han * 100 + ws.fu);
  }
  return v;
}

/// ダマ(リーチせず)で和了できるかの情報。テンパイ形で [discard] を切った後の
/// 待ちについて、リーチ無しのロンで役が付く待ちの残り枚数と、その最高打点
/// (本場・供託抜き)。CPU のリーチ/ダマ判断と校正用ベンチ(lib/bench)の特徴量が共有する。
class DamaInfo {
  /// 待ち牌の残り合計枚数(役の有無を問わない)
  final int waitCount;

  /// リーチ無しでも役が付く待ちの残り合計枚数
  final int yakuWaitCount;

  /// リーチ無しのロン打点の最大(役の付く待ちが無ければ 0)
  final int maxRonPoints;

  const DamaInfo({
    required this.waitCount,
    required this.yakuWaitCount,
    required this.maxRonPoints,
  });

  /// すべての待ちにリーチ無しで役が付く(ダマで取りこぼしが無い)
  bool get allWaitsHaveYaku => waitCount > 0 && yakuWaitCount == waitCount;
}

DamaInfo damaInfo(GameView view, List<int> hand14, int discard) {
  final me = view.players[view.youSeat];
  final concealed13 = [...hand14]..remove(discard);
  final meldCounts = toCounts([for (final m in me.melds) ...m.tiles]);
  final waits = calcLiveWaits(
    toCounts(concealed13),
    meldCounts,
    meldCount: me.melds.length,
  );
  var total = 0, withYaku = 0, best = 0;
  for (final w in waits) {
    final n = remainingOf(w, view, hand14);
    total += n;
    final ws = evaluateWin(
      WinContext(
        concealed: [...concealed13, w],
        melds: me.melds,
        winTile: w,
        isTsumo: false,
        seatWind: view.seatWind(view.youSeat),
        roundWind: view.roundWind,
        doraIndicators: view.doraIndicators,
      ),
    );
    if (ws == null) continue;
    withYaku += n;
    final pts = calcPayment(
      score: ws,
      isDealer: view.dealer == view.youSeat,
      isTsumo: false,
      honba: 0,
      riichiSticks: 0,
    ).declared;
    if (pts > best) best = pts;
  }
  return DamaInfo(
    waitCount: total,
    yakuWaitCount: withYaku,
    maxRonPoints: best,
  );
}

/// 手牌のうち、**リーチしている他家全員に100%通る現物**の牌種(正規化済)。
/// リーチ者がいなければ空。手牌の現物ハイライト(青)に使う。
/// 守備アドバイスの genbutsuKinds と同じ基準(safetyVs >= 100)。
Set<int> genbutsuInHand(GameView view) {
  final me = view.youSeat;
  final riichiSeats = [
    for (var i = 0; i < 4; i++)
      if (i != me && view.players[i].riichi) i,
  ];
  if (riichiSeats.isEmpty) return const {};
  final hand = [...view.hand, ?view.drawnTile];
  final out = <int>{};
  for (final k in hand.map(Tile.normalize).toSet()) {
    if (riichiSeats.every((s) => safetyVs(k, s, hand, view) >= 100)) {
      out.add(k);
    }
  }
  return out;
}

/// 手牌の現物ハイライトの2段階。
///
/// - strong: 守備アドバイスの「青=現物」と同じ基準。リーチ者だけでなく
///   危険な鳴き(役牌ポン・染め手気配など)の**全脅威**に対して100%通る
/// - faint: リーチ者全員には現物だが、他の脅威には言い切れない牌
///
/// アドバイス画面の現物表示と手牌のハイライトが食い違って見えないよう、
/// faint は薄い枠で「リーチにだけは通る」ことを示す。
({Set<int> strong, Set<int> faint}) genbutsuTiersInHand(GameView view) {
  final riichiSafe = genbutsuInHand(view);
  if (riichiSafe.isEmpty) return const (strong: {}, faint: {});
  final threats = buildThreats(view);
  final hand = [...view.hand, ?view.drawnTile];
  final strong = <int>{
    for (final k in riichiSafe)
      if (threats.every((t) => threatRisk(view, hand, k, t) >= 100)) k,
  };
  return (strong: strong, faint: riichiSafe.difference(strong));
}

/// CPUの攻め打牌(攻撃アドバイスの転用)。
///
/// 役候補それぞれの推奨打牌のうち**シャンテンを落とさないもの**に限定し、
/// その中で想定打点([YakuCandidate.points])が最も高い候補の打牌を返す。
/// 該当が無ければ null(呼び出し側は受け入れ枚数ベースの選択へフォールバック)。
///
/// 染め手などの候補は「役に矛盾する牌はシャンテンを落としても切る」推奨を
/// 出すことがある(人間向けには"一手戻す選択肢"として意味がある)が、
/// CPUの攻めでは手戻りしない方針なので、そうした候補はここで弾く。
int? attackDiscard(GameView view, {List<int> forbidden = const []}) {
  final hand = [...view.hand, ?view.drawnTile];
  if (hand.length % 3 != 2) return null; // 打牌の選択場面でない
  final me = view.players[view.youSeat];
  final meldCount = me.melds.length;
  final menzen = me.melds.every((m) => m.keepsConcealed);
  final isDealer = view.dealer == view.youSeat;

  // 最良の打牌後シャンテン(これより悪くなる打牌は選ばない)
  var best = 99;
  for (final k in hand.map(Tile.normalize).toSet()) {
    final counts = toCounts(hand)..[k] -= 1;
    best = min(best, calcShanten(counts, meldCount: meldCount));
  }

  int? bestTile;
  var bestPoints = -1;
  for (final c in _buildOffense(view, hand, menzen, isDealer, best)) {
    final d = c.discard;
    if (d == null) continue;
    final kind = Tile.normalize(d);
    if (forbidden.contains(kind)) continue;
    final counts = toCounts(hand)..[kind] -= 1;
    if (calcShanten(counts, meldCount: meldCount) > best) continue; // 手戻り禁止
    if (c.points > bestPoints) {
      bestPoints = c.points;
      bestTile = d;
    }
  }
  return bestTile;
}

AdviceReport buildAdvice(GameView view) {
  final hand = [...view.hand, ?view.drawnTile];
  final me = view.players[view.youSeat];
  final melds = me.melds;
  final meldCount = melds.length;
  final menzen = melds.every((m) => m.keepsConcealed);
  final isDealer = view.dealer == view.youSeat;

  // シャンテン数(3n+2枚なら最良の打牌後で評価)
  int shanten;
  if (hand.length % 3 == 2) {
    shanten = 99;
    for (final t in hand.map(Tile.normalize).toSet()) {
      final counts = toCounts(hand)..[t] -= 1;
      shanten = min(shanten, calcShanten(counts, meldCount: meldCount));
    }
  } else {
    shanten = calcShanten(toCounts(hand), meldCount: meldCount);
  }

  final offense = _buildOffense(view, hand, menzen, isDealer, shanten);
  final threats = buildThreats(view);
  final (danger, safe, genbutsu) = _assessTiles(view, hand, threats);
  final waits = shanten == 0 ? tenpaiWaits(view) : const <WaitOption>[];
  final ukeire = shanten >= 1 ? ukeireOptions(view) : const <UkeireOption>[];
  final sujiTables = [
    for (final t in threats)
      if (view.players[t.seat].riichi) sujiTableVs(view, t.seat),
  ];

  return AdviceReport(
    shanten: shanten,
    offense: offense,
    threats: threats,
    waits: waits,
    dangerTiles: danger,
    safeTiles: safe,
    genbutsuKinds: genbutsu,
    sujiTables: sujiTables,
    ukeire: ukeire,
  );
}

// ---------------- 攻撃 ----------------

List<YakuCandidate> _buildOffense(
  GameView view,
  List<int> hand,
  bool menzen,
  bool isDealer,
  int baseShanten,
) {
  final me = view.players[view.youSeat];
  final melds = me.melds;
  final counts = toCounts(hand);

  int remaining(int kind) => remainingOf(kind, view, hand);

  // ドラ(手牌+自分の副露、赤込み)
  final allMine = [...hand];
  for (final m in melds) {
    allMine.addAll(m.tiles);
  }
  final dora =
      allMine.where(Tile.isRed).length +
      countDora(allMine, view.doraIndicators);

  // --- 各役の実現可能性 ---
  // (タンヤオ・ピンフは役牌の定義が要るので下でまとめて判定する)

  // 役牌: 既に刻子/ポン済み、または対子で4枚目以降が場に残っている
  final seatW = windTile(view.seatWind(view.youSeat));
  final roundW = windTile(view.roundWind);
  final yakuhaiKinds = {Tile.haku, Tile.hatsu, Tile.chun, seatW, roundW};
  final yakuhaiParts = <(String, int)>[];
  // 役牌候補になっている牌種(その役牌を狙う打牌ではこれを切ってはいけない)
  final yakuhaiTiles = <int>{};
  for (final kind in yakuhaiKinds) {
    final han = yakuhaiHan(kind, seatW, roundW);
    final ponned = melds.any(
      (m) => !m.isRun && Tile.normalize(m.tiles[0]) == kind,
    );
    final confirmed = ponned || counts[kind] >= 3;
    final candidate = counts[kind] == 2 && remaining(kind) >= 1;
    if (confirmed || candidate) {
      yakuhaiParts.add((_yakuhaiName(kind, seatW, roundW), han));
      if (counts[kind] >= 2) yakuhaiTiles.add(kind); // 手牌にある役牌を保護
    }
  }

  // 一番枚数の多い色(七対子の染め判定に使う。面子手の染め手は _flushShanten)
  final suitCount = [0, 0, 0];
  for (final t in allMine) {
    if (!Tile.isHonor(t)) suitCount[Tile.suit(t)]++;
  }
  var domSuit = 0;
  for (var s = 1; s < 3; s++) {
    if (suitCount[s] > suitCount[domSuit]) domSuit = s;
  }

  // トイトイ: チーがなく、対子以上のブロックが4つ以上
  final noRuns = melds.every((m) => !m.isRun);
  var pairBlocks = melds.where((m) => !m.isRun).length;
  for (var k = 0; k < Tile.kindCount; k++) {
    if (counts[k] >= 2) pairBlocks++;
  }
  final toitoiOk = noRuns && pairBlocks >= 4;

  // 七対子: 門前で「ちょうど2枚の対子」が4組以上。
  // (刻子・槓子は七対子に使えないので counts==2 のみ数える)
  var pairs = 0;
  for (var k = 0; k < Tile.kindCount; k++) {
    if (counts[k] == 2) pairs++;
  }
  // 4組以上で候補に出す(4組は面子手と両にらみ、5組以上は七対子本命)。
  // どちらも add() で列挙し、点数上位が優先表示される。
  final chiitoiOk = menzen && pairs >= 4;

  // 七対子の複合役(できあがる七対子を構成する牌で判定)
  // 対子になっている牌 + 一枚だけの牌(=七対子の伸びしろ)をまとめて見る
  final chiitoiTiles = <int>[
    for (var k = 0; k < Tile.kindCount; k++)
      if (counts[k] >= 1) k,
  ];
  final chiitoiTanyao = chiitoiTiles.every(Tile.isSimple);
  final chiitoiSuits = <int>{};
  var chiitoiHasHonor = false;
  for (final k in chiitoiTiles) {
    if (Tile.isHonor(k)) {
      chiitoiHasHonor = true;
    } else {
      chiitoiSuits.add(Tile.suit(k));
    }
  }
  // 七対子は必ず7種なので、一色化は「使う種類が7種に収まる」ことも要る
  final chiitoiKinds = chiitoiTiles.length;
  final chiitoiChinitsu =
      chiitoiSuits.length == 1 && !chiitoiHasHonor && chiitoiKinds <= 7;
  final chiitoiHonitsu =
      chiitoiSuits.length <= 1 &&
      chiitoiHasHonor &&
      chiitoiKinds <= 7 &&
      !chiitoiChinitsu;

  // タンヤオ・ピンフ。聴牌していれば和了形まで確定しているので、実際に付くかを
  // 確かめる(幺九牌が残る聴牌でタンヤオ、両面でない待ちでピンフを出さない)。
  // まだ形が決まらないうちは、その役へ向かえる形かどうかの目安で出す。
  final tenpaiYaku = baseShanten == 0
      ? _tenpaiYaku(hand, melds, yakuhaiKinds)
      : null;
  final tanyaoOk =
      tenpaiYaku?.tanyao ??
      (melds.every((m) => m.tiles.every(Tile.isSimple)) &&
          hand.where(Tile.isTerminalOrHonor).length <= 3);
  final pinfuOk =
      tenpaiYaku?.pinfu ??
      (menzen && melds.isEmpty && _pinfuShapeOk(counts, yakuhaiKinds));

  // 面子を固定して狙う役(三色同順・一気通貫・一盃口・大三元)。
  // 他の役と違い「今の形に見えているか」では判定できない(複数の面子がそろって
  // 初めて成立するので、揃うまでは何の気配も出ない)。代わりに面子を固定した
  // ときのシャンテン数を数え、規定シャンテン以内なら候補に出す。
  //
  // 残りツモで聴牌まで届かない役は、狙えても間に合わないので出さない。
  final drawsLeft = _myDrawsLeft(view);

  // 手なりより2手以上戻る役は出さない。聴牌しているのに2シャンテンまで
  // 戻す一通などは選択肢にならないため。1手戻す程度なら選択肢として意味がある。
  // (役満だけは「夢」なのでこの制限をかけない)
  final targetCap = min(_maxTargetShanten, baseShanten + 1);
  final flushCap = min(_maxFlushShanten, baseShanten + 1);

  // 候補ごとに (シャンテン数, 必要な牌種) を返す。
  (int, Set<int>)? bestOf(List<List<List<int>>> targets, int maxShanten) {
    (int, Set<int>)? best;
    for (final blocks in targets) {
      final sh = _fixedBlocksShanten(view, hand, melds, blocks);
      if (sh == null || sh > maxShanten || sh > drawsLeft) continue;
      if (best != null && sh >= best.$1) continue;
      best = (sh, {for (final b in blocks) ...b});
    }
    return best;
  }

  // 三色同順: 同じ数字で始まる順子を3色そろえる(123〜789)
  final sanshoku = bestOf([
    for (var n = 0; n < 7; n++)
      [_runBlock(n), _runBlock(9 + n), _runBlock(18 + n)],
  ], targetCap);
  // 一気通貫: 同じ色の123+456+789
  final ittsu = bestOf([
    for (var s = 0; s < 3; s++)
      [_runBlock(s * 9), _runBlock(s * 9 + 3), _runBlock(s * 9 + 6)],
  ], targetCap);
  // 一盃口: 同じ順子2つ(門前限定)
  final iipeiko = menzen
      ? bestOf([
          for (var s = 0; s < 3; s++)
            for (var n = 0; n < 7; n++)
              [_runBlock(s * 9 + n), _runBlock(s * 9 + n)],
        ], targetCap)
      : null;
  // 大三元: 白發中を刻子で3つ
  final daisangen = bestOf([
    [
      _tripletBlock(Tile.haku),
      _tripletBlock(Tile.hatsu),
      _tripletBlock(Tile.chun),
    ],
  ], _maxYakumanShanten);
  // 国士無双は面子手ではないので専用計算(幺九牌の種類数で判定する)
  final kokushiSh = _kokushiShanten(view, hand, melds);
  final kokushi = (kokushiSh != null && kokushiSh <= drawsLeft)
      ? kokushiSh
      : null;

  // 混一色 / 清一色。これも「あと何枚で届くか」で測る。
  // 清一色で使える牌は混一色で使える牌の一部なので、清一色が混一色より近く
  // なることはない。距離が同じなら翻数の高い清一色を選べばよいので、混一色を
  // 出すのは清一色より本当に近いときだけにする。
  (int, int)? bestFlush({required bool pure}) {
    (int, int)? best; // (シャンテン数, 染める色)
    for (var s = 0; s < 3; s++) {
      final sh = _flushShanten(view, hand, melds, s, pure: pure);
      if (sh == null || sh > flushCap || sh > drawsLeft) continue;
      if (best == null || sh < best.$1) best = (sh, s);
    }
    return best;
  }

  final chinitsu = bestFlush(pure: true);
  final honitsuRaw = bestFlush(pure: false);
  final honitsu =
      (honitsuRaw != null && (chinitsu == null || honitsuRaw.$1 < chinitsu.$1))
      ? honitsuRaw
      : null;

  // 打牌前(3n+2枚)なら推奨打牌を計算できる
  final canRecommend = hand.length % 3 == 2;

  // --- 組み合わせ候補 ---
  final combos = <YakuCandidate>[];
  void add(
    List<(String, int)> parts, {
    int fu = 30,
    YakuShape shape = YakuShape.standard,
    int? flushSuit, // 混一色/清一色を狙う色(0..2)。染めない役は null
    bool flushPure = false, // 清一色狙い(字牌も不要牌として扱う)
    bool tanyao = false, // タンヤオを狙う(幺九牌を不要牌として優先)
    int? shanten, // この役に限定したときのシャンテン数(計算できる役のみ)
    Set<int> protect = const {}, // この役に必要で、切ってはいけない牌種
    int yakuman = 0, // 役満の複合数(0なら通常役)
  }) {
    final filtered = parts.where((p) => p.$1.isNotEmpty).toList();
    if (filtered.isEmpty) return;
    // 役満は翻数を数えず、ドラも点数に影響しない
    final han = yakuman > 0 ? 0 : filtered.fold(0, (a, p) => a + p.$2) + dora;
    final names = [
      for (final p in filtered) p.$1,
      if (yakuman == 0 && dora > 0) 'ドラ$dora',
    ];
    final pay = calcPayment(
      score: WinScore(yaku: const [], han: han, fu: fu, yakuman: yakuman),
      isDealer: isDealer,
      isTsumo: false,
      honba: 0,
      riichiSticks: 0,
    );
    final discard = canRecommend
        ? _recommendDiscard(
            view,
            hand,
            meldCount: melds.length,
            shape: shape,
            flushSuit: flushSuit,
            flushPure: flushPure,
            tanyao: tanyao,
            protect: protect,
          )
        : null;
    combos.add(
      YakuCandidate(
        parts: names,
        han: han,
        points: pay.ron,
        label: pay.label,
        discard: discard,
        shanten: shanten,
        isYakuman: yakuman > 0,
      ),
    );
  }

  if (menzen) {
    add(
      [('リーチ', 1), if (pinfuOk) ('ピンフ', 1), if (tanyaoOk) ('タンヤオ', 1)],
      fu: pinfuOk ? 30 : 40,
      tanyao: tanyaoOk,
    );
    if (chiitoiOk) {
      add(
        [
          ('リーチ', 1),
          ('七対子', 2),
          if (chiitoiTanyao) ('タンヤオ', 1),
          if (chiitoiChinitsu) ('チンイツ', 6),
          if (chiitoiHonitsu) ('ホンイツ', 3),
        ],
        fu: 25,
        shape: YakuShape.chiitoi,
        flushSuit: (chiitoiChinitsu || chiitoiHonitsu) ? domSuit : null,
        flushPure: chiitoiChinitsu,
        tanyao: chiitoiTanyao,
      );
    }
  } else {
    if (tanyaoOk) add([('タンヤオ', 1)], tanyao: true);
  }
  if (chinitsu != null) {
    final (sh, suit) = chinitsu;
    add(
      [if (menzen) ('リーチ', 1), ('チンイツ', menzen ? 6 : 5)],
      fu: 40,
      shanten: sh,
      flushSuit: suit,
      flushPure: true,
    );
  }
  if (honitsu != null) {
    final (sh, suit) = honitsu;
    add(
      [
        if (menzen) ('リーチ', 1),
        ('ホンイツ', menzen ? 3 : 2),
        ...yakuhaiParts.take(1),
      ],
      fu: 40,
      shanten: sh,
      flushSuit: suit,
    );
  }
  if (yakuhaiParts.isNotEmpty && chinitsu == null && honitsu == null) {
    // 役牌そのもの(手牌にある対子/刻子)は切ってはいけない
    add(yakuhaiParts.take(2).toList(), protect: yakuhaiTiles);
  }
  // 四暗刻単騎待ちのテンパイはトイトイではなく四暗刻を出す。この形に限っては
  // 聴牌を崩さない限り四暗刻が確定するので、トイトイを勧める意味がない。
  final suuankouTanki = _isSuuankouTanki(hand, melds);
  if (suuankouTanki) {
    add(
      [('四暗刻', 0)],
      shanten: 0,
      // 完成している暗刻は崩さない(切るなら単騎の余り牌)
      protect: {
        for (var k = 0; k < Tile.kindCount; k++)
          if (counts[k] >= 3) k,
      },
      yakuman: 1,
    );
  } else if (toitoiOk) {
    add([('トイトイ', 2), ...yakuhaiParts.take(1)], fu: 40);
  }

  // 三色同順・一気通貫は喰い下がり1翻、一盃口は門前限定1翻
  for (final (name, kuisagari, target) in [
    ('三色同順', true, sanshoku),
    ('一気通貫', true, ittsu),
    ('一盃口', false, iipeiko),
  ]) {
    if (target == null) continue;
    final (sh, kinds) = target;
    // 一通は必ず1・9を含むのでタンヤオにはならない
    final withTanyao = tanyaoOk && kinds.every(Tile.isSimple);
    add(
      [
        if (menzen) ('リーチ', 1),
        (name, kuisagari ? (menzen ? 2 : 1) : 1),
        if (withTanyao) ('タンヤオ', 1),
      ],
      fu: 40,
      shanten: sh,
      protect: kinds,
      tanyao: withTanyao,
    );
  }

  // 役満は夢として提示する。四暗刻はトイトイ候補とほぼ重なるので出さない。
  if (daisangen != null) {
    final (sh, kinds) = daisangen;
    add([('大三元', 0)], shanten: sh, protect: kinds, yakuman: 1);
  }
  if (kokushi != null) {
    add(
      [('国士無双', 0)],
      shanten: kokushi,
      protect: _yaochuKinds.toSet(),
      yakuman: 1,
    );
  }

  // 重複を除き、近い(=シャンテンが少ない)順、同じ距離なら点数の高い順に並べる。
  // 距離を先に見るのは、遠回りな三色が目前のテンパイを押しのけないようにするため。
  // シャンテンを計算していない役は手なりで進む役なので手なりの距離とみなす。
  combos.sort((a, b) {
    final as = a.shanten ?? baseShanten;
    final bs = b.shanten ?? baseShanten;
    if (as != bs) return as - bs;
    return b.points - a.points;
  });

  // 通常役は上位4つまで。役満は遠くても「夢」として必ず残す(上限で押し出すと、
  // 手なりの候補が多い手では永久に表示されなくなってしまう)。
  final seen = <String>{};
  final result = <YakuCandidate>[];
  var normalCount = 0;
  for (final c in combos) {
    if (!seen.add(c.parts.join('+'))) continue;
    if (c.isYakuman) {
      result.add(c);
    } else if (normalCount < 4) {
      result.add(c);
      normalCount++;
    }
  }
  return result;
}

/// まだ形が決まらない段階で「ピンフに向かえる形か」の目安。
/// 暗刻があったり役牌が対子だとピンフから外れていく。
bool _pinfuShapeOk(List<int> counts, Set<int> yakuhaiKinds) {
  for (var k = 0; k < Tile.kindCount; k++) {
    if (counts[k] >= 3) return false;
    if (counts[k] >= 2 && yakuhaiKinds.contains(k)) return false;
  }
  return true;
}

/// 聴牌している手に実際に付くタンヤオ・ピンフを返す。
///
/// 別々の打牌でしか成立しない役を「両方付く」と誤らないよう、(打牌, 和了牌)
/// ごとに見て翻が最も多くなる組を採る。3n+2枚なら聴牌を保てる打牌だけを試す。
({bool tanyao, bool pinfu}) _tenpaiYaku(
  List<int> hand,
  List<Meld> melds,
  Set<int> yakuhaiKinds,
) {
  final meldCount = melds.length;
  // 副露に幺九牌があるとタンヤオは付かない。ピンフは門前限定。
  final canTanyao = melds.every((m) => m.tiles.every(Tile.isSimple));
  final canPinfu = melds.isEmpty;
  // Mリーグの聴牌定義に沿う待ちを使う(自分の手牌・副露で4枚使い切っている待ちは
  // アガれないので、その待ちを根拠にピンフ・タンヤオを付けてはいけない)
  final meldCounts = toCounts([for (final m in melds) ...m.tiles]);
  var best = (tanyao: false, pinfu: false);
  var bestHan = -1;

  void consider(List<int> counts) {
    // 幺九牌が1枚でも残る聴牌形ではタンヤオは成立し得ない
    final allSimple = !_yaochuKinds.any((k) => counts[k] > 0);
    for (final w in calcLiveWaits(counts, meldCounts, meldCount: meldCount)) {
      final tanyao = canTanyao && allSimple && Tile.isSimple(w);
      final pinfu = canPinfu && _isPinfuWin(counts, w, yakuhaiKinds);
      final han = (tanyao ? 1 : 0) + (pinfu ? 1 : 0);
      if (han > bestHan) {
        bestHan = han;
        best = (tanyao: tanyao, pinfu: pinfu);
      }
    }
  }

  final counts = toCounts(hand);
  if (hand.length % 3 == 2) {
    for (var k = 0; k < Tile.kindCount; k++) {
      if (counts[k] == 0) continue;
      counts[k]--;
      if (calcShanten(counts, meldCount: meldCount) == 0) consider(counts);
      counts[k]++;
    }
  } else {
    consider(counts);
  }
  return best;
}

/// 13枚の聴牌形 [counts] に和了牌 [w] を加えた形がピンフか。
/// ピンフは「4面子すべて順子 + 役牌でない雀頭 + 両面待ち」。
bool _isPinfuWin(List<int> counts, int w, Set<int> yakuhaiKinds) {
  final full = List<int>.from(counts)..[w] += 1;
  for (final d in decompose(full)) {
    if (d.units.any((u) => !u.isRun)) continue; // 刻子があればピンフでない
    if (yakuhaiKinds.contains(d.pair)) continue; // 役牌の雀頭は2符つく
    for (final u in d.units) {
      if (w < u.tile || w > u.tile + 2) continue; // 和了牌を含む順子だけ見る
      // 両面は「n+1 n+2 で n/n+3 待ち」か「n n+1 で n-1/n+2 待ち」。
      // 789の7待ち(辺張)と123の3待ち(辺張)、真ん中(嵌張)は除く。
      final n = Tile.number(u.tile);
      if (w == u.tile && n != 7) return true;
      if (w == u.tile + 2 && n != 1) return true;
    }
  }
  return false;
}

/// 手役(三色・一通・一盃口)を候補に出す上限シャンテン数
const int _maxTargetShanten = 2;

/// 染め手(混一色・清一色)を候補に出す上限シャンテン数。手役より緩いのは、
/// 染め手は早い段階で決め打つ役で、遠いうちに気づけないと間に合わないため。
const int _maxFlushShanten = 4;

/// 大三元を候補に出す上限シャンテン数。手役より1つ緩いのは、役満は決め打ちを
/// 早く決める必要があり、「見えた時点で夢として提示する」ほうが役に立つため。
/// (国士無双は幺九牌の種類数で判定するので [_minKokushiKinds] を使う)
const int _maxYakumanShanten = 3;

/// 順子1つを表すブロック(開始牌種 [k] から3枚)
List<int> _runBlock(int k) => [k, k + 1, k + 2];

/// 刻子1つを表すブロック
List<int> _tripletBlock(int k) => [k, k, k];

/// 面子 [blocks] を固定したときのシャンテン数。到達できないなら null。
///
/// 4面子1雀頭のうち [blocks] を固定し、残りの面子と雀頭は何でもよいものとして
/// 「あと何枚必要か」を数える。シャンテン数 = 必要枚数 - 1。
int? _fixedBlocksShanten(
  GameView view,
  List<int> hand,
  List<Meld> melds,
  List<List<int>> blocks,
) {
  // 副露の割り当て。固定ブロックと一致する副露はそのブロックを埋めたものとして
  // 扱い、それ以外の副露は自由に使える面子枠を1つ消費する。
  final pending = [
    for (final b in blocks) [...b],
  ];
  var others = 0;
  for (final m in melds) {
    final kinds = m.tiles.map(Tile.normalize).toList()..sort();
    // 槓は4枚だが面子としては1ブロック。3枚に丸めて比較する
    final sig = kinds.length > 3 ? kinds.sublist(0, 3) : kinds;
    final i = pending.indexWhere((b) => _sameBlock(b, sig));
    if (i >= 0) {
      pending.removeAt(i);
    } else {
      others++;
    }
  }
  final freeSets = 4 - blocks.length - others;
  if (freeSets < 0) return null; // 面子枠が足りない

  // 固定ブロックに必要な牌のうち、手牌にない分は引いてくるしかない
  final need = List<int>.filled(Tile.kindCount, 0);
  for (final b in pending) {
    for (final k in b) {
      need[k]++;
    }
  }
  final leftover = toCounts(hand);
  var missing = 0;
  for (var k = 0; k < Tile.kindCount; k++) {
    if (need[k] == 0) continue;
    final have = min(leftover[k], need[k]);
    leftover[k] -= have;
    final short = need[k] - have;
    // 足りない分が山にも他家の手にも残っていなければ、その役は成立し得ない
    if (short > 0 && remainingOf(k, view, hand) < short) return null;
    missing += short;
  }

  // 余った牌で「残り freeSets 面子 + 雀頭」をどこまで賄えるか
  missing += (freeSets * 3 + 2) - _bestFit(leftover, freeSets);
  // 3n+2枚の手が既に和了形なら missing=0 になるが、buildAdvice のシャンテン数も
  // 「最良の打牌後」で見て0(テンパイ)を返すので、0で下げ止めて基準をそろえる。
  return max(0, missing - 1);
}

bool _sameBlock(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 四暗刻単騎待ちのテンパイか。
///
/// 暗刻(暗槓を含む)が4つ既に完成していて、残り1枚が単騎待ちの形。この形は
/// 聴牌を崩さない限り、ツモでもロンでも四暗刻が確定する。
/// シャンポン待ちは対象外(ロンだと4つ目が明刻になり四暗刻にならない)。
///
/// 四暗刻は他の待ちだとトイトイ候補とほぼ重なるので、確定するこの形だけを見る。
bool _isSuuankouTanki(List<int> hand, List<Meld> melds) {
  if (melds.any((m) => !m.keepsConcealed)) return false; // 明刻・チーは暗刻にならない
  final need = 4 - melds.length; // 手牌で作るべき暗刻の数(暗槓は完成済み)
  if (need < 0) return false;

  // 暗刻が need 個と、単騎の1枚だけが残っている形か
  bool isTanki(List<int> counts) {
    var triplets = 0;
    var singles = 0;
    for (final c in counts) {
      if (c == 0) continue;
      if (c == 3) {
        triplets++;
      } else if (c == 1) {
        singles++;
      } else {
        return false; // 対子が残る形はシャンポン待ちなので四暗刻は確定しない
      }
    }
    return triplets == need && singles == 1;
  }

  final counts = toCounts(hand);
  if (hand.length % 3 == 1) return isTanki(counts);
  // 3n+2枚なら、1枚切って単騎テンパイにできるか
  for (var k = 0; k < Tile.kindCount; k++) {
    if (counts[k] == 0) continue;
    if (isTanki(List<int>.from(counts)..[k] -= 1)) return true;
  }
  return false;
}

/// 国士無双を狙える最低の幺九牌の種類数。
///
/// 一般には配牌時に9種9牌あれば国士を検討するが、順目が進んで9種のままでは
/// ほぼ間に合わないので、1種きつくして10種以上を条件にする。
const int _minKokushiKinds = 10;

/// 自分に残されたツモ回数。
///
/// アドバイスは自分のツモ番(=自分の分は山から引いた後)に出すので、山の残りは
/// 下家から順に配られ、自分の番は4枚に1回巡ってくる。
/// 鳴きや槓で多少前後するが、到達可能性の目安としてはこれで足りる。
int _myDrawsLeft(GameView view) => view.wallRemaining ~/ 4;

/// 国士無双を狙えるならそのシャンテン数、狙えないなら null。
int? _kokushiShanten(GameView view, List<int> hand, List<Meld> melds) {
  if (melds.isNotEmpty) return null; // 暗槓も国士を壊す
  final counts = toCounts(hand);
  var kinds = 0;
  var hasPair = false;
  for (final k in _yaochuKinds) {
    if (counts[k] > 0) kinds++;
    if (counts[k] >= 2) hasPair = true;
    // 1枚も持っていない種が場に尽きていれば13種そろわない
    if (counts[k] == 0 && remainingOf(k, view, hand) < 1) return null;
  }
  if (kinds < _minKokushiKinds) return null;
  return max(0, 13 - kinds - (hasPair ? 1 : 0));
}

const List<int> _yaochuKinds = [
  0, 8, // 1m 9m
  9, 17, // 1p 9p
  18, 26, // 1s 9s
  27, 28, 29, 30, 31, 32, 33, // 東南西北白發中
];

/// 面子になり得るブロック全て(刻子34 + 順子21)
final List<List<int>> _allBlocks = [
  for (var k = 0; k < Tile.kindCount; k++) _tripletBlock(k),
  for (var s = 0; s < 3; s++)
    for (var n = 0; n < 7; n++) _runBlock(s * 9 + n),
];

/// [counts] から「[sets]面子 + 雀頭1組」に最大何枚使えるか。
/// [counts] は探索中に書き換えるが、戻るときに必ず元へ復元する。
int _bestFit(List<int> counts, int sets) {
  // 手牌に1枚も掛からない面子は0枚しか使えないので、あらかじめ候補から外す。
  // (探索中 counts は減る一方なので、ここで絞って安全)
  final cands = <int>[];
  for (var i = 0; i < _allBlocks.length; i++) {
    if (_allBlocks[i].any((k) => counts[k] > 0)) cands.add(i);
  }

  var best = _bestSets(counts, sets, 0, cands); // 雀頭に使える牌が無い場合
  for (var p = 0; p < Tile.kindCount; p++) {
    if (counts[p] == 0) continue;
    final pairUse = min(counts[p], 2);
    counts[p] -= pairUse;
    best = max(best, pairUse + _bestSets(counts, sets, 0, cands));
    counts[p] += pairUse;
  }
  return best;
}

/// [counts] から [sets] 個の面子に最大何枚使えるか。
///
/// [cands] の [from] 番目以降だけを使う。同じ面子の組み合わせを順番違いで
/// 数え直さないための枝刈りで、結果には影響しない(ある牌種を使う枚数は
/// min(手牌の枚数, 選んだ面子群が要求する枚数)になり、取る順番に依らない)。
int _bestSets(List<int> counts, int sets, int from, List<int> cands) {
  if (sets == 0) return 0;
  var best = 0; // 残りの面子は1枚も手牌に無い(全部引いてくる)場合
  for (var ci = from; ci < cands.length; ci++) {
    final block = _allBlocks[cands[ci]];
    var taken = 0; // block のどの位置を取ったか(復元用のビット)
    var use = 0;
    for (var j = 0; j < 3; j++) {
      if (counts[block[j]] > 0) {
        counts[block[j]]--;
        taken |= 1 << j;
        use++;
      }
    }
    if (use > 0) {
      best = max(best, use + _bestSets(counts, sets - 1, ci, cands));
    }
    for (var j = 0; j < 3; j++) {
      if (taken & (1 << j) != 0) counts[block[j]]++;
    }
  }
  return best;
}

/// 染め手(混一色・清一色)のシャンテン数。到達できないなら null。
///
/// [suit] 以外の数牌(清一色なら字牌も)を一切使わない和了形まで、あと何枚
/// 必要かを数える。副露は下ろせないので、色に合わない副露があれば不可能。
int? _flushShanten(
  GameView view,
  List<int> hand,
  List<Meld> melds,
  int suit, {
  required bool pure,
}) {
  bool allowed(int k) => Tile.isHonor(k) ? !pure : Tile.suit(k) == suit;
  for (final m in melds) {
    if (!m.tiles.every((t) => allowed(Tile.normalize(t)))) return null;
  }
  // 染める色(と字牌)以外は、切ることになるので最初から無いものとして数える
  final counts = toCounts(hand);
  final usable = List<int>.filled(Tile.kindCount, 0);
  for (var k = 0; k < Tile.kindCount; k++) {
    if (allowed(k)) usable[k] = counts[k];
  }
  final freeSets = 4 - melds.length;
  final missing = (freeSets * 3 + 2) - _bestFit(usable, freeSets);
  return max(0, missing - 1);
}

/// その役へまっすぐ向かうときに最も不要な牌を1枚返す。
/// 「シャンテンを落とさない打牌」の中から、役に不要な牌を最優先で選ぶ。
int? _recommendDiscard(
  GameView view,
  List<int> hand, {
  required int meldCount,
  required YakuShape shape,
  int? flushSuit,
  bool flushPure = false, // 清一色狙い(字牌も役に矛盾する)
  required bool tanyao,
  Set<int> protect = const {}, // その役に必要なので切ってはいけない牌種
}) {
  final baseShanten = _shapeShanten(hand, meldCount, shape);

  // その役に本質的に矛盾する牌(最終的に必ず不要になる牌)
  bool violatesYaku(int kind) {
    if (flushSuit != null) {
      if (Tile.isHonor(kind)) {
        if (flushPure) return true; // 清一色は字牌も邪魔
      } else if (Tile.suit(kind) != flushSuit) {
        return true; // 染める色以外の数牌
      }
    }
    if (tanyao && Tile.isTerminalOrHonor(kind)) return true;
    return false;
  }

  final seen = <int>{};
  final violators = <int>[]; // 役に矛盾する牌(落としてでも切る)
  final nonWorse = <int>[]; // シャンテンを落とさない牌
  final spare = <int>[]; // 役に必要ではない牌
  final all = <int>[];
  for (final t in hand) {
    final kind = Tile.normalize(t);
    if (!seen.add(kind)) continue;
    all.add(t);
    if (protect.contains(kind)) continue; // 役の骨格。切る候補にしない
    spare.add(t);
    if (violatesYaku(kind)) {
      violators.add(t);
      continue;
    }
    final rest = List<int>.from(hand)..remove(t);
    if (_shapeShanten(rest, meldCount, shape) <= baseShanten) {
      nonWorse.add(t);
    }
  }

  // 役に矛盾する牌があれば、シャンテンが落ちても最優先で切る。
  // なければシャンテン非悪化の中から、それも無ければ全牌から選ぶ。
  // (手牌が丸ごと役の骨格なら切る牌が無いので、最後は all に戻す)
  final pool = violators.isNotEmpty
      ? violators
      : (nonWorse.isNotEmpty ? nonWorse : (spare.isNotEmpty ? spare : all));
  if (pool.isEmpty) return null;

  // 不要度でスコアリング(高いほど切るべき)
  int score(int t) {
    final kind = Tile.normalize(t);
    var s = 0;
    if (flushSuit != null) {
      if (Tile.isHonor(kind)) {
        if (flushPure) s += 80;
      } else if (Tile.suit(kind) != flushSuit) {
        s += 100; // 色違いは真っ先に切る
      }
    }
    if (tanyao && Tile.isTerminalOrHonor(kind)) s += 60;
    s += _junkValue(view, hand, kind);
    return s;
  }

  pool.sort((a, b) => score(b) - score(a));
  return pool.first;
}

/// 役の形に応じたシャンテン数
int _shapeShanten(List<int> tiles, int meldCount, YakuShape shape) {
  final counts = toCounts(tiles);
  if (shape == YakuShape.chiitoi) {
    // 七対子シャンテン(門前前提)
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
  return calcShanten(counts, meldCount: meldCount);
}

/// 牌の不要度(高いほど切ってよい)。
///
/// 完成/半完成ブロックの牌は残す(負値)。孤立牌ほど切りやすい(正値)。
/// これを見ないと、対子・刻子・順子の一部まで「切ってよい」と誤り、
/// 東の暗刻から東を勧めるような打牌になる。
int _junkValue(GameView view, List<int> hand, int kind) {
  // ドラ・赤は残す
  final doraKinds = Tile.doraKinds(view.doraIndicators);
  if (doraKinds.contains(kind)) return -50;
  // 手牌に赤5があればその5も残す
  if (hand.any((t) => Tile.isRed(t) && Tile.normalize(t) == kind)) return -50;

  final counts = toCounts(hand);
  // 対子・刻子は完成/半完成ブロック。崩すと損なので残す。
  if (counts[kind] >= 3) return -40; // 刻子
  if (counts[kind] >= 2) return -20; // 対子

  if (Tile.isHonor(kind)) {
    // 孤立した字牌(役牌でない客風・単騎)は切りやすい
    return 8;
  }

  // 数牌: 隣接(±1・±2、同色)があれば順子・塔子の一部なので残す。
  final n = Tile.number(kind);
  final suit = Tile.suit(kind);
  bool hasNear(int m) => m >= 1 && m <= 9 && counts[suit * 9 + (m - 1)] > 0;
  if (hasNear(n - 1) || hasNear(n + 1) || hasNear(n - 2) || hasNear(n + 2)) {
    return -5; // 塔子・順子の一部
  }
  // 孤立した数牌。端ほど使いにくいので切りやすい。
  if (n == 1 || n == 9) return 5;
  if (n == 2 || n == 8) return 2;
  return 0;
}

String _yakuhaiName(int kind, int seatW, int roundW) {
  if (Tile.isDragon(kind)) return Tile.displayName(kind);
  final wind = Tile.displayName(kind);
  if (kind == seatW && kind == roundW) return 'ダブ$wind';
  return kind == seatW ? '自風$wind' : '場風$wind';
}

// ---------------- 守備 ----------------

List<ThreatInfo> buildThreats(GameView view) {
  final threats = <ThreatInfo>[];
  for (var i = 0; i < 4; i++) {
    if (i == view.youSeat) continue;
    final p = view.players[i];
    if (p.riichi) {
      threats.add(ThreatInfo(seat: i, description: 'リーチ', level: 2));
      continue;
    }
    if (p.melds.isEmpty) continue;

    final meldTiles = [for (final m in p.melds) ...m.tiles];
    final suits = <int>{};
    for (final t in meldTiles) {
      if (!Tile.isHonor(t)) suits.add(Tile.suit(t));
    }
    final descs = <String>[];
    if (p.melds.length >= 2 && suits.length <= 1) {
      descs.add(
        suits.isEmpty ? '字牌を集めている' : '${_suitNames[suits.first]}のホンイツ気配',
      );
    }
    final seatW = windTile(view.seatWind(i));
    final roundW = windTile(view.roundWind);
    for (final m in p.melds) {
      final kind = Tile.normalize(m.tiles[0]);
      if (!m.isRun && yakuhaiHan(kind, seatW, roundW) > 0) {
        descs.add('役牌(${Tile.displayName(kind)})を鳴いている');
        break;
      }
    }
    final meldDora =
        meldTiles.where(Tile.isRed).length +
        countDora(meldTiles, view.doraIndicators);
    if (meldDora > 0) descs.add('ドラ$meldDora枚をさらしている');
    final pons = p.melds.where((m) => !m.isRun).length;
    if (pons >= 2 && pons == p.melds.length) descs.add('トイトイ気配');

    if (descs.isNotEmpty) {
      threats.add(
        ThreatInfo(
          seat: i,
          description: descs.join('・'),
          level: p.melds.length >= 2 ? 2 : 1,
        ),
      );
    }
  }
  return threats;
}

/// 脅威1つに対する牌種の安全度(100=100%通る)。
/// リーチはsafetyVsそのまま、鳴き脅威は色読みを加味して緩めに評価する。
int threatRisk(GameView view, List<int> hand, int kind, ThreatInfo t) {
  final p = view.players[t.seat];
  var s = safetyVs(kind, t.seat, hand, view);
  if (!p.riichi) {
    // 鳴き読みは色に注目。1色に寄っている相手にはその色と字牌が危険
    final suits = <int>{};
    for (final m in p.melds) {
      for (final tile in m.tiles) {
        if (!Tile.isHonor(tile)) suits.add(Tile.suit(tile));
      }
    }
    if (p.melds.length >= 2 && suits.length == 1) {
      if (!Tile.isHonor(kind) && Tile.suit(kind) == suits.first) {
        return min(s, 30);
      }
      if (Tile.isHonor(kind)) return min(s, 50);
      return max(s, 70);
    }
    s = min(s + 25, 100); // リーチほど切迫していないので緩めに
  }
  return s;
}

/// 手牌の各牌の危険度を評価し、(危険牌, 比較的安全な牌, 現物の牌種) を返す
(List<int>, List<int>, Set<int>) _assessTiles(
  GameView view,
  List<int> hand,
  List<ThreatInfo> threats,
) {
  if (threats.isEmpty) return (const [], const [], const {});

  final scoreOf = <int, int>{}; // 牌種 → 安全度
  for (final kind in hand.map(Tile.normalize).toSet()) {
    var worst = 999;
    for (final t in threats) {
      worst = min(worst, threatRisk(view, hand, kind, t));
    }
    scoreOf[kind] = worst;
  }

  // 全脅威に対して安全度100(=現物やフリテンで100%通る)の牌種
  final genbutsu = {
    for (final e in scoreOf.entries)
      if (e.value >= 100) e.key,
  };

  // raw牌に戻す(種類ごとに1枚だけ代表を出す)
  final seen = <int>{};
  final ranked = <(int, int)>[]; // (raw, score) 種類ごと
  for (final t in hand) {
    final kind = Tile.normalize(t);
    if (!seen.add(kind)) continue;
    ranked.add((t, scoreOf[kind]!));
  }

  // 危険牌: 明確に危険(40以下)なものだけを危険度順に
  final danger =
      (ranked.where((e) => e.$2 <= 40).toList()..sort((a, b) => a.$2 - b.$2))
          .map((e) => e.$1)
          .toList();

  // 安全牌: 手牌の中で相対的に安全な牌を必ず提示する。
  // 危険牌に入っていない中から安全度が高い順に最大3枚(絶対安全でなくても
  // 「相対的にマシ」を示すのが守備の役に立つ)。
  final dangerSet = danger.toSet();
  // 現物は必ず含めたうえで、安全度の高い順に最大4枚
  final safe =
      (ranked.where((e) => !dangerSet.contains(e.$1)).toList()..sort((a, b) {
            final ag = genbutsu.contains(Tile.normalize(a.$1)) ? 1000 : 0;
            final bg = genbutsu.contains(Tile.normalize(b.$1)) ? 1000 : 0;
            return (b.$2 + bg) - (a.$2 + ag);
          }))
          .take(4)
          .map((e) => e.$1)
          .toList();

  return (danger, safe, genbutsu);
}
