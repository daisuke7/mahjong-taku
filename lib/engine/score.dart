/// 点数計算(符・翻 → 支払い)
library;

import 'yaku.dart';

class Payment {
  /// ロン: 放銃者の支払い。ツモ: 使わない
  final int ron;

  /// ツモ: 子の支払い / 親の支払い(親ツモ時は all がこの額)
  final int tsumoNonDealer;
  final int tsumoDealer;

  /// 和了者の総取得点(本場・供託込み)
  final int total;

  /// 供託(リーチ棒)を除いた申告点(和了打点+本場)
  final int declared;

  /// 点数名称(満貫など)
  final String label;

  const Payment({
    this.ron = 0,
    this.tsumoNonDealer = 0,
    this.tsumoDealer = 0,
    required this.total,
    required this.declared,
    required this.label,
  });
}

/// 100点単位の切り上げ(支払い額の丸め)
int ceil100(int v) => ((v + 99) ~/ 100) * 100;

/// (翻, 符)の基本点。満貫頭打ち 2000、切り上げ満貫(30符4翻・60符3翻=1920 → 2000)、
/// 6翻跳満 3000・8翻倍満 4000・11翻以上は三倍満 6000(Mリーグに数え役満は無い)。
/// 役満は別扱い(呼び出し側で 8000×n)。点数計算・逆転計算・ガイドの早見表が共有する。
int basePointsOf(int han, int fu) {
  if (han >= 11) return 6000;
  if (han >= 8) return 4000;
  if (han >= 6) return 3000;
  final base = fu * (1 << (2 + han));
  if (base >= 2000) return 2000;
  if (base == 1920) return 2000;
  return base;
}

/// 基本点の名称(満貫以上だけ名前が付く)
String limitLabelOf(int base) => switch (base) {
  6000 => '三倍満',
  4000 => '倍満',
  3000 => '跳満',
  2000 => '満貫',
  _ => '',
};

/// (翻, 符, ツモ/ロン) が和了形として存在しうるか(点数表と同じ除外)。
/// - 20符はロンでは無い(平和ツモ限定)。平和1翻+門前ツモ1翻で必ず2翻以上。
/// - 25符は七対子(2翻)のみ。ツモは門前ツモが付くので必ず3翻以上。
bool isValidHanFu({required int han, required int fu, required bool isTsumo}) {
  if (fu == 20) return isTsumo && han >= 2;
  if (fu == 25) return han >= (isTsumo ? 3 : 2);
  return han >= 1;
}

/// 持ち点の降順に席を並べる。同点は起家(席0)に近い方が上位
/// (Mリーグ 第6章第2条 項目6「起家に近い方が大きいポイントを取得する」)。
/// 半荘終了の精算・対局中の順位表・逆転計算が共有する。
List<int> rankSeatsByScore(List<int> scores) =>
    List.generate(scores.length, (i) => i)..sort((a, b) {
      final d = scores[b] - scores[a];
      return d != 0 ? d : a - b;
    });

/// Mリーグ順位点(オカ込み): 1位+50 / 2位+10 / 3位▲10 / 4位▲30 (千点単位)
const mleagueRankBonus = [50000, 10000, -10000, -30000];

/// 半荘終了時の精算(Mリーグ 第6章第2条 持ち点・順位点の要旨。原文は公式サイト)。
///
/// - 項目2: 順位は終了時の合計得点で決める。
/// - 項目5: 流局で終わったときに場に残ったリーチ棒はトップ者のもの。
/// - 項目6: 同点なら順位点を分け、流局終了時のリーチ棒も同点者で均等に分ける。
///   どちらも端数は起家に近い方が多く取る。
///
/// [scores] は席番号順の持ち点(**リーチ棒を配る前**)。
/// [pot] は場に残ったリーチ棒(和了で半荘が終わった場合は0)。
/// [returnScore] は返し点。
///
/// **順序が肝**: 項目6が「同点者に順位点とリーチ棒の**両方**を分ける」と規定して
/// いる以上、順位と同点の判定はリーチ棒を配る**前**の持ち点で行う。配ってから
/// 判定するとリーチ棒が同点を解消してしまい、按分が永久に発動しない。
({List<int> ranking, List<int> finalScores, List<double> points}) settleGame({
  required List<int> scores,
  required int pot,
  int returnScore = 30000,
}) {
  final n = scores.length;
  final ranking = rankSeatsByScore(scores);
  // 順位点は「リーチ棒を配る前」の持ち点で按分する
  final bonus = splitRankBonus(ranking: ranking, scores: scores);

  // リーチ棒はトップへ。トップが同点なら当該者で分ける(起家に近い方が大きい)。
  final finalScores = List<int>.from(scores);
  if (pot > 0) {
    final topScore = scores[ranking[0]];
    // ranking は同点なら起家に近い順に並んでいるので、その順で分配すればよい
    final tiedTop = [
      for (final seat in ranking)
        if (scores[seat] == topScore) seat,
    ];
    final shares = splitRiichiPot(pot, tiedTop.length);
    for (var i = 0; i < tiedTop.length; i++) {
      finalScores[tiedTop[i]] += shares[i];
    }
  }

  final points = List<double>.filled(n, 0);
  for (var rank = 0; rank < n; rank++) {
    final seat = ranking[rank];
    points[seat] = (finalScores[seat] - returnScore + bonus[rank]) / 1000.0;
  }
  return (ranking: ranking, finalScores: finalScores, points: points);
}

