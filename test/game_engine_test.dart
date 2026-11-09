import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';

/// 終局を観測するためのCPUラッパー
class _ObservingCpu extends CpuAgent {
  GameView? firstDealView; // 配牌後の最初のビュー
  GameView? lastView;

  _ObservingCpu({super.seed}) : super(thinkMillis: 0);

  @override
  void onView(GameView view) {
    if (view.hand.isNotEmpty) firstDealView ??= view;
    lastView = view;
    super.onView(view);
  }
}

void main() {
  test('CPU4人で東風戦が最後まで完走し点数が保存される', () async {
    final seatOrders = <String>{};
    for (final seed in [1, 7, 42]) {
      final engine = GameEngine(
        config: const GameConfig(rounds: 1),
        names: const ['A', 'B', 'C', 'D'],
        isCpu: const [true, true, true, true],
        advanceDelayMs: 0,
        autoPlayDelayMs: 0,
        seed: seed,
      );
      final observers = List.generate(
        4,
        (i) => _ObservingCpu(seed: seed * 10 + i),
      );
      for (var i = 0; i < 4; i++) {
        engine.setAgent(i, observers[i]);
      }
      await engine.run().timeout(const Duration(seconds: 120));

      // 点数の総和は常に 100000(供託はトップに払い戻し済み)
      expect(
        engine.scores.reduce((a, b) => a + b),
        100000,
        reason: 'seed=$seed で点数が保存されていない',
      );

      // 全員が終局ビューを受け取っている
      for (final o in observers) {
        expect(o.lastView?.phase, 'gameEnd', reason: 'seed=$seed');
        expect(o.lastView?.gameResult, isNotNull);
      }

      // Mリーグ式順位点はゼロサム
      final points = observers.first.lastView!.gameResult!.points;
      expect(
        points.reduce((a, b) => a + b),
        closeTo(0, 0.001),
        reason: 'seed=$seed',
      );

      // ビューのシリアライズが往復できる
      final v = observers.first.lastView!;
      final restored = GameView.fromJson(v.toJson());
      expect(restored.scores, v.scores);
      expect(restored.gameResult!.ranking, v.gameResult!.ranking);

      seatOrders.add(
        observers.first.firstDealView!.players.map((p) => p.name).join(),
      );
    }
    // 場決めがランダム(シードにより席の並びが変わる)
    expect(
      seatOrders.length,
      greaterThan(1),
      reason: '場決めが固定になっている: $seatOrders',
    );
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('連戦: 2試合の履歴とスタッツが記録される', () async {
    var decisions = 0;
    final engine = GameEngine(
      config: const GameConfig(rounds: 1),
      names: const ['A', 'B', 'C', 'D'],
      isCpu: const [true, true, true, true],
      advanceDelayMs: 0,
      // 1回だけ「次の試合へ」、その後終了
      waitNextGame: () async => ++decisions == 1,
      autoPlayDelayMs: 0,
      seed: 5,
    );
    final observer = _ObservingCpu(seed: 50);
    engine.setAgent(0, observer);
    for (var i = 1; i < 4; i++) {
      engine.setAgent(i, CpuAgent(seed: 50 + i, thinkMillis: 0));
    }
    await engine.run().timeout(const Duration(seconds: 240));

    final view = observer.lastView!;
    expect(view.history.length, 2);
    expect(view.gameIndex, 2);
    for (final g in view.history) {
      // 順位点はゼロサム
      expect(g.points.reduce((a, b) => a + b), closeTo(0, 0.001));
      // アガリ・リーチ・放銃は非負で、放銃はアガリより多くならない
      expect(g.wins.every((w) => w >= 0), isTrue);
      expect(
        g.dealIns.reduce((a, b) => a + b),
        lessThanOrEqualTo(g.wins.reduce((a, b) => a + b)),
      );
    }
    // 2試合目も点数保存(供託返却済みで総和10万)
    expect(engine.scores.reduce((a, b) => a + b), 100000);

    // GameStats のシリアライズ往復
    final restored = GameStats.fromJson(view.history.first.toJson());
    expect(restored.points, view.history.first.points);
    expect(restored.riichis, view.history.first.riichis);

    // メンバー列は1試合目の席順で固定(2試合目に席が変わっても不変)
    final game1Names = observer.firstDealView!.players
        .map((p) => p.name)
        .toList();
    expect(view.memberNameList, game1Names);
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('半荘戦も完走する', () async {
    final engine = GameEngine(
      config: const GameConfig(rounds: 2),
      names: const ['A', 'B', 'C', 'D'],
      isCpu: const [true, true, true, true],
      advanceDelayMs: 0,
      autoPlayDelayMs: 0,
      seed: 99,
    );
    for (var i = 0; i < 4; i++) {
      engine.setAgent(i, CpuAgent(seed: i, thinkMillis: 0));
    }
    await engine.run().timeout(const Duration(seconds: 240));
    expect(engine.scores.reduce((a, b) => a + b), 100000);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
