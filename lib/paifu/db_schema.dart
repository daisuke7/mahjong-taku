/// Mリーグ牌譜DB(konoui/m-league-game-db)のスキーマ対応表。
///
/// 配布元はシーズン中でもテーブル名・列名を改名する(2026-10-01 リリースで3テーブル・
/// 十数列が一斉に改名された。配布元 DB_CHANGELOG.md に改名表あり)。改名のたびに SQL を
/// 探し回らないよう、**改名され得る識別子はここの定数だけに書き、SQL はこれを参照する**。
/// 配布元の改名への追従は原則このファイルの書き換えだけで済ませる。それで済まない変更
/// (列の意味や分割が変わる等)が来たときに初めて読み出しコード側を直す。
///
/// 併せて、アプリが読むテーブルと列の一覧 [required] を持ち、取り込み時の検査
/// ([schemaProblems])と `check-paifu-db-schema` スキルの検査がこれを使う。
library;

import 'package:sqlite3/sqlite3.dart';

abstract final class DbSchema {
  // ---- テーブル名(改名されたもの)。コメントは旧名 ----
  static const agariYaku = 'agari_yaku'; // 旧 agari_yaku_event
  static const ryukyokuPlayer = 'ryukyoku_player'; // 旧 ryukyoku_player_event

  // ---- 列名(改名されたもの)。コメントは旧名 ----
  static const gameDayNumber = 'day_game_number'; // 旧 game.match_number
  static const kyokuOya = 'oya_player_id'; // 旧 kyoku.parent_player_id
  static const kyokuKyotaku = 'kyotaku_count'; // 旧 kyoku.reach_stick_count
  static const resultLeaguePoints =
      'league_points'; // 旧 game_player_result.points
  static const agariRevenue = 'revenue_points'; // 旧 agari_event.points(総取得点)
  static const agariTile = 'agari_tile'; // 旧 agari_event.winning_tile
  static const agariYakuNameId = 'yaku_name_id'; // 旧 agari_yaku_event.name_id
  static const haipaiActor = 'actor_player_id'; // 旧 haipai_event.player_id
  static const haipaiTenho = 'is_tenho_possible'; // 旧 tenho_possible
  static const haipaiChiho = 'is_chiho_possible'; // 旧 chiho_possible
  static const doraType = 'dora_type'; // 旧 dora_indicator_event.type
  static const doraIndicatorTile = 'dora_indicator_tile'; // 旧 dora_indicator
  static const ryukyokuTenpaiPoints =
      'tenpai_points'; // 旧 ryukyoku_player_event.points

  // ---- 2026-10-01 リリースで追加された列(他家の打牌時点の聴牌者の状態) ----
  static const tenpaiIsActor = 'is_actor';
  static const tenpaiTemporaryFuriten = 'is_temporary_furiten';
  static const tenpaiWaitingTiles = 'waiting_tiles'; // ',' 区切り
  static const tenpaiWaitingType = 'waiting_type'; // 両面/カンチャン/…/単騎 等8種
  // tenpai_agari_matrix の枚数。available は山に残る真の枚数(他家の手の中を除く=神視点)、
  // 本人から見える残りは ideal - discarded - dora_indicator
  static const matrixIdeal = 'ideal_tile_count';
  static const matrixDiscarded = 'discarded_tile_count';
  static const matrixDoraIndicator = 'dora_indicator_tile_count';

  /// アプリの SQL が参照するテーブルと列。取り込んだ DB にこれが全部あれば読める。
  /// 列を新しく参照したらここにも足す(スキルの検査が SQL と突き合わせる)。
  static const required = <String, List<String>>{
    'league_season': ['id', 'start_year', 'end_year'],
    'season_stage': ['id', 'league_season_id', 'stage'],
    'game': [
      'id',
      'season_stage_id',
      'date',
      gameDayNumber,
      'm_league_game_id',
    ],
    'kyoku': ['id', 'game_id', 'round', 'honba_count', kyokuKyotaku, kyokuOya],
    'kyoku_player_result': ['kyoku_id', 'player_id', 'score', 'player_wind'],
    'game_player_result': [
      'game_id',
      'player_id',
      'score',
      resultLeaguePoints,
      'rank',
    ],
    'player': ['id', 'name'],
    'event': ['id', 'kyoku_id', 'type', 'event_order'],
    'haipai_event': ['event_id', haipaiActor, 'hand', haipaiTenho, haipaiChiho],
    'draw_event': ['event_id', 'actor_player_id', 'tile', 'is_rinshan'],
    'discard_event': [
      'event_id',
      'actor_player_id',
      'tile',
      'is_reach_declaration',
      'is_tsumogiri',
    ],
    'reach_event': ['event_id', 'actor_player_id', 'is_accepted'],
    'pon_event': [
      'event_id',
      'actor_player_id',
      'target_player_id',
      'tile',
      'block',
    ],
    'chi_event': [
      'event_id',
      'actor_player_id',
      'target_player_id',
      'tile',
      'block',
    ],
    'daiminkan_event': [
      'event_id',
      'actor_player_id',
      'target_player_id',
      'tile',
      'block',
    ],
    'ankan_event': ['event_id', 'actor_player_id', 'block'],
    'shominkan_event': ['event_id', 'actor_player_id', 'tile', 'block'],
    'dora_indicator_event': ['event_id', doraType, doraIndicatorTile],
    'agari_event': [
      'event_id',
      'actor_player_id',
      'target_player_id',
      agariRevenue,
      agariTile,
      'fu',
      'han',
      'is_yakuman',
      'description',
    ],
    agariYaku: ['agari_event_id', agariYakuNameId, 'han'],
    'yaku_name': ['id', 'name'],
    'ryukyoku_event': ['event_id'],
    ryukyokuPlayer: [
      'ryukyoku_event_id',
      'player_id',
      'is_tenpai',
      ryukyokuTenpaiPoints,
    ],
    'player_tenpai_state': [
      'event_id',
      'player_id',
      tenpaiIsActor,
      tenpaiTemporaryFuriten,
      tenpaiWaitingTiles,
      tenpaiWaitingType,
    ],
    'tenpai_agari_matrix': [
      'event_id',
      'player_id',
      matrixIdeal,
      matrixDiscarded,
      matrixDoraIndicator,
    ],
  };
}

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

/// 取り込もうとした DB がこのアプリの対応外(テーブル・列が足りない)
class PaifuSchemaUnsupported implements Exception {
  /// 取り込もうとしたリリースのタグ(不明なら null)
  final String? tag;
  final List<String> problems;

  const PaifuSchemaUnsupported(this.tag, this.problems);

  @override
  String toString() =>
      'この牌譜バージョン${tag == null ? '' : '($tag)'}にはまだ対応していません。'
      '今の牌譜はそのまま使えます(足りないもの: ${problems.take(3).join(', ')}'
      '${problems.length > 3 ? ' 他${problems.length - 3}件' : ''})';
}
