import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/ui/widgets/table_widgets.dart';
import 'package:mahjong_taku/ui/widgets/tile_widget.dart';

// iPhone SE 横(1334x750)相当。riverW は game_screen と同じ h/24。
const double _w = 1334;
const double _h = 750;
const double _riverW = _h / 24;
// 手牌の高さ(handW*aspect)と、中央セットに使える縦幅
const double _handH = _w / 16.2 * TileWidget.aspect;
const double _availMidH = _h - (_handH + 12);

PlayerView _player({
  required int handCount,
  required List<Meld> melds,
  required int discardCount,
}) {
  return PlayerView(
    name: 'P',
    isCpu: true,
    connected: true,
    riichi: false,
    handCount: handCount,
    melds: melds,
    discards: List.generate(discardCount, (i) => DiscardInfo(i % 34)),
  );
}

Meld _pon(int t, int from) =>
    Meld(type: MeldType.pon, tiles: [t, t, t], fromSeat: from, calledTile: t);

Meld _kakan(int t, int from) => Meld(
  type: MeldType.kakan,
  tiles: [t, t, t, t],
  fromSeat: from,
  calledTile: t,
);

SeatArea _seat(
  int seat,
  List<Meld> melds,
  int discards, {
  required bool showHidden,
}) => SeatArea(
  player: _player(
    handCount: 13 - melds.length * 3,
    melds: melds,
    discardCount: discards,
  ),
  seat: seat,
  riverTileWidth: _riverW,
  showHiddenHand: showHidden,
);

/// 十分に広い領域で自然サイズを測る(画面クランプを避ける)
Future<Size> _measure(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(4000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull, reason: 'レイアウトでオーバーフロー例外');
  return tester.getSize(find.byType(SeatArea).first);
}

Future<double> _panelHeight(WidgetTester tester) async {
  tester.view.physicalSize = const Size(4000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final scale = _w * 0.36 < _h * 0.58 ? _w * 0.36 : _h * 0.58;
  final view = GameView(
    youSeat: 0,
    dealer: 0,
    roundWind: 0,
    kyoku: 1,
    honba: 1,
    riichiSticks: 1,
    wallRemaining: 70,
    currentSeat: 0,
    phase: 'playing',
    players: List.generate(
      4,
      (i) => _player(handCount: 13, melds: const [], discardCount: 0),
    ),
    hand: const [],
    scores: const [25000, 25000, 25000, 25000],
    doraIndicators: const [0],
    currentStats: GameStats.zero(),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: CenterPanel(view: view, scale: scale),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.getSize(find.byType(CenterPanel)).height;
}

void main() {
  testWidgets('中央パネル: 局・残数・供託(本場)を表示し、はみ出さない', (tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final view = GameView(
      youSeat: 0,
      dealer: 0,
      roundWind: 0,
      kyoku: 3,
      honba: 2,
      riichiSticks: 2, // 供託あり
      wallRemaining: 42,
      currentSeat: 0,
      phase: 'playing',
      players: List.generate(
        4,
        (i) => _player(handCount: 13, melds: const [], discardCount: 0),
      ),
      hand: const [],
      scores: const [25000, 25000, 25000, 25000],
      doraIndicators: const [0],
      currentStats: GameStats.zero(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: CenterPanel(view: view, scale: 440)),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('東3局'), findsOneWidget); // 局数(大きく中央・独立行)
    expect(find.text('2本場'), findsOneWidget); // 本場(小さく2行目・0でも表示)
    expect(find.text('残 42'), findsOneWidget); // 残り牌(右下)
    expect(find.text('2'), findsWidgets); // 供託本数
  });

  testWidgets('中央パネル: 0本場でも本場を表示する', (tester) async {
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final view = GameView(
      youSeat: 0,
      dealer: 0,
      roundWind: 0,
      kyoku: 1,
      honba: 0,
      riichiSticks: 0,
      wallRemaining: 70,
      currentSeat: 0,
      phase: 'playing',
      players: List.generate(
        4,
        (i) => _player(handCount: 13, melds: const [], discardCount: 0),
      ),
      hand: const [],
      scores: const [25000, 25000, 25000, 25000],
      doraIndicators: const [0],
      currentStats: GameStats.zero(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: CenterPanel(view: view, scale: 440)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('東1局'), findsOneWidget);
    expect(find.text('0本場'), findsOneWidget);
  });

  testWidgets('自分の副露は河の右に出て、ブロックの高さは河のみ(縦に増えない)', (tester) async {
    final hNoMeld = (await _measure(
      tester,
      _seat(0, const [], 18, showHidden: false),
    )).height;

    for (final n in [1, 2, 3, 4]) {
      final melds = [for (var i = 0; i < n; i++) _pon(i * 9, (i % 3) + 1)];
      final size = await _measure(
        tester,
        _seat(0, melds, 18, showHidden: false),
      );
      // 副露は河の右(横)に出るので、ブロックの高さは河のみ(手牌と重ならない)
      expect(
        size.height,
        closeTo(hNoMeld, 1.0),
        reason: '$n副露でブロック高さが増加(手牌と重なる恐れ)',
      );
    }
  });

  testWidgets('自分4副露でも下家(右)の河ゾーンに侵入しない幅に収まる', (tester) async {
    // 左右の河ゾーン(回転した相手ブロックの高さ=横幅)
    final sideZone = (await _measure(
      tester,
      _seat(1, const [], 18, showHidden: true),
    )).height;
    final availMidW = _w - 2 * sideZone;

    final fourMeld = [_pon(0, 1), _pon(9, 2), _pon(18, 3), _pon(27, 1)];
    final size = await _measure(
      tester,
      _seat(0, fourMeld, 18, showHidden: false),
    );
    expect(
      size.width,
      lessThanOrEqualTo(availMidW),
      reason: '4副露ブロック幅 ${size.width} が中央幅 $availMidW を超える(下家の河と重なる)',
    );
  });

  testWidgets('対面の副露(加槓含む)でもセットが縦に収まる', (tester) async {
    final panelH = await _panelHeight(tester);
    final hSelf = (await _measure(
      tester,
      _seat(0, const [], 18, showHidden: false),
    )).height;

    // 対面が加槓2つ(横向き2枚を縦に重ねるので背が高い)+ 3段の河
    final oppKakan = [_kakan(0, 1), _kakan(9, 2)];
    final hOpp = (await _measure(
      tester,
      _seat(2, oppKakan, 18, showHidden: true),
    )).height;

    final setH = hOpp + panelH + hSelf + _riverW * 0.5;
    expect(
      setH,
      lessThan(_availMidH),
      reason: '対面加槓時にセット($setH)が中央領域($_availMidH)に収まらない',
    );
  });
}
