/// 自分の対局の保存JSON(my_paifu_store.dart)を [ReplaySession] が読める
/// [PaifuSource] として提供する。playerId は席番号(0..3)。
/// 起家は常に席0(場決め仕様)なので、席順がそのまま1局目の東南西北順になる。
library;

import '../engine/yaku.dart';
import 'paifu_db.dart';

class MyPaifuSource implements PaifuSource {
  final Map<String, dynamic> _game;

  MyPaifuSource(Map<String, dynamic> game) : _game = game;

  /// ReplaySession に渡す gameId(単一試合ファイルなので固定)
  static const int soloGameId = 1;

  String get id => _game['id'] as String;
  String get date => _game['date'] as String;
  bool get finished => _game['finished'] as bool? ?? false;

  List<Map<String, dynamic>> get _kyokus => [
    for (final k in _game['kyokus'] as List) (k as Map).cast(),
  ];

  Map<String, dynamic> _kyoku(int kyokuId) => _kyokus[kyokuId - 1];

  @override
  List<PaifuPlayer> gamePlayers(int gameId) {
    final names = (_game['names'] as List).cast<String>();
    return [for (var i = 0; i < names.length; i++) PaifuPlayer(i, names[i])];
  }

  @override
  List<PaifuKyoku> kyokus(int gameId) {
    final ks = _kyokus;
    return [
      for (var i = 0; i < ks.length; i++)
        PaifuKyoku(
          id: i + 1,
          round: ks[i]['round'] as String,
          honba: ks[i]['honba_count'] as int,
          reachSticks: ks[i]['reach_stick_count'] as int,
          parentPlayerId: ks[i]['parent_player_id'] as int,
        ),
    ];
  }

  @override
  Map<int, int> kyokuEndScores(int kyokuId) {
    final scores = (_kyoku(kyokuId)['end_scores'] as List).cast<int>();
    return {for (var i = 0; i < scores.length; i++) i: scores[i]};
  }

  @override
  List<PaifuEvent> kyokuEvents(int kyokuId) => [
    for (final e in _kyoku(kyokuId)['events'] as List)
      _toEvent((e as Map).cast<String, dynamic>()),
  ];

  PaifuEvent _toEvent(Map<String, dynamic> e) {
    bool flag(String key) => e[key] == true;
    return PaifuEvent(
      type: e['type'] as String,
      order: e['event_order'] as int? ?? 0,
      actorPlayerId: (e['actor_player_id'] ?? e['player_id']) as int?,
      targetPlayerId: e['target_player_id'] as int?,
      hand: e['hand'] as String?,
      tile: e['tile'] as String?,
      rinshan: flag('is_rinshan'),
      reachDeclaration: flag('is_reach_declaration'),
      tsumogiri: flag('is_tsumogiri'),
      reachAccepted: flag('is_accepted'),
      block: e['block'] as String?,
      doraType: e['dora_type'] as String?,
      doraIndicator: e['dora_indicator'] as String?,
      points: e['points'] as int?,
      winningTile: e['winning_tile'] as String?,
      fu: e['fu'] as int?,
      han: e['han'] as int?,
      isYakuman: flag('is_yakuman'),
      description: e['description'] as String?,
      yaku: [
        for (final y in e['yaku'] as List? ?? const [])
          YakuItem((y as Map)['name'] as String, y['han'] as int),
      ],
      ryukyokuPlayers: [
        for (final p in e['players'] as List? ?? const [])
          (
            (p as Map)['player_id'] as int,
            p['is_tenpai'] == true,
            p['points'] as int,
          ),
      ],
    );
  }

  @override
  ({Map<int, int> wins, Map<int, int> riichis, Map<int, int> dealIns})
  statCounts(int gameId, {int? beforeKyokuId}) {
    final wins = <int, int>{};
    final riichis = <int, int>{};
    final dealIns = <int, int>{};
    final ks = _kyokus;
    final end = (beforeKyokuId ?? ks.length + 1) - 1;
    for (var i = 0; i < end && i < ks.length; i++) {
      for (final raw in ks[i]['events'] as List) {
        final e = (raw as Map).cast<String, dynamic>();
        switch (e['type']) {
          case 'tsumo' || 'ron':
            final actor = e['actor_player_id'] as int;
            wins[actor] = (wins[actor] ?? 0) + 1;
            final target = e['target_player_id'] as int?;
            if (target != null) dealIns[target] = (dealIns[target] ?? 0) + 1;
          case 'reach':
            if (e['is_accepted'] == true) {
              final actor = e['actor_player_id'] as int;
              riichis[actor] = (riichis[actor] ?? 0) + 1;
            }
        }
      }
    }
    return (wins: wins, riichis: riichis, dealIns: dealIns);
  }

  @override
  List<PaifuGameResult> gameResults(int gameId) {
    final results = _game['results'] as List?;
    if (results == null) return const [];
    return [
      for (final raw in results)
        PaifuGameResult(
          (raw as Map)['player_id'] as int,
          raw['score'] as int,
          (raw['points'] as num).toDouble(),
          raw['rank'] as int,
        ),
    ];
  }

  @override
  void close() {}
}
