import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/resume.dart';

/// 試合中断・復帰(牌譜リプレイ方式)。
/// エンジンは決定的なので、「局開始時の山 + 記録済みアクション」を
/// 流し込めば中断時点と完全に同じ状態に到達するはずである。

/// 最後のビューを観測するCPU
class _ObservingCpu extends CpuAgent {
  GameView? lastView;
  _ObservingCpu({super.seed}) : super(thinkMillis: 1);

  @override
  void onView(GameView view) {
    lastView = view;
    super.onView(view);
  }
}

/// 一切応答しないエージェント(リプレイの到達点で完全に停止させる)
class _BlockingAgent implements PlayerAgent {
  GameView? lastView;
  int prompts = 0;

  @override
  void onView(GameView view) => lastView = view;

  @override
  void onEmote(int seat, int emoji) {}

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) {
    prompts++;
    return Completer<TurnAction>().future;
  }

  @override
  Future<ReactAction> onReact(ReactPrompt prompt) {
    prompts++;
    return Completer<ReactAction>().future;
  }
}

int _totalDiscards(GameView v) =>
    v.players.fold(0, (n, p) => n + p.discards.length);

/// ビューの比較用JSON。イベント通し番号は試合をまたいで増えるため
/// (復帰後は局内の分しか再現されない)比較から除く。
Map<String, dynamic> _comparable(GameView v) =>
    Map<String, dynamic>.from(v.toJson())..remove('event');

