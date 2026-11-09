/// 役判定と符計算
library;

import 'hand.dart';
import 'meld.dart';
import 'models.dart';
import 'tile.dart';

const Map<String, int> _doraOrder = {'赤ドラ': 0, 'ドラ': 1, '裏ドラ': 2};
const Map<String, int> _fixedHeadOrder = {
  '立直': 0,
  'ダブル立直': 0,
  '門前清自摸和': 1,
  '断么九': 2,
  '平和': 3,
};

/// ドラ系の表示ラベル(純粋関数。局結果画面・アガリ一覧で共有)。
/// 「赤1」「ドラ2」「裏3」のように種類の短い名前+枚数。ドラ以外には使わない。
String doraDisplayLabel(YakuItem y) {
  const label = {'赤ドラ': '赤', 'ドラ': 'ドラ', '裏ドラ': '裏'};
  return '${label[y.name] ?? y.name}${y.han}';
}

/// 役1件の表示ラベル(純粋関数。局結果画面・アガリ一覧・記録画面で共有)。
/// ドラ系は [doraDisplayLabel]。役満は翻数を付けない。
/// [withHanSuffix] が true なら「立直 1翻」「国士無双 役満」、false なら
/// 「立直」「混全帯么九2」(2翻以上のみ翻数を添える・一覧向けの短縮形)。
String yakuItemLabel(
  YakuItem y, {
  required bool isYakuman,
  required bool withHanSuffix,
}) {
  if (y.isDora) return doraDisplayLabel(y);
  if (withHanSuffix) {
    return (isYakuman || y.isYakuman) ? '${y.name} 役満' : '${y.name} ${y.han}翻';
  }
  return (!isYakuman && y.han > 1) ? '${y.name}${y.han}' : y.name;
}

