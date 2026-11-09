/// 対局の状態ビュー・プロンプト・アクション(ホスト⇔クライアント間でJSON化して共有)
library;

import 'meld.dart';
import 'yaku.dart';

/// 対局設定
class GameConfig {
  /// 1=東風戦 2=半荘戦
  final int rounds;
  final int startScore;

  const GameConfig({this.rounds = 2, this.startScore = 25000});

  Map<String, dynamic> toJson() => {'rounds': rounds, 'startScore': startScore};

  factory GameConfig.fromJson(Map<String, dynamic> json) => GameConfig(
    rounds: json['rounds'] as int? ?? 2,
    startScore: json['startScore'] as int? ?? 25000,
  );
}

class DiscardInfo {
  final int tile;

  /// リーチ宣言牌。**これは「リーチ宣言の巡目」を表すデータであって、
  /// 表示フラグではない。** フリテン・現物の判断はすべてこの巡目が基準になる
  /// (`safety.dart` が [order] を引いて「リーチ後に通った牌」を決める)。
  ///
  /// 宣言牌が鳴かれると河から消えるため、Mリーグ「リーチ宣言牌に対して、
  /// チー・ポン・カンがあった場合は、次巡の打牌を横にする。」に従って**横向きの
  /// 表示だけ**を次の打牌へ移すが、そのときも**このフラグは動かさない**
  /// (動かすと宣言巡が後ろにずれ、現物の範囲が変わってしまう)。
  /// 横向きの組み立ては `table_widgets.dart` の `riverTiles()` を参照。
  final bool riichi;

  /// 鳴かれた牌。河には表示しないが、**自分の捨て牌であることに変わりはない**ので
  /// 捨て牌フリテン(`_SeatState.discardFuriten`)では数える。
  final bool calledAway;

  /// ツモ切り(引いてきた牌をそのまま切った)か。手出しと見分けるための表示用。
  final bool tsumogiri;

  /// 局内の全体通し捨て順(フリテン安全牌の判定に使う)
  final int order;

  const DiscardInfo(
    this.tile, {
    this.riichi = false,
    this.calledAway = false,
    this.tsumogiri = false,
    this.order = -1,
  });

  DiscardInfo copyWith({bool? riichi, bool? calledAway}) => DiscardInfo(
    tile,
    riichi: riichi ?? this.riichi,
    calledAway: calledAway ?? this.calledAway,
    tsumogiri: tsumogiri,
    order: order,
  );

  Map<String, dynamic> toJson() => {
    't': tile,
    if (riichi) 'r': true,
    if (calledAway) 'c': true,
    if (tsumogiri) 'g': true,
    'o': order,
  };

  factory DiscardInfo.fromJson(Map<String, dynamic> json) => DiscardInfo(
    json['t'] as int,
    riichi: json['r'] as bool? ?? false,
    calledAway: json['c'] as bool? ?? false,
    tsumogiri: json['g'] as bool? ?? false,
    order: json['o'] as int? ?? -1,
  );
}

class PlayerView {
  final String name;
  final bool isCpu;
  final bool connected;
  final bool riichi;
  final int handCount; // 手牌枚数(自分以外は裏向き表示用)
  final List<Meld> melds;
  final List<DiscardInfo> discards;

  const PlayerView({
    required this.name,
    required this.isCpu,
    required this.connected,
    required this.riichi,
    required this.handCount,
    required this.melds,
    required this.discards,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'cpu': isCpu,
    'conn': connected,
    'riichi': riichi,
    'count': handCount,
    'melds': melds.map((m) => m.toJson()).toList(),
    'discards': discards.map((d) => d.toJson()).toList(),
  };

  factory PlayerView.fromJson(Map<String, dynamic> json) => PlayerView(
    name: json['name'] as String,
    isCpu: json['cpu'] as bool,
    connected: json['conn'] as bool,
    riichi: json['riichi'] as bool,
    handCount: json['count'] as int,
    melds: (json['melds'] as List)
        .map((m) => Meld.fromJson((m as Map).cast<String, dynamic>()))
        .toList(),
    discards: (json['discards'] as List)
        .map((d) => DiscardInfo.fromJson((d as Map).cast<String, dynamic>()))
        .toList(),
  );
}

/// 1人の和了情報
class WinInfo {
  final int seat;
  final int fromSeat; // -1 ならツモ
  final int winTile;
  final WinScore score;
  final int points; // 総取得点
  final String label; // 満貫など
  final List<int> hand; // 和了時の手の内(和了牌含む)
  final List<Meld> melds;

