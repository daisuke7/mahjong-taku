import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/ui/widgets/tile_widget.dart';

/// TileWidget の状態表示(ツモ=緑点滅 / 喰い替え禁止=薄い灰色 / 現物=青点滅)。
/// 描画色の細部までは検証しづらいので、各状態で例外なく描け、脈動アニメの
/// 有無(ValueListenableBuilder の有無)が状態に一致することを確認する。
void main() {
  Future<void> pump(WidgetTester tester, TileWidget tile) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: tile)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('通常牌は脈動アニメを持たない', (tester) async {
    await pump(tester, const TileWidget(tile: 0, width: 40));
    expect(find.byType(ValueListenableBuilder<double>), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ツモ牌(drawn)は脈動する', (tester) async {
    await pump(tester, const TileWidget(tile: 0, width: 40, drawn: true));
    expect(find.byType(ValueListenableBuilder<double>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('現物(glowSafe)は脈動する', (tester) async {
    await pump(tester, const TileWidget(tile: 0, width: 40, glowSafe: true));
    expect(find.byType(ValueListenableBuilder<double>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ドラ(dora)は脈動する', (tester) async {
    await pump(tester, const TileWidget(tile: 0, width: 40, dora: true));
    expect(find.byType(ValueListenableBuilder<double>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('喰い替え禁止(forbidden)は脈動しない(静止)', (tester) async {
    await pump(tester, const TileWidget(tile: 0, width: 40, forbidden: true));
    expect(find.byType(ValueListenableBuilder<double>), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ツモ牌が現物かつドラでも例外なく描ける', (tester) async {
    await pump(
      tester,
      const TileWidget(
        tile: 0,
        width: 40,
        drawn: true,
        glowSafe: true,
        dora: true,
      ),
    );
    // 脈動が要る状態は1つの ValueListenableBuilder でまとめて描く
    expect(find.byType(ValueListenableBuilder<double>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
