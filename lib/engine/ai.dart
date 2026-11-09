/// CPU代打エージェント
library;

import 'dart:async';
import 'dart:math';

import 'advisor.dart';
import 'emotes.dart';
import 'game_engine.dart';
import 'hand.dart';
import 'models.dart';
import 'safety.dart';
import 'tile.dart';
import 'yaku.dart';

/// 他家の脅威(リーチ・警戒レベルの鳴き)に対する押し引きの方針。
/// 既定値は牌譜DBのプロ実打との一致率で校正したもの(2026-09-19、60試合・
/// 他家リーチあり手番 6,899 件。CPU 校正記録(非公開文書)§11.3、
/// `tool/jev_bench.dart cpu-report`)。旧方針(one=3, safe=0)からの変更点:
/// 1シャンテンは価値4以上でだけ押す(プロは CPU より降りる)、ただし攻めの打牌が
/// 現物または3枚見えの字牌なら押す、2シャンテン以上でも現物ならその牌を切る。
class PushPolicy {
  /// 1シャンテンで押すのに必要な手の価値(ドラ+赤+門前1)。
  final int oneShantenValue;

  /// 2シャンテンで押すのに必要な手の価値。99 なら常に降りる。
  final int twoShantenValue;

  /// 1シャンテン以下で、攻めの打牌の安全度(threatRisk、100=現物、90=3枚見えの字牌)が
  /// この値以上なら手の価値に関わらずその牌を切る(降りと攻めが両立する「ただ押し」)。
  /// 0 なら無効。
  final int safePushRisk;

  /// 2シャンテン以上で同じ扱いをする安全度。0 なら無効。
  final int deepSafePushRisk;

  const PushPolicy({
    this.oneShantenValue = 4,
    this.twoShantenValue = 99,
    this.safePushRisk = 90,
    this.deepSafePushRisk = 100,
  });

  /// 校正前の方針(2026-09-19 まで)。比較用。
  static const legacy = PushPolicy(
    oneShantenValue: 3,
    safePushRisk: 0,
    deepSafePushRisk: 0,
  );

  /// 押すか。[attackRisk] は攻めの打牌の安全度(不明なら 0)。
  bool shouldPush({
    required int shanten,
    required int handValue,
    int attackRisk = 0,
  }) {
    if (shanten <= 0) return true;
    final safe = shanten == 1 ? safePushRisk : deepSafePushRisk;
    if (safe > 0 && attackRisk >= safe) return true;
    if (shanten == 1) return handValue >= oneShantenValue;
    if (shanten == 2) return handValue >= twoShantenValue;
    return false;
  }

  @override
  String toString() =>
      'PushPolicy(one=$oneShantenValue, two=$twoShantenValue, '
      'safe=$safePushRisk, deepSafe=$deepSafePushRisk)';
}

/// リーチできるときにダマ(リーチせず聴牌)を選ぶ方針。
/// すべての待ちにリーチ無しで役が付く(取りこぼしが無い)ことが前提で、
/// 以下のいずれかに当たればダマ。各値 0 は無効。既定値は牌譜DBのプロ実打で
/// 校正したもの(2026-09-19、60試合・門前でテンパイを取った手番 1,458 件。
/// CPU 校正記録(非公開文書)§11.5)。校正前(常にリーチ)の一致 45% → 71%。
/// プロは役ありなら「待ち4枚以下」「残り山10未満」「南場トップで4000点以上リード」で
/// ほぼ曲げない。ダマ打点の高さ自体はリーチ率を変えなかった。
class RiichiPolicy {
  /// 待ちの残り枚数がこれ以下ならダマ(愚形は曲げない)
  final int damaMaxWaits;

  /// 残り山がこれ未満ならダマ(終盤は曲げない)
  final int damaWallBelow;

  /// 南場で1位かつ2位との差がこれ以上ならダマ(逃げ切り)
  final int damaLeadTop;

  /// ダマのロン打点がこれ以上ならダマ(打点十分)
  final int damaMinPoints;

  const RiichiPolicy({
    this.damaMaxWaits = 4,
    this.damaWallBelow = 10,
    this.damaLeadTop = 4000,
    this.damaMinPoints = 0,
  });