  const WinInfo({
    required this.seat,
    required this.fromSeat,
    required this.winTile,
    required this.score,
    required this.points,
    required this.label,
    required this.hand,
    required this.melds,
  });

  bool get isTsumo => fromSeat == -1;

  Map<String, dynamic> toJson() => {
    'seat': seat,
    'from': fromSeat,
    'winTile': winTile,
    'score': score.toJson(),
    'points': points,
    'label': label,
    'hand': hand,
    'melds': melds.map((m) => m.toJson()).toList(),
  };

  factory WinInfo.fromJson(Map<String, dynamic> json) => WinInfo(
    seat: json['seat'] as int,
    fromSeat: json['from'] as int,
    winTile: json['winTile'] as int,
    score: WinScore.fromJson((json['score'] as Map).cast<String, dynamic>()),
    points: json['points'] as int,
    label: json['label'] as String,
    hand: (json['hand'] as List).cast<int>(),
    melds: (json['melds'] as List)
        .map((m) => Meld.fromJson((m as Map).cast<String, dynamic>()))
        .toList(),
  );
}

/// 局の結果
class HandResult {
  final String type; // 'win' | 'draw'
  final List<WinInfo> wins;
  final List<int> tenpaiSeats; // 流局時
  final List<int> scoreChanges; // 4席分の増減
  final List<int> scores; // 適用後
  final List<int> uraIndicators;
  final Map<int, List<int>> revealedHands; // 席 → 手の内
  final bool dealerContinues;

  const HandResult({
    required this.type,
    this.wins = const [],
    this.tenpaiSeats = const [],
    required this.scoreChanges,
    required this.scores,
    this.uraIndicators = const [],
    this.revealedHands = const {},
    required this.dealerContinues,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'wins': wins.map((w) => w.toJson()).toList(),
    'tenpai': tenpaiSeats,
    'changes': scoreChanges,
    'scores': scores,
    'ura': uraIndicators,
    'revealed': revealedHands.map((k, v) => MapEntry(k.toString(), v)),
    'dealerContinues': dealerContinues,
  };

  factory HandResult.fromJson(Map<String, dynamic> json) => HandResult(
    type: json['type'] as String,
    wins: (json['wins'] as List)
        .map((w) => WinInfo.fromJson((w as Map).cast<String, dynamic>()))
        .toList(),
    tenpaiSeats: (json['tenpai'] as List).cast<int>(),
    scoreChanges: (json['changes'] as List).cast<int>(),
    scores: (json['scores'] as List).cast<int>(),
    uraIndicators: (json['ura'] as List).cast<int>(),
    revealedHands: (json['revealed'] as Map).map(
      (k, v) => MapEntry(int.parse(k as String), (v as List).cast<int>()),
    ),
    dealerContinues: json['dealerContinues'] as bool,
  );
}

/// 1試合分のスタッツ(ポイント・アガリ/リーチ/放銃回数)。全て席順(0..3)
class GameStats {
  final List<double> points;
  final List<int> wins;
  final List<int> riichis;
  final List<int> dealIns;

  const GameStats({
    required this.points,
    required this.wins,
    required this.riichis,
    required this.dealIns,
  });

  factory GameStats.zero() => GameStats(
    points: List.filled(4, 0),
    wins: List.filled(4, 0),
    riichis: List.filled(4, 0),
    dealIns: List.filled(4, 0),
  );

  Map<String, dynamic> toJson() => {
    'points': points,
    'wins': wins,
    'riichis': riichis,
    'dealIns': dealIns,
  };

  factory GameStats.fromJson(Map<String, dynamic> json) => GameStats(
    points: (json['points'] as List).map((e) => (e as num).toDouble()).toList(),
    wins: (json['wins'] as List).cast<int>(),
    riichis: (json['riichis'] as List).cast<int>(),
    dealIns: (json['dealIns'] as List).cast<int>(),
  );
}

class GameResult {
  final List<int> ranking; // 順位順の席番号
  final List<int> scores;

  /// Mリーグ式最終ポイント(素点-30000+順位点、1000点=1pt)
  final List<double> points;

