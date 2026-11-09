/// 読みクイズ(流局時のテンパイ・待ち当て)の出題ロジック。
///
/// Mリーグ牌譜DBから流局までもつれた局を選び、流局時点の卓の状態
/// (全員の手牌・河・副露)と正解(テンパイ/シャンテン数/待ち牌)を組む。
///
/// 正解の二段構え:
/// - テンパイ/ノーテンは **DBの流局時記録(is_tenpai)を正** とする
/// - 待ち牌・シャンテン数は共有純関数([calcShanten]/[calcLiveWaits]。
///   Mリーグの聴牌定義「自己の手牌・副露牌でアガリ牌が消去されている場合は
///   認められない」に準拠)で計算する
/// 両者が食い違う局(記録ミス・形はテンパイでもノーテン申告した局など)は
/// 出題しない。
library;

import 'dart:math';

import '../engine/hand.dart';
import '../engine/meld.dart';
import '../engine/models.dart';
import 'kyoku_state.dart';
import 'paifu_db.dart';

/// 難易度。リーチの有無で他家の打ち筋(降りているか)の読みやすさが変わる。
enum YomiQuizLevel {
  easy('かんたん', 'リーチのかかった流局局。リーチ者は待ち当てのみ'),
  normal('ふつう', 'すべての流局局を流局時点で出題'),
  hard('むずかしい', 'リーチのない流局局を、流局の2〜3巡前で出題');

  final String label;
  final String description;
  const YomiQuizLevel(this.label, this.description);
}

/// 1問分: 流局時点(または少し手前)の卓の状態と各席の正解。
class YomiQuizProblem {
  /// 出典(例 '2026-01-15 第1試合')
  final String sourceLabel;

  /// 流局の何打牌前で切り出したか(0=流局時点)
  final int cutoffDiscards;

  /// 次にツモる席(-1=なし)。巻き戻し出題でのみ入り、最終打牌者の下家で固定。
  /// 実際の牌譜では次に鳴きが入ることもあるが、それは未来の情報なので
  /// 漏らさない(その時点で観戦者に見えている「次のツモ番」だけを示す)。
  final int nextDrawSeat;

  // ---- 出典の牌譜ビューア起動用(-1/空 = 起動不可。テスト出題など) ----
  final int gameId;
  final int kyokuIndex; // kyokus(gameId) のインデックス
  final String mLeagueGameId;

  final List<String> names; // 席順(0..3)
  final int dealer;
  final int roundWind;
  final int kyokuNumber;
  final int honba;
  final int sticks; // 流局時点の供託(局中のリーチ込み)
  final List<int> scores; // 流局時点(リーチ棒支払い反映)
  final List<int> doraIndicators;
  final int wallRemaining;

  final List<List<int>> hands; // 各席の手牌(伏せて出題し、答え合わせで開く)
  final List<List<Meld>> melds;
  final List<List<DiscardInfo>> rivers;
  final List<bool> riichi;

  // ---- 正解 ----
  final List<bool> tenpai; // DBの流局時記録
  final List<int> shanten; // 計算値(0=テンパイ)
  final List<List<int>> waits; // テンパイ席のみ非空(牌種・正規化・昇順)

  const YomiQuizProblem({
    required this.sourceLabel,
    this.cutoffDiscards = 0,
    this.nextDrawSeat = -1,
    this.gameId = -1,
    this.kyokuIndex = -1,
    this.mLeagueGameId = '',
    required this.names,
    required this.dealer,
    required this.roundWind,
    required this.kyokuNumber,
    required this.honba,
    required this.sticks,
    required this.scores,
    required this.doraIndicators,
    required this.wallRemaining,
    required this.hands,
    required this.melds,
    required this.rivers,
    required this.riichi,
    required this.tenpai,
    required this.shanten,
    required this.waits,
  });

  /// 席 seat の解答区分(0=テンパイ 1=イーシャンテン 2=それ以外)
  int category(int seat) => tenpai[seat] ? 0 : (shanten[seat] == 1 ? 1 : 2);

  /// 区分の表示名(選択肢・解答チップ・採点で共有)
  static String categoryLabel(int c) => switch (c) {
    0 => 'テンパイ',
    1 => 'イーシャンテン',
    _ => 'それ以外',
  };
}

