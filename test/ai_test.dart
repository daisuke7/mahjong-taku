import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'hand_test.dart' show tiles;

/// テスト用のビューを組み立てる。seat1がリーチ者
GameView _view({
  required List<int> hand,
  int? drawn,
  bool opponentRiichi = true,
  List<int> riichiRiver = const [],
  List<int> doraIndicators = const [],
}) {
  final players = List.generate(
    4,
    (i) => PlayerView(
      name: 'P$i',
      isCpu: true,
      connected: true,
      riichi: i == 1 && opponentRiichi,
      handCount: 13,
      melds: const [],
      discards: i == 1
          ? [for (final t in riichiRiver) DiscardInfo(t)]
          : const [],
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
    doraIndicators: doraIndicators,
    hand: hand,
    drawnTile: drawn,
    players: players,
    phase: 'playing',
    currentStats: GameStats.zero(),
  );
}

void main() {
  group('CPUの押し引き(他家リーチ時)', () {
    // 2シャンテン以上の手: 234m 567m 88p 45s 99s + 1z ではなく
    // バラバラ手(現物9sあり)
    test('ノーテンなら降りて現物を切る', () async {
      final cpu = CpuAgent(seed: 1, thinkMillis: 0);
      final hand = tiles('2358m2358p358s99s'); // 13枚・大体3シャンテン
      final drawn = tiles('1z')[0];
      cpu.onView(
        _view(
          hand: hand,
          drawn: drawn,
          riichiRiver: tiles('9s'), // 9sが現物
        ),
      );
      final action = await cpu.onTurn(TurnPrompt(drawnTile: drawn));
      expect(action.type, 'discard');
      expect(Tile.normalize(action.tile), tiles('9s')[0], reason: '現物の9sを切るべき');
    });

    test('イーシャンテンでも安手なら降りる', () async {
      final cpu = CpuAgent(seed: 1, thinkMillis: 0);
      // 234m 567m 88p 45s 99s 1z + 2z(ツモ): 字牌切りでイーシャンテン。ドラなし
      final hand = tiles('234567m88p4599s1z');
      final drawn = tiles('2z')[0];
      cpu.onView(
        _view(
          hand: hand,
          drawn: drawn,
          riichiRiver: tiles('9s'),
          doraIndicators: tiles('5z'), // ドラは發(手にない)
        ),
      );
      final action = await cpu.onTurn(TurnPrompt(drawnTile: drawn));
      // 押すなら字牌を切るはずだが、降りるので現物9s
      expect(
        Tile.normalize(action.tile),
        tiles('9s')[0],
        reason: '安手のイーシャンテンは降りるべき',
      );
    });

    test('イーシャンテンで高打点なら押す', () async {
      final cpu = CpuAgent(seed: 1, thinkMillis: 0);
      // 同じイーシャンテンだが赤5s+ドラ4m+ドラ5s(手に各1枚)で価値4
      // (赤1+ドラ2+門前1)。押し引き方針の既定は価値4以上で押す(PushPolicy)
      final hand = tiles('234567m88p4099s1z'); // 4s + 赤5s
      final drawn = tiles('2z')[0];
      cpu.onView(
        _view(
          hand: hand,
          drawn: drawn,
          riichiRiver: tiles('9s'),
          doraIndicators: tiles('3m4s'), // ドラは4mと5s
        ),
      );
      final action = await cpu.onTurn(TurnPrompt(drawnTile: drawn));
      // 押すので不要な字牌切りになるはず(現物9sではない)
      expect(Tile.isHonor(action.tile), isTrue, reason: '高打点のイーシャンテンは押すべき');
    });

    test('聴牌ならリーチを打つ(押し)', () async {
      final cpu = CpuAgent(seed: 1, thinkMillis: 0);
      // 234m 567m 88p 456s 99s + 1z(ツモ) → 1z切りで聴牌
      final hand = tiles('234567m88p45699s');
      final drawn = tiles('1z')[0];
      cpu.onView(_view(hand: hand, drawn: drawn, riichiRiver: tiles('9s')));
      final action = await cpu.onTurn(
        TurnPrompt(drawnTile: drawn, riichiTiles: [drawn]),
      );
      expect(action.riichi, isTrue, reason: '聴牌なら押してリーチ');
    });

    test('リーチ者がいなければ通常打牌', () async {
      final cpu = CpuAgent(seed: 1, thinkMillis: 0);
      final hand = tiles('234567m88p4599s1z');
      final drawn = tiles('2z')[0];
      cpu.onView(_view(hand: hand, drawn: drawn, opponentRiichi: false));
      final action = await cpu.onTurn(TurnPrompt(drawnTile: drawn));
      expect(Tile.isHonor(action.tile), isTrue);
    });

    test('降り判断中は役牌でも鳴かない', () async {
      final cpu = CpuAgent(seed: 1, thinkMillis: 0);
      // 白のポンができる状況(リーチがなければ鳴く)
      final hand = tiles('2358m2358p358s55z');
      cpu.onView(_view(hand: hand, riichiRiver: tiles('1m')));
      final action = await cpu.onReact(
        ReactPrompt(fromSeat: 1, tile: tiles('5z')[0], canPon: true),
      );
      expect(action.type, 'pass');
    });

    test('リーチがなければ役牌はポンする(鳴いてテンパイする手)', () async {
      final cpu = CpuAgent(seed: 1, thinkMillis: 0);
      // 234m 567p 34s 88s 9s 白白: 白ポン→9s切りでテンパイ(CallPolicy: 進んで2以内)
      final hand = tiles('234m567p34889s55z');
      cpu.onView(_view(hand: hand, opponentRiichi: false));
      final action = await cpu.onReact(
        ReactPrompt(fromSeat: 1, tile: tiles('5z')[0], canPon: true),
      );
      expect(action.type, 'pon');
    });

    test('バラバラの手では役牌でもポンしない(校正済みの鳴き方針)', () async {
      final cpu = CpuAgent(seed: 1, thinkMillis: 0);
      // 鳴いても3シャンテン以上の手。プロはこの形の役牌を 24% しか鳴かない
      final hand = tiles('2358m2358p358s55z');
      cpu.onView(_view(hand: hand, opponentRiichi: false));
      final action = await cpu.onReact(
        ReactPrompt(fromSeat: 1, tile: tiles('5z')[0], canPon: true),
      );
      expect(action.type, 'pass');
    });
  });
}
