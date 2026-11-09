import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/advisor.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'hand_test.dart' show tiles;

GameView makeView({
  required List<int> hand,
  int? drawn,
  List<Meld> myMelds = const [],
  Map<int, List<Meld>> otherMelds = const {},
  Map<int, List<int>> rivers = const {},
  Map<int, List<DiscardInfo>> riverInfos = const {},
  Set<int> riichiSeats = const {},
  List<int> doraIndicators = const [],
  int wallRemaining = 40,
}) {
  final players = List.generate(
    4,
    (i) => PlayerView(
      name: 'P$i',
      isCpu: true,
      connected: true,
      riichi: riichiSeats.contains(i),
      handCount: 13,
      melds: i == 0 ? myMelds : (otherMelds[i] ?? const []),
      discards:
          riverInfos[i] ??
          [for (final t in rivers[i] ?? const <int>[]) DiscardInfo(t)],
    ),
  );
  return GameView(
    youSeat: 0,
    dealer: 1,
    roundWind: 0,
    kyoku: 2,
    honba: 0,
    riichiSticks: 0,
    wallRemaining: wallRemaining,
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
  group('アドバイス(攻撃)', () {
    test('テンパイのシャンテン数とリーチ候補', () {
      // 234m 567m 88p 456s 99s + 1z → 1z切りでテンパイ
      final view = makeView(
        hand: tiles('234567m88p45699s'),
        drawn: tiles('1z')[0],
      );
      final report = buildAdvice(view);
      expect(report.shanten, 0);
      expect(report.offense.any((c) => c.parts.contains('リーチ')), isTrue);
      // 想定点数がついている
      expect(report.offense.first.points, greaterThan(0));
    });

    test('鳴いている手に門前限定役は出ない', () {
      final view = makeView(
        hand: tiles('4567m88p45699s'), // 10枚+ツモ
        drawn: tiles('1z')[0],
        myMelds: [
          const Meld(
            type: MeldType.chi,
            tiles: [0, 1, 2],
            fromSeat: 3,
            calledTile: 0,
          ),
        ],
      );
      final report = buildAdvice(view);
      for (final c in report.offense) {
        expect(c.parts, isNot(contains('リーチ')));
        expect(c.parts, isNot(contains('ピンフ')));
        expect(c.parts, isNot(contains('七対子')));
      }
    });

    test('役牌対子は残り枚数がなければ候補に出ない', () {
      final hand = tiles('234567m2388p55z');
      final drawn = tiles('9p')[0];
      // 白(5z)が場に2枚出ている → 残り0
      final exhausted = makeView(
        hand: hand,
        drawn: drawn,
        rivers: {1: tiles('55z')},
      );
      final r1 = buildAdvice(exhausted);
      expect(
        r1.offense.any((c) => c.parts.contains('白')),
        isFalse,
        reason: '白は残り0枚なので候補に出してはいけない',
      );

      // 場に出ていなければ候補になる
      final available = makeView(hand: hand, drawn: drawn);
      final r2 = buildAdvice(available);
      expect(r2.offense.any((c) => c.parts.contains('白')), isTrue);
    });

    test('ドラが想定翻数に含まれる', () {
      final view = makeView(
        hand: tiles('234567m88p45699s'),
        drawn: tiles('1z')[0],
        doraIndicators: tiles('3m'), // ドラ4m(手に1枚)
      );
      final report = buildAdvice(view);
      final riichiCombo = report.offense.firstWhere(
        (c) => c.parts.contains('リーチ'),
      );
      expect(riichiCombo.parts.any((p) => p.startsWith('ドラ')), isTrue);
    });

    group('推奨打牌(まっすぐ向かう不要牌)', () {
      test('役牌の暗刻からその役牌を切らない', () {
        // 場風東(東場・自風北) + 東東東の暗刻 + 散らばった浮き牌。
        // 場風東狙いで東を切るのは役が消えるので論外。リーチ狙いでも
        // 完成した暗刻を崩すのはシャンテンを落とすだけ。孤立牌を切るべき。
        final view = makeView(
          hand: tiles('19m258p258s346z11z'),
          drawn: tiles('1z')[0],
          doraIndicators: tiles('2m'), // ドラ3m(東ではない)
        );
        final report = buildAdvice(view);
        for (final c in report.offense) {
          if (c.discard == null) continue;
          expect(
            Tile.normalize(c.discard!),
            isNot(tiles('1z')[0]),
            reason: '${c.parts.join("+")}: 東の暗刻から東を切ってはいけない',
          );
        }
        // 場風東候補は必ず出る(母数確認)
        expect(report.offense.any((c) => c.parts.contains('場風東')), isTrue);
      });

      test('孤立牌より対子・順子の一部を優先して残す', () {
        // 55p の対子と 78s の塔子があり、孤立の 1z がある。1z を切るべき。
        final view = makeView(
          hand: tiles('234m55p78s12369s1z'),
          drawn: tiles('4z')[0],
        );
        final report = buildAdvice(view);
        final riichi = report.offense.firstWhere(
          (c) => c.parts.contains('リーチ'),
        );
        final d = Tile.normalize(riichi.discard!);
        // 55p(対子)・78s(塔子)・234m(順子)は残す
        expect(d, isNot(tiles('5p')[0]));
        expect(d, isNot(tiles('7s')[0]));
        expect(d, isNot(tiles('8s')[0]));
      });

      test('染め手では色違いの牌を切る候補を出す', () {
        // 索子に寄せた手 + 孤立の1萬。混一色狙いでは1萬を切る
        final view = makeView(
          hand: tiles('23455678999s1m2z'),
          drawn: tiles('2z')[0],
        );
        final report = buildAdvice(view);
        final honitsu = report.offense
            .where(
              (c) =>
                  c.parts.any((p) => p.contains('ホンイツ') || p.contains('チンイツ')),
            )
            .toList();
        expect(honitsu, isNotEmpty);
        // 色違いの1萬が推奨打牌
        expect(Tile.normalize(honitsu.first.discard!), tiles('1m')[0]);
      });

      test('染め手では色違いが面子でもシャンテンを落として切る', () {
        // 索子+字牌に寄った2シャンテンの手 + 完成した萬子順子234m。
        // ホンイツ狙い(3シャンテン)なら、シャンテンが落ちても234mを崩して切る
        final view = makeView(
          hand: tiles('234m124578s1133z'),
          drawn: tiles('5z')[0],
        );
        final report = buildAdvice(view);
        final flush = report.offense
            .where(
              (c) =>
                  c.parts.any((p) => p.contains('ホンイツ') || p.contains('チンイツ')),
            )
            .toList();
        expect(flush, isNotEmpty, reason: '染め候補が出る');
        // 推奨打牌は萬子(染める索子以外)
        expect(
          Tile.suit(Tile.normalize(flush.first.discard!)),
          0,
          reason: '色違いの萬子を切る',
        );
      });

      test('推奨打牌はシャンテンを落とさない(手牌に含まれる牌)', () {
        final view = makeView(
          hand: tiles('234567m88p45699s'),
          drawn: tiles('1z')[0],
        );
        final report = buildAdvice(view);
        for (final c in report.offense) {
          if (c.discard == null) continue;
          final hand = [...view.hand, view.drawnTile!];
          expect(hand.contains(c.discard), isTrue, reason: '推奨打牌は手牌の中の牌であるべき');
        }
        // 面子手候補では孤立字牌の1zが不要牌になる
        final menzen = report.offense.firstWhere(
          (c) => c.parts.contains('リーチ'),
        );
        expect(Tile.normalize(menzen.discard!), tiles('1z')[0]);
      });

      test('ドラは不要牌に選ばれにくい', () {
        // 孤立牌が2つ(1z と ドラの中9m相当)。ドラ側は残す
        final view = makeView(
          hand: tiles('234567m88p4569s9s'),
          drawn: tiles('1z')[0],
          doraIndicators: tiles('8s'), // ドラ9s(手に2枚)
        );
        final report = buildAdvice(view);
        final menzen = report.offense.firstWhere(
          (c) => c.parts.contains('リーチ'),
        );
        // ドラの9sではなく孤立字牌1zを切る
        expect(Tile.normalize(menzen.discard!), tiles('1z')[0]);
      });
    });

    group('七対子', () {
      test('対子6組(テンパイ)で七対子が候補に出る', () {
        // 1122m3344p556677s = 対子6組+5s6s7s... 実際は 11 22 33 44 55 66 + 7s単騎
        final view = makeView(
          hand: tiles('1122m3344p5566s7s'),
          drawn: tiles('7s')[0],
        );
        final report = buildAdvice(view);
        expect(report.offense.any((c) => c.parts.contains('七対子')), isTrue);
      });

      test('対子4組では七対子と面子手の両方が候補に出る', () {
        // 対子4組 + 順子の種 = 面子手にも七対子にも向かう形
        final view = makeView(
          hand: tiles('1122m334455p678s'),
          drawn: tiles('9m')[0],
        );
        final report = buildAdvice(view);
        expect(
          report.offense.any((c) => c.parts.contains('七対子')),
          isTrue,
          reason: '4組なら七対子候補も出す',
        );
        expect(
          report.offense.any(
            (c) => !c.parts.contains('七対子') && c.parts.contains('リーチ'),
          ),
          isTrue,
          reason: '面子手(リーチ)候補も併せて出す',
        );
      });

      test('刻子は七対子の対子として数えない', () {
        // 111m 222m 333m 444m 5m = 刻子4つ、対子(ちょうど2枚)は0
        final view = makeView(
          hand: tiles('111222333444m5m'),
          drawn: tiles('5m')[0],
        );
        final report = buildAdvice(view);
        expect(
          report.offense.any((c) => c.parts.contains('七対子')),
          isFalse,
          reason: '刻子ばかりの手を七対子候補にしてはいけない',
        );
      });

      test('七対子にタンヤオが複合する', () {
        // 全て2〜8の対子6組+単騎
        final view = makeView(
          hand: tiles('2233m4455p6677s2s'),
          drawn: tiles('2s')[0],
        );
        final report = buildAdvice(view);
        final chiitoi = report.offense.firstWhere(
          (c) => c.parts.contains('七対子'),
        );
        expect(chiitoi.parts, contains('タンヤオ'));
      });

      test('七対子に混一色が複合する', () {
        // 索子+字牌で7種の七対子形
        final view = makeView(
          hand: tiles('2233445566s11z2z'),
          drawn: tiles('2z')[0],
        );
        final report = buildAdvice(view);
        final chiitoi = report.offense.firstWhere(
          (c) => c.parts.contains('七対子'),
        );
        expect(chiitoi.parts, contains('ホンイツ'));
      });
    });
  });

  group('現物ハイライト(genbutsuInHand)', () {
    test('リーチ者がいなければ空', () {
      final view = makeView(
        hand: tiles('1m5s2233445566p'),
        drawn: tiles('9s')[0],
      );
      expect(genbutsuInHand(view), isEmpty);
    });

    test('リーチ者の現物になっている手牌の牌種を返す', () {
      // 席2がリーチ。その河に 1m と 7s → 手牌の1m/7sは現物
      final view = makeView(
        hand: tiles('1m5s223344556p7s'),
        drawn: tiles('9s')[0],
        riichiSeats: {2},
        rivers: {2: tiles('1m7s')},
      );
      final g = genbutsuInHand(view);
      expect(g, contains(tiles('1m')[0]));
      expect(g, contains(tiles('7s')[0]));
      // 河に無い無スジ中張(5s)は現物でない
      expect(g, isNot(contains(tiles('5s')[0])));
    });

    test('複数リーチには全員に通る牌だけが現物', () {
      // 席1の河に1m、席2の河に9m。1mは席2に通らない → 現物でない
      final view = makeView(
        hand: tiles('1m9m2233445566p7s'),
        drawn: tiles('8s')[0],
        riichiSeats: {1, 2},
        rivers: {1: tiles('1m'), 2: tiles('9m')},
      );
      final g = genbutsuInHand(view);
      expect(g, isNot(contains(tiles('1m')[0])));
      expect(g, isNot(contains(tiles('9m')[0])));
    });
  });

  group('アドバイス(守備)', () {
    test('リーチ者の検出と危険牌・安全牌', () {
      final view = makeView(
        hand: tiles('1m5s2233445566p7s'),
        drawn: tiles('9s')[0],
        riichiSeats: {2},
        rivers: {2: tiles('1m')},
      );
      final report = buildAdvice(view);
      expect(report.threats.length, 1);
      expect(report.threats.first.description, 'リーチ');
      expect(report.threats.first.level, 2);
      // 現物1mは安全側、無スジ中張の5sは危険側
      expect(report.safeTiles.map(Tile.normalize), contains(tiles('1m')[0]));
      expect(report.dangerTiles.map(Tile.normalize), contains(tiles('5s')[0]));
      // 1mは現物として識別される(青く光る対象)
      expect(report.genbutsuKinds, contains(tiles('1m')[0]));
    });

    test('現物とそれ以外の安全牌が区別される', () {
      final view = makeView(
        hand: tiles('1m9p234m567m11s2z'),
        drawn: tiles('9s')[0],
        riichiSeats: {3},
        rivers: {
          3: tiles('1m9p'), // 1m,9pが現物
        },
      );
      final report = buildAdvice(view);
      // 現物は1mと9pの2種
      expect(
        report.genbutsuKinds,
        containsAll([tiles('1m')[0], tiles('9p')[0]]),
      );
      // 字牌2zは安全側だが現物ではない
      expect(report.genbutsuKinds, isNot(contains(tiles('2z')[0])));
      // 現物は安全牌リストに含まれる
      expect(
        report.safeTiles.map(Tile.normalize),
        containsAll([tiles('1m')[0], tiles('9p')[0]]),
      );
    });

    test('副露からホンイツ気配を読む', () {
      final view = makeView(
        hand: tiles('123m456m789m11p2s'),
        drawn: tiles('3s')[0],
        otherMelds: {
          3: [
            const Meld(
              type: MeldType.pon,
              tiles: [10, 10, 10], // 2p
              fromSeat: 0,
              calledTile: 10,
            ),
            const Meld(
              type: MeldType.pon,
              tiles: [16, 16, 16], // 8p
              fromSeat: 1,
              calledTile: 16,
            ),
          ],
        },
      );
      final report = buildAdvice(view);
      expect(report.threats.length, 1);
      expect(report.threats.first.description, contains('筒子'));
      // 筒子(11p)が危険牌に入る
      expect(report.dangerTiles.map(Tile.normalize), contains(tiles('1p')[0]));
    });

    test('リーチ検出時は現物やスジが無くても相対的に安全な牌を提示する', () {
      // 現物・スジは無いが字牌を持っている。安全牌(相対的にマシ)が出る
      final view = makeView(
        hand: tiles('234m567m234p1z2z3z'),
        drawn: tiles('4z')[0],
        riichiSeats: {3}, // 上家(席3=youSeat0の一つ前)
        rivers: {
          3: tiles('5s6s'), // 手牌と関係ない現物
        },
      );
      final report = buildAdvice(view);
      expect(report.threats.length, 1);
      expect(report.threats.first.description, 'リーチ');
      // 相対的に安全な字牌が安全牌として提示される
      expect(report.safeTiles, isNotEmpty, reason: '字牌を持っているのに安全牌が空になってはいけない');
      expect(
        report.safeTiles.every((t) => Tile.isHonor(t)),
        isTrue,
        reason: '数牌より字牌のほうが安全なので字牌が選ばれる',
      );
    });

    test('リーチ後に他家が通した牌はフリテンで安全牌になる', () {
      // 席2がリーチ(宣言牌order=2)。その後席3が5s(order=3)を通した。
      // 席1がリーチ前に捨てた7p(order=1)は安全ではない。
      final view = makeView(
        hand: tiles('55s77p22334466m1z'),
        drawn: tiles('9m')[0],
        riichiSeats: {2},
        riverInfos: {
          1: [DiscardInfo(tiles('7p')[0], order: 1)],
          2: [
            DiscardInfo(tiles('1z')[0], order: 0),
            DiscardInfo(tiles('2m')[0], riichi: true, order: 2),
          ],
          3: [DiscardInfo(tiles('5s')[0], order: 3)],
        },
      );
      final report = buildAdvice(view);
      // 5sはリーチ後に通った牌 → 安全牌に入り、危険牌には入らない
      expect(report.safeTiles.map(Tile.normalize), contains(tiles('5s')[0]));
      expect(
        report.dangerTiles.map(Tile.normalize),
        isNot(contains(tiles('5s')[0])),
      );
      // 7pはリーチ前に捨てられた牌なので安全扱いしない(無スジ中張=危険)
      expect(report.dangerTiles.map(Tile.normalize), contains(tiles('7p')[0]));
    });

    test('脅威がなければ守備情報は空', () {
      final view = makeView(
        hand: tiles('234567m88p45699s'),
        drawn: tiles('1z')[0],
      );
      final report = buildAdvice(view);
      expect(report.threats, isEmpty);
      expect(report.dangerTiles, isEmpty);
      expect(report.safeTiles, isEmpty);
    });
  });
}
