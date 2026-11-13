/// Mリーグ牌譜DB(konoui/m-league-game-db の database.sqlite3)の読み込み。
///
/// 牌の表記はアプリと同じ '123m'/'1z'〜'7z'、赤5は '0m/0p/0s'
/// ([Tile.parse] がそのまま読める)。鳴きブロックは '-'(横向き)・
/// '_'(伏せ牌)・'^'(ツモ切り)の制御文字を含むので [parseBlockTiles] で剥がす。
library;

import '../engine/display_text.dart';
import '../engine/tile.dart';
import '../engine/yaku.dart';

// sqlite3 実装は dart:ffi を要るので Web ビルドでは stub(常に利用不可)に差し替わる。
// 呼び出し側は環境を意識せず [PaifuDb] を使い、利用可否は [PaifuDb.available] で見る。
export 'paifu_db_native.dart'
    if (dart.library.js_interop) 'paifu_db_stub.dart'
    show PaifuDb;

/// 鳴きブロック表記(例 '6z6z-6z', '-7p6p8p', '_7z7z_', '88-8-8p')から
/// 牌リストを取り出す。制御文字は無視する(位置情報は使わない)。
List<int> parseBlockTiles(String block) =>
    Tile.parse(block.replaceAll(RegExp(r'[-_^]'), ''));

class PaifuSeason {
  final int id;
  final String label; // '2025-26'
  const PaifuSeason(this.id, this.label);
}

class PaifuStage {
  final int id;
  final String stage; // regular / semifinal / final
  const PaifuStage(this.id, this.stage);

  String get label => switch (stage) {
    'regular' => 'レギュラーシーズン',
    'semifinal' => 'セミファイナル',
    'final' => 'ファイナル',
    _ => stage,
  };
}

class PaifuGame {
  final int id;
  final String date;
  final int matchNumber; // その日の第n試合
  final String mLeagueGameId; // 例 L001_S022_0036_01B

  const PaifuGame({
    required this.id,
    required this.date,
    required this.matchNumber,
    required this.mLeagueGameId,
  });

  /// 卓の識別(2卓開催日のA/B)。IDの末尾文字でしか判別できない。
  String get tableLetter => tableLetterOf(mLeagueGameId);

  String label({required bool showTable}) => matchLabelOf(
    matchNumber: matchNumber,
    tableLetter: tableLetter,
    showTable: showTable,
  );
}

class PaifuPlayer {
  final int id;
  final String name;
  const PaifuPlayer(this.id, this.name);
}

/// 「南3局1本場」のような局の表記(round は '2z3' 形式)。本体は display_text.dart
String kyokuLabelOf(String round, int honba) =>
    kyokuLabelFromRound(round, honba: honba);

/// m_league_game_id(例 L001_S022_0036_01B)の末尾文字が卓名(A/B)。無ければ 'A'
String tableLetterOf(String mLeagueGameId) =>
    RegExp(r'([A-Z])$').firstMatch(mLeagueGameId)?.group(1) ?? 'A';

/// 試合のラベル「第1試合」「第1試合(A卓)」「2025-10-01 第1試合(A卓)」。
/// 卓名は2卓開催日だけ付ける([showTable])。日付付きは [date] を渡す。
String matchLabelOf({
  required int matchNumber,
  required String tableLetter,
  required bool showTable,
  String? date,
}) {
  final m = '第$matchNumber試合${showTable ? '($tableLetter卓)' : ''}';
  return date == null ? m : '$date $m';
}

/// 「局を探す」で列挙するアガリの種類
enum AgariSearchKind {
  yakuman('役満アガリ', '役満(複合含む)のアガリ'),
  sanbaiman('三倍満アガリ', '11翻以上(役満以外の上限)のアガリ'),
  baiman('倍満アガリ', '8〜10翻のアガリ'),
  ippatsu('リーチ一発アガリ', '一発が付いたアガリ'),
  dora7('ドラ7以上', '表・赤・裏を合わせてドラ7以上のアガリ'),
  ura3('裏ドラ3以上', '裏ドラが3以上乗ったリーチ和了'),
  hadakaTanki('裸単騎のアガリ', '4副露して手牌1枚で待っていたアガリ'),
  hellTanki('地獄単騎リーチの和了', 'リーチ宣言時に単騎待ちで、場に2枚見えていた(残り1枚)和了');

  final String label;
  final String description;
  const AgariSearchKind(this.label, this.description);
}

