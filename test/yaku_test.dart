import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/score.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/engine/yaku.dart';

import 'hand_test.dart' show tiles;

WinScore? eval({
  required String concealed,
  required String winTile,
  List<Meld> melds = const [],
  bool tsumo = false,
  bool riichi = false,
  bool ippatsu = false,
  int seatWind = 1,
  int roundWind = 0,
  String dora = '',
  String ura = '',
}) {
  return evaluateWin(
    WinContext(
      concealed: tiles(concealed),
      melds: melds,
      winTile: tiles(winTile)[0],
      isTsumo: tsumo,
      isRiichi: riichi,
      isIppatsu: ippatsu,
      seatWind: seatWind,
      roundWind: roundWind,
      doraIndicators: tiles(dora),
      uraIndicators: tiles(ura),
    ),
  );
}

bool hasYaku(WinScore? s, String name) =>
    s != null && s.yaku.any((y) => y.name.contains(name));

void main() {
  group('役判定', () {
    test('平和ツモ 20符', () {
      final s = eval(
        concealed: '234567m234p34566s',
        winTile: '5s',
        tsumo: true,
      );
      expect(hasYaku(s, '平和'), isTrue);
      expect(hasYaku(s, '門前清自摸和'), isTrue);
      expect(s!.fu, 20);
    });

    test('嵌張待ちは平和にならない', () {
      final s = eval(
        concealed: '234567m234p34566s',
        winTile: '4s',
        tsumo: true,
      );
      expect(s, isNotNull);
      expect(hasYaku(s, '平和'), isFalse);
    });

    test('断么九', () {
      final s = eval(concealed: '234567m345p45688s', winTile: '6s');
      expect(hasYaku(s, '断么九'), isTrue);
    });

    test('役牌(白)', () {
      final s = eval(concealed: '234567m345p88s555z', winTile: '8s');
      expect(hasYaku(s, '役牌 白'), isTrue);
    });

    test('場風・自風の複合(東場の東家)', () {
      final s = eval(
        concealed: '234567m345p88s111z',
        winTile: '8s',
        seatWind: 0,
        roundWind: 0,
      );
      expect(hasYaku(s, '自風 東'), isTrue);
      expect(hasYaku(s, '場風 東'), isTrue);
    });

    test('役なしは null(和了できない)', () {
      // 東場でのロン: 平和は東の雀頭(場風)で不成立、他の役もない
      final s = eval(
        concealed: '234567m345p789s11z',
        winTile: '9s',
        seatWind: 1,
        roundWind: 0,
      );
      expect(s, isNull);
    });

    test('七対子 25符2翻', () {
      final s = eval(concealed: '1122m3344p55s6677z', winTile: '5s');
      expect(hasYaku(s, '七対子'), isTrue);
      expect(s!.fu, 25);
    });

    test('二盃口は七対子より優先(高点法)', () {
      final s = eval(
        concealed: '112233m445566p77s',
        winTile: '7s',
        riichi: true,
      );
      expect(hasYaku(s, '二盃口'), isTrue);
    });

    test('一盃口', () {
      final s = eval(
        concealed: '112233m456p88s567s',
        winTile: '8s',
        riichi: true,
      );
      expect(hasYaku(s, '一盃口'), isTrue);
    });

    test('三色同順', () {
      final s = eval(concealed: '234m234p234s55m789m', winTile: '9m');
      expect(hasYaku(s, '三色同順'), isTrue);
    });

    test('一気通貫', () {
      final s = eval(concealed: '123456789m55p678s', winTile: '8s');
      expect(hasYaku(s, '一気通貫'), isTrue);
    });

    test('対々和+三暗刻(ポン込みツモ)', () {
      final s = eval(
        concealed: '222p333s99s99m9s',
        winTile: '9s',
        tsumo: true,
        melds: [
          const Meld(
            type: MeldType.pon,
            tiles: [0, 0, 0],
            fromSeat: 2,
            calledTile: 0,
          ),
        ],
      );
      expect(hasYaku(s, '対々和'), isTrue);
      expect(hasYaku(s, '三暗刻'), isTrue);
    });

    test('混一色(門前3翻)', () {
      final s = eval(concealed: '123456789m11z777z', winTile: '7z');
      expect(hasYaku(s, '混一色'), isTrue);
      final item = s!.yaku.firstWhere((y) => y.name == '混一色');
      expect(item.han, 3);
    });

    test('清一色', () {
      final s = eval(concealed: '11223345678999m', winTile: '9m');
      expect(hasYaku(s, '清一色'), isTrue);
    });

    test('全帯么九', () {
      final s = eval(concealed: '123m789p123s99s111z', winTile: '9s');
      expect(hasYaku(s, '全帯么九'), isTrue);
    });

    test('純全帯么九', () {
      final s = eval(concealed: '123m789p123999s99m', winTile: '9m');
      expect(hasYaku(s, '純全帯么九'), isTrue);
    });

    test('国士無双', () {
      final s = eval(concealed: '19m19p19s12345677z', winTile: '7z');
      expect(hasYaku(s, '国士無双'), isTrue);
      expect(s!.yakuman, greaterThanOrEqualTo(1));
    });

    test('四暗刻(ツモ)', () {
      final s = eval(
        concealed: '111m222p333s444s55m',
        winTile: '5m',
        tsumo: true,
      );
      expect(hasYaku(s, '四暗刻'), isTrue);
    });

    test('シャンポンロンは四暗刻にならない(三暗刻+対々和)', () {
      final s = eval(concealed: '111m222p333s444s55m', winTile: '4s');
      expect(hasYaku(s, '四暗刻'), isFalse);
      expect(hasYaku(s, '三暗刻'), isTrue);
      expect(hasYaku(s, '対々和'), isTrue);
    });

    test('大三元', () {
      final s = eval(concealed: '555z666z777z123m44p', winTile: '4p');
      expect(hasYaku(s, '大三元'), isTrue);
    });

    test('赤ドラ(Mリーグルール)', () {
      // 234567m 234p 34(赤5)66s ツモ: 断么九? 34赤5,6,6 → 345+66
      final s = eval(
        concealed: '234567m234p3406s6s',
        winTile: '0s',
        tsumo: true,
      );
      expect(hasYaku(s, '赤ドラ'), isTrue);
      final red = s!.yaku.firstWhere((y) => y.name == '赤ドラ');
      expect(red.han, 1);
    });

    test('副露に赤があっても数える', () {
      final s = eval(
        concealed: '234567m88s567s',
        winTile: '8s',
        melds: [
          Meld(
            type: MeldType.pon,
            tiles: [13, 13, Tile.red5p], // 5筒ポン(赤入り)
            fromSeat: 1,
            calledTile: Tile.red5p,
          ),
        ],
      );
      // 5筒ポンなのでタンヤオ+赤ドラ
      expect(hasYaku(s, '赤ドラ'), isTrue);
    });

    test('ドラ・裏ドラ', () {
      final s = eval(
        concealed: '234567m234p34566s',
        winTile: '5s',
        tsumo: true,
        riichi: true,
        dora: '1m', // ドラは2m
        ura: '2p', // 裏は3p
      );
      expect(hasYaku(s, 'ドラ'), isTrue);
      expect(hasYaku(s, '裏ドラ'), isTrue);
    });

    test('鳴きタンヤオ(食い断あり)', () {
      final s = eval(
        concealed: '234567m88s567s',
        winTile: '8s',
        melds: [
          const Meld(
            type: MeldType.pon,
            tiles: [12, 12, 12], // 4p
            fromSeat: 1,
            calledTile: 12,
          ),
        ],
      );
      expect(hasYaku(s, '断么九'), isTrue);
    });
  });

  group('点数計算', () {
    test('満貫ロン(子)8000点', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 5, fu: 30, yakuman: 0),
        isDealer: false,
        isTsumo: false,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.ron, 8000);
    });

    test('30符4翻は切り上げ満貫で8000(Mリーグルール)', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 4, fu: 30, yakuman: 0),
        isDealer: false,
        isTsumo: false,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.ron, 8000);
      expect(p.label, '満貫');
    });

    test('60符3翻も切り上げ満貫', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 3, fu: 60, yakuman: 0),
        isDealer: false,
        isTsumo: false,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.ron, 8000);
    });

    test('40符3翻は切り上げされない(5200)', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 3, fu: 40, yakuman: 0),
        isDealer: false,
        isTsumo: false,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.ron, 5200);
    });

    test('親ツモ 40符1翻は 700オール', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 1, fu: 40, yakuman: 0),
        isDealer: true,
        isTsumo: true,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.tsumoNonDealer, 700);
      expect(p.total, 2100);
    });

    test('子ツモ 30符2翻 500/1000', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 2, fu: 30, yakuman: 0),
        isDealer: false,
        isTsumo: true,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.tsumoNonDealer, 500);
      expect(p.tsumoDealer, 1000);
      expect(p.total, 2000);
    });

    test('役満ロン(親)48000点', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 0, fu: 30, yakuman: 1),
        isDealer: true,
        isTsumo: false,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.ron, 48000);
    });

    test('本場と供託', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 2, fu: 30, yakuman: 0),
        isDealer: false,
        isTsumo: false,
        honba: 2,
        riichiSticks: 1,
      );
      expect(p.ron, 2000 + 600);
      expect(p.total, 2600 + 1000); // 供託込みの総取得
      // 申告点は供託を含まない(打点+本場のみ)
      expect(p.declared, 2600);
    });

    // Mリーグルール:「役満以外の役が複合したアガリ点は、三倍満までを上限とする」
    // → 数え役満は無い
    test('13翻は数え役満にならず三倍満止まり', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 13, fu: 30, yakuman: 0),
        isDealer: false,
        isTsumo: false,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.ron, 24000);
      expect(p.label, '三倍満');
    });

    test('翻数がいくら伸びても三倍満で頭打ち', () {
      for (final han in [11, 13, 20]) {
        final p = calcPayment(
          score: WinScore(yaku: const [], han: han, fu: 30, yakuman: 0),
          isDealer: false,
          isTsumo: false,
          honba: 0,
          riichiSticks: 0,
        );
        expect(p.ron, 24000, reason: '$han翻');
        expect(p.label, '三倍満', reason: '$han翻');
      }
    });

    test('役満役そのものは従来どおり役満', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 0, fu: 30, yakuman: 1),
        isDealer: false,
        isTsumo: false,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.ron, 32000);
      expect(p.label, '役満');
    });

    test('海底のような1翻30符', () {
      final p = calcPayment(
        score: const WinScore(yaku: [], han: 1, fu: 30, yakuman: 0),
        isDealer: false,
        isTsumo: false,
        honba: 0,
        riichiSticks: 0,
      );
      expect(p.ron, 1000);
    });
  });

  group('WinScore シリアライズ', () {
    test('toJson/fromJson 往復', () {
      const s = WinScore(
        yaku: [YakuItem('立直', 1), YakuItem('ドラ', 2)],
        han: 3,
        fu: 40,
        yakuman: 0,
      );
      final restored = WinScore.fromJson(s.toJson());
      expect(restored.han, 3);
      expect(restored.fu, 40);
      expect(restored.yaku.length, 2);
      expect(restored.yaku[0].name, '立直');
    });
  });

  group('牌ユーティリティ', () {
    test('風牌', () {
      expect(windTile(0), Tile.east);
      expect(windTile(3), Tile.north);
    });
  });
}
