/// 対局の牌譜記録(「自分の対局」保存用)。
///
/// エンジンが局の進行に合わせて、Mリーグ牌譜DB(konoui/m-league-game-db)の
/// イベントスキーマと同じ意味論のJSONイベントを組み立てるための部品。
/// 将来「手動牌譜記録 → DB一本化」する場合に機械変換できるよう、
/// フィールド名はDBカラム名、牌はDB表記('5m'/'0m'/'1z')、鳴きブロックは
/// 本家の位置規約に従う:
/// - '-' が鳴いた牌に付き、位置が鳴き元(上家=先頭 / 対面=2番目 / 下家=末尾)
/// - チーは常に上家なので鳴いた牌が先頭
/// - 暗槓は伏せ2枚を '_' で表す('_5s0s_')
/// - 加槓はポンの鳴き牌の直後に加えた牌を置き、両方に '-' を付ける
library;

import 'meld.dart';
import 'tile.dart';
import 'yaku.dart';

/// 局単位の牌譜を受け取る(実装は保存層)。ホスト側エンジンだけが呼ぶ。
abstract class PaifuRecorder {
  /// 局が終わった(結果確定・点数適用済み)。[kyoku] は1局分の完全な記録:
  /// round / honba_count / reach_stick_count / parent_player_id /
  /// start_scores / end_scores / names(いずれも席順)/ events。
  void onKyoku(Map<String, dynamic> kyoku);

  /// 試合が終わった。[results] は席順の最終結果
  /// (player_id / score / points / rank)。
  void onGameEnd(List<Map<String, dynamic>> results);
}

/// 牌リストをDBの手牌表記へ('1m2m3m' ではなく '123m' の圧縮形)。
/// 入力はソート済み前提(スーツごとに連続していれば良い)。
String tilesToDbString(List<int> tiles) {
  final buf = StringBuffer();
  String digits = '';
  String suit = '';
  for (final t in tiles) {
    final s = Tile.dbNotation(t); // '5m' / '0m' / '1z'
    if (s.substring(1) != suit && digits.isNotEmpty) {
      buf.write('$digits$suit');
      digits = '';
    }
    suit = s.substring(1);
    digits += s.substring(0, 1);
  }
  if (digits.isNotEmpty) buf.write('$digits$suit');
  return buf.toString();
}

/// 鳴いた牌を副露ブロックのどこに置くか(上家=先頭 / 対面=2番目 / 下家=末尾)。
/// [relative] は鳴き元の相対位置((target - actor + 4) % 4: 下家=1 / 対面=2 / 上家=3)、
/// [othersLength] は鳴いた牌以外の枚数。牌譜 DB 表記と卓の副露表示が共有する。
int calledTilePosition(int relative, int othersLength) => switch (relative) {
  3 => 0,
  2 => 1,
  _ => othersLength,
};

/// ポン・大明槓のブロック表記。[relative] は鳴き元の相対位置
/// ((target - actor + 4) % 4: 下家=1 / 対面=2 / 上家=3)。
String callBlock({
  required List<int> tiles,
  required int calledTile,
  required int relative,
}) {
  final others = _withoutCalled(tiles, calledTile);
  final pos = calledTilePosition(relative, others.length);
  final parts = [for (final t in others) Tile.dbNotation(t)];
  parts.insert(pos, '-${Tile.dbNotation(calledTile)}');
  return parts.join();
}

/// チーのブロック表記(鳴いた牌が先頭、残りは昇順)。
String chiBlock({required List<int> tiles, required int calledTile}) {
  final others = _withoutCalled(tiles, calledTile);
  return '-${Tile.dbNotation(calledTile)}'
      '${others.map(Tile.dbNotation).join()}';
}

/// 暗槓のブロック表記(表向きの中2枚だけを '_' で挟む)。
/// [tiles] はエンジンの面子並び(赤があれば2枚目)をそのまま使う。
String ankanBlock(List<int> tiles) =>
    '_${Tile.dbNotation(tiles[1])}${Tile.dbNotation(tiles[2])}_';

