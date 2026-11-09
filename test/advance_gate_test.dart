import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';

/// ビューを記録するダミーエージェント(人間/CPU両用)
class _RecordingAgent implements PlayerAgent {
  final List<GameView> views = [];
  @override
  void onView(GameView view) => views.add(view);
  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) async =>
      TurnAction.discard(prompt.drawnTile ?? 0);
  @override
  Future<ReactAction> onReact(ReactPrompt prompt) async =>
      const ReactAction.pass();
  @override
  void onEmote(int seat, int emoji) {}
}

GameView _lastHandEnd(_RecordingAgent a) =>
    a.views.lastWhere((v) => v.phase == 'handEnd');

void main() {
  test('全員CPUなら3秒後に自動で次の局へ進む', () {
    fakeAsync((async) {
      final engine = GameEngine(
        config: const GameConfig(rounds: 1),
        names: const ['A', 'B', 'C', 'D'],
        isCpu: const [true, true, true, true],
        autoPlayDelayMs: 0,
        advanceDelayMs: 3000,
        seed: 3,
      );
      final observer = _RecordingAgent();
      engine.setAgent(0, observer);
      for (var i = 1; i < 4; i++) {
        engine.setAgent(i, observer);
      }
      unawaited(engine.run());
      async.flushMicrotasks();

      // 最初の局が終わって handEnd で止まっている
      expect(observer.views.any((v) => v.phase == 'handEnd'), isTrue);
      final endedGames = observer.views
          .where((v) => v.phase == 'handEnd')
          .map((v) => '${v.roundWind}-${v.kyoku}-${v.honba}')
          .toSet();
      final before = endedGames.length;

      // 2秒ではまだ進まない(3秒待ち)
      async.elapse(const Duration(seconds: 2));
      // 3秒経過で自動遷移 → 次の局が進む
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();

      final after = observer.views
          .where((v) => v.phase == 'handEnd')
          .map((v) => '${v.roundWind}-${v.kyoku}-${v.honba}')
          .toSet();
      expect(after.length, greaterThan(before), reason: '3秒後に自動で次の局へ進むはず');
    });
  });

  test('人間がいる場合は全員ACKするまで進まない', () {
    fakeAsync((async) {
      // 席0,1が人間、2,3がCPU
      final engine = GameEngine(
        config: const GameConfig(rounds: 1),
        names: const ['H0', 'H1', 'C2', 'C3'],
        isCpu: const [false, false, true, true],
        autoPlayDelayMs: 0,
        advanceDelayMs: 3000,
        seed: 5,
      );
      final a0 = _RecordingAgent();
      final a1 = _RecordingAgent();
      final cpu = _RecordingAgent();
      engine.setAgent(0, a0);
      engine.setAgent(1, a1);
      engine.setAgent(2, cpu);
      engine.setAgent(3, cpu);
      unawaited(engine.run());
      async.flushMicrotasks();

      String key(_RecordingAgent a) {
        final v = _lastHandEnd(a);
        return '${v.roundWind}-${v.kyoku}-${v.honba}';
      }

      final firstEnd = key(a0);

      // 3秒待っても人間がいるので自動遷移しない
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      // 席の並びは場決めで変わるので、人間席を名前で特定
      final humanSeats = [
        for (var s = 0; s < 4; s++)
          if (_lastHandEnd(a0).players[s].name == 'H0' ||
              _lastHandEnd(a0).players[s].name == 'H1')
            s,
      ];
      expect(humanSeats.length, 2);
      expect(key(a0), firstEnd, reason: '人間未確認なら進まない');

      // 片方だけACK → まだ進まない
      engine.ackAdvance(humanSeats.first);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(key(a0), firstEnd, reason: '全員確認していないので進まない');

      // 両方ACK → 次の局へ進む
      engine.ackAdvance(humanSeats[1]);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(key(a0), isNot(firstEnd), reason: '全員確認で次の局へ');
    });
  });

  test('確認待ち中に人間が切断(CPU化)したら残りだけで進む', () {
    fakeAsync((async) {
      final engine = GameEngine(
        config: const GameConfig(rounds: 1),
        names: const ['H0', 'C1', 'C2', 'C3'],
        isCpu: const [false, true, true, true],
        autoPlayDelayMs: 0,
        advanceDelayMs: 3000,
        seed: 9,
      );
      final a = _RecordingAgent();
      for (var i = 0; i < 4; i++) {
        engine.setAgent(i, a);
      }
      unawaited(engine.run());
      async.flushMicrotasks();

      final v = _lastHandEnd(a);
      final humanSeat = [
        for (var s = 0; s < 4; s++)
          if (v.players[s].name == 'H0') s,
      ].first;
      final firstEnd = '${v.roundWind}-${v.kyoku}-${v.honba}';

      // 人間未確認で待機中
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      final v2 = _lastHandEnd(a);
      expect('${v2.roundWind}-${v2.kyoku}-${v2.honba}', firstEnd);

      // 人間が切断→CPU代打(isCpu=trueに)
      engine.setAgent(humanSeat, a, isCpu: true, connected: false);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      final v3 = _lastHandEnd(a);
      expect(
        '${v3.roundWind}-${v3.kyoku}-${v3.honba}',
        isNot(firstEnd),
        reason: '人間が居なくなれば残りで進む',
      );
    });
  });
}
