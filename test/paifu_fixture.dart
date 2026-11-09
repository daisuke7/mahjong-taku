// 牌譜ビューア系テストで共有する、実DBと同じ形の最小フィクスチャ。
// テーブル名・列名は配布元の 2026-10-01 リリース以降のスキーマ(agari_yaku /
// ryukyoku_player / oya_player_id / day_game_number / revenue_points 等)。
// 列の並びは本物と同じでなくてよい(テストは位置指定の INSERT をこの定義に合わせている)。
// (paifu_replay_test.dart から抽出。1試合・1局: Bのリーチ・Cのポン・Aのツモ和了)
import 'package:sqlite3/sqlite3.dart';

/// 実DBと同じ形の最小フィクスチャ(1試合・1局・親のツモ和了)を作る
void buildPaifuFixture(String path) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE league_season (id INTEGER PRIMARY KEY, start_year INTEGER, end_year INTEGER);
    CREATE TABLE season_stage (id INTEGER PRIMARY KEY, league_season_id INTEGER, stage TEXT);
    CREATE TABLE player (id INTEGER PRIMARY KEY, name TEXT);
    CREATE TABLE game (id INTEGER PRIMARY KEY, season_stage_id INTEGER, date TEXT,
      day_game_number INTEGER, stage_game_number INTEGER, m_league_game_id TEXT);
    CREATE TABLE kyoku (id INTEGER PRIMARY KEY, game_id INTEGER, round TEXT,
      honba_count INTEGER, kyotaku_count INTEGER, oya_player_id INTEGER);
    CREATE TABLE kyoku_player_result (kyoku_id INTEGER, player_id INTEGER,
      score INTEGER, player_wind TEXT, rank INTEGER);
    CREATE TABLE game_player_result (game_id INTEGER, player_id INTEGER,
      score INTEGER, league_points REAL, penalty_league_points REAL, rank INTEGER);
    CREATE TABLE event (id INTEGER PRIMARY KEY, kyoku_id INTEGER, type TEXT, event_order INTEGER);
    CREATE TABLE haipai_event (event_id INTEGER, actor_player_id INTEGER, hand TEXT,
      is_tenho_possible INTEGER, is_chiho_possible INTEGER);
    CREATE TABLE draw_event (event_id INTEGER, actor_player_id INTEGER, tile TEXT, is_rinshan INTEGER);
    CREATE TABLE discard_event (event_id INTEGER, actor_player_id INTEGER, tile TEXT,
      is_reach_declaration INTEGER, is_tsumogiri INTEGER);
    CREATE TABLE reach_event (event_id INTEGER, actor_player_id INTEGER, is_accepted INTEGER);
    CREATE TABLE pon_event (event_id INTEGER, actor_player_id INTEGER, target_player_id INTEGER,
      tile TEXT, block TEXT);
    CREATE TABLE chi_event (event_id INTEGER, actor_player_id INTEGER, target_player_id INTEGER,
      tile TEXT, block TEXT);
    CREATE TABLE ankan_event (event_id INTEGER, actor_player_id INTEGER, block TEXT);
    CREATE TABLE daiminkan_event (event_id INTEGER, actor_player_id INTEGER, target_player_id INTEGER,
      tile TEXT, block TEXT);
    CREATE TABLE shominkan_event (event_id INTEGER, actor_player_id INTEGER, tile TEXT, block TEXT);
    CREATE TABLE dora_indicator_event (event_id INTEGER, dora_type TEXT, dora_indicator_tile TEXT, dora_tile TEXT);
    CREATE TABLE agari_event (event_id INTEGER, actor_player_id INTEGER, target_player_id INTEGER,
      revenue_points INTEGER, agari_points INTEGER, agari_tile TEXT, agari_waiting_type TEXT,
      fu INTEGER, han INTEGER, is_called INTEGER, is_menzen INTEGER, is_yakuman INTEGER,
      description TEXT);
    CREATE TABLE agari_yaku (agari_event_id INTEGER, yaku_name_id INTEGER, han INTEGER);
    CREATE TABLE yaku_name (id INTEGER PRIMARY KEY, name TEXT);
    CREATE TABLE ryukyoku_event (event_id INTEGER, reason TEXT);
    CREATE TABLE ryukyoku_player (ryukyoku_event_id INTEGER, player_id INTEGER,
      is_tenpai INTEGER, tenpai_points INTEGER);
    CREATE TABLE player_tenpai_state (event_id INTEGER, player_id INTEGER,
      is_actor INTEGER, is_temporary_furiten INTEGER, waiting_tiles TEXT,
      waiting_type TEXT);
    CREATE TABLE tenpai_agari_matrix (id INTEGER PRIMARY KEY, event_id INTEGER, player_id INTEGER,
      waiting_tile TEXT, ideal_tile_count INTEGER, discarded_tile_count INTEGER,
      dora_indicator_tile_count INTEGER, available_tile_count INTEGER, is_ron_agari INTEGER);
  ''');

  db.execute("INSERT INTO league_season VALUES (1, 2025, 2026)");
  db.execute("INSERT INTO season_stage VALUES (1, 1, 'regular')");
  for (final (id, name) in [(101, 'A'), (102, 'B'), (103, 'C'), (104, 'D')]) {
    db.execute('INSERT INTO player VALUES (?, ?)', [id, name]);
  }
  db.execute(
    "INSERT INTO game VALUES (1, 1, '2025-04-01', 1, 1, 'L001_S001_0001_01A')",
  );
  db.execute("INSERT INTO kyoku VALUES (1, 1, '1z1', 0, 0, 101)");
  for (final (pid, score, wind, rank) in [
    (101, 37000, '1z', 1),
    (102, 20000, '2z', 4),
    (103, 21000, '3z', 3),
    (104, 22000, '4z', 2),
  ]) {
    db.execute('INSERT INTO kyoku_player_result VALUES (1, ?, ?, ?, ?)', [
      pid,
      score,
      wind,
      rank,
    ]);
  }
  for (final (pid, score, pts, rank) in [
    (101, 37000, 57.0, 1),
    (102, 20000, -35.0, 4),
    (103, 21000, -19.0, 3),
    (104, 22000, -3.0, 2),
  ]) {
    db.execute('INSERT INTO game_player_result VALUES (1, ?, ?, ?, 0, ?)', [
      pid,
      score,
      pts,
      rank,
    ]);
  }
  db.execute("INSERT INTO yaku_name VALUES (1, 'ダブ東'), (2, 'ドラ')");

  var order = 0;
  int ev(String type) {
    order++;
    db.execute(
      'INSERT INTO event (kyoku_id, type, event_order) VALUES (1, ?, ?)',
      [type, order],
    );
    return db.lastInsertRowId;
  }

  // 牌の使用枚数・手番順・リーチの成立をエンジンと同じ基準で満たした記録
  // (ゴーストモードは実エンジンでこの記録を再現するため、矛盾があると
  //  再構成に失敗する)
  db.execute('INSERT INTO dora_indicator_event VALUES (?, ?, ?, ?)', [
    ev('dora_indicator'),
    'omote',
    '6s',
    '7s',
  ]);
  for (final (pid, hand) in [
    (101, '123m456p789s1122z'),
    (102, '23456m7899p7899s'),
    (103, '1122334m99p455s7z'),
    (104, '147m258p369s1234z'),
  ]) {
    db.execute('INSERT INTO haipai_event VALUES (?, ?, ?, 0, 0)', [
      ev('haipai'),
      pid,
      hand,
    ]);
  }
  // A: ツモ切り
  db.execute('INSERT INTO draw_event VALUES (?, 101, ?, 0)', [
    ev('draw'),
    '5z',
  ]);
  db.execute('INSERT INTO discard_event VALUES (?, 101, ?, 0, 1)', [
    ev('discard'),
    '5z',
  ]);
  // B: リーチ宣言(9筒切り、9s単騎)→ 成立
  db.execute('INSERT INTO draw_event VALUES (?, 102, ?, 0)', [
    ev('draw'),
    '7m',
  ]);
  // 実DBと同じく reach → 宣言打牌(discard) の順(2026-09-15 実DBの全リーチ 21246件で draw→reach→discard を確認)
  db.execute('INSERT INTO reach_event VALUES (?, 102, 1)', [ev('reach')]);
  db.execute('INSERT INTO discard_event VALUES (?, 102, ?, 1, 0)', [
    ev('discard'),
    '9p',
  ]);
  // C: Bの9筒をポン → 7z切り
  db.execute('INSERT INTO pon_event VALUES (?, 103, 102, ?, ?)', [
    ev('pon'),
    '9p',
    '9p9p-9p',
  ]);
  db.execute('INSERT INTO discard_event VALUES (?, 103, ?, 0, 0)', [
    ev('discard'),
    '7z',
  ]);
  // D: ツモ切り
  db.execute('INSERT INTO draw_event VALUES (?, 104, ?, 0)', [
    ev('draw'),
    '4z',
  ]);
  db.execute('INSERT INTO discard_event VALUES (?, 104, ?, 0, 1)', [
    ev('discard'),
    '4z',
  ]);
  // A: ツモ和了(2z=ダブ東)
  db.execute('INSERT INTO draw_event VALUES (?, 101, ?, 0)', [
    ev('draw'),
    '2z',
  ]);
  final agariId = ev('tsumo');
  db.execute(
    'INSERT INTO agari_event VALUES (?, 101, NULL, 12000, 8000, ?, ?, 40, 5, 0, 1, 0, ?)',
    [agariId, '2z', 'シャンポン', '40符5飜 満貫8000'],
  );
  db.execute('INSERT INTO agari_yaku VALUES (?, 1, 2)', [agariId]);
  db.execute('INSERT INTO agari_yaku VALUES (?, 2, 3)', [agariId]);

  db.dispose();
}