  const GameResult({
    required this.ranking,
    required this.scores,
    this.points = const [0, 0, 0, 0],
  });

  Map<String, dynamic> toJson() => {
    'ranking': ranking,
    'scores': scores,
    'points': points,
  };

  factory GameResult.fromJson(Map<String, dynamic> json) => GameResult(
    ranking: (json['ranking'] as List).cast<int>(),
    scores: (json['scores'] as List).cast<int>(),
    points: (json['points'] as List? ?? [0, 0, 0, 0])
        .map((e) => (e as num).toDouble())
        .toList(),
  );
}

/// 直近のイベント(UI演出用)
class GameEvent {
  final String type; // 'pon','chi','kan','riichi','tsumo','ron','draw'
  final int seat;
  final int serial; // 同一イベントの重複表示防止

  const GameEvent(this.type, this.seat, this.serial);

  Map<String, dynamic> toJson() => {
    'type': type,
    'seat': seat,
    'serial': serial,
  };

  factory GameEvent.fromJson(Map<String, dynamic> json) => GameEvent(
    json['type'] as String,
    json['seat'] as int,
    json['serial'] as int? ?? 0,
  );
}

/// 顔文字キャスト(席 seat のプレイヤーが emoji 番の表情を出した)
class EmoteCast {
  final int seat;
  final int emoji; // emoteFaces のインデックス(0..8)
  const EmoteCast(this.seat, this.emoji);
}

/// ある席から見た卓の状態
class GameView {
  final int youSeat;
  final int dealer;
  final int roundWind; // 0=東 1=南
  final int kyoku; // 1..4
  final int honba;
  final int riichiSticks;
  final int wallRemaining;
  final int currentSeat; // -1 = なし
  final List<int> scores;
  final List<int> doraIndicators;
  final List<int> hand; // 自分の手牌(ツモ牌除く、ソート済)
  final int? drawnTile;
  final List<PlayerView> players;
  final String phase; // 'playing' | 'handEnd' | 'gameEnd'
  final HandResult? handResult;
  final GameResult? gameResult;
  final GameEvent? lastEvent;

  /// 終了した試合のスタッツ(古い順)
  final List<GameStats> history;

  /// 現在の試合番号(1始まり。gameEnd中は終了した試合の番号)
  final int gameIndex;

  /// 対局中の試合の暫定スタッツ(メンバー順。ポイントは現時点の暫定値)
  final GameStats currentStats;

  /// メンバー(=1試合目の東南西北順で固定)の名前
  final List<String> memberNames;

  /// メンバー → 現在の席
  final List<int> memberSeats;

  /// 自分の待ち牌(牌種・正規化済。テンパイでなければ空)
  final List<int> myWaits;

  /// 自分がフリテンか(ロン不可)
  final bool myFuriten;

  const GameView({
    required this.youSeat,
    required this.dealer,
    required this.roundWind,
    required this.kyoku,
    required this.honba,
    required this.riichiSticks,
    required this.wallRemaining,
    required this.currentSeat,
    required this.scores,
    required this.doraIndicators,
    required this.hand,
    this.drawnTile,
    required this.players,
    required this.phase,
    this.handResult,
    this.gameResult,
    this.lastEvent,
    this.history = const [],
    this.gameIndex = 1,
    required this.currentStats,
    this.memberNames = const [],
    this.memberSeats = const [0, 1, 2, 3],
    this.myWaits = const [],
    this.myFuriten = false,
  });

  /// メンバー名(未設定なら席順の名前で代用)
  List<String> get memberNameList =>
      memberNames.length == 4 ? memberNames : [for (final p in players) p.name];

  /// 席 seat の自風(0=東...)
  int seatWind(int seat) => seatWindOf(seat, dealer);

  Map<String, dynamic> toJson() => {
    'you': youSeat,
    'dealer': dealer,
    'round': roundWind,
    'kyoku': kyoku,
    'honba': honba,
    'sticks': riichiSticks,
    'wall': wallRemaining,
    'current': currentSeat,
    'scores': scores,
    'dora': doraIndicators,
    'hand': hand,
    'drawn': drawnTile,
    'players': players.map((p) => p.toJson()).toList(),
    'phase': phase,
    'handResult': handResult?.toJson(),
    'gameResult': gameResult?.toJson(),
    'event': lastEvent?.toJson(),
    'history': history.map((h) => h.toJson()).toList(),
    'gameIndex': gameIndex,
    'currentStats': currentStats.toJson(),
    'memberNames': memberNames,
    'memberSeats': memberSeats,
    'myWaits': myWaits,
    'myFuriten': myFuriten,
  };

