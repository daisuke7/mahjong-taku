import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/ui/widgets/advice_dialog.dart';

import 'hand_test.dart' show tiles;

void main() {
  testWidgets('アドバイスダイアログが攻撃・守備を表示する', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final players = List.generate(
      4,
      (i) => PlayerView(
        name: 'P$i',
        isCpu: true,
        connected: true,
        riichi: i == 2,
        handCount: 13,
        melds: const [],
        discards: i == 2 ? [DiscardInfo(tiles('1m')[0])] : const [],
      ),
    );
    final view = GameView(
      youSeat: 0,
      dealer: 0,
      roundWind: 0,
      kyoku: 1,
      honba: 0,
      riichiSticks: 0,
      wallRemaining: 40,
      currentSeat: 0,
      scores: const [25000, 25000, 25000, 25000],
      doraIndicators: tiles('3m'),
      hand: tiles('234567m88p45699s'),
      drawnTile: tiles('1z')[0],
      players: players,
      phase: 'playing',
      currentStats: GameStats.zero(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showAdviceDialog(ctx, view),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('アドバイス'), findsOneWidget);
    expect(find.text('攻撃'), findsOneWidget);
    expect(find.text('守備'), findsOneWidget);
    expect(find.text('テンパイ!'), findsOneWidget);
    expect(find.textContaining('P2: リーチ'), findsOneWidget);
    // 役候補の推奨打牌(切→ + 牌)が表示される
    expect(find.text('切→'), findsWidgets);
    // 聴牌時は待ちと残り枚数が出る
    expect(find.text('待ち'), findsWidgets);
    expect(find.textContaining('残り'), findsWidgets);
    expect(find.textContaining('枚'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
