import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/ui/widgets/table_widgets.dart';
import 'package:mahjong_taku/ui/widgets/tile_widget.dart';

import 'hand_test.dart' show tiles;

GameView _viewWithDora(List<int> indicators) {
  final players = List.generate(
    4,
    (i) => const PlayerView(
      name: 'P',
      isCpu: true,
      connected: true,
      riichi: false,
      handCount: 13,
      melds: [],
      discards: [],
    ),
  );
  return GameView(
    youSeat: 0,
    dealer: 0,
    roundWind: 0,
    kyoku: 1,
    honba: 0,
    riichiSticks: 0,
    wallRemaining: 40,
    currentSeat: 0,
    scores: const [25000, 25000, 25000, 25000],
    doraIndicators: indicators,
    hand: const [],
    players: players,
    phase: 'playing',
    currentStats: GameStats.zero(),
  );
}

void main() {
  group('ドラ牌種の算出', () {
    test('ドラ表示牌の次がドラ牌種になる', () {
      // 表示牌1m→ドラ2m、表示牌9p→ドラ1p
      final kinds = TileWidget.doraKindsFrom([tiles('1m')[0], tiles('9p')[0]]);
      expect(kinds, contains(tiles('2m')[0]));
      expect(kinds, contains(tiles('1p')[0]));
    });

    test('カンで表示牌自体がドラになるケース', () {
      // 表示牌5m(ドラ6m)+カンドラ表示牌4m(ドラ5m)
      // → ドラ牌種は{6m,5m}。最初の表示牌5m自身がドラになる
      final kinds = TileWidget.doraKindsFrom([tiles('5m')[0], tiles('4m')[0]]);
      expect(kinds, containsAll([tiles('6m')[0], tiles('5m')[0]]));
      // 表示牌5mがドラ牌種に含まれる(=中央パネルで光るべき)
      expect(kinds.contains(tiles('5m')[0]), isTrue);
    });

    test('赤牌はドラ指定がなくても光る対象', () {
      // 赤5萬(red5m)を持つTileWidgetはdoraフラグ無しでも脈動する
      // (内部でTile.isRedを見るため)。ここではフラグ計算の独立性を確認。
      expect(Tile.isRed(Tile.red5m), isTrue);
      // 赤5mの正規化は通常5m。ドラ牌種集合に5mが含まれれば通常5mも光る
      final kinds = TileWidget.doraKindsFrom([tiles('4m')[0]]); // ドラ5m
      expect(kinds, contains(tiles('5m')[0]));
      expect(Tile.normalize(Tile.red5m), tiles('5m')[0]);
    });
  });

  testWidgets('ドラ牌・赤牌はTileWidgetがStatefulに構築される(例外なし)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              TileWidget(tile: tiles('2m')[0], width: 30, dora: true),
              TileWidget(tile: Tile.red5s, width: 30),
              TileWidget(tile: tiles('3p')[0], width: 30),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 900));
    expect(tester.takeException(), isNull);
    // 破棄してもTicker解放で例外が出ない
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('中央パネル: ドラになった表示牌はdoraフラグ付きで描画される', (tester) async {
    // 表示牌5m(ドラ6m)+カンドラ表示牌4m(ドラ5m) → 5m表示牌自身がドラ
    final view = _viewWithDora([tiles('5m')[0], tiles('4m')[0]]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: CenterPanel(view: view, scale: 300)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 表示牌5mのTileWidgetがdora:trueで描画される
    final indicator5m = tester
        .widgetList<TileWidget>(find.byType(TileWidget))
        .where((w) => w.tile == tiles('5m')[0]);
    expect(indicator5m, isNotEmpty);
    expect(
      indicator5m.every((w) => w.dora),
      isTrue,
      reason: '表示牌5mはドラ牌なので光る指定になる',
    );

    // 表示牌4m(自身はドラでない)はdora:false
    final indicator4m = tester
        .widgetList<TileWidget>(find.byType(TileWidget))
        .where((w) => w.tile == tiles('4m')[0]);
    expect(indicator4m.every((w) => !w.dora), isTrue, reason: '表示牌4mはドラ牌ではない');

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
