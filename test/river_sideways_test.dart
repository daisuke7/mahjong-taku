import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/safety.dart';
import 'package:mahjong_taku/ui/widgets/table_widgets.dart';

/// Mリーグ規定の要旨: リーチ宣言牌が鳴かれたときは、次巡の打牌を横向きにする。
///
/// 鳴かれた牌は河から取られて表示されない。リーチ宣言牌が鳴かれると横向きの
/// 情報ごと消えるため、次に河に残る打牌へ移して補償する。
void main() {
  // 牌ID: 0-8=1m-9m / 9-17=1p-9p / 18-26=1s-9s / 27-33=東南西北白發中
  const m1 = 0, m2 = 1, m3 = 2, m4 = 3, m5 = 4;

  group('riverTiles: 河の横向き表示', () {
    test('鳴かれていない宣言牌はその牌が横向き', () {
      final r = riverTiles([
        const DiscardInfo(m1, order: 0),
        const DiscardInfo(m2, riichi: true, order: 1),
        const DiscardInfo(m3, order: 2),
      ]);
      expect(r.map((e) => e.discard.tile), [m1, m2, m3]);
      expect(r.map((e) => e.sideways), [false, true, false]);
    });

    test('鳴かれた牌は河に表示しない', () {
      final r = riverTiles([
        const DiscardInfo(m1, order: 0),
        const DiscardInfo(m2, calledAway: true, order: 1),
        const DiscardInfo(m3, order: 2),
      ]);
      expect(r.map((e) => e.discard.tile), [m1, m3]);
      expect(r.every((e) => !e.sideways), isTrue);
    });

    test('宣言牌が鳴かれたら次の打牌を横にする', () {
      final r = riverTiles([
        const DiscardInfo(m1, order: 0),
        const DiscardInfo(m2, riichi: true, calledAway: true, order: 1),
        const DiscardInfo(m3, order: 2),
        const DiscardInfo(m4, order: 3),
      ]);
      // 宣言牌(m2)は河から消え、次の m3 が横向きになる
      expect(r.map((e) => e.discard.tile), [m1, m3, m4]);
      expect(r.map((e) => e.sideways), [
        false,
        true,
        false,
      ], reason: '横向きが m3 へ移る');
    });

    test('次の打牌も鳴かれたら、さらに次へ持ち越す', () {
      final r = riverTiles([
        const DiscardInfo(m1, riichi: true, calledAway: true, order: 0),
        const DiscardInfo(m2, calledAway: true, order: 1),
        const DiscardInfo(m3, order: 2),
      ]);
      expect(r.map((e) => e.discard.tile), [m3]);
      expect(r.map((e) => e.sideways), [true]);
    });

    test('宣言牌が鳴かれた後に打牌が無ければ横向きは出ない(和了・流局で局が終了)', () {
      final r = riverTiles([
        const DiscardInfo(m1, order: 0),
        const DiscardInfo(m2, riichi: true, calledAway: true, order: 1),
      ]);
      expect(r.map((e) => e.discard.tile), [m1]);
      expect(r.every((e) => !e.sideways), isTrue);
    });

    test('横向きは河全体で高々1枚', () {
      final r = riverTiles([
        const DiscardInfo(m1, riichi: true, calledAway: true, order: 0),
        const DiscardInfo(m2, order: 1),
        const DiscardInfo(m3, order: 2),
        const DiscardInfo(m4, order: 3),
        const DiscardInfo(m5, order: 4),
      ]);
      expect(r.where((e) => e.sideways).length, 1);
      expect(r.first.sideways, isTrue, reason: '宣言牌の次(m2)だけ');
    });
  });

  group('モデルの riichi フラグは動かさない', () {
    // 表示だけの補償にとどめる理由: DiscardInfo.riichi はリーチ宣言の巡目を
    // 表すデータで、safety.dart が現物の判定に使っている。フラグを次巡へ移すと
    // 宣言巡が後ろにずれ、「リーチ後に通った牌」の範囲が変わってしまう。
    test('宣言牌が鳴かれても、宣言巡を基準に現物が判定される', () {
      // 席1がリーチ宣言(order=1)。その宣言牌は鳴かれて河から消えている。
      // 席2が order=2 で 5m を打って通った → 5m は席1に対して現物同様に安全。
      final view = _view(
        riichiSeat: 1,
        riverInfos: {
          1: [
            const DiscardInfo(m1, order: 0),
            const DiscardInfo(m2, riichi: true, calledAway: true, order: 1),
          ],
          2: [const DiscardInfo(m5, order: 2)],
        },
      );
      expect(
        safetyVs(m5, 1, const [], view),
        100,
        reason:
            'リーチ宣言後に通った牌は安全。'
            '宣言牌が鳴かれても宣言巡(order=1)は失われない',
      );
    });

    test('リーチ宣言より前に通った牌は安全扱いしない', () {
      final view = _view(
        riichiSeat: 1,
        riverInfos: {
          1: [
            const DiscardInfo(m1, order: 1),
            const DiscardInfo(m2, riichi: true, calledAway: true, order: 2),
          ],
          2: [const DiscardInfo(m5, order: 0)], // 宣言より前
        },
      );
      expect(safetyVs(m5, 1, const [], view), lessThan(100));
    });
  });
}

GameView _view({
  required int riichiSeat,
  required Map<int, List<DiscardInfo>> riverInfos,
}) => GameView(
  youSeat: 0,
  dealer: 0,
  roundWind: 0,
  kyoku: 1,
  honba: 0,
  riichiSticks: 0,
  wallRemaining: 40,
  currentSeat: 0,
  phase: 'playing',
  scores: const [25000, 25000, 25000, 25000],
  doraIndicators: const [0],
  hand: const [],
  currentStats: GameStats.zero(),
  players: [
    for (var i = 0; i < 4; i++)
      PlayerView(
        name: 'P$i',
        isCpu: true,
        connected: true,
        riichi: i == riichiSeat,
        handCount: 13,
        melds: const [],
        discards: riverInfos[i] ?? const [],
      ),
  ],
);
