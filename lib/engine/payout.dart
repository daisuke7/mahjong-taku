/// 和了・流局の点数移動と、状況判定の共有ロジック(純粋関数のみ)。
///
/// 対戦エンジン(GameEngine)と記録エンジン(RecordEngine)が同じ計算を
/// 別々に持つと、片方だけ直してもう片方が置き去りになる(Mリーグ適合
/// レビューで実際に起きた: 海底×嶺上・天和地和・パオ・カン条件)。
/// 状態を持たない計算はすべてここに置き、両エンジンから呼ぶ。
library;

import 'meld.dart';
import 'score.dart';
import 'tile.dart';
import 'yaku.dart';

/// カンできる条件(Mリーグ: 4回まで・嶺上補充用の山が残っていること)
bool kanAllowed({required int kanCount, required int wallRemaining}) =>
    kanCount < 4 && wallRemaining > 0;

/// 鳴き(ポン・大明槓)成立後の責任払いマーク判定。
/// [melds] は成立後の副露列。3つ目の三元牌・4つ目の風牌を鳴かせたら包。
({bool daisangen, bool daisuushi}) paoMarks(List<Meld> melds, int calledKind) {
  var daisangen = false;
  var daisuushi = false;
  if (Tile.isDragon(calledKind)) {
    final dragons = melds
        .where((m) => !m.isRun && Tile.isDragon(Tile.normalize(m.tiles[0])))
        .length;
    daisangen = dragons == 3;
  }
  if (Tile.isWind(calledKind)) {
    final winds = melds
        .where((m) => !m.isRun && Tile.isWind(Tile.normalize(m.tiles[0])))
        .length;
    daisuushi = winds == 4;
  }
  return (daisangen: daisangen, daisuushi: daisuushi);
}

/// 和了役に包対象役満があれば (包の席, 役満数)。無ければ (-1, 0)。
/// pao* は各役満を確定させた放銃者の席(-1=包なし)。
(int, int) paoFor(
  WinScore score, {
  required int paoDaisangen,
  required int paoDaisuushi,
  required int paoSuukantsu,
}) {
  var paoSeat = -1;
  var count = 0;
  for (final y in score.yaku) {
    if (y.name == '大三元' && paoDaisangen >= 0) {
      paoSeat = paoDaisangen;
      count++;
    } else if (y.name == '大四喜' && paoDaisuushi >= 0) {
      paoSeat = paoDaisuushi;
      count++;
    } else if (y.name == '四槓子' && paoSuukantsu >= 0) {
      paoSeat = paoSuukantsu;
      count++;
    }
  }
  return (paoSeat, count);
}

/// 和了1件の点数移動(供託・本場・責任払い込み)。ツモは [fromSeat]=null。
/// Mリーグはアガリ者が常に1人(頭ハネ)なので、通常は局に1回だけ呼ばれる。
///
/// 戻り値:
/// - changes: 4席の増減(この和了1件分)
/// - declared: 供託を除く申告点(表示用。ツモの責任払いは本場込み)
/// - label: 支払い表示('満貫 8000' など。ツモの責任払いでは空)
({List<int> changes, int declared, String label}) winPayout({
  required WinScore score,
  required int seat,
  required int dealer,
  int? fromSeat,
  required int honba,
  required int riichiSticks,
  int paoSeat = -1,
  int paoCount = 0,
}) {
  final isDealer = seat == dealer;
  final isTsumo = fromSeat == null;
  final changes = List<int>.filled(4, 0);
  final hasPao =
      score.isYakuman &&
      paoSeat >= 0 &&
      paoCount > 0 &&
      paoSeat != seat &&
      (isTsumo || paoSeat != fromSeat);

  if (isTsumo) {
    if (hasPao) {
      // 責任払い: 包んだ分の役満はツモでも全額責任払い
      var declared = 8000 * paoCount * (isDealer ? 6 : 4) + honba * 300;
      changes[paoSeat] -= declared;
      final remainder = score.yakuman - paoCount;
      if (remainder > 0) {
        // 包対象でない役満の複合分は通常のツモ割り
        final sub = calcPayment(
          score: WinScore(
            yaku: score.yaku,
            han: 0,
            fu: score.fu,
            yakuman: remainder,
          ),
          isDealer: isDealer,
          isTsumo: true,
          honba: 0,
          riichiSticks: 0,
        );
        for (var i = 0; i < 4; i++) {
          if (i == seat) continue;
          changes[i] -= (isDealer || i != dealer)
              ? sub.tsumoNonDealer
              : sub.tsumoDealer;
        }
        declared += sub.declared;
      }
      changes[seat] = declared + riichiSticks * 1000;
      return (changes: changes, declared: declared, label: '');
    }
    final payment = calcPayment(
      score: score,
      isDealer: isDealer,
      isTsumo: true,
      honba: honba,
      riichiSticks: riichiSticks,
    );
    for (var i = 0; i < 4; i++) {
      if (i == seat) continue;
      changes[i] -= (isDealer || i != dealer)
          ? payment.tsumoNonDealer
          : payment.tsumoDealer;
    }
    changes[seat] = payment.total;
    return (changes: changes, declared: payment.declared, label: payment.label);
  }

  final payment = calcPayment(
    score: score,
    isDealer: isDealer,
    isTsumo: false,
    honba: honba,
    riichiSticks: riichiSticks,
  );
  changes[seat] += payment.total;
  changes[fromSeat] -= payment.ron;
  if (hasPao) {
    // 責任払い: ロンは包んだ席と放銃者で折半
    final paoShare = 8000 * paoCount * (isDealer ? 6 : 4) ~/ 2;
    changes[fromSeat] += paoShare;
    changes[paoSeat] -= paoShare;
  }
  return (changes: changes, declared: payment.declared, label: payment.label);
}

/// 流局のノーテン罰符(場3000点)。全員テンパイ・全員ノーテンは移動なし。
List<int> ryukyokuChanges(List<int> tenpaiSeats) {
  final changes = List<int>.filled(4, 0);
  if (tenpaiSeats.isNotEmpty && tenpaiSeats.length < 4) {
    final gain = 3000 ~/ tenpaiSeats.length;
    final loss = 3000 ~/ (4 - tenpaiSeats.length);
    for (var i = 0; i < 4; i++) {
      changes[i] = tenpaiSeats.contains(i) ? gain : -loss;
    }
  }
  return changes;
}