/// 表示用の役の並び(純粋関数。局結果画面・アガリ一覧で共有)。
/// 規則(2026-09-16 ユーザー指定):
/// 1. 立直(ダブル立直含む)・門前清自摸和・断么九・平和 は必ずこの順で先頭
/// 2. それ以外の役は翻数の少ない順(同じ翻数は元の順=安定。喰い下がりは考慮しない)
/// 3. ドラは末尾にまとめ、赤→表→裏の順
/// 対戦エンジンの役名(役牌 白 / 自風 東 / 全帯么九 …)と牌譜DBの役名
/// (白 / 自風 / 混全帯么九 …)のどちらでも、上の規則に関わる名前は同じ表記。
List<YakuItem> orderYakuForDisplay(List<YakuItem> yaku) {
  final head = <YakuItem>[];
  final rest = <(int, YakuItem)>[];
  final dora = <YakuItem>[];
  for (var i = 0; i < yaku.length; i++) {
    final y = yaku[i];
    if (_doraOrder.containsKey(y.name)) {
      dora.add(y);
    } else if (_fixedHeadOrder.containsKey(y.name)) {
      head.add(y);
    } else {
      rest.add((i, y));
    }
  }
  head.sort(
    (a, b) => _fixedHeadOrder[a.name]!.compareTo(_fixedHeadOrder[b.name]!),
  );
  rest.sort((a, b) {
    final c = a.$2.han.compareTo(b.$2.han);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  dora.sort((a, b) => _doraOrder[a.name]!.compareTo(_doraOrder[b.name]!));
  return [...head, for (final r in rest) r.$2, ...dora];
}

class YakuItem {
  final String name;
  final int han; // 役満は 0、yakuman フィールドで表す
  final bool isYakuman;

  const YakuItem(this.name, this.han, {this.isYakuman = false});

  /// ドラ系(表・赤・裏)か
  bool get isDora => _doraOrder.containsKey(name);

  Map<String, dynamic> toJson() => {
    'name': name,
    'han': han,
    'yakuman': isYakuman,
  };

  factory YakuItem.fromJson(Map<String, dynamic> json) => YakuItem(
    json['name'] as String,
    json['han'] as int,
    isYakuman: json['yakuman'] as bool? ?? false,
  );
}

class WinScore {
  final List<YakuItem> yaku;
  final int han; // ドラ込み(役満時は 0)
  final int fu;
  final int yakuman; // 役満の複合数

  const WinScore({
    required this.yaku,
    required this.han,
    required this.fu,
    required this.yakuman,
  });

  bool get isYakuman => yakuman > 0;

  /// 高点法の比較用
  int compareValue() => yakuman > 0 ? 1000000 * yakuman : han * 1000 + fu;

  Map<String, dynamic> toJson() => {
    'yaku': yaku.map((y) => y.toJson()).toList(),
    'han': han,
    'fu': fu,
    'yakuman': yakuman,
  };

  factory WinScore.fromJson(Map<String, dynamic> json) => WinScore(
    yaku: (json['yaku'] as List)
        .map((y) => YakuItem.fromJson((y as Map).cast<String, dynamic>()))
        .toList(),
    han: json['han'] as int,
    fu: json['fu'] as int,
    yakuman: json['yakuman'] as int,
  );
}

/// 和了時の状況
class WinContext {
  final List<int> concealed; // 手の内の牌(和了牌を含む)
  final List<Meld> melds;
  final int winTile;
  final bool isTsumo;
  final bool isRiichi;
  final bool isDoubleRiichi;
  final bool isIppatsu;
  final bool isHaitei;
  final bool isHoutei;
  final bool isRinshan;
  final bool isChankan;
  final bool isTenhou;
  final bool isChihou;
  final int seatWind; // 0..3
  final int roundWind; // 0..3
  final List<int> doraIndicators;
  final List<int> uraIndicators;

  const WinContext({
    required this.concealed,
    required this.melds,
    required this.winTile,
    required this.isTsumo,
    this.isRiichi = false,
    this.isDoubleRiichi = false,
    this.isIppatsu = false,
    this.isHaitei = false,
    this.isHoutei = false,
    this.isRinshan = false,
    this.isChankan = false,
    this.isTenhou = false,
    this.isChihou = false,
    required this.seatWind,
    required this.roundWind,
    this.doraIndicators = const [],
    this.uraIndicators = const [],
  });

  bool get isMenzen => melds.every((m) => m.keepsConcealed);
}

/// 状況フラグの組み立てを一箇所に集めた [WinContext] ファクトリ。
/// 対戦エンジンと記録エンジンで判定がずれないよう、状況の素材だけを受けて
/// - 海底 = 山0のツモ(嶺上牌は海底扱いにならない)
/// - 河底 = 山0のロン(搶槓を除く)
/// - 天和/地和 = 第一ツモ(自分の打牌なし・場に鳴きなし)
/// - 自風 = (席 - 親 + 4) % 4
/// をここで確定させる。
WinContext buildWinContext({
  required List<int> concealed,
  required List<Meld> melds,
  required int winTile,
  required bool isTsumo,
  bool isRiichi = false,
  bool isDoubleRiichi = false,
  bool isIppatsu = false,
  required bool wallEmpty,
  bool isRinshan = false,
  bool isChankan = false,
  required bool firstTurn,
  required int seat,
  required int dealer,
  required int roundWind,
  List<int> doraIndicators = const [],
  List<int> uraIndicators = const [],
}) {
  return WinContext(
    concealed: concealed,
    melds: melds,
    winTile: winTile,
    isTsumo: isTsumo,
    isRiichi: isRiichi,
    isDoubleRiichi: isDoubleRiichi,
    isIppatsu: isIppatsu,
    isHaitei: isTsumo && wallEmpty && !isRinshan,
    isHoutei: !isTsumo && wallEmpty && !isChankan,
    isRinshan: isTsumo && isRinshan,
    isChankan: !isTsumo && isChankan,
    isTenhou: isTsumo && seat == dealer && firstTurn,
    isChihou: isTsumo && seat != dealer && firstTurn,
    seatWind: seatWindOf(seat, dealer),
    roundWind: roundWind,
    doraIndicators: doraIndicators,
    uraIndicators: uraIndicators,
  );
}

/// 内部表現: 面子1つ(手の内+副露を統一)
class _Unit {
  final bool isRun;
  final int tile; // 順子は開始牌
  final bool open; // 副露(暗槓以外)
  final bool isKan;
  final bool ronCompleted; // ロンで完成した刻子(暗刻に数えない)

  _Unit({
    required this.isRun,
    required this.tile,
    required this.open,
    this.isKan = false,
    this.ronCompleted = false,
  });

  List<int> get tileKinds =>
      isRun ? [tile, tile + 1, tile + 2] : [tile, tile, tile];

  bool get hasTerminalOrHonor => tileKinds.any(Tile.isTerminalOrHonor);
  bool get hasTerminal => tileKinds.any(Tile.isTerminal);
  bool get isClosedTriplet => !isRun && !open && !ronCompleted;
}

enum _WaitType { ryanmen, kanchan, penchan, shanpon, tanki }

/// 和了を評価する。役がなければ null(和了できない)。
WinScore? evaluateWin(WinContext ctx) {
  final counts = toCounts(ctx.concealed);
  final total = ctx.concealed.length + ctx.melds.length * 3;
  assert(total == 14, 'hand size must be 14, got $total');

  WinScore? best;

  void consider(WinScore? s) {
    if (s == null) return;
    if (best == null || s.compareValue() > best!.compareValue()) best = s;
  }

  if (ctx.melds.isEmpty && isKokushi(counts)) {
    consider(_scoreKokushi(ctx));
  }
  if (ctx.melds.isEmpty && isChiitoi(counts)) {
    consider(_scoreChiitoi(ctx, counts));
  }
  final winKind = Tile.normalize(ctx.winTile);
  for (final decomp in decompose(counts)) {
    // 和了牌の置き場所(高点法のため全候補を試す)
    for (var i = 0; i < decomp.units.length; i++) {
      if (!decomp.units[i].contains(winKind)) continue;
      consider(_scoreStandard(ctx, decomp, placementUnit: i));
    }
    if (decomp.pair == winKind) {
      consider(_scoreStandard(ctx, decomp, placementUnit: -1));
    }
  }
  return best;
}

WinScore? _scoreKokushi(WinContext ctx) {
  final yaku = <YakuItem>[const YakuItem('国士無双', 0, isYakuman: true)];
  var yakuman = 1;
  if (ctx.isTenhou) {
    yaku.add(const YakuItem('天和', 0, isYakuman: true));
    yakuman++;
  }
  if (ctx.isChihou) {
    yaku.add(const YakuItem('地和', 0, isYakuman: true));
    yakuman++;
  }
  return WinScore(yaku: yaku, han: 0, fu: 25, yakuman: yakuman);
}

WinScore? _scoreChiitoi(WinContext ctx, List<int> counts) {
  final yaku = <YakuItem>[];
  final yakumanList = <YakuItem>[];

  final allTiles = <int>[];
  for (var t = 0; t < Tile.kindCount; t++) {
    for (var i = 0; i < counts[t]; i++) {
      allTiles.add(t);
    }
  }

  if (allTiles.every(Tile.isHonor)) {
    yakumanList.add(const YakuItem('字一色', 0, isYakuman: true));
  }
  _addStateYakuman(ctx, yakumanList);
  if (yakumanList.isNotEmpty) {
    return WinScore(
      yaku: yakumanList,
      han: 0,
      fu: 25,
      yakuman: yakumanList.length,
    );
  }

  yaku.add(const YakuItem('七対子', 2));
  _addStateYaku(ctx, yaku);
  if (allTiles.every(Tile.isSimple)) yaku.add(const YakuItem('断么九', 1));
  if (allTiles.every(Tile.isTerminalOrHonor)) {
    yaku.add(const YakuItem('混老頭', 2));
  }
  _addFlushYaku(allTiles, isMenzen: true, yaku: yaku);

  var han = yaku.fold(0, (a, y) => a + y.han);
  if (han == 0) return null;
  han += _addDora(ctx, yaku);
  return WinScore(yaku: yaku, han: han, fu: 25, yakuman: 0);
}

/// リーチ・ツモ・海底等の状況役(通常役)
void _addStateYaku(WinContext ctx, List<YakuItem> yaku) {
  if (ctx.isDoubleRiichi) {
    yaku.add(const YakuItem('ダブル立直', 2));
  } else if (ctx.isRiichi) {
    yaku.add(const YakuItem('立直', 1));
  }
  if (ctx.isIppatsu) yaku.add(const YakuItem('一発', 1));
  if (ctx.isMenzen && ctx.isTsumo) yaku.add(const YakuItem('門前清自摸和', 1));
  if (ctx.isHaitei) yaku.add(const YakuItem('海底摸月', 1));
  if (ctx.isHoutei) yaku.add(const YakuItem('河底撈魚', 1));
  if (ctx.isRinshan) yaku.add(const YakuItem('嶺上開花', 1));
  if (ctx.isChankan) yaku.add(const YakuItem('搶槓', 1));
}

void _addStateYakuman(WinContext ctx, List<YakuItem> yakuman) {
  if (ctx.isTenhou) yakuman.add(const YakuItem('天和', 0, isYakuman: true));
  if (ctx.isChihou) yakuman.add(const YakuItem('地和', 0, isYakuman: true));
}

/// 混一色・清一色
void _addFlushYaku(
  List<int> allTiles, {
  required bool isMenzen,
  required List<YakuItem> yaku,
}) {
  final suits = <int>{};
  var hasHonor = false;
  for (final t in allTiles) {
    if (Tile.isHonor(t)) {
      hasHonor = true;
    } else {
      suits.add(Tile.suit(t));
    }
  }
  if (suits.length == 1) {
    if (hasHonor) {
      yaku.add(YakuItem('混一色', isMenzen ? 3 : 2));
    } else {
      yaku.add(YakuItem('清一色', isMenzen ? 6 : 5));
    }
  }
}

/// ドラ・赤ドラ・裏ドラ(手の内+副露の生牌から数える)
int _addDora(WinContext ctx, List<YakuItem> yaku) {
  final raw = <int>[...ctx.concealed];
  for (final m in ctx.melds) {
    raw.addAll(m.tiles);
  }
  final dora = countDora(raw, ctx.doraIndicators);
  final red = raw.where(Tile.isRed).length;
  final ura = (ctx.isRiichi || ctx.isDoubleRiichi)
      ? countDora(raw, ctx.uraIndicators)
      : 0;
  if (dora > 0) yaku.add(YakuItem('ドラ', dora));
  if (red > 0) yaku.add(YakuItem('赤ドラ', red));
  if (ura > 0) yaku.add(YakuItem('裏ドラ', ura));
  return dora + red + ura;
}

WinScore? _scoreStandard(
  WinContext ctx,
  Decomposition decomp, {
  required int placementUnit,
}) {
  final isMenzen = ctx.isMenzen;
  final winKind = Tile.normalize(ctx.winTile);

  // 待ちの形
  _WaitType wait;
  if (placementUnit == -1) {
    wait = _WaitType.tanki;
  } else {
    final u = decomp.units[placementUnit];
    if (!u.isRun) {
      wait = _WaitType.shanpon;
    } else if (winKind == u.tile + 1) {
      wait = _WaitType.kanchan;
    } else if (winKind == u.tile + 2 && Tile.number(u.tile) == 1) {
      wait = _WaitType.penchan; // 12 + 3
    } else if (winKind == u.tile && Tile.number(u.tile) == 7) {
      wait = _WaitType.penchan; // 89 + 7
    } else {
      wait = _WaitType.ryanmen;
    }
  }

  // 面子リスト(手の内+副露)
  final units = <_Unit>[];
  for (var i = 0; i < decomp.units.length; i++) {
    final u = decomp.units[i];
    final ronCompleted = !ctx.isTsumo && i == placementUnit && !u.isRun;
    units.add(
      _Unit(
        isRun: u.isRun,
        tile: u.tile,
        open: false,
        ronCompleted: ronCompleted,
      ),
    );
  }
  for (final m in ctx.melds) {
    final kinds = m.tiles.map(Tile.normalize).toList();
    units.add(
      _Unit(
        isRun: m.isRun,
        tile: m.isRun ? kinds.reduce((a, b) => a < b ? a : b) : kinds[0],
        open: m.type != MeldType.ankan,
        isKan: m.isKan,
      ),
    );
  }
  final pair = decomp.pair;

  // 全牌リスト(ドラ・断么九などに使用。カンは4枚)
  final allTiles = <int>[pair, pair];
  for (final u in units) {
    allTiles.addAll(u.tileKinds);
    if (u.isKan) allTiles.add(u.tile);
  }

  final yakumanList = <YakuItem>[];
  final yaku = <YakuItem>[];

  final triplets = units.where((u) => !u.isRun).toList();
  final runs = units.where((u) => u.isRun).toList();
  final closedTriplets = units.where((u) => u.isClosedTriplet).length;
  final kans = units.where((u) => u.isKan).length;

  // ---- 役満 ----
  if (closedTriplets == 4) {
    yakumanList.add(const YakuItem('四暗刻', 0, isYakuman: true));
  }
  if (triplets.where((u) => Tile.isDragon(u.tile)).length == 3) {
    yakumanList.add(const YakuItem('大三元', 0, isYakuman: true));
  }
  final windTriplets = triplets.where((u) => Tile.isWind(u.tile)).length;
  if (windTriplets == 4) {
    yakumanList.add(const YakuItem('大四喜', 0, isYakuman: true));
  } else if (windTriplets == 3 && Tile.isWind(pair)) {
    yakumanList.add(const YakuItem('小四喜', 0, isYakuman: true));
  }
  if (allTiles.every(Tile.isHonor)) {
    yakumanList.add(const YakuItem('字一色', 0, isYakuman: true));
  }
  if (allTiles.every(Tile.isTerminal)) {
    yakumanList.add(const YakuItem('清老頭', 0, isYakuman: true));
  }
  const greenTiles = {19, 20, 21, 23, 25, Tile.hatsu}; // 索子23468+發
  if (allTiles.every(greenTiles.contains)) {
    yakumanList.add(const YakuItem('緑一色', 0, isYakuman: true));
  }
  if (kans == 4) {
    yakumanList.add(const YakuItem('四槓子', 0, isYakuman: true));
  }
  if (isMenzen && ctx.melds.isEmpty && _isChuren(ctx.concealed)) {
    yakumanList.add(const YakuItem('九蓮宝燈', 0, isYakuman: true));
  }
  _addStateYakuman(ctx, yakumanList);

  if (yakumanList.isNotEmpty) {
    return WinScore(
      yaku: yakumanList,
      han: 0,
      fu: 30,
      yakuman: yakumanList.length,
    );
  }

  // ---- 通常役 ----
  _addStateYaku(ctx, yaku);

  // 平和
  final pairIsYakuhai =
      Tile.isDragon(pair) ||
      pair == windTile(ctx.seatWind) ||
      pair == windTile(ctx.roundWind);
  final isPinfu =
      isMenzen &&
      runs.length == 4 &&
      !pairIsYakuhai &&
      wait == _WaitType.ryanmen;
  if (isPinfu) yaku.add(const YakuItem('平和', 1));

  if (allTiles.every(Tile.isSimple)) yaku.add(const YakuItem('断么九', 1));

  // 役牌
  for (final u in triplets) {
    if (Tile.isDragon(u.tile)) {
      yaku.add(YakuItem('役牌 ${Tile.displayName(u.tile)}', 1));
    }
    if (u.tile == windTile(ctx.seatWind)) {
      yaku.add(YakuItem('自風 ${windNames[ctx.seatWind]}', 1));
    }
    if (u.tile == windTile(ctx.roundWind)) {
      yaku.add(YakuItem('場風 ${windNames[ctx.roundWind]}', 1));
    }
  }

  // 一盃口・二盃口(門前のみ)
  if (isMenzen) {
    final runStarts = runs.map((u) => u.tile).toList()..sort();
    var peikou = 0;
    for (var i = 0; i + 1 < runStarts.length; i++) {
      if (runStarts[i] == runStarts[i + 1]) {
        peikou++;
        i++; // 同一順子2組を1盃口として消費
      }
    }
    if (peikou >= 2) {
      yaku.add(const YakuItem('二盃口', 3));
    } else if (peikou == 1) {
      yaku.add(const YakuItem('一盃口', 1));
    }
  }

  // 三色同順
  {
    final runSet = runs.map((u) => u.tile).toSet();
    var found = false;
    for (var n = 0; n <= 6 && !found; n++) {
      if (runSet.contains(n) &&
          runSet.contains(n + 9) &&
          runSet.contains(n + 18)) {
        found = true;
      }
    }
    if (found) yaku.add(YakuItem('三色同順', isMenzen ? 2 : 1));
  }

  // 三色同刻
  {
    final tripSet = triplets
        .where((u) => !Tile.isHonor(u.tile))
        .map((u) => u.tile)
        .toSet();
    var found = false;
    for (var n = 0; n <= 8 && !found; n++) {
      if (tripSet.contains(n) &&
          tripSet.contains(n + 9) &&
          tripSet.contains(n + 18)) {
        found = true;
      }
    }
    if (found) yaku.add(const YakuItem('三色同刻', 2));
  }

  // 一気通貫
  {
    final runSet = runs.map((u) => u.tile).toSet();
    var found = false;
    for (var s = 0; s < 3 && !found; s++) {
      final base = s * 9;
      if (runSet.contains(base) &&
          runSet.contains(base + 3) &&
          runSet.contains(base + 6)) {
        found = true;
      }
    }
    if (found) yaku.add(YakuItem('一気通貫', isMenzen ? 2 : 1));
  }

  // 混老頭 / 対々和 / 三暗刻 / 三槓子
  final allTerminalOrHonor = allTiles.every(Tile.isTerminalOrHonor);
  if (allTerminalOrHonor) yaku.add(const YakuItem('混老頭', 2));
  if (triplets.length == 4) yaku.add(const YakuItem('対々和', 2));
  if (closedTriplets == 3) yaku.add(const YakuItem('三暗刻', 2));
  if (kans == 3) yaku.add(const YakuItem('三槓子', 2));

  // 小三元
  if (triplets.where((u) => Tile.isDragon(u.tile)).length == 2 &&
      Tile.isDragon(pair)) {
    yaku.add(const YakuItem('小三元', 2));
  }

  // チャンタ・純チャン(混老頭と複合しない: 順子を含む場合のみ)
  if (!allTerminalOrHonor && runs.isNotEmpty) {
    final allUnitsHaveTH =
        units.every((u) => u.hasTerminalOrHonor) &&
        Tile.isTerminalOrHonor(pair);
    if (allUnitsHaveTH) {
      final noHonor = allTiles.every((t) => !Tile.isHonor(t));
      if (noHonor) {
        yaku.add(YakuItem('純全帯么九', isMenzen ? 3 : 2));
      } else {
        yaku.add(YakuItem('全帯么九', isMenzen ? 2 : 1));
      }
    }
  }

  _addFlushYaku(allTiles, isMenzen: isMenzen, yaku: yaku);

  var han = yaku.fold(0, (a, y) => a + y.han);
  if (han == 0) return null; // 役なし

  // ---- 符計算 ----
  var fu = 20;
  if (isPinfu) {
    fu = ctx.isTsumo ? 20 : 30;
  } else {
    for (final u in units) {
      if (u.isRun) continue;
      final honorOrTerminal = Tile.isTerminalOrHonor(u.tile);
      var base = u.isKan ? 8 : 2;
      if (!u.open && !u.ronCompleted) base *= 2;
      if (honorOrTerminal) base *= 2;
      fu += base;
    }
    if (Tile.isDragon(pair)) fu += 2;
    if (pair == windTile(ctx.seatWind)) fu += 2;
    if (pair == windTile(ctx.roundWind) && ctx.roundWind != ctx.seatWind) {
      fu += 2;
    }
    if (wait == _WaitType.tanki ||
        wait == _WaitType.kanchan ||
        wait == _WaitType.penchan) {
      fu += 2;
    }
    if (ctx.isTsumo) fu += 2;
    if (!ctx.isTsumo && isMenzen) fu += 10;
    if (!isMenzen && fu == 20) fu = 30; // 食い平和形
    fu = ((fu + 9) ~/ 10) * 10;
  }

  han += _addDora(ctx, yaku);
  return WinScore(yaku: yaku, han: han, fu: fu, yakuman: 0);
}

/// 九蓮宝燈(清一色で 1112345678999 + 任意の1枚)
bool _isChuren(List<int> concealed) {
  final counts = toCounts(concealed);
  final suits = concealed.map(Tile.suit).toSet();
  if (suits.length != 1 || suits.first == 3) return false;
  final base = suits.first * 9;
  for (var n = 0; n < 9; n++) {
    final need = (n == 0 || n == 8) ? 3 : 1;
    if (counts[base + n] < need) return false;
  }
  return true;
}

/// [tiles] に含まれるドラの枚数([indicators] は表示牌。赤は数えない)。
/// 役計算・CPU の手牌評価・他家の副露評価が共有する。
int countDora(Iterable<int> tiles, List<int> indicators) {
  var n = 0;
  for (final ind in indicators) {
    final d = Tile.doraFromIndicator(ind);
    n += tiles.where((t) => Tile.normalize(t) == d).length;
  }
  return n;
}

/// 牌種 [kind] を刻子にしたときの役牌の翻数(三元牌 1、自風・場風は重なれば 2)。
/// [seatWindTile] / [roundWindTile] は風牌そのもの(windTile(風))。0 なら役牌でない。
int yakuhaiHan(int kind, int seatWindTile, int roundWindTile) =>
    (Tile.isDragon(kind) ? 1 : 0) +
    (kind == seatWindTile ? 1 : 0) +
    (kind == roundWindTile ? 1 : 0);