/// 一覧表示用の役の文字列(純粋関数)。並びは [orderYakuForDisplay](engine/yaku.dart)
/// と同じ(先頭4種固定 → 翻数順 → ドラは赤→表→裏)。
/// ドラは「赤1 ドラ2 裏3」(枚数は常に付ける)。役満は翻数を付けず、2翻以上の役は翻数を添える。
String formatAgariYaku(List<YakuItem> yaku, {required bool isYakuman}) {
  return [
    for (final y in orderYakuForDisplay(yaku))
      yakuItemLabel(y, isYakuman: isYakuman, withHanSuffix: false),
  ].join(' ');
}

/// 「局を探す」で見つかったアガリの1件
class FoundAgari {
  final int gameId;
  final int kyokuId;
  final String date;
  final int matchNumber;
  final String mLeagueGameId;
  final String round;
  final int honba;
  final int winnerId;
  final String winnerName;
  final String loserName; // ツモなら ''
  final int points;
  final int han;
  final int fu;
  final bool isTsumo;
  final bool isYakuman; // 役満(翻数は表示しない。Mリーグは数え役満なし)
  final List<YakuItem> yakuItems; // DBの記録順

  const FoundAgari({
    required this.gameId,
    required this.kyokuId,
    required this.date,
    required this.matchNumber,
    required this.mLeagueGameId,
    required this.round,
    required this.honba,
    required this.winnerId,
    required this.winnerName,
    required this.loserName,
    required this.points,
    required this.han,
    required this.fu,
    required this.isTsumo,
    required this.isYakuman,
    required this.yakuItems,
  });

  String get kyokuLabel => kyokuLabelOf(round, honba);
  String get tableLetter => tableLetterOf(mLeagueGameId);

  /// 一覧表示用: 役 → ドラ(赤・表・裏の順)。例 '立直 平和 赤1 ドラ2 裏3'
  String get yaku => formatAgariYaku(yakuItems, isYakuman: isYakuman);
}

/// 「天和・地和チャンス」(配牌13枚がテンパイしていた局)の1件。
/// DBの haipai_event.is_tenho_possible / is_chiho_possible(配布元が計算)を使う。
class HaipaiTenpai {
  final int gameId;
  final int kyokuId;
  final String date;
  final int matchNumber;
  final String mLeagueGameId;
  final String round; // '1z1' 形式
  final int honba;
  final int playerId;
  final String name;
  final bool isDealer; // 親=天和チャンス、子=地和チャンス
  final String hand; // 配牌(DB表記 '123m456p789s1122z')
  final String firstTile; // 第一打(DB表記)。無ければ ''
  final bool firstTsumogiri;
  final bool firstReach;
  final String winType; // この人が和了したなら 'tsumo'/'ron'、無ければ ''
  final int points;

  const HaipaiTenpai({
    required this.gameId,
    required this.kyokuId,
    required this.date,
    required this.matchNumber,
    required this.mLeagueGameId,
    required this.round,
    required this.honba,
    required this.playerId,
    required this.name,
    required this.isDealer,
    required this.hand,
    required this.firstTile,
    required this.firstTsumogiri,
    required this.firstReach,
    required this.winType,
    required this.points,
  });

  String get kyokuLabel => kyokuLabelOf(round, honba);
  String get tableLetter => tableLetterOf(mLeagueGameId);
  String get chanceLabel => isDealer ? '天和チャンス' : '地和チャンス';

  /// 第一打の扱い: 'ツモ切りリーチ' / '手出しリーチ' / 'ツモ切り(ダマ)' / '手出し(ダマ)'
  String get firstActionLabel {
    if (firstTile.isEmpty) return '';
    final how = firstTsumogiri ? 'ツモ切り' : '手出し';
    return firstReach ? '$howリーチ' : '$how(ダマ)';
  }

  /// この人の結果: 'ツモ 13000点' / 'ロン 6200点' / '不成就'
  String get resultLabel => switch (winType) {
    'tsumo' => 'ツモ $points点',
    'ron' => 'ロン $points点',
    _ => '不成就',
  };
}

/// 「全員集合からの決着」の1件: 南4局(本場付きも含む)の開始時に4人全員が 20,000〜29,999点
/// (Mリーグ実況の「全員集合」)で、その局で試合が終わった(親が連荘しなかった)局。
/// 開始時の点数は直前の局の `kyoku_player_result.score`(局終了時点の点数)から取る。
class ZeninShugoFinal {
  final int gameId;
  final int kyokuId;
  final String date;
  final int matchNumber;
  final String mLeagueGameId;
  final String round;
  final int honba;