/// 局のイベント列から流局時点(または [cutoffDiscards] 打牌手前)のクイズ問題を組む。
///
/// 出題しない局(null を返す):
/// - 流局で終わっていない局・配牌が記録されていない局
/// - 流局時点の出題で、DBのテンパイ記録と [calcLiveWaits] の判定が食い違う局
/// - 形はテンパイだがアガリ牌を自分で使い切っていてノーテン扱いの局
///   (「それ以外」とも「イーシャンテン」とも言い切れず、3択の正解が
///   一意にならないため)
/// - 巻き戻し出題([cutoffDiscards] > 0)でリーチのある局
///   (リーチ宣言の直後で切ると宣言と供託が食い違う中途半端な状態になり得る
///   ため、むずかしいモードの「リーチなし局」条件をここでも強制する)。
///   このとき正解はDB記録が使えないため全席 [calcLiveWaits] の計算のみで組む。
YomiQuizProblem? buildYomiQuizProblem({
  required List<PaifuEvent> events,
  required Map<int, int> seatOf,
  required List<String> names,
  required PaifuKyoku kyoku,
  required List<int> startScores,
  required String sourceLabel,
  int cutoffDiscards = 0,
  int gameId = -1,
  int kyokuIndex = -1,
  String mLeagueGameId = '',
}) {
  // 局の結末と全体像を先に確認する
  List<(int, bool, int)>? ryukyokuPlayers;
  var totalDiscards = 0;
  var hasReach = false;
  for (final ev in events) {
    switch (ev.type) {
      case 'ron' || 'tsumo':
        return null; // 和了局は出題しない
      case 'ryukyoku':
        ryukyokuPlayers = ev.ryukyokuPlayers;
      case 'discard':
        totalDiscards++;
      case 'reach':
        hasReach = hasReach || ev.reachAccepted;
    }
  }
  if (ryukyokuPlayers == null) return null;
  if (cutoffDiscards > 0 && (hasReach || totalDiscards - cutoffDiscards < 4)) {
    return null;
  }
  final targetDiscards = totalDiscards - cutoffDiscards;

  final ks = KyokuTileState(seatOf);
  final scores = [...startScores];
  var sticks = kyoku.reachSticks;
  var discards = 0;
  var lastDiscardSeat = -1;
  for (final ev in events) {
    if (ev.type == 'discard') {
      lastDiscardSeat = seatOf[ev.actorPlayerId] ?? -1;
    }
    switch (ev.type) {
      case 'ron' || 'tsumo' || 'ryukyoku':
        continue; // 局の結果はここでは適用しない
      case 'reach':
        ks.apply(ev);
        if (ev.reachAccepted) {
          scores[seatOf[ev.actorPlayerId]!] -= 1000;
          sticks++;
        }
      default:
        ks.apply(ev);
    }
    // 巻き戻し出題: 目標打牌数に達した打牌の直後(全員ツモ牌なし)で切る
    if (cutoffDiscards > 0 &&
        ev.type == 'discard' &&
        ++discards >= targetDiscards) {
      break;
    }
  }
  if (ks.hands.any((h) => h.isEmpty)) return null;
  // 切り出し時点は打牌直後なのでツモ牌が残っていることはない(欠損の検出)
  if (ks.drawn.any((d) => d != null)) return null;

  final tenpai = List.filled(4, false);
  if (cutoffDiscards == 0) {
    for (final (pid, t, _) in ryukyokuPlayers) {
      final seat = seatOf[pid];
      if (seat == null) return null;
      tenpai[seat] = t;
    }
  }

  final shanten = <int>[];
  final waits = <List<int>>[];
  for (var s = 0; s < 4; s++) {
    final meldCount = ks.melds[s].length;
    final counts = toCounts(ks.hands[s]);
    final meldCounts = toCounts([for (final m in ks.melds[s]) ...m.tiles]);
    final sh = calcShanten(counts, meldCount: meldCount);
    final w = calcLiveWaits(counts, meldCounts, meldCount: meldCount);
    if (cutoffDiscards == 0) {
      // 検算: DB記録と計算が一致しない局は出さない
      if (tenpai[s] != w.isNotEmpty) return null;
    } else {
      tenpai[s] = w.isNotEmpty; // 途中巡目の記録は無いので計算が正
    }
    if (!tenpai[s] && sh == 0) return null; // アガリ牌使い切りのノーテン形
    shanten.add(sh);
    waits.add(tenpai[s] ? w : const []);
  }

  return YomiQuizProblem(
    sourceLabel: sourceLabel,
    cutoffDiscards: cutoffDiscards,
    nextDrawSeat: cutoffDiscards > 0 && lastDiscardSeat >= 0
        ? (lastDiscardSeat + 1) % 4
        : -1,
    gameId: gameId,
    kyokuIndex: kyokuIndex,
    mLeagueGameId: mLeagueGameId,
    names: names,
    dealer: seatOf[kyoku.parentPlayerId] ?? 0,
    roundWind: kyoku.roundWind,
    kyokuNumber: kyoku.kyokuNumber,
    honba: kyoku.honba,
    sticks: sticks,
    scores: scores,
    doraIndicators: ks.doraInds,
    wallRemaining: ks.wall,
    hands: ks.hands,
    melds: ks.melds,
    rivers: ks.rivers,
    riichi: ks.riichi,
    tenpai: tenpai,
    shanten: shanten,
    waits: waits,
  );
}

