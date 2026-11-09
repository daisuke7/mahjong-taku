import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/advisor.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/hand.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'advisor_test.dart' show makeView;
import 'hand_test.dart' show tiles;

/// CPUの攻め打牌(攻撃アドバイスの転用)。
/// - シャンテンを落とす打牌は選ばない(手戻りしない)
/// - シャンテンを保つ候補の中では想定打点が最も高いものを選ぶ
void main() {
  int shantenAfter(GameView v, int kind) {
    final hand = [...v.hand, v.drawnTile!];
    final counts = toCounts(hand)..[kind] -= 1;
    return calcShanten(counts, meldCount: v.players[v.youSeat].melds.length);
  }

  int bestShanten(GameView v) {
    final hand = [...v.hand, v.drawnTile!];
    var best = 99;
    for (final k in hand.map(Tile.normalize).toSet()) {
      final counts = toCounts(hand)..[k] -= 1;
      final s = calcShanten(
        counts,
        meldCount: v.players[v.youSeat].melds.length,
      );
      if (s < best) best = s;
    }
    return best;
  }

  group('attackDiscard', () {
    test('高打点でも手戻りになる候補の打牌は選ばない', () {
      // 手なり2シャンテン。ホンイツ(12000点)は「2萬切り=手戻り」を推奨するが、
      // CPUは手戻りしないのでシャンテン維持の一気通貫(8000点)側の白切りを選ぶ。
      final v = makeView(
        hand: tiles('234m124578s1133z'),
        drawn: tiles('5z')[0],
        doraIndicators: tiles('2m'),
      );
      final t = attackDiscard(v);
      expect(t, isNotNull);
      final kind = Tile.normalize(t!);
      expect(kind, isNot(tiles('2m')[0]), reason: '234mを崩す2萬切りは手戻りなので選ばない');
      expect(
        shantenAfter(v, kind),
        bestShanten(v),
        reason: '選んだ打牌はシャンテンを落とさない',
      );
    });

    test('シャンテンを保つ候補の中で打点最大の候補の打牌を選ぶ', () {
      // 23m 456m 45688p 東東 9m + ツモ7s。シャンテン維持の候補が3つ:
      //   リーチ+タンヤオ+ドラ1(5200点) 切=9萬
      //   場風東+ドラ1(2000点)          切=9萬
      //   リーチ+一気通貫+ドラ1(8000点)  切=7索 (789m の種に 9m を残す)
      // 打点最大の一気通貫に従い 7索 を切る(受け入れ最大なら 9萬 になる)。
      final v = makeView(
        hand: tiles('23m456m45688p11z9m'),
        drawn: tiles('7s')[0],
        doraIndicators: tiles('2m'),
      );
      // 前提: 打点の異なる生き残り候補が複数あり、打牌が分かれること
      final best = bestShanten(v);
      final survivors = <YakuCandidate>[];
      for (final c in buildAdvice(v).offense) {
        final d = c.discard;
        if (d == null) continue;
        if (shantenAfter(v, Tile.normalize(d)) > best) continue;
        survivors.add(c);
      }
      expect(survivors.length, greaterThanOrEqualTo(2));
      expect(
        survivors.map((c) => Tile.normalize(c.discard!)).toSet().length,
        greaterThanOrEqualTo(2),
        reason: '前提: 候補間で打牌が分かれている',
      );

      final t = attackDiscard(v);
      expect(Tile.normalize(t!), tiles('7s')[0], reason: '最高打点(一気通貫)の打牌を選ぶ');
      expect(shantenAfter(v, Tile.normalize(t)), best);
    });

    test('役候補が無い手は null(従来ロジックへのフォールバック)', () {
      // 幺九入りのチー(123m) + 役牌対子なしのバラ手 → 候補が出ない
      final v = makeView(
        hand: tiles('24568p2467s9s'),
        drawn: tiles('9m')[0],
        myMelds: [
          const Meld(
            type: MeldType.chi,
            tiles: [0, 1, 2],
            fromSeat: 3,
            calledTile: 0,
          ),
        ],
      );
      expect(buildAdvice(v).offense, isEmpty, reason: '前提: 候補ゼロの手');
      expect(attackDiscard(v), isNull);
    });

    test('喰い替え禁止の牌は選ばない', () {
      final v = makeView(
        hand: tiles('234m124578s1133z'),
        drawn: tiles('5z')[0],
        doraIndicators: tiles('2m'),
      );
      final normally = Tile.normalize(attackDiscard(v)!);
      // 通常の選択(白)を禁止すると、別のシャンテン維持牌に切り替わる
      final t = attackDiscard(v, forbidden: [normally]);
      if (t != null) {
        expect(Tile.normalize(t), isNot(normally));
        expect(shantenAfter(v, Tile.normalize(t)), bestShanten(v));
      }
    });
  });

  group('CpuAgent の配線', () {
    test('攻め打牌は attackDiscard の牌になる(受け入れ最大とは別の牌)', () async {
      // 上と同じ分岐する手。従来の受け入れ最大ロジックなら 9萬 を切るが、
      // アドバイザー転用後は一気通貫(8000点)の 7索 切りになる。
      final v = makeView(
        hand: tiles('23m456m45688p11z9m'),
        drawn: tiles('7s')[0],
        doraIndicators: tiles('2m'),
      );
      final cpu = CpuAgent(seed: 1, thinkMillis: 0);
      cpu.onView(v);
      final action = await cpu.onTurn(TurnPrompt(drawnTile: v.drawnTile));
      expect(action.type, 'discard');
      expect(
        Tile.normalize(action.tile),
        tiles('7s')[0],
        reason: '受け入れ最大(9萬)ではなく打点最大候補の7索',
      );
    });
  });
}
