import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/ui/widgets/table_widgets.dart';
import 'package:mahjong_taku/ui/widgets/tile_widget.dart';

/// 手出し/ツモ切りの「消えてから河に置かれる」演出。
/// 見た目の細部はテストしづらいので、例外なく描け、新しい打牌で
/// アニメが起動する(ゴースト/ポップインが出る)ことを確認する。
void main() {
  // Center を使うと Align(center) が混ざるので topLeft で包む
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  );

  HiddenHand hand(int order, bool tsumogiri) => HiddenHand(
    count: 13,
    meldCount: 0,
    tileWidth: 20,
    animOrder: order,
    tsumogiri: tsumogiri,
  );

  testWidgets('河の最新牌は他家(animateNewest)でポップイン演出が入る', (tester) async {
    await tester.pumpWidget(
      wrap(
        DiscardRiver(
          discards: const [
            DiscardInfo(0, order: 0),
            DiscardInfo(1, tsumogiri: true, order: 1),
          ],
          tileWidth: 20,
          animateNewest: true,
        ),
      ),
    );
    // 最新牌はアニメ(TweenAnimationBuilder)で包まれる
    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('自分(animateNewest=false)の河は演出なし', (tester) async {
    await tester.pumpWidget(
      wrap(
        const DiscardRiver(discards: [DiscardInfo(0, order: 0)], tileWidth: 20),
      ),
    );
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HiddenHand: 新しい打牌で消える演出が再生される', (tester) async {
    // 初期状態(order=0)。ゴーストは出ない(value=1)。
    await tester.pumpWidget(
      wrap(
        const HiddenHand(
          count: 13,
          meldCount: 0,
          tileWidth: 20,
          animOrder: 0,
          tsumogiri: false,
        ),
      ),
    );
    // 裏牌13枚 + ゴースト用の重ねレイヤはあるが不可視(SizedBox.shrink)
    final before = tester
        .widgetList<TileWidget>(find.byType(TileWidget))
        .length;
    expect(before, 13, reason: '初期はゴーストを出さない');

    // 新しい打牌(order=1・手出し)→ 消える演出が起動
    await tester.pumpWidget(
      wrap(
        const HiddenHand(
          count: 13,
          meldCount: 0,
          tileWidth: 20,
          animOrder: 1,
          tsumogiri: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 30));
    // 演出中はゴースト牌が1枚増えて見える
    final during = tester
        .widgetList<TileWidget>(find.byType(TileWidget))
        .length;
    expect(during, 14, reason: '消える牌のゴーストが重なる');

    // 演出が終われば元に戻る
    await tester.pumpAndSettle();
    final after = tester.widgetList<TileWidget>(find.byType(TileWidget)).length;
    expect(after, 13);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ツモ切りのゴーストは右端に出る', (tester) async {
    await tester.pumpWidget(wrap(hand(0, false))); // 初期
    await tester.pumpWidget(wrap(hand(1, true))); // ツモ切り発生
    await tester.pump(const Duration(milliseconds: 20));
    final aligns = tester
        .widgetList<Align>(find.byType(Align))
        .map((a) => a.alignment)
        .toList();
    expect(aligns, contains(Alignment.centerRight));
    expect(aligns, isNot(contains(Alignment.center)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('手出しのゴーストは中央に出る', (tester) async {
    await tester.pumpWidget(wrap(hand(0, false))); // 初期
    await tester.pumpWidget(wrap(hand(1, false))); // 手出し発生
    await tester.pump(const Duration(milliseconds: 20));
    final aligns = tester
        .widgetList<Align>(find.byType(Align))
        .map((a) => a.alignment)
        .toList();
    expect(aligns, contains(Alignment.center));
    expect(aligns, isNot(contains(Alignment.centerRight)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
