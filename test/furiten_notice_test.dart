import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/furiten_notice.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';

GameView _view({
  required List<int> discardLens,
  required List<int> myWaits,
  required bool myFuriten,
  int youSeat = 0,
  int? lastDiscardTileBySeat1,
}) {
  return GameView(
    youSeat: youSeat,
    dealer: 0,
    roundWind: 0,
    kyoku: 1,
    honba: 0,
    riichiSticks: 0,
    wallRemaining: 60,
    currentSeat: 0,
    phase: 'playing',
    players: [
      for (var i = 0; i < 4; i++)
        PlayerView(
          name: 'P$i',
          isCpu: i != youSeat,
          connected: true,
          riichi: false,
          handCount: 13,
          melds: const [],
          discards: [
            for (var d = 0; d < discardLens[i]; d++)
              // 席1の最後の捨て牌だけ指定牌にできるようにする
              DiscardInfo(
                (i == 1 &&
                        d == discardLens[i] - 1 &&
                        lastDiscardTileBySeat1 != null)
                    ? lastDiscardTileBySeat1
                    : 27,
              ), // 27=東(待ちに含めない無害牌)
          ],
        ),
    ],
    hand: const [],
    scores: const [25000, 25000, 25000, 25000],
    doraIndicators: const [0],
    currentStats: GameStats.zero(),
    myWaits: myWaits,
    myFuriten: myFuriten,
  );
}

void main() {
  const s4 = 21; // 4索(自分の待ち)

  test('フリテンで他家が当たり牌を捨てた瞬間 → 通知', () {
    final v = _view(
      discardLens: [3, 5, 2, 4], // 席1が新たに捨てた(前回4→今5)
      myWaits: [s4],
      myFuriten: true,
      lastDiscardTileBySeat1: s4, // 席1の最新捨て牌=当たり牌
    );
    expect(furitenNotice(prevDiscardLens: [3, 4, 2, 4], v: v), isTrue);
  });

  test('フリテンでない(ロン可)なら通知しない', () {
    final v = _view(
      discardLens: [3, 5, 2, 4],
      myWaits: [s4],
      myFuriten: false, // フリテンでない
      lastDiscardTileBySeat1: s4,
    );
    expect(furitenNotice(prevDiscardLens: [3, 4, 2, 4], v: v), isFalse);
  });

  test('当たり牌でなければ通知しない', () {
    final v = _view(
      discardLens: [3, 5, 2, 4],
      myWaits: [s4],
      myFuriten: true,
      lastDiscardTileBySeat1: 22, // 5索(待ちでない)
    );
    expect(furitenNotice(prevDiscardLens: [3, 4, 2, 4], v: v), isFalse);
  });

  test('自分の捨て牌では通知しない', () {
    final v = _view(
      discardLens: [4, 4, 2, 4], // 席0(自分)が増えた
      myWaits: [s4],
      myFuriten: true,
    );
    expect(furitenNotice(prevDiscardLens: [3, 4, 2, 4], v: v), isFalse);
  });

  test('テンパイでない(待ち空)なら通知しない', () {
    final v = _view(
      discardLens: [3, 5, 2, 4],
      myWaits: const [],
      myFuriten: true,
      lastDiscardTileBySeat1: s4,
    );
    expect(furitenNotice(prevDiscardLens: [3, 4, 2, 4], v: v), isFalse);
  });

  test('局が変わって河がリセットされた場合は通知しない', () {
    final v = _view(
      discardLens: [0, 1, 0, 0], // 新しい局(前回より減っている)
      myWaits: [s4],
      myFuriten: true,
      lastDiscardTileBySeat1: s4,
    );
    expect(furitenNotice(prevDiscardLens: [5, 6, 5, 5], v: v), isFalse);
  });

  test('赤5でも正規化して当たり判定する', () {
    // 待ち=5索(22)。席1が赤5索(Tile.red5s=36)を捨てる。
    final v = _view(
      discardLens: [3, 5, 2, 4],
      myWaits: [22],
      myFuriten: true,
      lastDiscardTileBySeat1: Tile.red5s,
    );
    expect(furitenNotice(prevDiscardLens: [3, 4, 2, 4], v: v), isTrue);
  });
}
