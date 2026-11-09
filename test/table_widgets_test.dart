import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/ui/widgets/table_widgets.dart';
import 'package:mahjong_taku/ui/widgets/tile_widget.dart';

void main() {
  testWidgets('河は4段以上でもあふれない', (tester) async {
    // 24枚(4段)+ リーチ宣言牌
    final discards = [
      for (var i = 0; i < 24; i++) DiscardInfo(i % 34, riichi: i == 7),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: DiscardRiver(discards: discards, tileWidth: 24)),
        ),
      ),
    );
    // オーバーフロー例外が出ないこと
    expect(tester.takeException(), isNull);
  });

  group('副露の倒し方向', () {
    Future<List<TileWidget>> pumpMeld(WidgetTester tester, Meld meld) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MeldRow(melds: [meld], tileWidth: 24, ownerSeat: 0),
          ),
        ),
      );
      return tester.widgetList<TileWidget>(find.byType(TileWidget)).toList();
    }

    testWidgets('上家からのチーは鳴いた牌が左端で横向き(2s,1s,3s)', (tester) async {
      // 1s,3s持ちで上家(席3)から2sをチー
      final widgets = await pumpMeld(
        tester,
        const Meld(
          type: MeldType.chi,
          tiles: [18, 19, 20], // 1s,2s,3s
          fromSeat: 3,
          calledTile: 19,
        ),
      );
      expect(widgets.map((w) => w.tile).toList(), [19, 18, 20]); // 2s,1s,3s
      expect(widgets.map((w) => w.sideways).toList(), [true, false, false]);
    });

    testWidgets('対面からのポンは中央が横向き', (tester) async {
      final widgets = await pumpMeld(
        tester,
        const Meld(
          type: MeldType.pon,
          tiles: [4, 4, 4], // 5m
          fromSeat: 2,
          calledTile: 4,
        ),
      );
      expect(widgets.map((w) => w.sideways).toList(), [false, true, false]);
    });

    testWidgets('下家からのポンは右端が横向き', (tester) async {
      final widgets = await pumpMeld(
        tester,
        const Meld(
          type: MeldType.pon,
          tiles: [4, 4, 4],
          fromSeat: 1,
          calledTile: 4,
        ),
      );
      expect(widgets.map((w) => w.sideways).toList(), [false, false, true]);
    });

    testWidgets('大明槓も方向に従う(上家=左端)', (tester) async {
      final widgets = await pumpMeld(
        tester,
        const Meld(
          type: MeldType.minkan,
          tiles: [8, 8, 8, 8], // 9m
          fromSeat: 3,
          calledTile: 8,
        ),
      );
      expect(widgets.length, 4);
      expect(widgets.map((w) => w.sideways).toList(), [
        true,
        false,
        false,
        false,
      ]);
    });

    testWidgets('加槓は横向き2枚が重なる', (tester) async {
      final widgets = await pumpMeld(
        tester,
        const Meld(
          type: MeldType.kakan,
          tiles: [13, 13, Tile.red5p, 13], // 5p加槓(赤含む)
          fromSeat: 2,
          calledTile: 13,
        ),
      );
      expect(widgets.length, 4);
      expect(widgets.where((w) => w.sideways).length, 2);
    });
  });

  testWidgets('鳴かれた牌は河に表示されない', (tester) async {
    final discards = [
      const DiscardInfo(0),
      const DiscardInfo(1, calledAway: true),
      const DiscardInfo(2),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DiscardRiver(discards: discards, tileWidth: 24)),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