  /// 常にリーチ(校正前の方針、2026-09-19 まで)。比較用
  static const alwaysRiichi = RiichiPolicy(
    damaMaxWaits: 0,
    damaWallBelow: 0,
    damaLeadTop: 0,
  );

  bool shouldDama({
    required DamaInfo dama,
    required int wall,
    required bool southRound,
    required bool isTop,
    required int lead,
  }) {
    if (!dama.allWaitsHaveYaku) return false;
    if (damaMinPoints > 0 && dama.maxRonPoints >= damaMinPoints) return true;
    if (damaMaxWaits > 0 && dama.waitCount <= damaMaxWaits) return true;
    if (damaWallBelow > 0 && wall < damaWallBelow) return true;
    if (damaLeadTop > 0 && southRound && isTop && lead >= damaLeadTop) {
      return true;
    }
    return false;
  }

  @override
  String toString() =>
      'RiichiPolicy(maxWaits=$damaMaxWaits, wallBelow=$damaWallBelow, '
      'leadTop=$damaLeadTop, minPoints=$damaMinPoints)';
}

/// 攻めの打牌選択の方針: 打点重視の打牌(`attackDiscard`)を、受け入れ最大の打牌に
/// 対する受け入れ損失が [maxUkeireLoss] 枚以内のときだけ採る。
/// 既定 0 = 受け入れ最大を基本にし、同枚数のときだけ打点で選ぶ。牌譜DBの
/// プロ実打との一致は損失 0 が最良で、許す枚数を増やすほど単調に下がった
/// (2026-09-19、CPU 校正記録(非公開文書)§11.6)。
class AttackPolicy {
  final int maxUkeireLoss;

  const AttackPolicy({this.maxUkeireLoss = 0});

  /// 校正前(常に打点重視、2026-09-19 まで)。比較用
  static const legacy = AttackPolicy(maxUkeireLoss: 99);

  @override
  String toString() => 'AttackPolicy(maxUkeireLoss=$maxUkeireLoss)';
}

/// 他家の打牌に対する鳴き(ポン・チー)の方針。既定値は牌譜DBのプロ実打で校正
/// (2026-09-19、60試合・鳴ける局面 9,608 件。CPU 校正記録(非公開文書)§11.7)。
/// 校正前は「役牌は常にポン、副露済みならシャンテンが進めば鳴く」で、
/// 役牌を鳴きすぎ(プロ 50% に対し CPU 95%)、深い手でも鳴きすぎていた。
/// 門前での役牌以外の鳴きはプロも 5% 程度なので行わない。
class CallPolicy {
  /// 役牌ポン: シャンテンがこれ以上進むこと
  final int yakuhaiMinGain;

  /// 役牌ポン: 鳴いた後(打牌込み)のシャンテン数がこれ以下
  final int yakuhaiMaxAfter;

  /// 役牌ポン: 手の価値(ドラ+赤)がこれ以上なら上の条件に関わらずポン
  final int yakuhaiMinValue;

  /// 副露済みの手の役牌以外: シャンテンが進み、鳴いた後がこれ以下なら鳴く
  final int openMaxAfter;

  /// 他家リーチ中: 鳴いた後のシャンテン数がこれ以下のときだけ鳴く(0=テンパイのみ)
  final int threatMaxAfter;

  const CallPolicy({
    this.yakuhaiMinGain = 1,
    this.yakuhaiMaxAfter = 2,
    this.yakuhaiMinValue = 3,
    this.openMaxAfter = 2,
    this.threatMaxAfter = 0,
  });

  /// 校正前(2026-09-19 まで)に近い方針。比較用
  static const legacy = CallPolicy(
    yakuhaiMinGain: -9,
    yakuhaiMaxAfter: 99,
    yakuhaiMinValue: 99,
    openMaxAfter: 99,
    threatMaxAfter: 99,
  );

  bool shouldCall({
    required bool yakuhai,
    required bool menzen,
    required int before,
    required int after,
    required int handValue,
    required bool threat,
  }) {
    final gain = before - after;
    if (threat && after > threatMaxAfter) return false;
    if (yakuhai) {
      if (gain < 0) return false;
      if (handValue >= yakuhaiMinValue) return true;
      return gain >= yakuhaiMinGain && after <= yakuhaiMaxAfter;
    }
    if (menzen) return false;
    return gain >= 1 && after <= openMaxAfter;
  }