/// 出題デッキ: DB内の流局局をシャッフルして順に出題する。
class YomiQuizDeck {
  final PaifuDb db;
  final Random _rng;
  late final List<({int kyokuId, int gameId})> _pool;
  int _next = 0;

  YomiQuizDeck(this.db, {int? seed}) : _rng = Random(seed) {
    _pool = db.ryukyokuKyokus()..shuffle(_rng);
  }

  /// 次の問題。難易度に合う局が1つも無ければ null。
  YomiQuizProblem? nextProblem(YomiQuizLevel level) {
    for (var tried = 0; tried < _pool.length; tried++) {
      if (_next >= _pool.length) {
        _next = 0;
        _pool.shuffle(_rng);
      }
      final entry = _pool[_next++];
      final p = _buildFrom(entry, level);
      if (p != null) return p;
    }
    return null;
  }

  YomiQuizProblem? _buildFrom(
    ({int kyokuId, int gameId}) entry,
    YomiQuizLevel level,
  ) {
    final players = db.gamePlayers(entry.gameId);
    if (players.length != 4) return null;
    final kyokus = db.kyokus(entry.gameId);
    final i = kyokus.indexWhere((k) => k.id == entry.kyokuId);
    if (i < 0) return null;
    final seatOf = {for (var s = 0; s < 4; s++) players[s].id: s};
    final startScores = i == 0
        ? List.filled(4, 25000)
        : () {
            final byPlayer = db.kyokuEndScores(kyokus[i - 1].id);
            return [for (final p in players) byPlayer[p.id] ?? 25000];
          }();
    final game = db.gameById(entry.gameId);
    // 出典: 例 '2025-10-01 第1試合(A卓)'(卓名は2卓開催日のみ。表記は matchLabelOf で共通)
    final p = buildYomiQuizProblem(
      events: db.kyokuEvents(entry.kyokuId),
      seatOf: seatOf,
      names: [for (final p in players) p.name],
      kyoku: kyokus[i],
      startScores: startScores,
      sourceLabel: game == null
          ? ''
          : matchLabelOf(
              matchNumber: game.matchNumber,
              tableLetter: game.tableLetter,
              showTable: db.hasMultipleTables(game.date),
              date: game.date,
            ),
      gameId: entry.gameId,
      kyokuIndex: i,
      mLeagueGameId: game?.mLeagueGameId ?? '',
      // むずかしい: 流局の2〜3巡(8〜12打牌)手前で切り出す。
      // リーチなし局の条件は buildYomiQuizProblem 側で強制される。
      cutoffDiscards: level == YomiQuizLevel.hard ? 8 + _rng.nextInt(5) : 0,
    );
    if (p == null) return null;
    // かんたん: リーチのかかった局だけを出題する
    if (level == YomiQuizLevel.easy && !p.riichi.contains(true)) return null;
    return p;
  }
}
