import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/emotes.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';

class _RecAgent implements PlayerAgent {
  final List<(int, int)> emotes = [];
  @override
  void onView(GameView view) {}
  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) async =>
      TurnAction.discard(prompt.drawnTile ?? 0);
  @override
  Future<ReactAction> onReact(ReactPrompt prompt) async =>
      const ReactAction.pass();
  @override
  void onEmote(int seat, int emoji) => emotes.add((seat, emoji));
}

void main() {
  test('castEmote は全席に配信される', () {
    final engine = GameEngine(
      config: const GameConfig(rounds: 1),
      names: const ['A', 'B', 'C', 'D'],
      isCpu: const [true, true, true, true],
      advanceDelayMs: 0,
    );
    final agents = List.generate(4, (_) => _RecAgent());
    for (var i = 0; i < 4; i++) {
      engine.setAgent(i, agents[i]);
    }

    engine.castEmote(2, 5);

    // 全員が「席2が絵文字5を出した」を受信
    for (final a in agents) {
      expect(a.emotes, contains((2, 5)));
    }
  });

  test('絵文字は9種類(iOS/Android共通の表情)', () {
    expect(emoteFaces.length, 9);
    expect(emoteCount, 9);
    // 各要素が空でない
    for (final f in emoteFaces) {
      expect(f.isNotEmpty, isTrue);
    }
  });
}
