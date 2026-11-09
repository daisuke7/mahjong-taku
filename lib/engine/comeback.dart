/// 逆転計算: 自分より上位の相手を上回るために最低限必要な手(翻・符)と、
/// その手で得られる点(供託・本場込み)を、ツモ/ロン別に求める。
/// - 符も考慮して (翻×符) 全組合せから、獲得点の昇順で最初に逆転する手を選ぶ。
/// - ツモは対象者も支払う。ロンは直撃を考慮しない(対象者は減らない)。
/// - Mリーグルール(切り上げ満貫)。
library;

import 'models.dart';
import 'score.dart';

/// 逆転に必要な手(ツモ or ロン)
class NeededHand {
  final bool reachable; // 役満でも届かない場合 false
  final int han; // 限定手は代表翻(満貫=5 等)
  final int fu; // 0 = 限定手(満貫以上)
  final int gain; // その手で得られる点(供託・本場込み)
  final String label; // 表示用 例 "2翻40符" / "満貫" / "—"

  const NeededHand({
    required this.reachable,
    required this.han,
    required this.fu,
    required this.gain,
    required this.label,
  });

  static const none = NeededHand(
    reachable: false,
    han: 0,
    fu: 0,
    gain: 0,
    label: '—',
  );
}

// 実用的な符の範囲。70符以上の特殊手まで含めると「2翻70符」のような
// 非現実的な最小手が選ばれるため、20〜60符に限定する。
const _fuList = [20, 25, 30, 40, 50, 60];

/// 限定手(代表翻, 名称, 基本点)
///
/// Mリーグルールに数え役満は無く、通常役の複合は三倍満が上限。よって
/// 基本点8000に届く手は「役満役そのものを作る」以外に無い。役満の代表翻は
/// 翻数由来ではないため便宜上13としているが、翻数として意味は持たない。
const _limits = <(int, String, int)>[
  (5, '満貫', 2000),
  (6, '跳満', 3000),
  (8, '倍満', 4000),
  (11, '三倍満', 6000),
  (13, '役満', 8000),
];

/// self が target(自分より上位)を上回るのに必要な最小の手。
NeededHand neededHand({
  required bool isTsumo,
  required int selfScore,
  required int targetScore,
  required bool selfDealer,
  required bool targetDealer,
  required int honba,
  required int sticks,
}) {
  // 候補: (han, fu, base, label)。満貫以上は限定手として fu=0。
  final cands = <(int, int, int, String)>[];
  for (final fu in _fuList) {
    for (var han = 1; han <= 4; han++) {
      if (!isValidHanFu(han: han, fu: fu, isTsumo: isTsumo)) continue;
      final b = basePointsOf(han, fu);
      if (b >= 2000) continue; // 満貫以上は限定手で扱う
      cands.add((han, fu, b, '$han翻$fu符'));
    }
  }
  for (final (han, name, b) in _limits) {
    cands.add((han, 0, b, name));
  }

  int gainOf(int base) {
    if (isTsumo) {
      final ko = ceil100(base);
      final oya = ceil100(base * 2);
      final self = selfDealer ? 3 * oya : oya + 2 * ko;
      return self + 300 * honba + 1000 * sticks;
    }
    return ceil100(base * (selfDealer ? 6 : 4)) + 300 * honba + 1000 * sticks;
  }

  bool overtakes(int base) {
    final gain = gainOf(base);
    if (!isTsumo) return selfScore + gain > targetScore;
    // ツモは対象者も支払う
    final ko = ceil100(base);
    final oya = ceil100(base * 2);
    final targetPay =
        (selfDealer ? oya : (targetDealer ? oya : ko)) + 100 * honba;
    return selfScore + gain > targetScore - targetPay;
  }

  cands.sort((a, b) => gainOf(a.$3).compareTo(gainOf(b.$3)));
  for (final (han, fu, base, label) in cands) {
    if (overtakes(base)) {
      return NeededHand(
        reachable: true,
        han: han,
        fu: fu,
        gain: gainOf(base),
        label: label,
      );
    }
  }
  return NeededHand.none;
}

/// 順位表の1行
class RankEntry {
  final int seat;
  final String name;
  final int score;
  final int diff; // 自分との差(score - selfScore)。上位ほどプラス。
  final bool isSelf;

  /// 自分より上位の相手のみ設定。逆転に必要な手。
  final NeededHand? tsumo;
  final NeededHand? ron;

  const RankEntry({
    required this.seat,
    required this.name,
    required this.score,
    required this.diff,
    required this.isSelf,
    this.tsumo,
    this.ron,
  });
}

/// 現局の状態から順位表(順位順)を作る。
List<RankEntry> buildRanking(GameView view) {
  // 同点は起家に近い方が上位(半荘終了の精算 settleGame と同じ規則。
  // 以前はその局の東>南>西>北で並べていて、親が席0でない局では精算と食い違った)
  final seats = rankSeatsByScore(view.scores);
  final self = view.youSeat;
  final selfScore = view.scores[self];
  final selfDealer = view.dealer == self;
  final selfIdx = seats.indexOf(self);

  return [
    for (var i = 0; i < seats.length; i++)
      () {
        final s = seats[i];
        final above = i < selfIdx; // 自分より上位
        NeededHand? need(bool tsumo) => above
            ? neededHand(
                isTsumo: tsumo,
                selfScore: selfScore,
                targetScore: view.scores[s],
                selfDealer: selfDealer,
                targetDealer: view.dealer == s,
                honba: view.honba,
                sticks: view.riichiSticks,
              )
            : null;
        return RankEntry(
          seat: s,
          name: view.players[s].name,
          score: view.scores[s],
          diff: view.scores[s] - selfScore,
          isSelf: s == self,
          tsumo: need(true),
          ron: need(false),
        );
      }(),
  ];
}