  @override
  String toString() =>
      'CallPolicy(yakuhai: gain>=$yakuhaiMinGain & after<=$yakuhaiMaxAfter '
      'or value>=$yakuhaiMinValue, open: after<=$openMaxAfter, '
      'threat: after<=$threatMaxAfter)';
}

class CpuAgent implements PlayerAgent {
  final Random _rng;
  GameView? _view;

  /// 攻めの打牌選択の方針
  final AttackPolicy attackPolicy;

  /// 鳴きの方針
  final CallPolicy callPolicy;

  /// 押し引きの方針
  final PushPolicy policy;

  /// リーチ/ダマの方針
  final RiichiPolicy riichiPolicy;

  /// 演出用の思考時間(ミリ秒)。テストでは 0 にする
  final int thinkMillis;

  /// 顔文字キャストの送信口(エンジンが配線する)。null なら演出なし。
  void Function(int emoji)? castEmote;

  bool _resultCast = false; // 同じ局結果で二重キャストしない

  CpuAgent({
    int? seed,
    this.thinkMillis = 550,
    this.policy = const PushPolicy(),
    this.riichiPolicy = const RiichiPolicy(),
    this.attackPolicy = const AttackPolicy(),
    this.callPolicy = const CallPolicy(),
  }) : _rng = Random(seed);

  @override
  void onView(GameView view) {
    _view = view;
    _maybeCastOnResult(view);
  }

  /// 和了・放銃時に一定確率で顔をキャストする。
  void _maybeCastOnResult(GameView v) {
    if (v.phase == 'playing') {
      _resultCast = false;
      return;
    }
    if (v.phase != 'handEnd' || v.handResult == null || _resultCast) return;
    _resultCast = true;
    final me = v.youSeat;
    final r = v.handResult!;
    if (r.wins.any((w) => w.seat == me)) {
      _castRandom(emoteHappy, 0.6); // 和了 → うれしい
    } else if (r.wins.any((w) => w.fromSeat == me)) {
      _castRandom(emoteRegret, 0.7); // 放銃 → くやしい
    }
  }

  void _castRandom(List<int> pool, double prob) {
    final cast = castEmote;
    if (cast == null || _rng.nextDouble() > prob) return;
    cast(pool[_rng.nextInt(pool.length)]);
  }

  @override
  void onEmote(int seat, int emoji) {} // CPUは受信不要(表示しない)

