import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';

/// Mリーグ規定の要旨: リーチ後に和了牌を見逃すことはできるが、以後はフリテンで
/// ツモ和了しかできない。同巡内に自分の和了牌が出てロンしなかった場合も、その巡は
/// フリテン(同巡内フリテン)になる。
///
/// 搶槓(加槓へのロン)を見逃した場合も同じ。加槓牌は `_applyKan` で副露面子へ移り
/// **どの河にも残らない**ため、見逃した時点でフリテンを立てないと捨て牌フリテンでも
/// 捕捉できず、後から同じ牌でロンできてしまう。
///
/// 搶槓を見逃し、ポン・加槓を積極的に行うCPU。
/// 通常の [CpuAgent] は `canRon` なら必ずロンするのでこの場面に到達しない。
/// ポンを挟まないと加槓が発生せず、加槓が無いと搶槓も無い。
class _ChankanPassCpu extends CpuAgent {
  _ChankanPassCpu({super.seed}) : super(thinkMillis: 0);

  /// 搶槓を見逃した回数(テストの母数確認用)
  int passedChankan = 0;

  /// 見逃したのにフリテンにならなかった場面(=バグ)
  final List<String> leaks = [];

  int? _passedKind;

  @override
  Future<ReactAction> onReact(ReactPrompt prompt) async {
    if (prompt.isChankan && prompt.canRon) {
      passedChankan++;
      _passedKind = Tile.normalize(prompt.tile);
      return const ReactAction.pass(); // 搶槓を見逃す
    }
    if (prompt.canPon) return const ReactAction.pon();
    return super.onReact(prompt);
  }

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) async {
    if (prompt.kakanKinds.isNotEmpty) {
      return TurnAction.kakan(prompt.kakanKinds.first);
    }
    return super.onTurn(prompt);
  }

  @override
  void onView(GameView view) {
    super.onView(view);
    final kind = _passedKind;
    if (kind == null || view.phase != 'playing') return;
    // 見逃した牌がまだ待ちに残っているなら、フリテンでなければならない
    if (view.myWaits.contains(kind) && !view.myFuriten) {
      leaks.add('牌種$kind を搶槓で見逃したのにフリテンになっていない');
    }
    _passedKind = null;
  }
}

void main() {
  // 搶槓は「ポン → 4枚目をツモって加槓 → 他家がその牌で聴牌」が必要で極めて稀。
  // 120シード探索して、実際に搶槓の見逃しが発生するシードだけを使う
  // (全員がポン・加槓を積極的にしても40半荘で3回程度しか起きない)。
  const seedsWithChankan = [17, 19, 31, 45, 62, 74, 78, 99, 118];

  test('搶槓を見逃したらフリテンになる', () async {
    var total = 0;

    for (final seed in seedsWithChankan) {
      final engine = GameEngine(
        config: const GameConfig(rounds: 2),
        names: const ['A', 'B', 'C', 'D'],
        isCpu: const [true, true, true, true],
        advanceDelayMs: 0,
        autoPlayDelayMs: 0,
        seed: seed,
      );
      final cpus = List.generate(
        4,
        (i) => _ChankanPassCpu(seed: seed * 10 + i),
      );
      for (var i = 0; i < 4; i++) {
        engine.setAgent(i, cpus[i]);
      }
      await engine.run().timeout(const Duration(seconds: 120));

      for (final cpu in cpus) {
        total += cpu.passedChankan;
        expect(cpu.leaks, isEmpty, reason: 'seed=$seed ${cpu.leaks}');
      }
    }

    expect(
      total,
      greaterThan(0),
      reason:
          '搶槓の見逃しを一度も観測できず、検証になっていない'
          '(CPUの打ち筋が変わってシードが当たらなくなった可能性)',
    );
  });
}
