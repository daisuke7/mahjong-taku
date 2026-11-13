/// [PaifuDb] の Web 用スタブ(sqlite3 は dart:ffi を要るため Web では使えない)。
///
/// 直接 import しない。paifu_db.dart の条件付き export で Web ビルド時だけ選ばれる。
/// 利用可否は [available] で先に見る前提。開く・読むは常に [UnsupportedError]。
/// 公開メンバーの一覧は [PaifuDbApi](足りなければ analyzer が赤くする)。
library;

import 'paifu_db.dart';

class PaifuDb implements PaifuDbApi {
  /// この環境で牌譜DBを開けるか(ネイティブ=true、Web=false)。
  static const bool available = false;

  PaifuDb.open(String path) {
    throw UnsupportedError('この環境では牌譜DBを開けません');
  }

  static List<String> schemaProblemsAt(String path) => const [
    '(この環境では牌譜DBを使えない)',
  ];

  static Never _unsupported() => throw UnsupportedError('この環境では牌譜DBを使えません');

  @override
  void close() => _unsupported();

  @override
  String? latestGameDate() => _unsupported();

  @override
  List<PaifuSeason> seasons() => _unsupported();

  @override
  List<PaifuStage> stages(int seasonId) => _unsupported();

  @override
  List<String> dates(int stageId) => _unsupported();

  @override
  List<PaifuGame> games(int stageId, String date) => _unsupported();

  @override
  List<PaifuPlayer> gamePlayers(int gameId) => _unsupported();

  @override
  List<PaifuKyoku> kyokus(int gameId) => _unsupported();

  @override
  Map<int, int> kyokuEndScores(int kyokuId) => _unsupported();

  @override
  List<PaifuGameResult> gameResults(int gameId) => _unsupported();

  @override
  List<FailedRiichi> failedRiichis() => _unsupported();

  @override
  List<MissedRonAgari> missedRonAgaris() => _unsupported();

  @override
  List<ZeninShugoFinal> zeninShugoFinals() => _unsupported();

  @override
  List<HaipaiTenpai> haipaiTenpais() => _unsupported();

  @override
  int countAgari(AgariSearchKind kind, {int? seasonId}) => _unsupported();

  @override
  List<FoundAgari> searchAgari(AgariSearchKind kind, {int? seasonId}) =>
      _unsupported();

  @override
  PaifuGame? gameById(int gameId) => _unsupported();

  @override
  Set<String> multiTableDates() => _unsupported();

  @override
  Set<(int, int)> hellTankiRiichiPairs() => _unsupported();

  @override
  bool hasMultipleTables(String date) => _unsupported();

  @override
  List<PaifuEvent> kyokuEvents(int kyokuId) => _unsupported();

  @override
  List<({int kyokuId, int gameId})> ryukyokuKyokus() => _unsupported();

  @override
  List<({String mid, int seasonId, int stageId, String date})> locateGames(
    Set<String> mLeagueGameIds,
  ) => _unsupported();

  @override
  ({Map<int, int> wins, Map<int, int> riichis, Map<int, int> dealIns})
  statCounts(int gameId, {int? beforeKyokuId}) => _unsupported();
}
