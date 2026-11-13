/// [PaifuDb] の sqlite3 実装(ネイティブ専用。Web ビルドでは paifu_db_stub.dart が代わりに export される)。
///
/// 直接 import しない。常に paifu_db.dart 経由で [PaifuDb] を使う。
library;

import 'package:sqlite3/sqlite3.dart';

import '../engine/tile.dart';
import '../engine/yaku.dart';
import 'db_schema.dart';
import 'paifu_db.dart';

/// 開いた DB に [DbSchema.required] のテーブル・列が揃っているか。
/// 足りないものを 'table' または 'table.column' の形で返す(空なら読める)。
List<String> schemaProblems(Database db) {
  final problems = <String>[];
  for (final e in DbSchema.required.entries) {
    // table_info は生成列(agari_event.revenue_points 等)を返さないので table_xinfo を使う
    // (2026-10-02 に正常な DB を「読めない形式」と誤判定した原因)
    final cols = {
      for (final r in db.select('PRAGMA table_xinfo(${e.key})'))
        r['name'] as String,
    };
    if (cols.isEmpty) {
      problems.add(e.key);
      continue;
    }
    for (final c in e.value) {
      if (!cols.contains(c)) problems.add('${e.key}.$c');
    }
  }
  return problems;
}

/// Mリーグ牌譜DB(konoui/m-league-game-db)の読み出し。SQL は配布元の
/// **2026-10-01 リリース(20261001-2219)以降のスキーマ**に合わせている。
/// 同リリースでテーブル名・列名が大きく改名された(配布元 DB_CHANGELOG.md:
/// agari_yaku_event→agari_yaku、ryukyoku_player_event→ryukyoku_player、
/// kyoku.parent_player_id→oya_player_id・reach_stick_count→kyotaku_count、
/// game.match_number→day_game_number、agari_event.points→revenue_points(生成列)・
/// winning_tile→agari_tile、haipai_event.player_id→actor_player_id・
/// tenho_possible→is_tenho_possible 等)。それより前の DB は読めない
/// (アプリ内の「最新牌譜ダウンロード」で取り直す)。改名され得る識別子は
/// db_schema.dart の [DbSchema] に集約してあり、次の改名はそこだけ直す。
class PaifuDb implements PaifuDbApi {
  /// この環境で牌譜DBを開けるか(ネイティブ=true、Web=false)。
  static const bool available = true;

  final Database _db;

  PaifuDb.open(String path) : _db = sqlite3.open(path, mode: OpenMode.readOnly);