  /// 開始時の点数(起家からの席順)
  final List<({String name, int score})> startScores;

  /// 局の和了者(流局なら null)
  final int? agariPlayerId;

  /// 試合1位
  final int topPlayerId;
  final String winnerName;

  const ZeninShugoFinal({
    required this.gameId,
    required this.kyokuId,
    required this.date,
    required this.matchNumber,
    required this.mLeagueGameId,
    required this.round,
    required this.honba,
    required this.startScores,
    required this.agariName,
    required this.isTsumo,
    required this.points,
    required this.agariPlayerId,
    required this.topPlayerId,
    required this.winnerName,
  });

  /// 和了者名・ツモか・点(流局なら空・false・0)
  final String agariName;
  final bool isTsumo;
  final int points;

  /// 「園田賢 ツモ 2000点」「流局」(和了要約は display_text の winSummary と共有)
  String get resultLabel => agariPlayerId == null
      ? '流局'
      : winSummary(name: agariName, isTsumo: isTsumo, points: points);

  /// 再生の視点(局の和了者、流局なら試合1位)
  int get viewPlayerId => agariPlayerId ?? topPlayerId;

  /// 和了したのにトップになれなかった(和了者 ≠ 試合1位)
  bool get agariButNotTop =>
      agariPlayerId != null && agariPlayerId != topPlayerId;

  String get kyokuLabel => kyokuLabelOf(round, honba);
  String get tableLetter => tableLetterOf(mLeagueGameId);

  /// '園田賢 24800 / 白鳥翔 20500 / …'
  String get startScoresLabel =>
      startScores.map((s) => '${s.name} ${s.score}').join(' / ');
}

/// 「見逃しからのロン和了」の1件: 役のあるロン牌を見逃して同巡内フリテンになった人が、
/// 同じ局で後にロン和了した。DB の player_tenpai_state.is_temporary_furiten
/// (他家の打牌時点の聴牌者の行)を使う。
class MissedRonAgari {
  final int gameId;
  final int kyokuId;
  final String date;
  final int matchNumber;
  final String mLeagueGameId;
  final String round;
  final int honba;
  final int winnerId;
  final String winnerName;
  final String missedTile; // 見逃した牌(DB表記)
  final String missedFromName; // 見逃した牌を切った人
  final String ronTile; // 後にロンした牌(DB表記)
  final String loserName; // 放銃者
  final int points;

  const MissedRonAgari({
    required this.gameId,
    required this.kyokuId,
    required this.date,
    required this.matchNumber,
    required this.mLeagueGameId,
    required this.round,
    required this.honba,
    required this.winnerId,
    required this.winnerName,
    required this.missedTile,
    required this.missedFromName,
    required this.ronTile,
    required this.loserName,
    required this.points,
  });

  String get kyokuLabel => kyokuLabelOf(round, honba);
  String get tableLetter => tableLetterOf(mLeagueGameId);

  /// 見逃した相手本人から討ち取った(いちばん堪える形)
  bool get sameOpponent => missedFromName == loserName;
}

/// 「通らなかったリーチ」(宣言牌をロンされて不成立になったリーチ)の1件
class FailedRiichi {
  final int gameId;
  final int kyokuId;
  final String date;
  final int matchNumber;
  final String mLeagueGameId;
  final String round; // '1z1' 形式
  final int honba;
  final int riichiPlayerId;
  final String riichiName;
  final String declTile; // 宣言牌(DB表記 '2m' 等)
  final String winnerName;
  final int points;

  const FailedRiichi({
    required this.gameId,
    required this.kyokuId,
    required this.date,
    required this.matchNumber,
    required this.mLeagueGameId,
    required this.round,
    required this.honba,
    required this.riichiPlayerId,
    required this.riichiName,
    required this.declTile,
    required this.winnerName,
    required this.points,
  });

  String get kyokuLabel => kyokuLabelOf(round, honba);
  String get tableLetter => tableLetterOf(mLeagueGameId);
}

class PaifuKyoku {
  final int id;
  final String round; // '1z1'(東1)〜'2z4'(南4)
  final int honba;
  final int reachSticks; // 局開始時の供託本数
  final int parentPlayerId;

  const PaifuKyoku({
    required this.id,
    required this.round,
    required this.honba,
    required this.reachSticks,
    required this.parentPlayerId,
  });

  /// 場風(0=東 1=南 2=西)
  int get roundWind => int.parse(round.substring(0, 1)) - 1;

  /// 局(1..4)
  int get kyokuNumber => int.parse(round.substring(2));
}