  factory GameView.fromJson(Map<String, dynamic> json) => GameView(
    youSeat: json['you'] as int,
    dealer: json['dealer'] as int,
    roundWind: json['round'] as int,
    kyoku: json['kyoku'] as int,
    honba: json['honba'] as int,
    riichiSticks: json['sticks'] as int,
    wallRemaining: json['wall'] as int,
    currentSeat: json['current'] as int,
    scores: (json['scores'] as List).cast<int>(),
    doraIndicators: (json['dora'] as List).cast<int>(),
    hand: (json['hand'] as List).cast<int>(),
    drawnTile: json['drawn'] as int?,
    players: (json['players'] as List)
        .map((p) => PlayerView.fromJson((p as Map).cast<String, dynamic>()))
        .toList(),
    phase: json['phase'] as String,
    handResult: json['handResult'] == null
        ? null
        : HandResult.fromJson(
            (json['handResult'] as Map).cast<String, dynamic>(),
          ),
    gameResult: json['gameResult'] == null
        ? null
        : GameResult.fromJson(
            (json['gameResult'] as Map).cast<String, dynamic>(),
          ),
    lastEvent: json['event'] == null
        ? null
        : GameEvent.fromJson((json['event'] as Map).cast<String, dynamic>()),
    history: (json['history'] as List? ?? [])
        .map((h) => GameStats.fromJson((h as Map).cast<String, dynamic>()))
        .toList(),
    gameIndex: json['gameIndex'] as int? ?? 1,
    currentStats: json['currentStats'] == null
        ? GameStats.zero()
        : GameStats.fromJson(
            (json['currentStats'] as Map).cast<String, dynamic>(),
          ),
    memberNames: (json['memberNames'] as List? ?? []).cast<String>(),
    memberSeats: (json['memberSeats'] as List? ?? [0, 1, 2, 3]).cast<int>(),
    myWaits: (json['myWaits'] as List? ?? []).cast<int>(),
    myFuriten: json['myFuriten'] as bool? ?? false,
  );
}

/// 自分の手番で可能な行動
class TurnPrompt {
  final int? drawnTile; // 鳴いた直後は null
  final bool canTsumo;
  final List<int> riichiTiles; // リーチ宣言できる打牌(空=リーチ不可)
  final List<int> ankanKinds;
  final List<int> kakanKinds;
  final List<int> forbiddenDiscards; // 喰い替え禁止牌
  final bool riichiLocked; // リーチ中(ツモ切りのみ)

  const TurnPrompt({
    this.drawnTile,
    this.canTsumo = false,
    this.riichiTiles = const [],
    this.ankanKinds = const [],
    this.kakanKinds = const [],
    this.forbiddenDiscards = const [],
    this.riichiLocked = false,
  });

  Map<String, dynamic> toJson() => {
    'drawn': drawnTile,
    'tsumo': canTsumo,
    'riichi': riichiTiles,
    'ankan': ankanKinds,
    'kakan': kakanKinds,
    'forbidden': forbiddenDiscards,
    'locked': riichiLocked,
  };

  factory TurnPrompt.fromJson(Map<String, dynamic> json) => TurnPrompt(
    drawnTile: json['drawn'] as int?,
    canTsumo: json['tsumo'] as bool? ?? false,
    riichiTiles: (json['riichi'] as List? ?? []).cast<int>(),
    ankanKinds: (json['ankan'] as List? ?? []).cast<int>(),
    kakanKinds: (json['kakan'] as List? ?? []).cast<int>(),
    forbiddenDiscards: (json['forbidden'] as List? ?? []).cast<int>(),
    riichiLocked: json['locked'] as bool? ?? false,
  );
}

class TurnAction {
  final String type; // 'discard' | 'tsumo' | 'ankan' | 'kakan'
  final int tile; // discard: 打牌 / ankan・kakan: 牌種
  final bool riichi;

