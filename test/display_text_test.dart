import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/display_text.dart';
import 'package:mahjong_taku/engine/paifu_record.dart';
import 'package:mahjong_taku/engine/yaku.dart';
import 'package:mahjong_taku/paifu/paifu_db.dart';

/// 表示文言の純粋関数(対戦・記録・ビューア・一覧で共有)の仕様
void main() {
  test('局の表記: 本場は0のとき省略、alwaysHonba で常に付ける', () {
    expect(kyokuLabel(0, 1), '東1局');
    expect(kyokuLabel(1, 3, honba: 1), '南3局1本場');
    expect(kyokuLabel(0, 1, alwaysHonba: true), '東1局0本場');
    expect(
      kyokuLabel(0, 1, honba: 0, alwaysHonba: true, honbaSep: ' '),
      '東1局 0本場',
    );
    expect(kyokuLabelFromRound('2z3', honba: 2), '南3局2本場');
    expect(kyokuLabelOf('1z4', 0), '東4局');
  });

  test('風の名前: 起家からの席順', () {
    expect(seatWindName(0), '東家');
    expect(seatWindName(3), '北家');
    expect(seatFromChiichaLabel(1), '起家から南家');
  });

  test('符号付き点差', () {
    expect(formatSignedPoints(1200), '+1200');
    expect(formatSignedPoints(-8000), '-8000');
    expect(formatSignedPoints(0), '0');
    expect(formatSignedPoints(0, zero: '±0'), '±0');
    expect(formatSignedPoints(0, zero: ''), '');
  });

  test('翻符・和了要約・流局要約', () {
    expect(hanFuLabel(2, 40), '2翻40符');
    expect(
      winSummary(name: '茅森早香', isTsumo: true, points: 19300),
      '茅森早香 ツモ 19300点',
    );
    expect(
      winSummary(
        name: '浅見真紀',
        isTsumo: false,
        loserName: '茅森早香',
        points: 13000,
      ),
      '浅見真紀 茅森早香からロン 13000点',
    );
    expect(winSummary(name: 'A', isTsumo: false, points: 1000), 'A ロン 1000点');
    expect(tenpaiSummary(const []), '全員ノーテン');
    expect(tenpaiSummary(const ['A', 'B', 'C', 'D']), '全員テンパイ');
    expect(tenpaiSummary(const ['A', 'C']), 'テンパイ: A・C');
  });

  test('試合ラベルと卓名', () {
    expect(tableLetterOf('L001_S022_0036_01B'), 'B');
    expect(tableLetterOf('L001_S025_0001_01A'), 'A');
    expect(tableLetterOf(''), 'A');
    expect(
      matchLabelOf(matchNumber: 1, tableLetter: 'A', showTable: false),
      '第1試合',
    );
    expect(
      matchLabelOf(
        matchNumber: 2,
        tableLetter: 'B',
        showTable: true,
        date: '2025-10-01',
      ),
      '2025-10-01 第2試合(B卓)',
    );
  });

  test('牌譜DBの description 表記と逆変換', () {
    expect(
      agariDescription(
        isYakuman: false,
        fu: 40,
        han: 5,
        label: '満貫',
        declared: 8000,
      ),
      '40符5飜 満貫8000',
    );
    expect(
      agariDescription(
        isYakuman: true,
        fu: 30,
        han: 13,
        label: '役満',
        declared: 32000,
      ),
      '役満',
    );
    expect(limitLabelFromDescription('40符5飜 満貫8000'), '満貫');
    expect(limitLabelFromDescription('30符13飜 三倍満24000'), '三倍満');
    expect(limitLabelFromDescription('役満'), '役満');
    expect(limitLabelFromDescription('30符2飜 2000'), '');
    expect(limitLabelFromDescription(null), '');
  });

  test('役1件のラベル: 結果画面(翻付き)と一覧(短縮)の2形式', () {
    const riichi = YakuItem('立直', 1);
    const chanta = YakuItem('混全帯么九', 2);
    const ura = YakuItem('裏ドラ', 3);
    const kokushi = YakuItem('国士無双', 13);
    expect(
      yakuItemLabel(riichi, isYakuman: false, withHanSuffix: true),
      '立直 1翻',
    );
    expect(yakuItemLabel(riichi, isYakuman: false, withHanSuffix: false), '立直');
    expect(
      yakuItemLabel(chanta, isYakuman: false, withHanSuffix: false),
      '混全帯么九2',
    );
    expect(yakuItemLabel(ura, isYakuman: false, withHanSuffix: true), '裏3');
    expect(
      yakuItemLabel(kokushi, isYakuman: true, withHanSuffix: true),
      '国士無双 役満',
    );
    expect(
      yakuItemLabel(kokushi, isYakuman: true, withHanSuffix: false),
      '国士無双',
    );
  });
}