/// 半荘終了時に場に残ったリーチ棒を、トップ者で分ける(Mリーグ 第6章第2条 項目5・6 の要旨)。
///
/// 流局終了時のリーチ棒はトップ者に入り、トップが同点なら当該者で均等に分ける。
/// 規定は 3 名同点で 1000 点のとき 400・300・300、2000 点ならその 2 倍(800・600・600)と
/// 例示しており、割り切れない分は起家に近い方が多く取る。
///
/// [pot] は場に残った点(1000点単位)。[n] は同点のトップ者の人数。
/// 戻り値は**起家に近い順**の取り分(呼び出し側はその順で渡すこと)。
///
/// **麻雀の授受に100点未満は存在しない。** 原文が3名の場合だけ 400・300・300 と
/// 名指しするのはそのためで、1000÷3 が100点単位に割り切れないから。2名は
/// 500ずつで割り切れるので規定が要らない。
///
/// 4名同点は**供託が偶数本のときしか成立しない**ので、これも規定が要らない。
/// 全員の持ち点が等しいなら各自 (100000 - 1000N)/4 = 25000 - 250N 点であり、
/// 持ち点が100点単位である以上 N は偶数でなければならない。よって pot~/4 は
/// 必ず100の倍数になり、250点のような端数は生じない。
List<int> splitRiichiPot(int pot, int n) {
  if (n <= 1) return [pot];
  if (n == 3) {
    final unit = pot ~/ 1000; // 1000点あたり 400/300/300 を本数分
    return [400 * unit, 300 * unit, 300 * unit];
  }
  return List<int>.filled(n, pot ~/ n);
}

/// 同点者の順位点を按分する(Mリーグルール)。
///
/// 「半荘終了時に同点で終わった場合、順位点を分ける。3名が同点だった場合の
/// 端数は起家に近い方が大きいポイントを取得する。」
///
/// [ranking] は順位順の席番号(同点は起家に近い順に並んでいる前提)。
/// [scores] は席番号順の持ち点。戻り値は**順位順**の順位点。
///
/// 同点の並びごとに順位点を合算して頭割りし、端数は表示単位である
/// 100点(=0.1pt)刻みで起家に近い者から1単位ずつ配る。
/// 例: 1〜3位が同点 → (50000+10000-10000)/3 → +16.7 / +16.7 / +16.6 pt
List<int> splitRankBonus({
  required List<int> ranking,
  required List<int> scores,
  List<int> rankBonus = mleagueRankBonus,
}) {
  final n0 = ranking.length;
  final result = List<int>.filled(n0, 0);
  var rank = 0;
  while (rank < n0) {
    // 同点が続く範囲 [rank, end) を求める
    var end = rank + 1;
    while (end < n0 && scores[ranking[end]] == scores[ranking[rank]]) {
      end++;
    }
    final n = end - rank;
    if (n == 1) {
      result[rank] = rankBonus[rank];
    } else {
      var total = 0;
      for (var i = rank; i < end; i++) {
        total += rankBonus[i];
      }
      // 100点単位で頭割りし、余りは起家に近い者(=rankingの前方)から1単位ずつ。
      // floor除算にすることで、負の端数でも「前方ほど大きい」が保たれる。
      final units = total ~/ 100;
      final each = (units / n).floor();
      var rem = units - each * n; // 0 <= rem < n
      for (var i = rank; i < end; i++) {
        result[i] = (each + (rem > 0 ? 1 : 0)) * 100;
        if (rem > 0) rem--;
      }
    }
    rank = end;
  }
  return result;
}

/// 基本点と名称
(int, String) _basePoints(WinScore score) {
  if (score.yakuman > 0) {
    final label = score.yakuman > 1 ? '${score.yakuman}倍役満' : '役満';
    return (8000 * score.yakuman, label);
  }
  final base = basePointsOf(score.han, score.fu);
  return (base, limitLabelOf(base));
}

/// 和了の支払い計算
Payment calcPayment({
  required WinScore score,
  required bool isDealer,
  required bool isTsumo,
  required int honba,
  required int riichiSticks,
}) {
  final (base, label) = _basePoints(score);
  final pot = riichiSticks * 1000;

  if (isTsumo) {
    if (isDealer) {
      final each = ceil100(base * 2) + honba * 100;
      return Payment(
        tsumoNonDealer: each,
        total: each * 3 + pot,
        declared: each * 3,
        label: label,
      );
    }
    final nonDealer = ceil100(base) + honba * 100;
    final dealer = ceil100(base * 2) + honba * 100;
    return Payment(
      tsumoNonDealer: nonDealer,
      tsumoDealer: dealer,
      total: nonDealer * 2 + dealer + pot,
      declared: nonDealer * 2 + dealer,
      label: label,
    );
  }

  final ron = ceil100(base * (isDealer ? 6 : 4)) + honba * 300;
  return Payment(ron: ron, total: ron + pot, declared: ron, label: label);
}
