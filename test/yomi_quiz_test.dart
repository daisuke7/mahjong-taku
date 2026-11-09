import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'yomi_quiz_fixtures.dart';

void main() {
  test('流局局からテンパイ・シャンテン・待ちの正解を組み立てる', () {
    final p = buildQuizProblem(standardRyukyokuEvents());
    expect(p, isNotNull);
    p!;
    // 局情報
    expect(p.dealer, 2);
    expect(p.roundWind, 1);
    expect(p.kyokuNumber, 3);
    expect(p.honba, 2);
    // リーチ: 供託+1・席0から1000点・リーチフラグ
    expect(p.sticks, 2);
    expect(p.scores, [24000, 25000, 25000, 25000]);
    expect(p.riichi, [true, false, false, false]);
    // 正解(テンパイはDB記録・待ちは計算)
    expect(p.tenpai, [true, false, false, true]);
    expect(p.shanten[0], 0);
    expect(p.shanten[1], 1);
    expect(p.shanten[2], greaterThan(1));
    expect(p.shanten[3], 0);
    expect(p.waits[0], [Tile.east, Tile.haku]);
    expect(p.waits[1], isEmpty);
    expect(p.waits[3], Tile.parse('14s'));
    // 解答区分
    expect([for (var s = 0; s < 4; s++) p.category(s)], [0, 1, 2, 0]);
    // 副露聴牌: ポン1つ・手牌10枚
    expect(p.melds[3], hasLength(1));
    expect(p.melds[3].first.type, MeldType.pon);
    expect(p.hands[3], hasLength(10));
    // 鳴かれた牌は河で calledAway(表示側で非表示になる)
    expect(p.rivers[1].first.calledAway, isTrue);
    // ツモ切り情報が河に残っている(読みの材料)
    expect(p.rivers[0].first.tsumogiri, isTrue);
    expect(p.rivers[3].first.tsumogiri, isFalse);
    expect(p.wallRemaining, 66);
    expect(p.doraIndicators, [0]);
  });

  test('DBのテンパイ記録と計算が食い違う局は出題しない', () {
    // 席1(イーシャンテン)をテンパイと記録した壊れたデータ
    final p = buildQuizProblem(
      standardRyukyokuEvents(
        ryukyokuPlayers: [
          (100, true, 1500),
          (101, true, 1500),
          (102, false, -1500),
          (103, true, 0),
        ],
      ),
    );
    expect(p, isNull);
  });

  test('アガリ牌を使い切った形式テンパイ形(ノーテン扱い)の局は出題しない', () {
    final e = Ev();
    // 席3: 發3枚持ち → ポンで4枚目を晒し、發単騎に受けるとアガリ牌が
    // 場に存在しない(Mリーグ定義でノーテン)
    final p = buildQuizProblem([
      e.haipai(100, '123m456p789s1155z'),
      e.haipai(101, '123m456p45789s12z'),
      e.haipai(102, '147m258p369s1234z'),
      e.haipai(103, '234m567p678s6667z'),
      e.draw(101, '6z'),
      e.discard(101, '6z'),
      e.pon(103, 101, '6z', '6z6z-6z'),
      e.discard(103, '7z', tsumogiri: false),
      e.ryukyoku([
        (100, true, 3000),
        (101, false, -1000),
        (102, false, -1000),
        (103, false, -1000),
      ]),
    ]);
    expect(p, isNull);
  });

  test('巻き戻し出題: リーチなし局を指定打牌数だけ手前で切り出し、正解は計算で組む', () {
    // 全5打牌の1打牌前 = 4打牌目(席0の9m)の直後で切る。
    // 席2はまだ5mをツモっていない。
    final p = buildQuizProblem(noRiichiRyukyokuEvents(), cutoffDiscards: 1);
    expect(p, isNotNull);
    p!;
    expect(p.cutoffDiscards, 1);
    expect(p.wallRemaining, 67); // 適用されたツモは 9p・6z・9m の3回
    expect([for (final r in p.rivers) r.length], [2, 1, 0, 1]);
    // リーチなしなので供託・点数は局開始のまま
    expect(p.sticks, 1);
    expect(p.scores, [25000, 25000, 25000, 25000]);
    expect(p.riichi, [false, false, false, false]);
    // 正解はDB記録ではなく計算(この時点の手牌は流局時と同じ)
    expect(p.tenpai, [true, false, false, true]);
    expect(p.waits[0], [Tile.east, Tile.haku]);
    expect(p.waits[3], Tile.parse('14s'));
    // 次のツモ番 = 最終打牌者(席0の9m)の下家
    expect(p.nextDrawSeat, 1);
  });

  test('流局時点の出題では次のツモ番は出さない(山は空)', () {
    final p = buildQuizProblem(standardRyukyokuEvents());
    expect(p!.nextDrawSeat, -1);
  });

  test('巻き戻し出題: リーチのある局・残り打牌が少なすぎる局は出題しない', () {
    // リーチあり(供託・宣言と表示が食い違う中途半端な状態になり得る)
    expect(
      buildQuizProblem(standardRyukyokuEvents(), cutoffDiscards: 1),
      isNull,
    );
    // 全5打牌から2打牌戻すと残り3打牌 < 4
    expect(
      buildQuizProblem(noRiichiRyukyokuEvents(), cutoffDiscards: 2),
      isNull,
    );
  });

  test('和了で終わった局は出題しない', () {
    final e = Ev();
    final p = buildQuizProblem([
      e.haipai(100, '123m456p789s1155z'),
      e.haipai(101, '123m456p45789s12z'),
      e.haipai(102, '147m258p369s1234z'),
      e.haipai(103, '234m567p23s4466z7z'),
      e.draw(100, '1z'),
      e.tsumo(100),
    ]);
    expect(p, isNull);
  });
}
