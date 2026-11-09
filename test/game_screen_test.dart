import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/session/local_session.dart';
import 'package:mahjong_taku/ui/game_screen.dart';
import 'package:mahjong_taku/ui/widgets/tile_widget.dart';

void main() {
  testWidgets('ソロ対局: 画面が表示され打牌して進行する', (tester) async {
    tester.view.physicalSize = const Size(1600, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final session = LocalSession(
      playerName: 'テスト',
      config: const GameConfig(rounds: 1),
      cpuThinkMillis: 0,
      autoPlayDelayMs: 0,
      seed: 7,
    );
    await tester.pumpWidget(MaterialApp(home: GameScreen(session: session)));
    await tester.pump();

    expect(find.textContaining('東1局'), findsOneWidget);

    // 場決めがランダムなので、自分の手番が来るまで進める
    for (var i = 0; i < 300 && session.activeTurnPrompt == null; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(session.activeTurnPrompt, isNotNull);
    await tester.pump();

    // ドラ表示1枚 + 手牌13枚 + ツモ牌1枚
    final faceTiles = find.byWidgetPredicate(
      (w) => w is TileWidget && w.tile != null,
    );
    expect(faceTiles.evaluate().length, greaterThanOrEqualTo(15));

    // ツモ切り(最後に描画される牌 = ツモ牌)。
    // CPUは思考0msなので、pump後には自分の河に牌が出ているはず
    await tester.tap(faceTiles.last);
    await tester.pump();
    final you = session.latestView!.youSeat;
    expect(
      session.latestView!.players[you].discards,
      isNotEmpty,
      reason: 'タップした牌が河に出ていない',
    );

    // CPUの手番を進める。自分へのプロンプトはツモ切り/パスで返す
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      final view = session.latestView;
      if (view != null && view.phase != 'playing') {
        session.advance();
        continue;
      }
      final turn = session.activeTurnPrompt;
      if (turn != null) {
        session.sendTurn(
          TurnAction.discard(turn.drawnTile ?? view!.hand.first),
        );
        continue;
      }
      final react = session.activeReactPrompt;
      if (react != null) {
        session.sendReact(const ReactAction.pass());
      }
    }

    // 河に牌が出て対局が進行している
    final view = session.latestView!;
    final totalDiscards = view.players.fold(0, (a, p) => a + p.discards.length);
    expect(totalDiscards, greaterThan(4));

    // 画面破棄でセッションも破棄される(タイマー残りなし)
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