  /// 打牌がツモ切りか。null は「不明」で、エンジンが tile == ツモ牌 で推定する
  /// (CPU・旧データ・ネットワーク旧クライアント)。牌は同種同値の int なので、
  /// 手牌にツモ牌と同じ牌があるときの**手出し**(false)はこのフラグでしか
  /// 伝わらない(河のツモ切り表示・牌譜の is_tsumogiri に効く)。
  final bool? tsumogiri;

  const TurnAction.discard(this.tile, {this.riichi = false, this.tsumogiri})
    : type = 'discard';
  const TurnAction.tsumo()
    : type = 'tsumo',
      tile = -1,
      riichi = false,
      tsumogiri = null;
  const TurnAction.ankan(this.tile)
    : type = 'ankan',
      riichi = false,
      tsumogiri = null;
  const TurnAction.kakan(this.tile)
    : type = 'kakan',
      riichi = false,
      tsumogiri = null;

  TurnAction._(this.type, this.tile, this.riichi, this.tsumogiri);

  Map<String, dynamic> toJson() => {
    'type': type,
    'tile': tile,
    'riichi': riichi,
    if (tsumogiri != null) 'tg': tsumogiri,
  };

  factory TurnAction.fromJson(Map<String, dynamic> json) => TurnAction._(
    json['type'] as String,
    json['tile'] as int? ?? -1,
    json['riichi'] as bool? ?? false,
    json['tg'] as bool?,
  );
}

/// 他家の打牌・加槓への反応
class ReactPrompt {
  final int fromSeat;
  final int tile;
  final bool canRon;
  final bool canPon;
  final bool canKan; // 大明槓
  /// チーで使う手牌2枚の組(実牌ID)。赤が絡む場合は赤/通常を別候補にする。
  final List<List<int>> chiOptions;

  /// ポンで晒す手牌2枚の組(実牌ID)。赤が絡んで選択が生じる場合のみ複数。
  final List<List<int>> ponOptions;
  final bool isChankan; // 加槓に対するロン(搶槓)

  const ReactPrompt({
    required this.fromSeat,
    required this.tile,
    this.canRon = false,
    this.canPon = false,
    this.canKan = false,
    this.chiOptions = const [],
    this.ponOptions = const [],
    this.isChankan = false,
  });

  Map<String, dynamic> toJson() => {
    'from': fromSeat,
    'tile': tile,
    'ron': canRon,
    'pon': canPon,
    'kan': canKan,
    'chi': chiOptions,
    'ponOpts': ponOptions,
    'chankan': isChankan,
  };

  factory ReactPrompt.fromJson(Map<String, dynamic> json) => ReactPrompt(
    fromSeat: json['from'] as int,
    tile: json['tile'] as int,
    canRon: json['ron'] as bool? ?? false,
    canPon: json['pon'] as bool? ?? false,
    canKan: json['kan'] as bool? ?? false,
    chiOptions: (json['chi'] as List? ?? [])
        .map((o) => (o as List).cast<int>())
        .toList(),
    ponOptions: (json['ponOpts'] as List? ?? [])
        .map((o) => (o as List).cast<int>())
        .toList(),
    isChankan: json['chankan'] as bool? ?? false,
  );
}

class ReactAction {
  final String type; // 'pass' | 'ron' | 'pon' | 'kan' | 'chi'

  /// チー: 手牌から使う2枚(実牌ID。赤を含めて指定)
  /// ポン: 晒す2枚(赤の選択がある場合。空なら既定=赤を温存)
  final List<int> tiles;

  const ReactAction.pass() : type = 'pass', tiles = const [];
  const ReactAction.ron() : type = 'ron', tiles = const [];
  const ReactAction.pon([this.tiles = const []]) : type = 'pon';
  const ReactAction.kan() : type = 'kan', tiles = const [];
  const ReactAction.chi(this.tiles) : type = 'chi';

  ReactAction._(this.type, this.tiles);

  Map<String, dynamic> toJson() => {'type': type, 'tiles': tiles};

  factory ReactAction.fromJson(Map<String, dynamic> json) => ReactAction._(
    json['type'] as String,
    // 旧フォーマット('chi')も受け付ける
    (json['tiles'] as List? ?? json['chi'] as List? ?? const []).cast<int>(),
  );
}

/// 席 [seat] の自風(0=東 1=南 2=西 3=北)。親が [dealer] の局で、親が東。
/// 対局ビュー・役判定・手動記録が共有する。
int seatWindOf(int seat, int dealer) => (seat - dealer + 4) % 4;
