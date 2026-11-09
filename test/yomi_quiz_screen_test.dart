import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/ui/widgets/tile_widget.dart';
import 'package:mahjong_taku/ui/yomi_quiz_screen.dart';

import 'yomi_quiz_fixtures.dart';

void main() {
  testWidgets('解答 → 待ち牌選択 → 答え合わせ → 次の問題の流れ', (tester) async {
    // iPhone SE 横画面と同サイズ。あふれ(RenderFlex overflow)は
    // テストでは例外になるので、最小想定サイズで通ることが回帰チェックになる
    await tester.binding.setSurfaceSize(const Size(667, 375));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final p = buildQuizProblem(standardRyukyokuEvents())!;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: YomiQuizScreen(debugProblems: [p]),
      ),
    );
    await tester.pumpAndSettle();

    // 出典は解答前から右上に見えている(当時の映像を見に行けるように)
    expect(find.text('テスト'), findsOneWidget);
    // 4家とも未回答で答え合わせは押せない
    // (席0はリーチ者なので3択なし・待ち当てのみ)
    expect(find.text('タップで解答'), findsNWidgets(3));
    expect(find.text('リーチ: 待ちは?'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '答え合わせ'))
          .onPressed,
      isNull,
    );

    Future<void> pickState(String chip, String state) async {
      await tester.tap(find.text(chip));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(state),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> pickWaits(List<int> kinds) async {
      for (final k in kinds) {
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byWidgetPredicate(
              (w) => w is TileWidget && w.tile == k,
            ),
          ),
        );
        await tester.pump();
      }
      await tester.tap(find.text('決定'));
      await tester.pumpAndSettle();
    }

    // 席0(西 A): リーチ者 → タップで待ち牌選択に直行。東/白でピタリ正解
    await tester.tap(find.text('西 A'));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing); // 3択は出ない
    await pickWaits([Tile.east, Tile.haku]);
    // 席1(北 B): イーシャンテン → 正解
    await pickState('北 B', 'イーシャンテン');
    // 席2(東 C): テンパイ(待ち 中) → 不正解
    await pickState('東 C', 'テンパイ');
    await pickWaits([Tile.chun]);
    // 席3(南 D): テンパイ・待ち 1s のみ → 状態正解・待ちは不完全
    await pickState('南 D', 'テンパイ');
    await pickWaits([Tile.parse('1s').single]);

    // 答え合わせ
    await tester.tap(find.widgetWithText(FilledButton, '答え合わせ'));
    // 開いた手牌にドラ(2m)が含まれ脈動アニメが回り続けるので settle は使わない
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('答え合わせ テスト'), findsOneWidget);
    // テスト出題(DB由来でない)ではビューア起動ボタンは出ない
    expect(find.text('ビューアで再生'), findsNothing);

    // 4行の結果枠は同一サイズに揃っている
    final rowSizes = [
      for (var s = 0; s < 4; s++)
        tester.getSize(find.byKey(ValueKey('resultRow$s'))),
    ];
    expect(rowSizes.toSet(), hasLength(1));
    expect(find.textContaining('◎'), findsOneWidget); // 席0のみピタリ
    expect(find.textContaining('✕'), findsOneWidget); // 席2のみ不正解
    expect(find.textContaining('正解: テンパイ'), findsNWidgets(2));
    expect(find.textContaining('正解: イーシャンテン'), findsOneWidget);
    expect(find.textContaining('正解: それ以外'), findsOneWidget);

    // 卓を確認 → 全員の手牌が開かれている(裏向きだった手牌が実牌になる)
    await tester.ensureVisible(find.text('卓を確認'));
    await tester.tap(find.text('卓を確認'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('答え合わせ テスト'), findsNothing); // オーバーレイが閉じた
    expect(find.text('結果'), findsOneWidget);

    // 次の問題 → 解答がリセットされる
    await tester.tap(find.widgetWithText(FilledButton, '次の問題'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('タップで解答'), findsNWidgets(3));
    expect(find.text('リーチ: 待ちは?'), findsOneWidget);
  });

  testWidgets('巻き戻し出題では次のツモ番を表示する', (tester) async {
    await tester.binding.setSurfaceSize(const Size(667, 375));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final p = buildQuizProblem(noRiichiRyukyokuEvents(), cutoffDiscards: 1)!;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: YomiQuizScreen(debugProblems: [p]),
      ),
    );
    await tester.pumpAndSettle();

    // 最終打牌者(席0)の下家 = 席1(北 B)
    expect(find.text('次のツモ: 北 B'), findsOneWidget);
  });
}
