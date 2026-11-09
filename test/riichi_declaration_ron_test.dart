import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';

/// Mリーグ:「リーチは、門前清（メンゼン）であればかける事ができ、
/// リーチ宣言牌に対してロンがなければ成立する。」
///
/// 宣言牌をロンされたらリーチは不成立。供託の1000点は出さないので、
/// 放銃者は放銃分しか失わず、和了者もその1000点を受け取らない。
///
/// 必ずリーチし、ビューも記録するCPU。通常のCpuAgentは押し引きを見て
/// リーチを見送るので、宣言牌ロンの場面になかなか到達しない。
class _AlwaysRiichiCpu extends CpuAgent {
  _AlwaysRiichiCpu({super.seed}) : super(thinkMillis: 0);

  final List<GameView> views = [];

  @override
  void onView(GameView view) {
    super.onView(view);
    views.add(view);
  }

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) async {
    if (prompt.riichiTiles.isNotEmpty) {
      return TurnAction.discard(prompt.riichiTiles.first, riichi: true);
    }
    return super.onTurn(prompt);
  }
}

void main() {
  test('リーチ宣言牌でロンされたらリーチ棒を出さない', () async {
    var checked = 0;

    for (final seed in [1, 2, 3, 5, 7, 11, 13, 42, 99, 123, 456, 777, 2024]) {
      final engine = GameEngine(
        config: const GameConfig(rounds: 2),
        names: const ['A', 'B', 'C', 'D'],
        isCpu: const [true, true, true, true],
        advanceDelayMs: 0,
        autoPlayDelayMs: 0,
        seed: seed,
      );
      final watcher = _AlwaysRiichiCpu(seed: seed * 10);
      engine.setAgent(0, watcher);
      for (var i = 1; i < 4; i++) {
        engine.setAgent(i, _AlwaysRiichiCpu(seed: seed * 10 + i));
      }
      await engine.run().timeout(const Duration(seconds: 120));

      // 局ごとの開始時スコアを覚えながら handEnd を探す
      var handKey = '';
      List<int> startScores = const [];
      GameView? lastPlaying;

      for (final v in watcher.views) {
        final key = '${v.roundWind}-${v.kyoku}-${v.honba}';
        if (v.phase == 'playing') {
          if (key != handKey) {
            handKey = key;
            startScores = List<int>.from(v.scores);
          }
          lastPlaying = v;
          continue;
        }
        if (v.phase != 'handEnd' || lastPlaying == null) continue;
        final r = v.handResult;
        if (r == null || r.type != 'win' || r.wins.isEmpty) continue;

        final win = r.wins.first;
        final loser = win.fromSeat;
        if (loser < 0) continue; // ツモは対象外

        // 放銃牌がリーチ宣言牌だったか(不成立にした時点で横向きを外すので、
        // ロン直前の playing ビューで見る)
        final river = lastPlaying.players[loser].discards;
        if (river.isEmpty) continue;
        if (!river.last.riichi || river.last.tile != win.winTile) continue;

        // --- ここが本題 ---
        // 局中に放銃者のスコアが動くのは「リーチ棒」と「精算」だけ。宣言牌を
        // ロンされた放銃者はこの局でリーチ棒を出していないはずなので、
        // 「開始時スコア + 精算 = 終了時スコア」が厳密に成り立つ。
        // 1000点を供託してしまっているとここが1000ズレる。
        // (和了者側は自分がリーチしている場合に正当な1000点を払っているので、
        //  同じ式は使えない)
        expect(
          startScores[loser] + r.scoreChanges[loser],
          r.scores[loser],
          reason:
              'seed=$seed 席$loser がリーチ棒1000点を余分に払っている '
              '(宣言牌をロンされたのでリーチは不成立)',
        );

        // 状態としてもリーチは付いていない
        expect(
          v.players[loser].riichi,
          isFalse,
          reason: 'seed=$seed 宣言牌をロンされたらリーチは成立しない',
        );
        expect(
          v.players[loser].discards.last.riichi,
          isFalse,
          reason: 'seed=$seed 不成立のリーチ宣言牌を横向きにしてはいけない',
        );
        checked++;
      }
    }

    expect(checked, greaterThan(0), reason: 'リーチ宣言牌ロンを一度も観測できず、検証になっていない');
  });
}
