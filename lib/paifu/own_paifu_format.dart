/// 自分の牌譜 JSON(対戦の保存・手動記録)の形式の版と、版の繰り上げ(マイグレーション)。
///
/// 方針(ユーザー決定 2026-10-02):
/// - JSON のキー名はアプリ内部の名前で固定し、配布元 DB の改名に**追従しない**。
///   DB と内部名の対応は [internalToDbKey] の変換表に持ち、DB 側が改名されたら表だけ直す。
/// - 内部の形式そのものを変えざるを得ないときは [ownPaifuFormatVersion] を上げ、
///   [migrateOwnPaifu] に「旧版 → 新版」の変換を1段足す。保存済みファイルは読み込み時に
///   その場で繰り上げる(ファイルは書き戻さない。次に保存されたときに新版になる)。
library;

/// 現在の形式の版。`format` キーに保存する。無い(旧ファイル)は版 0 とみなす。
const ownPaifuFormatVersion = 1;

/// 内部キー → 配布元 DB の列名(2026-10-01 リリース以降)。DB 一本化のときの変換表。
/// 「内部名は旧 DB の列名」なので、改名前は恒等写像だった。
const internalToDbKey = <String, String>{
  // kyoku
  'reach_stick_count': 'kyotaku_count',
  'parent_player_id': 'oya_player_id',
  // haipai
  'player_id': 'actor_player_id',
  // dora_indicator
  'dora_type': 'dora_type',
  'dora_indicator': 'dora_indicator_tile',
  // agari
  'points': 'revenue_points',
  'winning_tile': 'agari_tile',
  // ryukyoku players
  'tenpai_points': 'tenpai_points',
  // game_player_result
  'league_points': 'league_points',
};

/// 読み込んだ JSON を現在の版に繰り上げる(純粋関数。元の Map は変更しない)。
Map<String, dynamic> migrateOwnPaifu(Map<String, dynamic> game) {
  var g = Map<String, dynamic>.from(game);
  var v = (g['format'] as int?) ?? 0;
  while (v < ownPaifuFormatVersion) {
    g = switch (v) {
      // 版0(format キー無し)→ 版1: キーは変えない。版の明示だけ
      0 => {...g, 'format': 1},
      _ => throw StateError('自分牌譜の版 $v からの繰り上げが定義されていない'),
    };
    v = g['format'] as int;
  }
  return g;
}

/// 保存するときに版を付ける
Map<String, dynamic> stampOwnPaifuFormat(Map<String, dynamic> game) => {
  ...game,
  'format': ownPaifuFormatVersion,
};
