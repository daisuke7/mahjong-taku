/// 表示文言の純粋関数(対戦・記録・ビューア・一覧で共有)。
///
/// CLAUDE.md §2「同じ計算を2箇所に書かない」は表示規則にも及ぶ。
/// 局の表記・風の名前・符号付き点差・翻符・和了と流局の要約は、ここ以外に書かない。
library;

import 'tile.dart';

/// 「東1局」「南3局1本場」。[alwaysHonba] なら0本場も付け、[honbaSep] で区切る
/// (卓中央の2行表示など「東1局 0本場」の形もこの1関数で作る)。
String kyokuLabel(
  int roundWind,
  int kyoku, {
  int honba = 0,
  bool alwaysHonba = false,
  String honbaSep = '',
}) {
  final base = '${windNames[roundWind]}$kyoku局';
  if (honba > 0 || alwaysHonba) return '$base$honbaSep$honba本場';
  return base;
}

/// 牌譜DBの round 表記('2z3' = 南3局)から局の表記を作る
String kyokuLabelFromRound(String round, {int honba = 0}) {
  final wind = int.parse(round.substring(0, 1)) - 1;
  final kyoku = int.parse(round.substring(2));
  return kyokuLabel(wind, kyoku, honba: honba);
}

/// 起家からの席順(0..3)→「東家」「南家」…
String seatWindName(int seatIndex) => '${windNames[seatIndex % 4]}家';

/// 「起家から東家」(視点選択などの席の説明)
String seatFromChiichaLabel(int seatIndex) => '起家から${seatWindName(seatIndex)}';

/// 符号付きの点差。正は '+n'、負は '-n'、0は [zero](既定 '0')。
String formatSignedPoints(int n, {String zero = '0'}) {
  if (n == 0) return zero;
  return n > 0 ? '+$n' : '$n';
}

/// CPU プレイヤーの名前(席順)。ソロ対局・部屋の空席・ギャラリー対局が共有する。
const List<String> cpuPlayerNames = ['CPU 東子', 'CPU 南美', 'CPU 西夫', 'CPU 北斗'];

/// 「2翻40符」
String hanFuLabel(int han, int fu) => '$han翻$fu符';

/// 和了の要約「名前 ツモ 8000点」「名前 相手からロン 8000点」。
/// [loserName] が空ならロンでも相手名を出さない。
String winSummary({
  required String name,
  required bool isTsumo,
  String loserName = '',
  required int points,
}) {
  final how = isTsumo ? 'ツモ' : (loserName.isEmpty ? 'ロン' : '$loserNameからロン');
  return '$name $how $points点';
}

/// 流局時のテンパイ要約「全員ノーテン」「全員テンパイ」「テンパイ: A・B」。
String tenpaiSummary(List<String> tenpaiNames, {int playerCount = 4}) {
  if (tenpaiNames.isEmpty) return '全員ノーテン';
  if (tenpaiNames.length >= playerCount) return '全員テンパイ';
  return 'テンパイ: ${tenpaiNames.join('・')}';
}
