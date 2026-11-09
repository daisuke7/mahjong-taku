import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/yaku.dart';
import 'package:mahjong_taku/ui/widgets/result_overlay.dart';
import 'package:mahjong_taku/ui/widgets/tile_widget.dart';

import 'hand_test.dart' show tiles;

GameStats _stats(List<double> points) => GameStats(
  points: points,
  wins: const [2, 1, 0, 1],
  riichis: const [1, 2, 0, 0],
  dealIns: const [0, 1, 2, 0],
);

GameView _viewWith(HandResult result) {
  final players = List.generate(
    4,
    (i) => PlayerView(
      name: 'P$i',
      isCpu: false,
      connected: true,
      riichi: false,
      handCount: 13,
      melds: const [],
      discards: const [],
    ),
  );
  return GameView(
    youSeat: 0,
    dealer: 0,
    roundWind: 0,
    kyoku: 1,
    honba: 0,
    riichiSticks: 0,
    wallRemaining: 30,
    currentSeat: -1,
    scores: const [25000, 25000, 25000, 25000],
    doraIndicators: tiles('1m'),
    hand: const [],
    players: players,
    phase: 'handEnd',
    handResult: result,
    currentStats: GameStats.zero(),
  );
}

void main() {
  testWidgets('和了表示: 和了牌は牌姿から分離して右端に表示される', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final hand = tiles('234567m234p34566s'); // 14枚(和了牌5s込み)
    final winTile = tiles('5s')[0];
    final result = HandResult(
      type: 'win',
      wins: [
        WinInfo(
          seat: 1,
          fromSeat: -1,
          winTile: winTile,
          score: const WinScore(
            yaku: [YakuItem('平和', 1)],
            han: 1,
            fu: 20,
            yakuman: 0,
          ),
          points: 700,
          label: '',
          hand: hand,
          melds: const [],
        ),
      ],
      scoreChanges: const [0, 700, -300, -200],
      scores: const [25000, 25700, 24700, 24800],
      dealerContinues: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              HandResultOverlay(
                view: _viewWith(result),
                acked: false,
                onAdvance: () {},
              ),
            ],
          ),
        ),
      ),
    );

    // 牌姿13枚 + 分離された和了牌1枚 + ドラ等はなし
    final tileWidgets = tester
        .widgetList<TileWidget>(find.byType(TileWidget))
        .toList();
    expect(tileWidgets.length, 14);

    // 分離された和了牌(ハイライト付き)はちょうど1枚で、和了牌そのもの
    final highlighted = tileWidgets.where((t) => t.highlighted).toList();
    expect(highlighted.length, 1);
    expect(highlighted.single.tile, winTile);

    // ハイライト牌が一番右に配置されている
    final winFinder = find.byWidgetPredicate(
      (w) => w is TileWidget && w.highlighted,
    );
    final winX = tester.getTopLeft(winFinder).dx;
    for (final t in find.byType(TileWidget).evaluate()) {
      expect(
        tester.getTopLeft(find.byWidget(t.widget)).dx,
        lessThanOrEqualTo(winX),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('流局: 聴牌者は牌姿(手牌+副露)、ノーテンは牌姿を出さない', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 席1が聴牌(手牌10枚 + 白ポン)、席3が聴牌(手牌13枚・門前)、席0/2はノーテン
    final players = [
      for (var i = 0; i < 4; i++)
        PlayerView(
          name: 'P$i',
          isCpu: false,
          connected: true,
          riichi: false,
          handCount: 13,
          melds: i == 1
              ? [
                  const Meld(
                    type: MeldType.pon,
                    tiles: [31, 31, 31],
                    fromSeat: 2,
                    calledTile: 31,
                  ), // 白ポン
                ]
              : const [],
          discards: const [],
        ),
    ];
    final result = HandResult(
      type: 'draw',
      tenpaiSeats: const [1, 3],
      scoreChanges: const [-1500, 1500, -1500, 1500],
      scores: const [23500, 26500, 23500, 26500],
      revealedHands: {
        1: tiles('234m567m99p12s'), // 10枚(白ポンで面子1)
        3: tiles('234567m234p3455s'), // 13枚
      },
      dealerContinues: false,
    );
    final view = GameView(
      youSeat: 0,
      dealer: 0,
      roundWind: 0,
      kyoku: 1,
      honba: 0,
      riichiSticks: 0,
      wallRemaining: 0,
      currentSeat: -1,
      scores: const [23500, 26500, 23500, 26500],
      doraIndicators: tiles('1m'),
      hand: const [],
      players: players,
      phase: 'handEnd',
      handResult: result,
      currentStats: GameStats.zero(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              HandResultOverlay(view: view, acked: false, onAdvance: () {}),
            ],
          ),
        ),
      ),
    );

    expect(find.text('流局'), findsOneWidget);
    // ノーテンの席は「ノーテン」表示、聴牌の席は牌姿(TileWidget)
    expect(find.text('ノーテン'), findsNWidgets(2)); // 席0・席2
    // 牌姿の牌数: 席1(手牌10 + 白ポン3) + 席3(手牌13) = 26枚
    // + ドラ表示は牌姿には含まれない
    final tileCount = tester
        .widgetList<TileWidget>(find.byType(TileWidget))
        .length;
    expect(tileCount, 10 + 3 + 13);
    expect(tester.takeException(), isNull);
  });

  testWidgets('流局: 聴牌牌姿の暗槓は両端が伏せ牌になる', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 席1が 2s暗槓 + 手牌10枚で聴牌
    final players = [
      for (var i = 0; i < 4; i++)
        PlayerView(
          name: 'P$i',
          isCpu: false,
          connected: true,
          riichi: false,
          handCount: 13,
          melds: i == 1
              ? [
                  const Meld(
                    type: MeldType.ankan,
                    tiles: [19, 19, 19, 19], // 2s暗槓
                    fromSeat: 1,
                    calledTile: 19,
                  ),
                ]
              : const [],
          discards: const [],
        ),
    ];
    final result = HandResult(
      type: 'draw',
      tenpaiSeats: const [1],
      scoreChanges: const [-1000, 3000, -1000, -1000],
      scores: const [24000, 28000, 24000, 24000],
      revealedHands: {1: tiles('234m567m99p11s')}, // 10枚
      dealerContinues: false,
    );
    final view = GameView(
      youSeat: 0,
      dealer: 0,
      roundWind: 0,
      kyoku: 1,
      honba: 0,
      riichiSticks: 0,
      wallRemaining: 0,
      currentSeat: -1,
      scores: const [24000, 28000, 24000, 24000],
      doraIndicators: tiles('1m'),
      hand: const [],
      players: players,
      phase: 'handEnd',
      handResult: result,
      currentStats: GameStats.zero(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              HandResultOverlay(view: view, acked: false, onAdvance: () {}),
            ],
          ),
        ),
      ),
    );

    final tileWidgets = tester
        .widgetList<TileWidget>(find.byType(TileWidget))
        .toList();
    // 暗槓は 伏せ(null) + 表 + 表 + 伏せ(null) → 伏せ牌が2枚出る
    final faceDown = tileWidgets.where((t) => t.tile == null).length;
    expect(faceDown, 2, reason: '暗槓の両端が伏せ牌になっていない');
    // 手牌10 + 暗槓4(うち伏せ2) = 14枚ぶんの TileWidget
    expect(tileWidgets.length, 10 + 4);
    expect(tester.takeException(), isNull);
  });

  test('ankanFaceUp: 赤牌があれば表向きの2枚に含める', () {
    // 5s暗槓(赤5s=36を1枚含む): [5s, 5s, 5s, 赤5s]
    final face = ankanFaceUp(const [22, 22, 22, 36]);
    expect(face.any(Tile.isRed), isTrue, reason: '赤5sが表向きに含まれる');
    // 赤が無い暗槓は普通に2枚
    final plain = ankanFaceUp(const [19, 19, 19, 19]);
    expect(plain.length, 2);
    expect(plain.any(Tile.isRed), isFalse);
  });

  testWidgets('流局: 暗槓の赤牌は表向きで見える', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 席1が 5s暗槓(赤5s入り) + 手牌10枚で聴牌
    final players = [
      for (var i = 0; i < 4; i++)
        PlayerView(
          name: 'P$i',
          isCpu: false,
          connected: true,
          riichi: false,
          handCount: 13,
          melds: i == 1
              ? [
                  const Meld(
                    type: MeldType.ankan,
                    tiles: [22, 22, 22, 36], // 5s暗槓・赤5s込み
                    fromSeat: 1,
                    calledTile: 22,
                  ),
                ]
              : const [],
          discards: const [],
        ),
    ];
    final result = HandResult(
      type: 'draw',
      tenpaiSeats: const [1],
      scoreChanges: const [-1000, 3000, -1000, -1000],
      scores: const [24000, 28000, 24000, 24000],
      revealedHands: {1: tiles('234m567m99p11s')},
      dealerContinues: false,
    );
    final view = GameView(
      youSeat: 0,
      dealer: 0,
      roundWind: 0,
      kyoku: 1,
      honba: 0,
      riichiSticks: 0,
      wallRemaining: 0,
      currentSeat: -1,
      scores: const [24000, 28000, 24000, 24000],
      doraIndicators: tiles('1m'),
      hand: const [],
      players: players,
      phase: 'handEnd',
      handResult: result,
      currentStats: GameStats.zero(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              HandResultOverlay(view: view, acked: false, onAdvance: () {}),
            ],
          ),
        ),
      ),
    );

    // 表向きの牌の中に赤5s(36)がある
    final faceUp = tester
        .widgetList<TileWidget>(find.byType(TileWidget))
        .where((t) => t.tile != null);
    expect(faceUp.any((t) => t.tile == 36), isTrue, reason: '暗槓の赤5sが表向きに出ていない');
    expect(tester.takeException(), isNull);
  });

  testWidgets('試合結果: スタッツ表と次の試合ボタンが表示される', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final base = _viewWith(
      const HandResult(
        type: 'draw',
        scoreChanges: [0, 0, 0, 0],
        scores: [42000, 30000, 18000, 10000],
        dealerContinues: false,
      ),
    );
    final view = GameView(
      youSeat: base.youSeat,
      dealer: 0,
      roundWind: 1,
      kyoku: 4,
      honba: 0,
      riichiSticks: 0,
      wallRemaining: 0,
      currentSeat: -1,
      scores: const [42000, 30000, 18000, 10000],
      doraIndicators: tiles('1m'),
      hand: const [],
      players: base.players,
      phase: 'gameEnd',
      gameResult: const GameResult(
        ranking: [0, 1, 2, 3],
        scores: [42000, 30000, 18000, 10000],
        points: [62.0, 10.0, -22.0, -50.0],
      ),
      history: [
        _stats(const [62.0, 10.0, -22.0, -50.0]),
      ],
      gameIndex: 1,
      currentStats: GameStats.zero(),
    );

    var nextPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              GameResultOverlay(
                view: view,
                isHost: true,
                onNextGame: () => nextPressed = true,
                onExit: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('第1試合 結果'), findsOneWidget);
    expect(find.text('ポイント'), findsOneWidget);
    expect(find.text('アガリ'), findsOneWidget);
    expect(find.text('リーチ'), findsOneWidget);
    expect(find.text('放銃'), findsOneWidget);
    expect(find.text('+62.0'), findsOneWidget);
    expect(find.text('▲50.0'), findsOneWidget);

    await tester.tap(find.text('次の試合へ'));
    expect(nextPressed, isTrue);
  });

  testWidgets('総合成績表: 試合ごとの行・対局中の行・合計、行タップでスタッツ', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final base = _viewWith(
      const HandResult(
        type: 'draw',
        scoreChanges: [0, 0, 0, 0],
        scores: [25000, 25000, 25000, 25000],
        dealerContinues: false,
      ),
    );
    final view = GameView(
      youSeat: 0,
      dealer: 0,
      roundWind: 0,
      kyoku: 2,
      honba: 0,
      riichiSticks: 0,
      wallRemaining: 40,
      currentSeat: 0,
      scores: const [26000, 25000, 25000, 24000],
      doraIndicators: tiles('1m'),
      hand: const [],
      players: base.players,
      phase: 'playing',
      history: [
        _stats(const [62.0, 10.0, -22.0, -50.0]),
        _stats(const [-30.0, 50.0, -15.0, -5.0]),
      ],
      gameIndex: 3,
      currentStats: _stats(const [17.0, 5.0, -5.0, -17.0]),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [ScoreboardOverlay(view: view, onClose: () {})],
          ),
        ),
      ),
    );

    // 終了2試合+対局中1試合+合計
    expect(find.text('第1試合'), findsOneWidget);
    expect(find.text('第2試合'), findsOneWidget);
    expect(find.text('第3試合(対局中)'), findsOneWidget);
    expect(find.text('合計'), findsOneWidget);
    // 合計 = 62-30+17 = +49.0 (P0列)
    expect(find.text('+49.0'), findsOneWidget);

    // 行タップでその試合のスタッツダイアログ
    await tester.tap(find.text('第1試合'));
    await tester.pumpAndSettle();
    expect(find.text('第1試合のゲームスタッツ'), findsOneWidget);
    expect(find.text('アガリ'), findsOneWidget);
  });
}
