import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/comeback.dart';
import 'package:mahjong_taku/engine/score.dart';
import 'package:mahjong_taku/engine/models.dart';

NeededHand _ron(
  int self,
  int target, {
  bool selfDealer = false,
  int honba = 0,
  int sticks = 0,
}) => neededHand(
  isTsumo: false,
  selfScore: self,
  targetScore: target,
  selfDealer: selfDealer,
  targetDealer: false,
  honba: honba,
  sticks: sticks,
);

NeededHand _tsumo(
  int self,
  int target, {
  bool selfDealer = false,
  bool targetDealer = false,
  int honba = 0,
  int sticks = 0,
}) => neededHand(
  isTsumo: true,
  selfScore: self,
  targetScore: target,
  selfDealer: selfDealer,
  targetDealer: targetDealer,
  honba: honba,
  sticks: sticks,
);

GameView _view(
  List<int> scores, {
  int you = 0,
  int dealer = 0,
  int honba = 0,
  int sticks = 0,
}) => GameView(
  youSeat: you,
  dealer: dealer,
  roundWind: 0,
  kyoku: 1,
  honba: honba,
  riichiSticks: sticks,
  wallRemaining: 70,
  currentSeat: 0,
  phase: 'playing',
  players: [
    for (var i = 0; i < 4; i++)
      PlayerView(
        name: 'P$i',
        isCpu: true,
        connected: true,
        riichi: false,
        handCount: 13,
        melds: const [],
        discards: const [],
      ),
  ],
  hand: const [],
  scores: scores,
  doraIndicators: const [0],
  currentStats: GameStats.zero(),
);

void main() {
  group('逆転計算(ロン)', () {
    test('7000差は満貫ロンで逆転(子)', () {
      final r = _ron(15000, 22000);
      expect(r.reachable, isTrue);
      expect(r.gain, 8000);
      expect(r.label, '満貫');
    });

    test('9000差は跳満ロンが必要(子・満貫では届かない)', () {
      final r = _ron(15000, 24000);
      expect(r.reachable, isTrue);
      expect(r.gain, 12000);
      expect(r.label, '跳満');
    });

    test('親のロンは同じ手でも高い', () {
      // 6000差・親: 3翻40符ロン(親)=7700で逆転
      final r = _ron(20000, 26000, selfDealer: true);
      expect(r.reachable, isTrue);
      expect(r.gain, 7700);
    });

    test('供託があると必要な手が下がる', () {
      final without = _ron(15000, 22000); // 満貫8000
      final withSticks = _ron(15000, 22000, sticks: 1); // 供託1000込み
      expect(withSticks.gain, lessThan(without.gain + 1000));
      // 供託込みで7000差を満貫未満で逆転できる
      expect(withSticks.gain, lessThan(8000 + 1000));
      expect(withSticks.reachable, isTrue);
    });

    test('本場があると必要な手が下がる', () {
      final r = _ron(15000, 22000, honba: 3); // ロン+900
      // 本場込みで満貫未満(サブ満貫)でも逆転しうる
      expect(r.reachable, isTrue);
      expect(r.gain, lessThanOrEqualTo(8000 + 900));
    });

    test('届かないほどの大差は reachable=false', () {
      final r = _ron(0, 200000);
      expect(r.reachable, isFalse);
      expect(r.label, '—');
    });
  });

  group('逆転計算(ツモ)', () {
    test('ツモは対象者も払うのでロンより軽い手で逆転できる', () {
      const self = 20000, target = 24000;
      final ron = _ron(self, target);
      final tsumo = _tsumo(self, target);
      expect(tsumo.reachable, isTrue);
      expect(ron.reachable, isTrue);
      expect(tsumo.gain, lessThan(ron.gain));
    });
  });

  group('順位表', () {
    test('自分が最下位なら上位3人に逆転手が付く', () {
      final rows = buildRanking(_view([10000, 20000, 30000, 40000], you: 0));
      expect(rows.length, 4);
      // 順位順(点数降順)
      expect(rows.map((r) => r.score).toList(), [40000, 30000, 20000, 10000]);
      // 自分は最下位
      final selfIdx = rows.indexWhere((r) => r.isSelf);
      expect(selfIdx, 3);
      // 上位3人は逆転手あり、自分はなし
      for (var i = 0; i < 3; i++) {
        expect(rows[i].tsumo, isNotNull);
        expect(rows[i].ron, isNotNull);
      }
      expect(rows[3].tsumo, isNull);
      expect(rows[3].ron, isNull);
      // 点数差
      expect(rows[0].diff, 30000); // 40000-10000
      expect(rows[3].diff, 0);
    });

    test('同点は起家(席0)に近い方が上位(精算 settleGame と同じ規則)', () {
      // 南2局(親=席1)で席0と席1が同点。以前は「その局の東>南>西>北」で
      // 席1(親)を上にしていたが、Mリーグ規定は起家に近い方(席0)が上位
      final rows = buildRanking(
        _view([30000, 30000, 25000, 15000], you: 2, dealer: 1),
      );
      expect(rows[0].name, 'P0');
      expect(rows[1].name, 'P1');
      // 精算側の順位付けと一致する
      expect(rankSeatsByScore([30000, 30000, 25000, 15000]), [0, 1, 2, 3]);
    });

    test('自分が1位なら誰にも逆転手は付かない', () {
      final rows = buildRanking(_view([40000, 20000, 30000, 10000], you: 0));
      expect(rows.first.isSelf, isTrue);
      for (final r in rows) {
        expect(r.tsumo, isNull);
        expect(r.ron, isNull);
      }
    });
  });
}