  /// DB ファイルにアプリが読むテーブル・列が揃っているか(足りないものの一覧。空なら可)。
  /// 取り込み時と起動時の検査に使う。開けないファイルは「全部足りない」扱い。
  static List<String> schemaProblemsAt(String path) {
    try {
      final db = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        return schemaProblems(db);
      } finally {
        db.dispose();
      }
    } catch (e) {
      return ['(開けない: $e)'];
    }
  }

  @override
  void close() => _db.dispose();

  /// 記録されている最終試合日(牌譜バージョン表示用)
  @override
  String? latestGameDate() {
    final r = _db.select('SELECT MAX(date) AS d FROM game');
    return r.first['d'] as String?;
  }

  @override
  List<PaifuSeason> seasons() => [
    for (final r in _db.select(
      'SELECT id, start_year, end_year FROM league_season '
      'ORDER BY start_year DESC',
    ))
      PaifuSeason(
        r['id'] as int,
        '${r['start_year']}-${(r['end_year'] as int) % 100}',
      ),
  ];

  @override
  List<PaifuStage> stages(int seasonId) => [
    for (final r in _db.select(
      'SELECT s.id, s.stage FROM season_stage s '
      'WHERE s.league_season_id = ? '
      // レギュラー→セミ→ファイナルの開催順
      "ORDER BY CASE s.stage WHEN 'regular' THEN 0 "
      "WHEN 'semifinal' THEN 1 ELSE 2 END",
      [seasonId],
    ))
      // 試合が1つも無いステージ(未開催)は出さない
      if (_db.select('SELECT 1 FROM game WHERE season_stage_id = ? LIMIT 1', [
        r['id'],
      ]).isNotEmpty)
        PaifuStage(r['id'] as int, r['stage'] as String),
  ];

  @override
  List<String> dates(int stageId) => [
    for (final r in _db.select(
      'SELECT DISTINCT date FROM game WHERE season_stage_id = ? '
      'ORDER BY date DESC',
      [stageId],
    ))
      r['date'] as String,
  ];

  @override
  List<PaifuGame> games(int stageId, String date) => [
    for (final r in _db.select(
      'SELECT id, date, ${DbSchema.gameDayNumber}, m_league_game_id FROM game '
      'WHERE season_stage_id = ? AND date = ? '
      'ORDER BY m_league_game_id',
      [stageId, date],
    ))
      PaifuGame(
        id: r['id'] as int,
        date: r['date'] as String,
        matchNumber: r[DbSchema.gameDayNumber] as int,
        mLeagueGameId: r['m_league_game_id'] as String,
      ),
  ];

  /// 試合の4人を**1局目の席順(東南西北)**で返す
  @override
  List<PaifuPlayer> gamePlayers(int gameId) {
    final firstKyoku = _db.select(
      'SELECT id FROM kyoku WHERE game_id = ? ORDER BY id LIMIT 1',
      [gameId],
    );
    if (firstKyoku.isEmpty) return const [];
    final rows = _db.select(
      'SELECT r.player_id, r.player_wind, p.name '
      'FROM kyoku_player_result r JOIN player p ON p.id = r.player_id '
      'WHERE r.kyoku_id = ? '
      'ORDER BY r.player_wind',
      [firstKyoku.first['id']],
    );
    // player_wind は '1z'..'4z'(東南西北)。文字列ソートで席順になる。
    return [
      for (final r in rows)
        PaifuPlayer(r['player_id'] as int, r['name'] as String),
    ];
  }

  @override
  List<PaifuKyoku> kyokus(int gameId) => [
    for (final r in _db.select(
      'SELECT id, round, honba_count, ${DbSchema.kyokuKyotaku}, '
      '${DbSchema.kyokuOya} FROM kyoku WHERE game_id = ? ORDER BY id',
      [gameId],
    ))
      PaifuKyoku(
        id: r['id'] as int,
        round: r['round'] as String,
        honba: r['honba_count'] as int,
        reachSticks: r[DbSchema.kyokuKyotaku] as int,
        parentPlayerId: r[DbSchema.kyokuOya] as int,
      ),
  ];

  /// 局終了時の点数(playerId → score)
  @override
  Map<int, int> kyokuEndScores(int kyokuId) => {
    for (final r in _db.select(
      'SELECT player_id, score FROM kyoku_player_result '
      'WHERE kyoku_id = ?',
      [kyokuId],
    ))
      r['player_id'] as int: r['score'] as int,
  };

  @override
  List<PaifuGameResult> gameResults(int gameId) => [
    for (final r in _db.select(
      'SELECT player_id, score, ${DbSchema.resultLeaguePoints}, rank FROM game_player_result '
      'WHERE game_id = ?',
      [gameId],
    ))
      PaifuGameResult(
        r['player_id'] as int,
        r['score'] as int,
        (r[DbSchema.resultLeaguePoints] as num).toDouble(),
        r['rank'] as int,
      ),
  ];

  /// 流局で終わった局の一覧(読みクイズの出題プール)
  @override
  List<({int kyokuId, int gameId})> ryukyokuKyokus() => [
    for (final r in _db.select(
      'SELECT e.kyoku_id AS kid, k.game_id AS gid FROM event e '
      'JOIN kyoku k ON k.id = e.kyoku_id WHERE e.type = ?',
      ['ryukyoku'],
    ))
      (kyokuId: r['kid'] as int, gameId: r['gid'] as int),
  ];

  /// 通らなかったリーチ(reach_event.is_accepted=0)の一覧。新しい試合日順。
  /// 宣言牌はリーチ直後の打牌、討ち取った側はその局の後続ロン。
  @override
  List<FailedRiichi> failedRiichis() => [
    for (final r in _db.select(
      'SELECT g.id AS gid, k.id AS kid, g.date, g.${DbSchema.gameDayNumber} AS mn, '
      'g.m_league_game_id AS mid, k.round, k.honba_count AS honba, '
      'r.actor_player_id AS pid, p.name AS pname, '
      "COALESCE(d.tile, '') AS tile, "
      "COALESCE(p2.name, '') AS wname, COALESCE(a.${DbSchema.agariRevenue}, 0) AS pts "
      'FROM event e JOIN reach_event r ON r.event_id = e.id '
      'JOIN kyoku k ON k.id = e.kyoku_id JOIN game g ON g.id = k.game_id '
      'JOIN player p ON p.id = r.actor_player_id '
      'LEFT JOIN event ed ON ed.kyoku_id = k.id '
      '  AND ed.event_order = e.event_order + 1 '
      'LEFT JOIN discard_event d ON d.event_id = ed.id '
      'LEFT JOIN event er ON er.kyoku_id = k.id AND er.type = ? '
      '  AND er.event_order > e.event_order '
      'LEFT JOIN agari_event a ON a.event_id = er.id '
      'LEFT JOIN player p2 ON p2.id = a.actor_player_id '
      'WHERE r.is_accepted = 0 '
      'ORDER BY g.date DESC, g.${DbSchema.gameDayNumber} DESC, e.event_order',
      ['ron'],
    ))
      FailedRiichi(
        gameId: r['gid'] as int,
        kyokuId: r['kid'] as int,
        date: r['date'] as String,
        matchNumber: r['mn'] as int,
        mLeagueGameId: r['mid'] as String,
        round: r['round'] as String,
        honba: r['honba'] as int,
        riichiPlayerId: r['pid'] as int,
        riichiName: r['pname'] as String,
        declTile: r['tile'] as String,
        winnerName: r['wname'] as String,
        points: r['pts'] as int,
      ),
  ];

  /// 見逃しからのロン和了の一覧。新しい試合日順。
  ///
  /// DB の聴牌者の行は「そのイベントの後の状態」なので、見逃した打牌そのものの行では
  /// まだロンできる(フラグ 0)。同巡内フリテンのフラグは**次の他家の打牌の行**で立つ。
  /// そのため「フラグが最初に立った行」から1つ戻り、それより前で待ち牌に含まれる他家の
  /// 最後の打牌を見逃した牌とする(2026-10-02 ユーザー指摘: 2022-03-10 の勝又健志の
  /// 見逃しが「魚谷の9p」ではなく「松本の2p」であること。失敗談に記録)。
  @override
  List<MissedRonAgari> missedRonAgaris() => [
    for (final r in _db.select(
      'WITH flagged AS ('
      '  SELECT e.kyoku_id, ts.player_id, MIN(e.event_order) AS first_eo '
      '  FROM player_tenpai_state ts JOIN event e ON e.id = ts.event_id '
      '  WHERE ts.${DbSchema.tenpaiTemporaryFuriten} = 1 AND ts.${DbSchema.tenpaiIsActor} = 0 '
      '  GROUP BY e.kyoku_id, ts.player_id), '
      'miss AS ('
      '  SELECT f.kyoku_id, f.player_id, f.first_eo, ('
      '    SELECT x.id FROM event x JOIN discard_event xd ON xd.event_id = x.id '
      '    JOIN player_tenpai_state xt ON xt.event_id = x.id AND xt.player_id = f.player_id '
      '    WHERE x.kyoku_id = f.kyoku_id AND x.event_order < f.first_eo '
      '      AND xd.actor_player_id <> f.player_id '
      "      AND (',' || xt.${DbSchema.tenpaiWaitingTiles} || ',') "
      "        LIKE ('%,' || REPLACE(xd.tile, '0', '5') || ',%') "
      '    ORDER BY x.event_order DESC LIMIT 1) AS miss_event_id '
      '  FROM flagged f) '
      'SELECT g.id AS gid, k.id AS kid, g.date, g.${DbSchema.gameDayNumber} AS mn, '
      'g.m_league_game_id AS mid, k.round, k.honba_count AS honba, '
      'm.player_id AS wid, pw.name AS wname, '
      "COALESCE(md.tile, '') AS mtile, COALESCE(pm.name, '') AS mfrom, "
      "a.${DbSchema.agariTile} AS rtile, COALESCE(pl.name, '') AS lname, "
      'a.${DbSchema.agariRevenue} AS pts '
      'FROM miss m '
      "JOIN event er ON er.kyoku_id = m.kyoku_id AND er.type = 'ron' "
      '  AND er.event_order > m.first_eo '
      'JOIN agari_event a ON a.event_id = er.id AND a.actor_player_id = m.player_id '
      'LEFT JOIN discard_event md ON md.event_id = m.miss_event_id '
      'LEFT JOIN player pm ON pm.id = md.actor_player_id '
      'JOIN kyoku k ON k.id = m.kyoku_id JOIN game g ON g.id = k.game_id '
      'JOIN player pw ON pw.id = m.player_id '
      'LEFT JOIN player pl ON pl.id = a.target_player_id '
      'ORDER BY g.date DESC, g.${DbSchema.gameDayNumber} DESC, er.event_order',
    ))
      MissedRonAgari(
        gameId: r['gid'] as int,
        kyokuId: r['kid'] as int,
        date: r['date'] as String,
        matchNumber: r['mn'] as int,
        mLeagueGameId: r['mid'] as String,
        round: r['round'] as String,
        honba: r['honba'] as int,
        winnerId: r['wid'] as int,
        winnerName: r['wname'] as String,
        missedTile: r['mtile'] as String,
        missedFromName: r['mfrom'] as String,
        ronTile: r['rtile'] as String,
        loserName: r['lname'] as String,
        points: r['pts'] as int,
      ),
  ];

  /// 全員集合からの決着の一覧。新しい試合日順。
  ///
  /// 南4局で試合の最後の局(同じ試合でそれより後の局が無い)のうち、直前の局の終了時点数
  /// (`kyoku_player_result.score`。最終局の値は `game_player_result.score` と全件一致 [実])が
  /// 4人とも 20,000 以上 30,000 未満のもの。
  @override
  List<ZeninShugoFinal> zeninShugoFinals() {
    final rows = _db.select(
      'SELECT g.id AS gid, k.id AS kid, g.date, g.${DbSchema.gameDayNumber} AS mn, '
      'g.m_league_game_id AS mid, k.round, k.honba_count AS honba, '
      '(SELECT MAX(k2.id) FROM kyoku k2 WHERE k2.game_id = k.game_id AND k2.id < k.id) AS prev_id, '
      "COALESCE(ea.type, '') AS rtype, COALESCE(a.actor_player_id, 0) AS aid, "
      "COALESCE(pa.name, '') AS aname, COALESCE(a.${DbSchema.agariRevenue}, 0) AS pts, "
      'gr.player_id AS top_id, pt.name AS top_name '
      'FROM kyoku k JOIN game g ON g.id = k.game_id '
      'JOIN game_player_result gr ON gr.game_id = g.id AND gr.rank = 1 '
      'JOIN player pt ON pt.id = gr.player_id '
      'LEFT JOIN event ea ON ea.id = ('
      '  SELECT y.id FROM event y JOIN agari_event aa ON aa.event_id = y.id '
      '  WHERE y.kyoku_id = k.id LIMIT 1) '
      'LEFT JOIN agari_event a ON a.event_id = ea.id '
      'LEFT JOIN player pa ON pa.id = a.actor_player_id '
      "WHERE k.round = '2z4' "
      '  AND k.id = (SELECT MAX(k3.id) FROM kyoku k3 WHERE k3.game_id = k.game_id) '
      '  AND prev_id IS NOT NULL '
      '  AND NOT EXISTS (SELECT 1 FROM kyoku_player_result r WHERE r.kyoku_id = prev_id '
      '    AND (r.score < 20000 OR r.score >= 30000)) '
      'ORDER BY g.date DESC, g.${DbSchema.gameDayNumber} DESC',
    );
    return [
      for (final r in rows)
        ZeninShugoFinal(
          gameId: r['gid'] as int,
          kyokuId: r['kid'] as int,
          date: r['date'] as String,
          matchNumber: r['mn'] as int,
          mLeagueGameId: r['mid'] as String,
          round: r['round'] as String,
          honba: r['honba'] as int,
          startScores: [
            for (final s in _db.select(
              'SELECT p.name, r.score FROM kyoku_player_result r '
              'JOIN player p ON p.id = r.player_id '
              'WHERE r.kyoku_id = ? ORDER BY r.player_wind',
              [r['prev_id'] as int],
            ))
              (name: s['name'] as String, score: s['score'] as int),
          ],
          agariName: (r['aname'] as String?) ?? '',
          isTsumo: r['rtype'] == 'tsumo',
          points: (r['pts'] as int?) ?? 0,
          agariPlayerId: (r['aid'] as int) == 0 ? null : r['aid'] as int,
          topPlayerId: r['top_id'] as int,
          winnerName: r['top_name'] as String,
        ),
    ];
  }

  /// 天和・地和チャンス(配牌テンパイ)の一覧。新しい試合日順。
  /// 第一打はその人のその局の最初の打牌、結果はその人自身の和了のみ。
  @override
  List<HaipaiTenpai> haipaiTenpais() => [
    for (final r in _db.select(
      'SELECT g.id AS gid, k.id AS kid, g.date, g.${DbSchema.gameDayNumber} AS mn, '
      'g.m_league_game_id AS mid, k.round, k.honba_count AS honba, '
      'h.${DbSchema.haipaiActor} AS pid, p.name AS pname, h.hand, '
      '(k.${DbSchema.kyokuOya} = h.${DbSchema.haipaiActor}) AS dealer, '
      "COALESCE(d.tile, '') AS ftile, COALESCE(d.is_tsumogiri, 0) AS fts, "
      'COALESCE(d.is_reach_declaration, 0) AS frd, '
      "COALESCE(ya.type, '') AS wtype, COALESCE(a.${DbSchema.agariRevenue}, 0) AS pts "
      'FROM haipai_event h JOIN event e ON e.id = h.event_id '
      'JOIN kyoku k ON k.id = e.kyoku_id JOIN game g ON g.id = k.game_id '
      'JOIN player p ON p.id = h.${DbSchema.haipaiActor} '
      'LEFT JOIN discard_event d ON d.event_id = ('
      '  SELECT x.id FROM event x JOIN discard_event dd ON dd.event_id = x.id '
      '  WHERE x.kyoku_id = k.id AND dd.actor_player_id = h.${DbSchema.haipaiActor} '
      '  ORDER BY x.event_order LIMIT 1) '
      'LEFT JOIN event ya ON ya.id = ('
      '  SELECT y.id FROM event y JOIN agari_event aa ON aa.event_id = y.id '
      '  WHERE y.kyoku_id = k.id AND aa.actor_player_id = h.${DbSchema.haipaiActor} LIMIT 1) '
      'LEFT JOIN agari_event a ON a.event_id = ya.id '
      'WHERE h.${DbSchema.haipaiTenho} = 1 OR h.${DbSchema.haipaiChiho} = 1 '
      'ORDER BY g.date DESC, g.${DbSchema.gameDayNumber} DESC, e.event_order',
    ))
      HaipaiTenpai(
        gameId: r['gid'] as int,
        kyokuId: r['kid'] as int,
        date: r['date'] as String,
        matchNumber: r['mn'] as int,
        mLeagueGameId: r['mid'] as String,
        round: r['round'] as String,
        honba: r['honba'] as int,
        playerId: r['pid'] as int,
        name: r['pname'] as String,
        isDealer: (r['dealer'] as int) == 1,
        hand: r['hand'] as String,
        firstTile: r['ftile'] as String,
        firstTsumogiri: (r['fts'] as int) == 1,
        firstReach: (r['frd'] as int) == 1,
        winType: r['wtype'] as String,
        points: r['pts'] as int,
      ),
  ];

  /// 種類別のアガリ検索(新しい試合日順)。
  /// 役満= is_yakuman、三倍満= 役満以外で11翻以上(Mリーグは数え役満なし・
  /// 三倍満が上限)、一発= 役に「一発」を含む。
  /// [seasonId] を指定するとそのシーズンだけに絞る。
  String _agariWhere(AgariSearchKind kind) => switch (kind) {
    AgariSearchKind.yakuman => 'a.is_yakuman = 1',
    AgariSearchKind.sanbaiman => 'a.is_yakuman = 0 AND a.han >= 11',
    AgariSearchKind.baiman => 'a.is_yakuman = 0 AND a.han BETWEEN 8 AND 10',
    AgariSearchKind.ippatsu =>
      'EXISTS (SELECT 1 FROM ${DbSchema.agariYaku} y JOIN yaku_name n '
          "ON n.id = y.${DbSchema.agariYakuNameId} WHERE y.agari_event_id = a.event_id AND n.name = '一発')",
    AgariSearchKind.dora7 =>
      '(SELECT COALESCE(SUM(y.han), 0) FROM ${DbSchema.agariYaku} y JOIN yaku_name n '
          'ON n.id = y.${DbSchema.agariYakuNameId} WHERE y.agari_event_id = a.event_id '
          "AND n.name IN ('ドラ', '赤ドラ', '裏ドラ')) >= 7",
    AgariSearchKind.ura3 =>
      'EXISTS (SELECT 1 FROM ${DbSchema.agariYaku} y JOIN yaku_name n '
          "ON n.id = y.${DbSchema.agariYakuNameId} WHERE y.agari_event_id = a.event_id AND n.name = '裏ドラ' AND y.han >= 3)",
    // 裸単騎: 和了者がその局に4つ鳴いている(ポン・チー・大明槓・暗槓。加槓はポンの
    // 昇格なので数えない)。4副露なら残りの手牌は1枚で、待ちは必ず単騎。
    // 「局×選手ごとの鳴き数」を非相関のサブクエリで一度だけ集計し、行値の IN で突き合わせる
    // (和了ごとの相関サブクエリにすると全和了×全鳴きの走査になり、実DBで数十秒以上掛かった)。
    // 結合順は CROSS JOIN で「鳴き(約13万行)を外側、event は主キー引き」に固定する。
    // 任せると event 全件(約160万行)を走査する計画になり 0.9 秒掛かった(固定後 0.05 秒)
    AgariSearchKind.hadakaTanki =>
      '(e.kyoku_id, a.actor_player_id) IN ('
          'SELECT x.kyoku_id, m.actor_player_id FROM ('
          'SELECT event_id, actor_player_id FROM pon_event UNION ALL '
          'SELECT event_id, actor_player_id FROM chi_event UNION ALL '
          'SELECT event_id, actor_player_id FROM daiminkan_event UNION ALL '
          'SELECT event_id, actor_player_id FROM ankan_event) m '
          'CROSS JOIN event x ON x.id = m.event_id '
          'GROUP BY x.kyoku_id, m.actor_player_id HAVING COUNT(*) = 4)',
    // 地獄単騎: 宣言時にリーチ者から見える待ち牌の残りが 1(場に2枚見えている)。
    // 河・ドラ表示・自分の手牌に加えて**他家の副露に含まれる枚数も数える**ため、
    // Dart 側で集計した (局, 選手) の集合を行値の IN で渡す([hellTankiRiichiPairs])
    AgariSearchKind.hellTanki => _pairsClause(hellTankiRiichiPairs()),
  };

  /// (e.kyoku_id, a.actor_player_id) が [pairs] のいずれかに一致する WHERE 句
  static String _pairsClause(Set<(int, int)> pairs) => pairs.isEmpty
      ? '0 = 1'
      : '(e.kyoku_id, a.actor_player_id) IN (VALUES '
            '${pairs.map((p) => '(${p.$1}, ${p.$2})').join(', ')})';

  Set<(int, int)>? _hellTankiCache;

  /// 地獄単騎リーチの (局ID, 選手ID)。リーチ宣言打牌の時点で本人の待ちが単騎で、
  /// **リーチ者から見えている**待ち牌の残りが 1 枚(場に 2 枚見えている)。
  /// 見える残り = 4 − 自分の手牌 − 全員の河 − ドラ表示牌(以上は tenpai_agari_matrix の
  /// ideal/discarded/dora_indicator)− **他家の副露に含まれる枚数**(鳴きイベントの block を
  /// [parseBlockTiles] で数える。副露も場に見えている牌なので必ず数える。ユーザー方針 2026-10-03:
  /// 完全に判定できないなら機能ごと諦める。性能のために省かない)。
  /// available_tile_count は山に残る真の枚数(他家の手の中まで差し引いた神視点)なので使わない。
  /// 一度計算したら保持する(実DBで 0.3 秒程度)。
  @override
  Set<(int, int)> hellTankiRiichiPairs() {
    final cached = _hellTankiCache;
    if (cached != null) return cached;
    // 単騎待ちのリーチ宣言: 局・順・選手・待ち牌・見える残りの基礎(副露を引く前)
    final decls = _db.select(
      'SELECT ev.kyoku_id AS kid, ev.event_order AS eo, d.actor_player_id AS pid, '
      'ts.${DbSchema.tenpaiWaitingTiles} AS wait, '
      '(SELECT MIN(mx.${DbSchema.matrixIdeal} - mx.${DbSchema.matrixDiscarded} '
      '  - mx.${DbSchema.matrixDoraIndicator}) FROM tenpai_agari_matrix mx '
      '  WHERE mx.event_id = ev.id AND mx.player_id = d.actor_player_id) AS base '
      'FROM event ev JOIN discard_event d ON d.event_id = ev.id '
      'JOIN player_tenpai_state ts ON ts.event_id = ev.id '
      '  AND ts.player_id = d.actor_player_id AND ts.${DbSchema.tenpaiIsActor} = 1 '
      "WHERE d.is_reach_declaration = 1 AND ts.${DbSchema.tenpaiWaitingType} = '単騎'",
    );
    if (decls.isEmpty) return _hellTankiCache = const {};
    // それらの局の鳴き(全員分。宣言より前で他家のものだけを後で使う)
    final kyokuIds = decls.map((r) => r['kid'] as int).toSet();
    final meldsByKyoku = <int, List<Row>>{};
    for (final r in _db.select(
      'SELECT e.kyoku_id AS kid, e.event_order AS eo, m.actor_player_id AS pid, '
      'm.kind, m.block FROM event e JOIN ('
      "SELECT event_id, actor_player_id, 'pon' AS kind, block FROM pon_event UNION ALL "
      "SELECT event_id, actor_player_id, 'chi', block FROM chi_event UNION ALL "
      "SELECT event_id, actor_player_id, 'daiminkan', block FROM daiminkan_event UNION ALL "
      "SELECT event_id, actor_player_id, 'ankan', block FROM ankan_event UNION ALL "
      "SELECT event_id, actor_player_id, 'shominkan', block FROM shominkan_event"
      ') m ON m.event_id = e.id '
      'WHERE e.kyoku_id IN (${List.filled(kyokuIds.length, '?').join(',')})',
      kyokuIds.toList(),
    )) {
      (meldsByKyoku[r['kid'] as int] ??= []).add(r);
    }
    final out = <(int, int)>{};
    for (final d in decls) {
      final base = d['base'] as int?;
      if (base == null) continue;
      final kid = d['kid'] as int;
      final pid = d['pid'] as int;
      final eo = d['eo'] as int;
      final waitTiles = Tile.parse(d['wait'] as String);
      if (waitTiles.length != 1) continue; // 単騎なので1種
      final wait = Tile.normalize(waitTiles.single);
      var inMelds = 0;
      for (final m in meldsByKyoku[kid] ?? const <Row>[]) {
        if (m['pid'] == pid || (m['eo'] as int) >= eo) continue;
        inMelds += _meldTilesOfKind(
          m['kind'] as String,
          m['block'] as String,
          wait,
        );
      }
      if (base - inMelds == 1) out.add((kid, pid));
    }
    return _hellTankiCache = out;
  }

  /// 副露1つに含まれる牌種 [kind] の枚数。暗槓の block は伏せ2枚を省いて書かれる
  /// (`_7z7z_`)ので4枚と数え、加槓はポン(3枚)が別に記録済みなので加えた1枚だけ数える。
  static int _meldTilesOfKind(String meldKind, String block, int kind) {
    final tiles = parseBlockTiles(block);
    if (tiles.isEmpty) return 0;
    final same = Tile.normalize(tiles.first) == kind;
    return switch (meldKind) {
      'ankan' => same ? 4 : 0,
      'shominkan' => same ? 1 : 0,
      _ => tiles.where((t) => Tile.normalize(t) == kind).length,
    };
  }

  /// [searchAgari] と同じ条件の件数だけを数える(一覧を組み立てないので速い)。
  @override
  int countAgari(AgariSearchKind kind, {int? seasonId}) {
    final rows = _db.select(
      'SELECT COUNT(*) AS c FROM agari_event a JOIN event e ON e.id = a.event_id '
      '${seasonId == null ? '' : 'JOIN kyoku k ON k.id = e.kyoku_id JOIN game g ON g.id = k.game_id JOIN season_stage ss ON ss.id = g.season_stage_id '}'
      'WHERE ${_agariWhere(kind)} '
      '${seasonId == null ? '' : 'AND ss.league_season_id = ? '}',
      [?seasonId],
    );
    return rows.first['c'] as int;
  }

  @override
  List<FoundAgari> searchAgari(AgariSearchKind kind, {int? seasonId}) {
    final where = _agariWhere(kind);
    // 1行=1役で取り、アガリごとにまとめる(役の並びは Dart 側の純粋関数で整える)
    final rows = _db.select(
      'SELECT a.event_id AS eid, g.id AS gid, k.id AS kid, g.date, '
      'g.${DbSchema.gameDayNumber} AS mn, g.m_league_game_id AS mid, k.round, '
      'k.honba_count AS honba, a.actor_player_id AS wid, p.name AS wname, '
      "COALESCE(pl.name, '') AS lname, a.${DbSchema.agariRevenue} AS points, a.han, a.fu, "
      'a.is_yakuman AS yakuman, e.type AS etype, '
      'n.name AS yname, y.han AS yhan '
      'FROM agari_event a JOIN event e ON e.id = a.event_id '
      'JOIN kyoku k ON k.id = e.kyoku_id JOIN game g ON g.id = k.game_id '
      'JOIN player p ON p.id = a.actor_player_id '
      'LEFT JOIN player pl ON pl.id = a.target_player_id '
      'JOIN season_stage ss ON ss.id = g.season_stage_id '
      'LEFT JOIN ${DbSchema.agariYaku} y ON y.agari_event_id = a.event_id '
      'LEFT JOIN yaku_name n ON n.id = y.${DbSchema.agariYakuNameId} '
      'WHERE $where '
      '${seasonId == null ? '' : 'AND ss.league_season_id = ? '}'
      'ORDER BY g.date DESC, g.${DbSchema.gameDayNumber} DESC, e.event_order, y.rowid',
      [?seasonId],
    );
    final result = <FoundAgari>[];
    final yakuOf = <int, List<YakuItem>>{};
    for (final r in rows) {
      final eid = r['eid'] as int;
      if (!yakuOf.containsKey(eid)) {
        yakuOf[eid] = [];
        result.add(
          FoundAgari(
            gameId: r['gid'] as int,
            kyokuId: r['kid'] as int,
            date: r['date'] as String,
            matchNumber: r['mn'] as int,
            mLeagueGameId: r['mid'] as String,
            round: r['round'] as String,
            honba: r['honba'] as int,
            winnerId: r['wid'] as int,
            winnerName: r['wname'] as String,
            loserName: r['lname'] as String,
            points: r['points'] as int,
            han: r['han'] as int,
            fu: r['fu'] as int,
            isTsumo: r['etype'] == 'tsumo',
            isYakuman: (r['yakuman'] as int) == 1,
            yakuItems: yakuOf[eid]!,
          ),
        );
      }
      if (r['yname'] != null) {
        yakuOf[eid]!.add(YakuItem(r['yname'] as String, r['yhan'] as int));
      }
    }
    return result;
  }

  /// 試合IDから試合情報を引く(読みクイズの出典表示用)
  @override
  PaifuGame? gameById(int gameId) {
    final rows = _db.select(
      'SELECT id, date, ${DbSchema.gameDayNumber}, m_league_game_id FROM game '
      'WHERE id = ?',
      [gameId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return PaifuGame(
      id: r['id'] as int,
      date: r['date'] as String,
      matchNumber: r[DbSchema.gameDayNumber] as int,
      mLeagueGameId: r['m_league_game_id'] as String,
    );
  }

  /// その試合日に複数卓(A/B)があるか。出典表示に卓名を含める要否の判定用
  /// (卓名は m_league_game_id の末尾文字。[PaifuGame.tableLetter] と同じ規則)
  /// 2卓開催の日付の集合(一覧で行ごとに問い合わせないための一括版)
  @override
  Set<String> multiTableDates() => {
    for (final r in _db.select(
      'SELECT date FROM game GROUP BY date '
      'HAVING COUNT(DISTINCT substr(m_league_game_id, -1)) > 1',
    ))
      r['date'] as String,
  };

  @override
  bool hasMultipleTables(String date) {
    final r = _db.select(
      'SELECT COUNT(DISTINCT substr(m_league_game_id, -1)) AS c '
      'FROM game WHERE date = ?',
      [date],
    );
    return ((r.first['c'] as int?) ?? 0) > 1;
  }

  /// 公式試合ID(m_league_game_id)の集合がどこ(シーズン/ステージ/日付)の
  /// 試合かを引く。お気に入り局の★マーク表示に使う。
  @override
  List<({String mid, int seasonId, int stageId, String date})> locateGames(
    Set<String> mLeagueGameIds,
  ) {
    if (mLeagueGameIds.isEmpty) return const [];
    final ids = mLeagueGameIds.toList();
    final marks = List.filled(ids.length, '?').join(',');
    return [
      for (final r in _db.select(
        'SELECT g.m_league_game_id AS mid, g.date, '
        'g.season_stage_id AS sid, ss.league_season_id AS lid '
        'FROM game g JOIN season_stage ss ON ss.id = g.season_stage_id '
        'WHERE g.m_league_game_id IN ($marks)',
        ids,
      ))
        (
          mid: r['mid'] as String,
          seasonId: r['lid'] as int,
          stageId: r['sid'] as int,
          date: r['date'] as String,
        ),
    ];
  }

  /// 試合のスタッツ集計(playerId → 回数)。[beforeKyokuId] を渡すとその局より
  /// 前までの集計になる(局シークで戻ってもスタッツが二重加算されないように、
  /// 再生側は局の頭ごとにこれで数え直す)。
  @override
  ({Map<int, int> wins, Map<int, int> riichis, Map<int, int> dealIns})
  statCounts(int gameId, {int? beforeKyokuId}) {
    final cond = beforeKyokuId == null ? '' : ' AND k.id < $beforeKyokuId';
    Map<int, int> count(String sql) => {
      for (final r in _db.select(sql, [gameId])) r['pid'] as int: r['c'] as int,
    };
    return (
      wins: count(
        'SELECT a.actor_player_id AS pid, COUNT(*) AS c FROM agari_event a '
        'JOIN event e ON e.id = a.event_id '
        'JOIN kyoku k ON k.id = e.kyoku_id '
        'WHERE k.game_id = ?$cond GROUP BY 1',
      ),
      riichis: count(
        'SELECT r.actor_player_id AS pid, COUNT(*) AS c FROM reach_event r '
        'JOIN event e ON e.id = r.event_id '
        'JOIN kyoku k ON k.id = e.kyoku_id '
        'WHERE k.game_id = ?$cond AND r.is_accepted = 1 GROUP BY 1',
      ),
      dealIns: count(
        'SELECT a.target_player_id AS pid, COUNT(*) AS c FROM agari_event a '
        'JOIN event e ON e.id = a.event_id '
        'JOIN kyoku k ON k.id = e.kyoku_id '
        'WHERE k.game_id = ?$cond AND a.target_player_id IS NOT NULL '
        'GROUP BY 1',
      ),
    );
  }

  /// 局の全イベントを発生順で返す
  @override
  List<PaifuEvent> kyokuEvents(int kyokuId) {
    Map<int, Row> byEventId(String table) => {
      for (final r in _db.select(
        'SELECT d.*, e.id AS eid FROM $table d '
        'JOIN event e ON e.id = d.event_id WHERE e.kyoku_id = ?',
        [kyokuId],
      ))
        r['eid'] as int: r,
    };

    final haipai = byEventId('haipai_event');
    final draw = byEventId('draw_event');
    final discard = byEventId('discard_event');
    final reach = byEventId('reach_event');
    final pon = byEventId('pon_event');
    final chi = byEventId('chi_event');
    final ankan = byEventId('ankan_event');
    final daiminkan = byEventId('daiminkan_event');
    final shominkan = byEventId('shominkan_event');
    final dora = byEventId('dora_indicator_event');
    final agari = byEventId('agari_event');

    // アガリの役(agari_event_id = event_id)
    final yakuByEvent = <int, List<YakuItem>>{};
    for (final r in _db.select(
      'SELECT y.agari_event_id AS eid, n.name, y.han '
      'FROM ${DbSchema.agariYaku} y '
      'JOIN yaku_name n ON n.id = y.${DbSchema.agariYakuNameId} '
      'JOIN event e ON e.id = y.agari_event_id WHERE e.kyoku_id = ?',
      [kyokuId],
    )) {
      (yakuByEvent[r['eid'] as int] ??= []).add(
        YakuItem(r['name'] as String, r['han'] as int),
      );
    }

    // 流局時のプレイヤー情報
    final ryukyokuPlayersByEvent = <int, List<(int, bool, int)>>{};
    for (final r in _db.select(
      'SELECT rp.ryukyoku_event_id AS eid, rp.player_id, rp.is_tenpai, '
      'rp.${DbSchema.ryukyokuTenpaiPoints} FROM ${DbSchema.ryukyokuPlayer} rp '
      'JOIN event e ON e.id = rp.ryukyoku_event_id WHERE e.kyoku_id = ?',
      [kyokuId],
    )) {
      (ryukyokuPlayersByEvent[r['eid'] as int] ??= []).add((
        r['player_id'] as int,
        (r['is_tenpai'] as int) != 0,
        r[DbSchema.ryukyokuTenpaiPoints] as int,
      ));
    }

    bool flag(Row? r, String col) => r != null && (r[col] as int? ?? 0) != 0;

    final events = <PaifuEvent>[];
    for (final e in _db.select(
      'SELECT id, type, event_order FROM event WHERE kyoku_id = ? '
      'ORDER BY event_order',
      [kyokuId],
    )) {
      final id = e['id'] as int;
      final type = e['type'] as String;
      final order = e['event_order'] as int;
      switch (type) {
        case 'haipai':
          final r = haipai[id]!;
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              actorPlayerId: r[DbSchema.haipaiActor] as int,
              hand: r['hand'] as String,
            ),
          );
        case 'draw':
          final r = draw[id]!;
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              actorPlayerId: r['actor_player_id'] as int,
              tile: r['tile'] as String,
              rinshan: flag(r, 'is_rinshan'),
            ),
          );
        case 'discard':
          final r = discard[id]!;
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              actorPlayerId: r['actor_player_id'] as int,
              tile: r['tile'] as String,
              reachDeclaration: flag(r, 'is_reach_declaration'),
              tsumogiri: flag(r, 'is_tsumogiri'),
            ),
          );
        case 'reach':
          final r = reach[id]!;
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              actorPlayerId: r['actor_player_id'] as int,
              reachAccepted: flag(r, 'is_accepted'),
            ),
          );
        case 'pon' || 'chi' || 'daiminkan':
          final r = switch (type) {
            'pon' => pon[id]!,
            'chi' => chi[id]!,
            _ => daiminkan[id]!,
          };
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              actorPlayerId: r['actor_player_id'] as int,
              targetPlayerId: r['target_player_id'] as int,
              tile: r['tile'] as String,
              block: r['block'] as String,
            ),
          );
        case 'shominkan':
          final r = shominkan[id]!;
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              actorPlayerId: r['actor_player_id'] as int,
              tile: r['tile'] as String,
              block: r['block'] as String,
            ),
          );
        case 'ankan':
          final r = ankan[id]!;
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              actorPlayerId: r['actor_player_id'] as int,
              block: r['block'] as String,
            ),
          );
        case 'dora_indicator':
          final r = dora[id]!;
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              doraType: r[DbSchema.doraType] as String,
              doraIndicator: r[DbSchema.doraIndicatorTile] as String,
            ),
          );
        case 'ron' || 'tsumo':
          final r = agari[id]!;
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              actorPlayerId: r['actor_player_id'] as int,
              targetPlayerId: r['target_player_id'] as int?,
              points: r[DbSchema.agariRevenue] as int,
              winningTile: r[DbSchema.agariTile] as String,
              fu: r['fu'] as int,
              han: r['han'] as int,
              isYakuman: flag(r, 'is_yakuman'),
              description: r['description'] as String?,
              yaku: yakuByEvent[id] ?? const [],
            ),
          );
        case 'ryukyoku':
          events.add(
            PaifuEvent(
              type: type,
              order: order,
              ryukyokuPlayers: ryukyokuPlayersByEvent[id] ?? const [],
            ),
          );
      }
    }
    return events;
  }
}