/// 加槓のブロック表記。元のポンのブロックの鳴き牌の直後に、
/// 加えた牌を '-' 付きで差し込む。
String shominkanBlock({
  required Meld meld, // type == kakan(tiles は元ポン3枚+加えた1枚)
  required int actorSeat,
}) {
  final added = meld.tiles.last;
  final ponTiles = meld.tiles.sublist(0, 3);
  final relative = (meld.fromSeat - actorSeat + 4) % 4;
  final base = callBlock(
    tiles: ponTiles,
    calledTile: meld.calledTile,
    relative: relative,
  );
  final calledStr = '-${Tile.dbNotation(meld.calledTile)}';
  final i = base.indexOf(calledStr);
  final insertAt = i + calledStr.length;
  return '${base.substring(0, insertAt)}'
      '-${Tile.dbNotation(added)}${base.substring(insertAt)}';
}

List<int> _withoutCalled(List<int> tiles, int calledTile) {
  final others = [...tiles];
  if (!others.remove(calledTile)) {
    final i = others.indexWhere(
      (t) => Tile.normalize(t) == Tile.normalize(calledTile),
    );
    if (i >= 0) others.removeAt(i);
  }
  return others..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
}

/// 牌譜DBの agari_event.description 表記(「役満」「40符5飜 満貫8000」)。
/// 対戦エンジン・記録エンジンの両方がこれで書き、[limitLabelFromDescription] が読む。
String agariDescription({
  required bool isYakuman,
  required int fu,
  required int han,
  required String label,
  required int declared,
}) => isYakuman ? '役満' : '$fu符$han飜 $label$declared';

/// description から限定手のラベル(役満/三倍満/倍満/跳満/満貫)を取り出す。無ければ ''
String limitLabelFromDescription(String? description) =>
    RegExp('(役満|三倍満|倍満|跳満|満貫)').firstMatch(description ?? '')?.group(1) ?? '';

/// エンジンの役名 → Mリーグ牌譜DBの yaku_name 表記。
/// 旧DB(〜2026-05)には '純全帯么九色'・'ニ盃口'(カタカナのニ)という表記癖が
/// あったが、2026-09-12 のリリースで '純全帯么九'・'二盃口' に修正された
/// (実DBで確認済み)。以後はその表記に合わせる。
String dbYakuName(String engineName) {
  if (engineName.startsWith('役牌 ')) return engineName.substring(3);
  if (engineName.startsWith('自風')) return '自風';
  if (engineName.startsWith('場風')) return '場風';
  return switch (engineName) {
    '全帯么九' => '混全帯么九',
    _ => engineName,
  };
}

/// 役リストをDB表記のJSONへ。
List<Map<String, dynamic>> yakuToJson(List<YakuItem> yaku) => [
  for (final y in yaku) {'name': dbYakuName(y.name), 'han': y.han},
];

/// 実DBの yaku_name テーブルの全表記(2026-09-12 リリース時点・45件)。
/// [dbYakuName] の出力がこの集合に収まることをテストで担保する。
const Set<String> dbYakuNames = {
  '立直',
  'ダブル立直',
  '門前清自摸和',
  '平和',
  '断么九',
  '一盃口',
  '自風',
  '場風',
  '白',
  '發',
  '中',
  '一発',
  '嶺上開花',
  '搶槓',
  '海底摸月',
  '河底撈魚',
  'ドラ',
  '赤ドラ',
  '裏ドラ',
  '七対子',
  '三色同順',
  '対々和',
  '三暗刻',
  '三槓子',
  '三色同刻',
  '小三元',
  '混老頭',
  '混全帯么九',
  '一気通貫',
  '混一色',
  '純全帯么九',
  '二盃口',
  '清一色',
  '国士無双',
  '九蓮宝燈',
  '四暗刻',
  '大三元',
  '字一色',
  '清老頭',
  '四槓子',
  '小四喜',
  '大四喜',
  '緑一色',
  '天和',
  '地和',
};
