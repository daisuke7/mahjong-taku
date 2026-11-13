import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/session/local_session.dart';

/// ソロ対局の中断→[LocalSession.resume] による直接復帰(復帰ロビーを経由しない経路。
/// 通信対戦の無い Web ビルドが使う)。復帰後のビューが中断時点の局・点数・席順と一致し、
/// 自席が同じ名前のまま対局が続くことを見る。
void main() {
  test('LocalSession.resume は中断時点の局・点数・席順で再開する', () async {
    final session = LocalSession(
      playerName: 'テスト',
      config: const GameConfig(),
      cpuThinkMillis: 0,
      autoPlayDelayMs: 0,
      advanceDelayMs: 0,
      seed: 5,
    );
    // 何巡か進むまで待つ
    GameView? before;
    for (
      var i = 0;
      i < 200 && (before == null || before.wallRemaining > 60);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      before = session.latestView;
    }
    expect(before, isNotNull);
    final saved = await session.suspend();
    expect(saved, isNotNull);
    await session.dispose();

    final resumed = LocalSession.resume(
      saved!,
      cpuThinkMillis: 0,
      autoPlayDelayMs: 0,
      advanceDelayMs: 0,
      seed: 5,
    );
    GameView? after;
    for (var i = 0; i < 200 && after == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      after = resumed.latestView;
    }
    expect(after, isNotNull);
    expect(
      after!.players.map((p) => p.name),
      before!.players.map((p) => p.name),
    );
    expect(after.youSeat, before.youSeat);
    expect(after.players[after.youSeat].name, 'テスト');
    expect(after.roundWind, before.roundWind);
    expect(after.kyoku, before.kyoku);
    expect(after.honba, before.honba);
    expect(after.scores, before.scores);
    expect(resumed.isHost, isTrue);
    await resumed.dispose();
  });
}