void main() {
  test('中断→復帰リプレイで全席のビューが中断時点と完全一致する', () async {
    for (final seed in [3, 11, 27]) {
      final engine = GameEngine(
        config: const GameConfig(rounds: 1),
        names: const ['A', 'B', 'C', 'D'],
        isCpu: const [true, true, true, true],
        advanceDelayMs: 0,
        autoPlayDelayMs: 0,
        seed: seed,
      );
      final observers = List.generate(4, (i) => _ObservingCpu(seed: seed + i));
      for (var i = 0; i < 4; i++) {
        engine.setAgent(i, observers[i]);
      }
      unawaited(engine.run());

      // 対局中盤(捨て牌がある程度出た局の途中)まで進める
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final v = observers[0].lastView;
        if (v != null && v.phase == 'playing' && _totalDiscards(v) >= 6) break;
      }
      final data = engine.suspendAndCapture();
      // 比較基準は中断した瞬間のビュー(名前 → JSON)。ここで即座に固定する
      final originals = {
        for (final o in observers)
          o.lastView!.players[o.lastView!.youSeat].name: jsonEncode(
            _comparable(o.lastView!),
          ),
      };

      // JSONで往復(実際の保存経路と同じ)
      final restored = ResumeData.fromJson(
        (jsonDecode(jsonEncode(data.toJson())) as Map).cast<String, dynamic>(),
      );
      expect(restored.actions.length, data.actions.length);
      expect(restored.wall, data.wall);

      // 応答しないエージェントで復帰 → リプレイは記録済みアクションを
      // 使い切った時点(=中断時点)で必ず停止する
      final resumed = GameEngine.fromResume(
        restored,
        advanceDelayMs: 0,
        autoPlayDelayMs: 0,
      );
      final blockers = List.generate(4, (_) => _BlockingAgent());
      for (var i = 0; i < 4; i++) {
        resumed.setAgent(i, blockers[i]);
      }
      unawaited(resumed.run());

      // リプレイ完了(キューが空)+ライブの応答待ちに入るまで待つ
      while (resumed.isReplaying || blockers.every((b) => b.prompts == 0)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 場決めで元エンジンのエージェントは席を移動しているので、
      // 座席インデックスではなく名前でビューを対応付ける
      for (var i = 0; i < 4; i++) {
        final v = blockers[i].lastView!;
        final name = v.players[v.youSeat].name;
        expect(
          jsonEncode(_comparable(v)),
          originals[name],
          reason: 'seed=$seed $name のビューが中断時点と一致しない',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('復帰後そのまま最後まで完走し点数が保存される(2回中断しても良い)', () async {
    final engine = GameEngine(
      config: const GameConfig(rounds: 1),
      names: const ['A', 'B', 'C', 'D'],
      isCpu: const [true, true, true, true],
      advanceDelayMs: 0,
      autoPlayDelayMs: 0,
      seed: 8,
    );
    final observer = _ObservingCpu(seed: 80);
    engine.setAgent(0, observer);
    for (var i = 1; i < 4; i++) {
      engine.setAgent(i, CpuAgent(seed: 80 + i, thinkMillis: 1));
    }
    unawaited(engine.run());
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final v = observer.lastView;
      if (v != null && v.phase == 'playing' && _totalDiscards(v) >= 4) break;
    }
    final first = engine.suspendAndCapture();

    // 1回目の復帰 → 少し進めてもう一度中断(記録が引き継がれること)
    final resumed1 = GameEngine.fromResume(
      ResumeData.fromJson(first.toJson()),
      advanceDelayMs: 0,
      autoPlayDelayMs: 0,
      seed: 1,
    );
    final ob1 = _ObservingCpu(seed: 91);
    resumed1.setAgent(0, ob1);
    for (var i = 1; i < 4; i++) {
      resumed1.setAgent(i, CpuAgent(seed: 91 + i, thinkMillis: 1));
    }
    unawaited(resumed1.run());
    final before = _totalDiscards(observer.lastView!);
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final v = ob1.lastView;
      // 中断時点より確実に先へ進んでから2回目の中断
      if (v != null &&
          !resumed1.isReplaying &&
          (v.phase != 'playing' || _totalDiscards(v) >= before + 3)) {
        break;
      }
    }
    final second = resumed1.suspendAndCapture();

    // 2回目の復帰 → 完走
    final resumed2 = GameEngine.fromResume(
      ResumeData.fromJson(second.toJson()),
      advanceDelayMs: 0,
      autoPlayDelayMs: 0,
      seed: 2,
    );
    final ob2 = _ObservingCpu(seed: 95);
    resumed2.setAgent(0, ob2);
    for (var i = 1; i < 4; i++) {
      resumed2.setAgent(i, CpuAgent(seed: 95 + i, thinkMillis: 1));
    }
    await resumed2.run().timeout(const Duration(seconds: 120));

    expect(
      resumed2.scores.reduce((a, b) => a + b),
      100000,
      reason: '復帰後も点数総和が保存される',
    );
    expect(ob2.lastView?.phase, 'gameEnd');
    expect(ob2.lastView?.gameResult, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('局結果表示中の中断: 復帰リプレイで同じ局結果に到達する', () async {
    // 席0を人間扱いにして局終了確認で必ず止める(確認待ちの間に中断する)
    final engine = GameEngine(
      config: const GameConfig(rounds: 1),
      names: const ['人間', 'B', 'C', 'D'],
      isCpu: const [false, true, true, true],
      advanceDelayMs: 0,
      autoPlayDelayMs: 0,
      seed: 21,
    );
    final human = _ObservingCpu(seed: 210); // 中身はCPUだが席は人間扱い
    engine.setAgent(0, human);
    for (var i = 1; i < 4; i++) {
      engine.setAgent(i, CpuAgent(seed: 210 + i, thinkMillis: 1));
    }
    unawaited(engine.run());
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (human.lastView?.phase == 'handEnd') break;
    }
    final atHandEnd = human.lastView!;
    final data = engine.suspendAndCapture();

    final resumed = GameEngine.fromResume(
      ResumeData.fromJson(data.toJson()),
      advanceDelayMs: 0,
      autoPlayDelayMs: 0,
      seed: 3,
    );
    final human2 = _ObservingCpu(seed: 300);
    resumed.setAgent(resumed.seatOfName('人間'), human2, connected: true);
    for (var i = 0; i < 4; i++) {
      if (resumed.seatOfName('人間') == i) continue;
      resumed.setAgent(i, CpuAgent(seed: 300 + i, thinkMillis: 1));
    }
    unawaited(resumed.run());
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (human2.lastView?.phase == 'handEnd') break;
    }

    // 同じ局結果(点数変動・和了情報)が再現される
    expect(
      jsonEncode(human2.lastView!.handResult!.toJson()),
      jsonEncode(atHandEnd.handResult!.toJson()),
    );
    expect(human2.lastView!.scores, atHandEnd.scores);
    expect(human2.lastView!.kyoku, atHandEnd.kyoku);
    expect(human2.lastView!.honba, atHandEnd.honba);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('中断後はエンジンが進行しない(捨て牌が増えない)', () async {
    final engine = GameEngine(
      config: const GameConfig(rounds: 1),
      names: const ['A', 'B', 'C', 'D'],
      isCpu: const [true, true, true, true],
      advanceDelayMs: 0,
      autoPlayDelayMs: 0,
      seed: 14,
    );
    final observer = _ObservingCpu(seed: 140);
    engine.setAgent(0, observer);
    for (var i = 1; i < 4; i++) {
      engine.setAgent(i, CpuAgent(seed: 140 + i, thinkMillis: 1));
    }
    unawaited(engine.run());
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final v = observer.lastView;
      if (v != null && v.phase == 'playing' && _totalDiscards(v) >= 3) break;
    }
    engine.suspendAndCapture();
    final frozen = jsonEncode(_comparable(observer.lastView!));
    // CPUの応答が残っていても、以後は状態が変化しない
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      jsonEncode(_comparable(observer.lastView!)),
      frozen,
      reason: '中断後に対局が進んでいる',
    );
  });
}
