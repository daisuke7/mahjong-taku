import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';

/// 顔文字は「エージェントの現在の席」で配信されなければならない。
///
/// 場決め(`_randomizeSeating`)はエージェントを試合ごとに別の席へ動かす。
/// セットアップ時の席インデックスを固定で使うと、放銃した席と別の位置に
/// 顔文字が出てしまう(実機で確認されたバグ)。`castEmoteFrom(agent, ...)` は
/// 席をエージェントの同一性から都度引き直す。
///
/// 検証する不変条件: **castEmoteFrom(cpu) が配信する席 == その cpu の現在の
/// view.youSeat。** これが崩れると顔文字が別席に出る。

/// 自分の現在の席(youSeat)を覚えておくCPU
class _SeatAwareCpu extends CpuAgent {
  _SeatAwareCpu({super.seed}) : super(thinkMillis: 0);
  int youSeat = -1;
  @override
  void onView(GameView v) {
    youSeat = v.youSeat;
    super.onView(v); // 放銃時はここで castEmote が発火しうる
  }
}

/// 配信された(席, 絵文字)を記録するだけの受信者
class _Sink implements PlayerAgent {
  final List<int> seats = [];
  @override
  void onEmote(int seat, int emoji) => seats.add(seat);
  @override
  void onView(GameView v) {}
  @override
  Future<TurnAction> onTurn(TurnPrompt p) async =>
      TurnAction.discard(p.drawnTile ?? 0);
  @override
  Future<ReactAction> onReact(ReactPrompt p) async =>
      p.canRon ? const ReactAction.ron() : const ReactAction.pass();
}

void main() {
  test('castEmoteFrom は「そのエージェントの現在の席」で配信する', () async {
    var casts = 0;
    final mismatches = <String>[];

    for (final seed in [1, 2, 3, 5, 7, 11, 13, 17, 23, 42, 99, 123]) {
      final engine = GameEngine(
        config: const GameConfig(rounds: 2),
        names: const ['A', 'B', 'C', 'D'],
        isCpu: const [true, true, true, true],
        advanceDelayMs: 0,
        autoPlayDelayMs: 0,
        seed: seed,
      );
      final sink = _Sink();
      engine.setAgent(0, sink);
      for (var i = 1; i < 4; i++) {
        final cpu = _SeatAwareCpu(seed: seed * 10 + i);
        cpu.castEmote = (e) {
          // castEmoteFrom は同期で全席の onEmote を呼ぶので、直前に sink を
          // クリアしておけば、配信された席がこの1回で確定する。
          sink.seats.clear();
          engine.castEmoteFrom(cpu, e);
          casts++;
          // 配信された席が、この CPU の現在の席(youSeat)と一致するはず
          if (sink.seats.isEmpty || sink.seats.first != cpu.youSeat) {
            mismatches.add('cpuの席=${cpu.youSeat} だが配信席=${sink.seats}');
          }
        };
        engine.setAgent(i, cpu);
      }
      await engine.run().timeout(const Duration(seconds: 120));
    }

    expect(casts, greaterThan(0), reason: '顔文字を一度も観測できていない');
    expect(mismatches, isEmpty, reason: mismatches.take(5).join(' / '));
  });
}