/// 牌譜イベント1件。type ごとに使うフィールドが異なる(未使用は null/空)。
class PaifuEvent {
  final String type; // event.type の値
  final int order;
  final int? actorPlayerId;
  final int? targetPlayerId;
  final String? hand; // haipai
  final String? tile; // draw/discard/鳴きの取得牌
  final bool rinshan; // draw
  final bool reachDeclaration; // discard
  final bool tsumogiri; // discard
  final bool reachAccepted; // reach
  final String? block; // 鳴き
  final String? doraType; // omote / ura
  final String? doraIndicator;
  // agari
  final int? points;
  final String? winningTile;
  final int? fu;
  final int? han;
  final bool isYakuman;
  final String? description;
  final List<YakuItem> yaku;
  // ryukyoku: (playerId, テンパイか, 点数増減)
  final List<(int, bool, int)> ryukyokuPlayers;

  const PaifuEvent({
    required this.type,
    required this.order,
    this.actorPlayerId,
    this.targetPlayerId,
    this.hand,
    this.tile,
    this.rinshan = false,
    this.reachDeclaration = false,
    this.tsumogiri = false,
    this.reachAccepted = false,
    this.block,
    this.doraType,
    this.doraIndicator,
    this.points,
    this.winningTile,
    this.fu,
    this.han,
    this.isYakuman = false,
    this.description,
    this.yaku = const [],
    this.ryukyokuPlayers = const [],
  });
}

/// 試合の最終結果(1人分)
class PaifuGameResult {
  final int playerId;
  final int score;
  final double points;
  final int rank;
  const PaifuGameResult(this.playerId, this.score, this.points, this.rank);
}

/// 牌譜の読み出しインターフェース。[ReplaySession] が試合を再生するのに
/// 必要な最小限のメソッド群で、MリーグDB([PaifuDb])と自分の対局の保存
/// (MyPaifuSource)の両方が実装する。playerId の意味は実装ごとに閉じる
/// (DB=グローバルID / 自分牌譜=席番号)。
abstract class PaifuSource {
  /// 試合の4人を1局目の席順(東南西北)で返す
  List<PaifuPlayer> gamePlayers(int gameId);

  List<PaifuKyoku> kyokus(int gameId);

  /// 局終了時の点数(playerId → score)
  Map<int, int> kyokuEndScores(int kyokuId);

  /// 局の全イベントを発生順で返す
  List<PaifuEvent> kyokuEvents(int kyokuId);

  /// 試合のスタッツ集計(playerId → 回数)。[beforeKyokuId] を渡すと
  /// その局より前までの集計になる。
  ({Map<int, int> wins, Map<int, int> riichis, Map<int, int> dealIns})
  statCounts(int gameId, {int? beforeKyokuId});

  /// 試合の最終結果(未終了なら空)
  List<PaifuGameResult> gameResults(int gameId);

  void close();
}

/// MリーグDB実装 [PaifuDb] が持つべき公開メンバーの宣言(sqlite 実装 paifu_db_native.dart と
/// Web スタブ paifu_db_stub.dart の両方が implements する)。[PaifuSource] の分は継承。
/// 片方にだけメソッドを足すと analyzer がその場で赤くする(Web ビルドを待たない)。
/// static メンバー(`available`・`schemaProblemsAt`)はインターフェースに書けないので両実装に同名で置く。
abstract interface class PaifuDbApi implements PaifuSource {
  String? latestGameDate();

  List<PaifuSeason> seasons();

  List<PaifuStage> stages(int seasonId);

  List<String> dates(int stageId);

  List<PaifuGame> games(int stageId, String date);

  List<FailedRiichi> failedRiichis();

  List<MissedRonAgari> missedRonAgaris();

  List<ZeninShugoFinal> zeninShugoFinals();

  List<HaipaiTenpai> haipaiTenpais();

  int countAgari(AgariSearchKind kind, {int? seasonId});

  List<FoundAgari> searchAgari(AgariSearchKind kind, {int? seasonId});

  PaifuGame? gameById(int gameId);

  Set<String> multiTableDates();

  Set<(int, int)> hellTankiRiichiPairs();

  bool hasMultipleTables(String date);

  List<({int kyokuId, int gameId})> ryukyokuKyokus();

  List<({String mid, int seasonId, int stageId, String date})> locateGames(
    Set<String> mLeagueGameIds,
  );

  @override
  ({Map<int, int> wins, Map<int, int> riichis, Map<int, int> dealIns})
  statCounts(int gameId, {int? beforeKyokuId});
}