  Future<void> _think(double scale) async {
    if (thinkMillis <= 0) return;
    final ms = (thinkMillis * scale * (0.7 + _rng.nextDouble() * 0.6)).round();
    await Future<void>.delayed(Duration(milliseconds: ms));
  }

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) async {
    await _think(1.0);
    if (prompt.canTsumo) return const TurnAction.tsumo();

    final view = _view;
    final hand = List<int>.from(view?.hand ?? []);
    if (prompt.drawnTile != null) hand.add(prompt.drawnTile!);
    hand.sort();
    final meldCount = view == null
        ? 0
        : view.players[view.youSeat].melds.length;

    // リーチ中: 暗槓できるならする、できなければツモ切り
    if (prompt.riichiLocked) {
      if (prompt.ankanKinds.isNotEmpty) {
        return TurnAction.ankan(prompt.ankanKinds.first);
      }
      return TurnAction.discard(prompt.drawnTile ?? hand.first);
    }

    // 押し引き: 他家の脅威(リーチ+警戒レベルの鳴き)に対して、聴牌なら押し、
    // イーシャンテンは手の価値次第、それ以外は降りて安全牌を切る
    final threats = _threats(view);
    if (threats.isNotEmpty && view != null) {
      final shanten = _bestShantenAfterDiscard(hand, meldCount);
      // 攻めるならこの牌、の安全度(現物なら攻守が両立する)
      final attack =
          attackDiscard(view, forbidden: prompt.forbiddenDiscards) ??
          _chooseDiscard(hand, meldCount, prompt.forbiddenDiscards);
      var attackRisk = 999;
      for (final t in threats) {
        final r = threatRisk(view, hand, Tile.normalize(attack), t);
        if (r < attackRisk) attackRisk = r;
      }
      if (!_shouldPush(shanten, hand, view, attackRisk: attackRisk)) {
        return TurnAction.discard(
          _chooseSafeDiscard(hand, prompt.forbiddenDiscards, threats, view),
        );
      }
    }

    // 暗槓・加槓: シャンテンを悪化させないなら実行
    // (カン後の手は 3n+1 枚になるので直接シャンテンを比較できる)
    for (final kind in [...prompt.ankanKinds, ...prompt.kakanKinds]) {
      final isAnkan = prompt.ankanKinds.contains(kind);
      final before = _bestShantenAfterDiscard(hand, meldCount);
      final after = isAnkan
          ? calcShanten(
              toCounts(
                List<int>.from(hand)
                  ..removeWhere((t) => Tile.normalize(t) == kind),
              ),
              meldCount: meldCount + 1,
            )
          : calcShanten(
              toCounts(_removeOneOfKind(hand, kind)),
              meldCount: meldCount,
            );
      if (after <= before) {
        return isAnkan ? TurnAction.ankan(kind) : TurnAction.kakan(kind);
      }
    }

    // リーチできるなら宣言。宣言牌は待ち表示(tenpaiWaits)と共有の基準
    // 「待ちが最も広い打牌、同枚数なら打点期待(ドラ・役)の高い待ち」で選ぶ。
    if (prompt.riichiTiles.isNotEmpty) {
      int? bestTile;
      if (view != null) {
        for (final o in tenpaiWaits(view)) {
          final d = o.discard;
          if (d == null) continue;
          // 同種に赤と通常があれば通常牌を切って赤を残す
          final matches =
              prompt.riichiTiles
                  .where((t) => Tile.normalize(t) == Tile.normalize(d))
                  .toList()
                ..sort(
                  (a, b) => (Tile.isRed(a) ? 1 : 0) - (Tile.isRed(b) ? 1 : 0),
                );
          if (matches.isNotEmpty) {
            bestTile = matches.first;
            break;
          }
        }
      }
      if (bestTile == null) {
        // view が無い(通常起きない)ときのフォールバック: 待ち枚数のみ
        var bestWaits = -1;
        for (final t in prompt.riichiTiles) {
          final counts = toCounts(hand)..[Tile.normalize(t)] -= 1;
          // ここは受け入れ枚数の比較なので calcWaits で足りる。
          // 自分で4枚使い切っている待ちは _remainingOf が0を返す(remainingOf は
          // 副露も数える)ため、calcLiveWaits を使っても n は変わらない。
          final waits = calcWaits(counts, meldCount: meldCount);
          var n = 0;
          for (final w in waits) {
            n += _remainingOf(w, hand);
          }
          if (n > bestWaits) {
            bestWaits = n;
            bestTile = t;
          }
        }
      }
      // ダマ判断(役があり取りこぼしの無い聴牌で、方針に当たればリーチしない)
      if (view != null) {
        final me = view.youSeat;
        final others = [
          for (var s = 0; s < 4; s++)
            if (s != me) view.scores[s],
        ];
        final top = others.reduce(max);
        if (riichiPolicy.shouldDama(
          dama: damaInfo(view, hand, bestTile!),
          wall: view.wallRemaining,
          southRound: view.roundWind >= 1,
          isTop: view.scores[me] > top,
          lead: view.scores[me] - top,
        )) {
          return TurnAction.discard(bestTile);
        }
      }
      _castRandom(emoteRiichi, 0.35); // リーチ宣言 → 一定確率でドヤ/ニヤリ
      return TurnAction.discard(bestTile!, riichi: true);
    }

    // 攻め: 攻撃アドバイスを転用する。シャンテンを落とさない候補に限定した
    // 上で、役の想定打点が最も高くなる打牌を選ぶ(手戻りはしない)。
    // 役候補が無い手(役無しの副露手など)は従来の受け入れ最大の打牌に
    // フォールバックする。
    final discard = _chooseDiscard(hand, meldCount, prompt.forbiddenDiscards);
    if (view != null) {
      final t = attackDiscard(view, forbidden: prompt.forbiddenDiscards);
      // 打点重視の打牌は、受け入れ最大からの損失が方針の範囲内のときだけ採る
      if (t != null &&
          _ukeireAfter(hand, meldCount, discard) -
                  _ukeireAfter(hand, meldCount, t) <=
              attackPolicy.maxUkeireLoss) {
        return TurnAction.discard(t);
      }
    }
    return TurnAction.discard(discard);
  }

  @override
  Future<ReactAction> onReact(ReactPrompt prompt) async {
    await _think(0.5);
    if (prompt.canRon) return const ReactAction.ron();

    final view = _view;
    if (view == null) return const ReactAction.pass();
    final me = view.players[view.youSeat];
    final hand = List<int>.from(view.hand);
    final meldCount = me.melds.length;
    final tile = prompt.tile;

    // 他家の脅威がいて押せる手でなければ鳴かない(降り)
    final threats = _threats(view);
    if (threats.isNotEmpty) {
      final shanten = calcShanten(toCounts(hand), meldCount: meldCount);
      if (!_shouldPush(shanten, hand, view)) {
        return const ReactAction.pass();
      }
    }

    final isYakuhai =
        yakuhaiHan(
          tile,
          windTile(view.seatWind(view.youSeat)),
          windTile(view.roundWind),
        ) >
        0;
    final menzen = me.melds.every((m) => m.keepsConcealed);
    final before = calcShanten(toCounts(hand), meldCount: meldCount);
    final kind = Tile.normalize(tile);
    // 手の価値(ドラ+赤)。_handValue の門前ボーナスは鳴きの判断では数えない
    final value = _handValue(hand, view) - (menzen ? 1 : 0);
    bool ok(int after, {required bool yakuhai}) => callPolicy.shouldCall(
      yakuhai: yakuhai,
      menzen: menzen,
      before: before,
      after: after,
      handValue: value,
      threat: threats.isNotEmpty,
    );

    if (prompt.canPon) {
      final rest = _removeOneOfKind(_removeOneOfKind(hand, kind), kind);
      // ポン後は打牌して13-3n枚に戻るので、打牌込みで最良を評価
      final after = _bestShantenAfterDiscard(rest, meldCount + 1);
      if (ok(after, yakuhai: isYakuhai)) return const ReactAction.pon();
    }
    // チーは最もシャンテンが進む形を選ぶ
    List<int>? bestOpt;
    var bestAfter = 99;
    for (final opt in prompt.chiOptions) {
      final rest = _removeOneOfKind(_removeOneOfKind(hand, opt[0]), opt[1]);
      final after = _bestShantenAfterDiscard(rest, meldCount + 1);
      if (after < bestAfter) {
        bestAfter = after;
        bestOpt = opt;
      }
    }
    if (bestOpt != null && ok(bestAfter, yakuhai: false)) {
      return ReactAction.chi(bestOpt);
    }
    return const ReactAction.pass();
  }

  /// 押し引きの対象にする他家の脅威。守備アドバイスの脅威判定を共有し、
  /// リーチと警戒レベル(2)の鳴き(染め手2副露・ドラさらし等)だけを見る。
  /// 注意レベル(1)の鳴きで降りるのは弱気すぎるので対象にしない。
  List<ThreatInfo> _threats(GameView? view) {
    if (view == null) return const [];
    return [
      for (final t in buildThreats(view))
        if (t.level >= 2) t,
    ];
  }

  /// 押すかどうかは [policy] に委ねる(聴牌なら押し、以下は手の価値と打牌の安全度)
  bool _shouldPush(
    int shanten,
    List<int> hand,
    GameView view, {
    int attackRisk = 0,
  }) => policy.shouldPush(
    shanten: shanten,
    handValue: _handValue(hand, view),
    attackRisk: attackRisk,
  );

  /// 手の価値の概算(ドラ+赤+門前ならリーチ分1翻)
  int _handValue(List<int> hand, GameView view) {
    final all = List<int>.from(hand);
    for (final m in view.players[view.youSeat].melds) {
      all.addAll(m.tiles);
    }
    var value = countDora(all, view.doraIndicators);
    value += all.where(Tile.isRed).length;
    final menzen = view.players[view.youSeat].melds.every(
      (m) => m.keepsConcealed,
    );
    if (menzen) value += 1;
    return value;
  }

  /// 降り: 最も安全な牌を切る。安全度は守備アドバイスと同じ threatRisk
  /// (リーチは現物・スジ、鳴き脅威は色読み込み)で全脅威の最小値。
  int _chooseSafeDiscard(
    List<int> hand,
    List<int> forbidden,
    List<ThreatInfo> threats,
    GameView view,
  ) {
    final candidates = hand
        .toSet()
        .where((t) => !forbidden.contains(Tile.normalize(t)))
        .toList();
    if (candidates.isEmpty) return hand.first;
    var best = candidates.first;
    var bestScore = -1;
    var bestJunk = -99;
    for (final t in candidates) {
      var score = 999;
      for (final threat in threats) {
        final s = threatRisk(view, hand, Tile.normalize(t), threat);
        if (s < score) score = s;
      }
      final junk = _junkScore(t);
      if (score > bestScore || (score == bestScore && junk > bestJunk)) {
        bestScore = score;
        bestJunk = junk;
        best = t;
      }
    }
    return best;
  }

  /// 指定牌種を1枚除いたコピーを返す
  List<int> _removeOneOfKind(List<int> hand, int kind) {
    final copy = List<int>.from(hand);
    var idx = copy.indexOf(kind);
    if (idx < 0) idx = copy.indexWhere((t) => Tile.normalize(t) == kind);
    if (idx >= 0) copy.removeAt(idx);
    return copy;
  }

  /// 14-3n枚の手から最良の打牌を選ぶ。
  /// シャンテン小 → ウケ大 → くっつき見込み小 → 残す価値小 → 不要牌らしさ大
  /// の順で比較する(後半3つはウケ同率のタイブレーク。赤グローと同じ基準)。
  int _chooseDiscard(List<int> hand, int meldCount, List<int> forbidden) {
    final candidates = hand
        .toSet()
        .where((t) => !forbidden.contains(Tile.normalize(t)))
        .toList();
    if (candidates.isEmpty) return hand.first;

    final view = _view;
    final countsAll = toCounts(hand);
    var bestTile = candidates.first;
    List<int>? bestScore;

    for (final t in candidates) {
      final rest = List<int>.from(hand)..remove(t);
      final counts = toCounts(rest);
      final shanten = calcShanten(counts, meldCount: meldCount);
      var ukeire = 0;
      if (bestScore == null || shanten <= bestScore[0]) {
        // 受け入れ枚数(シャンテンが進む牌の残り枚数合計)。
        // 計算はウケ表示(advisor.ukeireMap)と共有する。
        ukeire = ukeireMap(
          counts,
          meldCount: meldCount,
          shanten: shanten,
          remainingOf: (k) => _remainingOf(k, hand),
        ).values.fold(0, (a, b) => a + b);
      }
      final kind = Tile.normalize(t);
      final score = [
        shanten,
        -ukeire,
        view == null ? 0 : stickPotential(view, hand, kind),
        view == null ? 0 : keepTileValue(view, countsAll, kind, t),
        -_junkScore(t),
      ];
      if (bestScore == null || _lexLess(score, bestScore)) {
        bestScore = score;
        bestTile = t;
      }
    }
    return bestTile;
  }

  /// 辞書式比較(小さいほど良いスコア列)
  bool _lexLess(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return false;
  }

  /// 3n+2枚から1枚切った時の最小シャンテン
  int _bestShantenAfterDiscard(List<int> hand, int meldCount) =>
      bestShantenAfterDiscard(hand, meldCount: meldCount);

  /// 打牌後の受け入れ枚数(シャンテンが進む牌の残り枚数合計)
  int _ukeireAfter(List<int> hand, int meldCount, int tile) {
    final rest = List<int>.from(hand)..remove(tile);
    final counts = toCounts(rest);
    final shanten = calcShanten(counts, meldCount: meldCount);
    return ukeireMap(
      counts,
      meldCount: meldCount,
      shanten: shanten,
      remainingOf: (k) => _remainingOf(k, hand),
    ).values.fold(0, (a, b) => a + b);
  }

  /// 見えている範囲での残り枚数
  int _remainingOf(int kind, List<int> myHand) =>
      remainingOf(kind, _view, myHand);

  /// 不要牌らしさ(高いほど切りやすい): 孤立字牌 > 端牌 > 中張牌 > 赤
  int _junkScore(int t) {
    if (Tile.isRed(t)) return -1; // 赤はドラなので温存
    if (Tile.isHonor(t)) return 3;
    final n = Tile.number(t);
    if (n == 1 || n == 9) return 2;
    if (n == 2 || n == 8) return 1;
    return 0;
  }
}
