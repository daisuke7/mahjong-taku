import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/ui/widgets/rank_table.dart';

// 自分(seat0)は子・本場/供託なしにして、必要手のラベルを予測可能にする
GameView _view(List<int> scores, {int you = 0}) => GameView(
  youSeat: you,
  dealer: 1,
  roundWind: 0,
  kyoku: 1,
  honba: 0,
  riichiSticks: 0,
  wallRemaining: 70,
  currentSeat: 0,
  phase: 'playing',
  players: [
    for (var i = 0; i < 4; i++)
      PlayerView(
        name: 'P$i',
        isCpu: i != you,
        connected: true,
        riichi: false,
        handCount: 13,
        melds: const [],
        discards: const [],
      ),
  ],
  hand: const [],
  scores: scores,
  doraIndicators: const [0],
  currentStats: GameStats.zero(),
);

void main() {
  testWidgets('順位表ダイアログ: 見出し・逆転手・自分の行を表示(実寸で例外なし)', (tester) async {
    tester.view.physicalSize = const Size(1334, 750);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 自分(seat0)が最下位
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RankTableDialog(view: _view([10000, 20000, 30000, 40000])),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('順位表 / 逆転の目安'), findsOneWidget);
    expect(find.text('逆転ツモ'), findsOneWidget);
    expect(find.text('逆転ロン'), findsOneWidget);
    // 上位相手への逆転手(ロン): 10000差=跳満, 20000差=三倍満, 30000差=役満
    expect(find.text('跳満'), findsWidgets);
    expect(find.text('役満'), findsWidgets);
    // 自分の行が示される
    expect(find.textContaining('(自分)'), findsOneWidget);
  });

  testWidgets('自分が1位なら逆転手は全て「—」', (tester) async {
    tester.view.physicalSize = const Size(1334, 750);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RankTableDialog(view: _view([40000, 30000, 20000, 10000])),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 跳満などの逆転手ラベルは出ない
    expect(find.text('跳満'), findsNothing);
    expect(find.text('役満'), findsNothing);
  });
}
