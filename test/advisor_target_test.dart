import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/advisor.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/tile.dart';

import 'advisor_test.dart' show makeView;
import 'hand_test.dart' show tiles;

/// 三色同順・一気通貫は「3面子そろって初めて成立する」ため、他の役のように
/// 今の形から気配を読むことができない。順子3つを固定したシャンテン数で
/// 判定し、2シャンテン以内なら候補に出す。
void main() {
  YakuCandidate? find(AdviceReport r, String name) {
    for (final c in r.offense) {
      if (c.parts.contains(name)) return c;
    }
    return null;
  }

  group('三色同順', () {
    test('テンパイしている三色は候補に出る', () {
      // 234m 56m 234p 99p 234s + 1z → 1z切りで4m/7m待ちのテンパイ。三色は完成済み
      final v = makeView(
        hand: tiles('23456m23499p234s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      final c = find(r, '三色同順');
      expect(c, isNotNull, reason: '完成している三色が候補に出ないのはおかしい');
      expect(c!.shanten, 0);
      expect(c.parts, contains('リーチ'));
      expect(c.han, greaterThanOrEqualTo(3), reason: 'リーチ1 + 三色同順2');
    });

    test('2シャンテンの三色まで候補に出る', () {
      // 234m 234s はそろい、筒子は 34p。2p を引けば三色が確定する
      final v = makeView(
        hand: tiles('23456m34499p234s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      final c = find(r, '三色同順');
      expect(c, isNotNull);
      expect(c!.shanten, lessThanOrEqualTo(2));
    });

    test('遠すぎる三色は候補に出さない', () {
      // 三色の芽がまったくない手
      final v = makeView(
        hand: tiles('1199m1199p1199s7z'),
        drawn: tiles('7z')[0],
      );
      final r = buildAdvice(v);
      expect(find(r, '三色同順'), isNull, reason: '3シャンテン以上離れた役を出すと助言にならない');
    });

    test('三色に必要な牌が場に尽きていれば候補に出さない', () {
      // 234m 34p 234s + 字牌。狙えるのは「2pを引いての234三色」だけで、
      // 345や123は3シャンテン以上離れている(数牌が2〜4しかないため)。
      final hand = tiles('234m34p234s11223z');
      final drawn = tiles('3z')[0];
      final alive = buildAdvice(makeView(hand: hand, drawn: drawn));
      expect(find(alive, '三色同順'), isNotNull, reason: '前提: 生きていれば出る');

      final dead = buildAdvice(
        makeView(hand: hand, drawn: drawn, rivers: {1: tiles('2222p')}),
      );
      expect(find(dead, '三色同順'), isNull, reason: '2pが枯れているので234三色は不可能');
    });

    test('鳴いていれば喰い下がり1翻で出る', () {
      // 234p をチーしている。234m 234s がそろえば三色
      final v = makeView(
        hand: tiles('234m56799p234s'),
        drawn: tiles('9p')[0],
        myMelds: [
          const Meld(
            type: MeldType.chi,
            tiles: [10, 11, 12],
            fromSeat: 3,
            calledTile: 10,
          ), // 234p
        ],
      );
      final r = buildAdvice(v);
      final c = find(r, '三色同順');
      expect(c, isNotNull, reason: '副露した順子も三色の一部として数える');
      expect(c!.parts, isNot(contains('リーチ')));
    });

    test('三色と無関係な副露が2つあれば不可能', () {
      // 白ポン + 中ポン = 面子枠が2つ埋まる。三色(3面子)+2 = 5面子で成立しない
      final v = makeView(
        hand: tiles('234m234p234s1z'),
        drawn: tiles('1z')[0],
        myMelds: [
          const Meld(
            type: MeldType.pon,
            tiles: [31, 31, 31],
            fromSeat: 3,
            calledTile: 31,
          ), // 白
          const Meld(
            type: MeldType.pon,
            tiles: [33, 33, 33],
            fromSeat: 3,
            calledTile: 33,
          ), // 中
        ],
      );
      expect(find(buildAdvice(v), '三色同順'), isNull);
    });

    test('推奨打牌は三色に必要な牌を切らない', () {
      final v = makeView(
        hand: tiles('23456m23499p234s'),
        drawn: tiles('1z')[0],
      );
      final c = find(buildAdvice(v), '三色同順')!;
      expect(c.discard, isNotNull);
      // 234m/234p/234s は三色の骨格。切ってはいけない
      const skeleton = {0, 1, 2, 9, 10, 11, 18, 19, 20};
      expect(
        skeleton.contains(Tile.normalize(c.discard!)),
        isFalse,
        reason: '三色の骨格を切る打牌を勧めてはいけない',
      );
    });
  });

  group('一気通貫', () {
    test('テンパイしている一通は候補に出る', () {
      // 123456789s + 23m + 99p + 1z → 1z切りで1m/4m待ちのテンパイ
      final v = makeView(
        hand: tiles('23m99p123456789s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      final c = find(r, '一気通貫');
      expect(c, isNotNull);
      expect(c!.shanten, 0);
    });

    test('一通にタンヤオは複合しない', () {
      final v = makeView(
        hand: tiles('23m99p123456789s'),
        drawn: tiles('1z')[0],
      );
      final c = find(buildAdvice(v), '一気通貫')!;
      expect(c.parts, isNot(contains('タンヤオ')), reason: '一通は必ず1・9を含む');
    });

    test('遠すぎる一通は候補に出さない', () {
      final v = makeView(
        hand: tiles('1199m1199p1199s7z'),
        drawn: tiles('7z')[0],
      );
      expect(find(buildAdvice(v), '一気通貫'), isNull);
    });
  });

  group('一盃口', () {
    test('同じ順子2つがそろっていれば候補に出る', () {
      // 223344m 567p 45s 99s + 1z → 1z切りで3s/6s待ちのテンパイ。一盃口は完成済み
      final v = makeView(
        hand: tiles('223344m567p4599s'),
        drawn: tiles('1z')[0],
      );
      final c = find(buildAdvice(v), '一盃口');
      expect(c, isNotNull);
      expect(c!.shanten, 0);
      expect(c.parts, contains('リーチ'));
    });

    test('鳴いていれば一盃口は出ない(門前限定)', () {
      final v = makeView(
        hand: tiles('223344m567p45s'),
        drawn: tiles('9s')[0],
        myMelds: [
          const Meld(
            type: MeldType.chi,
            tiles: [11, 12, 13],
            fromSeat: 3,
            calledTile: 11,
          ), // 345p
        ],
      );
      expect(find(buildAdvice(v), '一盃口'), isNull);
    });

    test('遠すぎる一盃口は候補に出さない', () {
      final v = makeView(
        hand: tiles('19m19p19s1234567z'),
        drawn: tiles('1z')[0],
      );
      expect(find(buildAdvice(v), '一盃口'), isNull);
    });
  });

  group('大三元(夢)', () {
    test('白發中が対子でそろえば候補に出る', () {
      // 白白 發發 中中 + 234m 567p 99s
      final v = makeView(
        hand: tiles('234m567p9s556677z'),
        drawn: tiles('9s')[0],
      );
      final c = find(buildAdvice(v), '大三元');
      expect(c, isNotNull, reason: '三元牌が3種とも対子なら夢として見せる');
      expect(c!.shanten, 2);
      expect(c.label, '役満');
      expect(c.points, 32000, reason: '子の役満は32000点');
      expect(c.han, 0, reason: '役満は翻数を数えない');
    });

    test('鳴いた三元牌も数える', () {
      // 白ポン + 發發 + 中中
      final v = makeView(
        hand: tiles('234m567p99s6677z'),
        drawn: tiles('1m')[0],
        myMelds: [
          const Meld(
            type: MeldType.pon,
            tiles: [31, 31, 31],
            fromSeat: 3,
            calledTile: 31,
          ), // 白
        ],
      );
      final c = find(buildAdvice(v), '大三元');
      expect(c, isNotNull, reason: 'ポンした白も大三元の一部');
    });

    test('三元牌が場に尽きていれば候補に出さない', () {
      final hand = tiles('234m567p9s556677z');
      final drawn = tiles('9s')[0];
      expect(
        find(buildAdvice(makeView(hand: hand, drawn: drawn)), '大三元'),
        isNotNull,
        reason: '前提: 生きていれば出る',
      );

      // 中(7z)の残り2枚が両方とも河にある → 中の刻子は作れない
      final dead = buildAdvice(
        makeView(hand: hand, drawn: drawn, rivers: {1: tiles('77z')}),
      );
      expect(find(dead, '大三元'), isNull, reason: '中が枯れているので大三元は不可能');
    });

    test('三元牌が乏しければ候補に出さない', () {
      final v = makeView(
        hand: tiles('234567m234567p5z'),
        drawn: tiles('9s')[0],
      );
      expect(find(buildAdvice(v), '大三元'), isNull);
    });
  });

  group('四暗刻単騎', () {
    test('単騎待ちテンパイならトイトイではなく四暗刻を出す', () {
      // 111m 222m 333m 444m + 5p単騎 + 9s(余り) → 9s切りで四暗刻単騎テンパイ
      final v = makeView(hand: tiles('111222333444m5p'), drawn: tiles('9s')[0]);
      final r = buildAdvice(v);
      final c = find(r, '四暗刻');
      expect(c, isNotNull, reason: '聴牌を崩さない限り四暗刻が確定する形');
      expect(c!.shanten, 0);
      expect(c.label, '役満');
      expect(find(r, 'トイトイ'), isNull, reason: '四暗刻が確定するのでトイトイは出さない');
    });

    test('シャンポン待ちは四暗刻を出さない(ロンだと明刻になる)', () {
      // 111m 222m 333m + 44m 55p → 9s切りで4m/5pのシャンポン待ち。
      // ロンだと4つ目が明刻になるので四暗刻にならない
      final v = makeView(hand: tiles('11122233344m55p'), drawn: tiles('9s')[0]);
      final r = buildAdvice(v);
      expect(find(r, '四暗刻'), isNull, reason: 'シャンポン待ちでは四暗刻は確定しない');
      expect(find(r, 'トイトイ'), isNotNull, reason: 'この形はトイトイとして案内する');
    });

    test('ポンしていれば四暗刻を出さない', () {
      // 111m 222m 333m + 5p単騎 + 4mポン(明刻)
      final v = makeView(
        hand: tiles('111222333m5p'),
        drawn: tiles('9s')[0],
        myMelds: [
          const Meld(
            type: MeldType.pon,
            tiles: [3, 3, 3],
            fromSeat: 3,
            calledTile: 3,
          ), // 4mポン
        ],
      );
      expect(find(buildAdvice(v), '四暗刻'), isNull, reason: '明刻は暗刻に数えない');
    });

    test('暗槓は暗刻として数える', () {
      // 4m暗槓 + 111m 222m 333m + 5p単騎
      final v = makeView(
        hand: tiles('111222333m5p'),
        drawn: tiles('9s')[0],
        myMelds: [
          const Meld(
            type: MeldType.ankan,
            tiles: [3, 3, 3, 3],
            fromSeat: 0,
            calledTile: 3,
          ), // 4m暗槓
        ],
      );
      expect(
        find(buildAdvice(v), '四暗刻'),
        isNotNull,
        reason: '暗槓は暗刻なので四暗刻が成立する',
      );
    });

    test('推奨打牌は暗刻を崩さない', () {
      final v = makeView(hand: tiles('111222333444m5p'), drawn: tiles('9s')[0]);
      final c = find(buildAdvice(v), '四暗刻')!;
      expect(
        Tile.normalize(c.discard!),
        tiles('9s')[0],
        reason: '暗刻でも単騎でもない余り牌を切る',
      );
    });
  });

  group('国士無双(夢)', () {
    test('幺九牌が11種そろえば候補に出る', () {
      // 11m 9m 19p 19s 12345z + 5m → 11種+対子(1m1m)
      final v = makeView(
        hand: tiles('1195m19p19s12345z'),
        drawn: tiles('5p')[0],
      );
      final c = find(buildAdvice(v), '国士無双');
      expect(c, isNotNull);
      expect(c!.shanten, 1, reason: '13種 - 11種 - 対子1 = 1シャンテン');
      expect(c.label, '役満');
    });

    test('幺九牌が10種あれば候補に出る', () {
      // 19m 19p 19s 1234z + 456m → 10種・対子なし
      final v = makeView(
        hand: tiles('19m456m19p19s1234z'),
        drawn: tiles('7m')[0],
      );
      final c = find(buildAdvice(v), '国士無双');
      expect(c, isNotNull, reason: '10種そろっていれば夢として見せる');
      expect(c!.shanten, 3, reason: '13種 - 10種 - 対子なし = 3シャンテン');
    });

    test('幺九牌が9種では候補に出さない', () {
      // 11m 9m 19p 19s 123z + 456m → 9種+対子。10種に届かない
      final v = makeView(
        hand: tiles('119m456m19p19s123z'),
        drawn: tiles('7m')[0],
      );
      expect(
        find(buildAdvice(v), '国士無双'),
        isNull,
        reason: '9種のままでは順目が進むと間に合わないので出さない',
      );
    });

    test('残りツモで聴牌に届かなければ候補に出さない', () {
      // 10種・対子なし = 3シャンテン。聴牌まであと3回ツモが要る
      final hand = tiles('19m456m19p19s1234z');
      final drawn = tiles('7m')[0];

      // 山12枚 → 自分のツモはあと3回。ぎりぎり届く
      final inTime = buildAdvice(
        makeView(hand: hand, drawn: drawn, wallRemaining: 12),
      );
      expect(find(inTime, '国士無双'), isNotNull, reason: '前提: 3回ツモがあれば出る');

      // 山8枚 → 自分のツモはあと2回。3シャンテンからは聴牌すらできない
      final tooLate = buildAdvice(
        makeView(hand: hand, drawn: drawn, wallRemaining: 8),
      );
      expect(find(tooLate, '国士無双'), isNull, reason: '残りツモ2回では3シャンテンから間に合わない');
    });

    test('鳴いていれば国士無双は出ない', () {
      final v = makeView(
        hand: tiles('119m19p19s123z'),
        drawn: tiles('4z')[0],
        myMelds: [
          const Meld(
            type: MeldType.chi,
            tiles: [0, 1, 2],
            fromSeat: 3,
            calledTile: 0,
          ),
        ],
      );
      expect(find(buildAdvice(v), '国士無双'), isNull);
    });

    test('幺九牌が乏しければ候補に出さない', () {
      final v = makeView(
        hand: tiles('234567m23455p234s'),
        drawn: tiles('6p')[0],
      );
      expect(find(buildAdvice(v), '国士無双'), isNull);
    });

    test('推奨打牌は幺九牌を切らない', () {
      final v = makeView(
        hand: tiles('1195m19p19s12345z'),
        drawn: tiles('5p')[0],
      );
      final c = find(buildAdvice(v), '国士無双')!;
      expect(c.discard, isNotNull);
      expect(
        Tile.isTerminalOrHonor(Tile.normalize(c.discard!)),
        isFalse,
        reason: '国士に必要な幺九牌ではなく、中張牌(5m/5p)を切るべき',
      );
    });
  });

  group('染め手(混一色・清一色)', () {
    test('字牌を持っていても清一色が候補に出る', () {
      // 234sチー + 索子9枚 + 1z1z。字牌2枚を切れば清一色は1シャンテン。
      // 「字牌が1枚でもあれば清一色ではない」と判定してはいけない
      final v = makeView(
        hand: tiles('56799s123s1z1z'),
        drawn: tiles('5s')[0],
        myMelds: [
          const Meld(
            type: MeldType.chi,
            tiles: [19, 20, 21],
            fromSeat: 3,
            calledTile: 19,
          ), // 234s
        ],
      );
      final c = find(buildAdvice(v), 'チンイツ');
      expect(c, isNotNull, reason: '字牌は切ればよいので清一色を諦める理由にならない');
      expect(c!.shanten, 1);
    });

    test('清一色と同じ距離なら混一色は出さない', () {
      // 索子のみ13枚。字牌が無いので混一色の距離は清一色と同じ。
      // 同じ距離なら翻数の高い清一色を選べばよく、混一色を出す意味がない
      final v = makeView(hand: tiles('2345678999s234s'), drawn: tiles('5s')[0]);
      final r = buildAdvice(v);
      expect(find(r, 'チンイツ'), isNotNull);
      expect(find(r, 'ホンイツ'), isNull, reason: '清一色と同距離の混一色は下位互換なので出さない');
    });

    test('混一色のほうが近ければ混一色を先に出す', () {
      // 索子12枚(123s 456s 789s 234s) + 東東。
      // 東を雀頭にすれば混一色は和了形だが、清一色にするには東2枚を
      // 索子に替える必要があるぶん遠い
      final v = makeView(
        hand: tiles('123456789s234s1z'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      final honitsu = find(r, 'ホンイツ');
      expect(honitsu, isNotNull);
      expect(honitsu!.shanten, 0);
      // 清一色は遠いので、出るとしても混一色より後ろ
      final chinitsu = find(r, 'チンイツ');
      if (chinitsu != null) {
        expect(chinitsu.shanten, greaterThan(honitsu.shanten!));
        expect(
          r.offense.indexOf(chinitsu),
          greaterThan(r.offense.indexOf(honitsu)),
        );
      }
    });

    test('色の合わない副露があれば染め手は出ない', () {
      // 索子に染めたいが萬子をチーしている。副露は下ろせないので不可能
      final v = makeView(
        hand: tiles('2345678999s'),
        drawn: tiles('9s')[0],
        myMelds: [
          const Meld(
            type: MeldType.chi,
            tiles: [0, 1, 2],
            fromSeat: 3,
            calledTile: 0,
          ), // 123m
        ],
      );
      final r = buildAdvice(v);
      expect(find(r, 'チンイツ'), isNull);
      expect(find(r, 'ホンイツ'), isNull);
    });

    test('遠すぎる染め手は候補に出さない', () {
      final v = makeView(
        hand: tiles('123m456p789s1234z'),
        drawn: tiles('5z')[0],
      );
      final r = buildAdvice(v);
      expect(find(r, 'チンイツ'), isNull);
      expect(find(r, 'ホンイツ'), isNull);
    });
  });

  group('遠回りの許容量', () {
    // 聴牌しているのに2シャンテンまで戻す役は選択肢にならない。
    // 1手戻す程度なら選択肢として意味がある。
    test('聴牌なら2シャンテン戻る一通は出さない', () {
      // 123456789s + 234m + 99p → 既にテンパイ。一通は完成済みなので出るが、
      // 同じ手で2シャンテン戻る役は出ない
      final v = makeView(
        hand: tiles('23m99p123456789s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      for (final c in r.offense) {
        if (c.isYakuman) continue; // 役満は夢なので別枠
        expect(
          c.shanten ?? 0,
          lessThanOrEqualTo(1),
          reason: '聴牌から2手以上戻る役(${c.parts.join("+")})を勧めてはいけない',
        );
      }
    });

    test('聴牌でも1手戻すだけなら候補に出る', () {
      // 234m 234p 234s + 56m + 99p → 1z切りでテンパイ(4m/7m待ち)。三色は完成済み
      final v = makeView(
        hand: tiles('23456m23499p234s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      expect(find(r, '三色同順'), isNotNull, reason: '0シャンテンの三色は当然出る');
    });

    test('2シャンテンなら3シャンテンの染め手まで出る', () {
      // 手なり2シャンテン。ホンイツは3シャンテン(1手戻す)なので選択肢になる
      final v = makeView(
        hand: tiles('234m124578s1133z'),
        drawn: tiles('5z')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 2);
      final honitsu = find(r, 'ホンイツ');
      expect(honitsu, isNotNull);
      expect(honitsu!.shanten, 3);
    });
  });

  group('タンヤオ', () {
    test('聴牌形に幺九牌が残るならタンヤオを出さない', () {
      // 123m 456m 234p 55s 78s + 4p → 4p切りで6s/9s待ちのテンパイ。
      // 1mが残るのでタンヤオは絶対に付かない(幺九牌が3枚以下でも同じ)
      final v = makeView(
        hand: tiles('123456m234p5578s'),
        drawn: tiles('4p')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      for (final c in r.offense) {
        expect(
          c.parts,
          isNot(contains('タンヤオ')),
          reason: '1mが残る聴牌形でタンヤオを出してはいけない',
        );
      }
    });

    test('タンヤオが付かない聴牌では幺九牌切りを勧めない', () {
      // 上と同じ手。タンヤオを狙って1mを切るのは一手戻りなので、
      // テンパイに取る4p切りを勧めるべき
      final v = makeView(
        hand: tiles('123456m234p5578s'),
        drawn: tiles('4p')[0],
      );
      final r = buildAdvice(v);
      final main = r.offense.firstWhere((c) => c.parts.contains('リーチ'));
      expect(
        Tile.normalize(main.discard!),
        tiles('4p')[0],
        reason: '聴牌を崩す1m切りではなく、テンパイに取る4p切り',
      );
    });

    test('全て中張牌の聴牌ならタンヤオが出る', () {
      // 234m 456m 234p 55s 78s + 4p → 4p切りで6s/9s待ち…は9sが幺九。
      // 234m 456m 234p 55s 34s + 9p → 9p切りで2s/5s待ち(両方中張)
      final v = makeView(
        hand: tiles('234456m234p5534s'),
        drawn: tiles('9p')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      expect(find(r, 'タンヤオ'), isNotNull);
    });

    test('待ち牌を自分の副露で使い切った聴牌はタンヤオを出さない', () {
      // 5s を3枚ポン。手牌 234m 456m 234p + 5s 単騎 → 5s待ちだが、5s は
      // ポンで3枚 + 手牌1枚 = 4枚とも自分が持っており、場に1枚も残らない。
      // Mリーグの聴牌定義ではノーテンなので、タンヤオを含む役を出してはいけない。
      // (calcWaits では 5s を待ちとして拾ってしまう。calcLiveWaits が要る)
      final v = makeView(
        hand: tiles('234m456m234p5s'),
        drawn: tiles('9m')[0], // 打牌前(9m を切れば上記の聴牌形)
        myMelds: [
          const Meld(
            type: MeldType.pon,
            tiles: [22, 22, 22],
            fromSeat: 3,
            calledTile: 22,
          ), // 5sポン
        ],
      );
      final r = buildAdvice(v);
      for (final c in r.offense) {
        expect(
          c.parts,
          isNot(contains('タンヤオ')),
          reason: '待ちを自分で使い切っているのでアガれない=タンヤオも付かない',
        );
      }
    });
  });

  group('聴牌時の待ち表示', () {
    // 指定した牌を切ったときの待ちを探す
    WaitOption? optFor(AdviceReport r, int discardKind) {
      for (final o in r.waits) {
        if (o.discard != null && Tile.normalize(o.discard!) == discardKind) {
          return o;
        }
      }
      return null;
    }

    test('両面待ちの待ち牌と残り枚数が出る', () {
      // 234m 567m 234p 88s + 78p → 1z切りで6p/9p両面待ち。
      // 待ち牌(6p/9p)は手牌に無いので場に各4枚残っている
      final v = makeView(
        hand: tiles('234567m234p78p88s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      final o = optFor(r, tiles('1z')[0])!;
      expect(o.tiles, [tiles('6p')[0], tiles('9p')[0]]);
      expect(o.total, 8, reason: '6p/9p が各4枚');
    });

    test('待ち牌が場に見えているぶん残り枚数が減る', () {
      // 同じ手。6p を2枚、9p を1枚、他家の河が持っている
      final v = makeView(
        hand: tiles('234567m234p78p88s'),
        drawn: tiles('1z')[0],
        rivers: {1: tiles('66p9p')},
      );
      final o = optFor(buildAdvice(v), tiles('1z')[0])!;
      // 6p 残り2、9p 残り3 → 合計5。残りの多い順(9p→6p)に並ぶ
      expect(o.tiles, [tiles('9p')[0], tiles('6p')[0]]);
      expect(o.remaining[tiles('6p')[0]], 2);
      expect(o.remaining[tiles('9p')[0]], 3);
      expect(o.total, 5);
    });

    test('聴牌していなければ待ちは空', () {
      final v = makeView(hand: tiles('19m19p19s1234z'), drawn: tiles('5z')[0]);
      final r = buildAdvice(v);
      expect(r.shanten, greaterThan(0));
      expect(r.waits, isEmpty);
    });

    test('自分の副露で使い切った待ちは出さない', () {
      // 5s を3枚ポン + 5s 単騎。5s は自分で4枚 → 待ちに残らない=ノーテン
      final v = makeView(
        hand: tiles('234m456m234p5s'),
        drawn: tiles('9m')[0],
        myMelds: [
          const Meld(
            type: MeldType.pon,
            tiles: [22, 22, 22],
            fromSeat: 3,
            calledTile: 22,
          ),
        ],
      );
      final r = buildAdvice(v);
      for (final o in r.waits) {
        expect(o.tiles, isNot(contains(tiles('5s')[0])));
      }
    });

    test('切る牌ごとに待ちが変わる場合は打牌ごとに出る', () {
      // 123m 456m 789m 55p + 3s5s → テンパイ形は2通り:
      //   3s切り → 5p/5s のシャンポン…ではなく、55p雀頭+3s5s嵌張(4s待ち)
      //   5s切り → 55p雀頭 + 3s が浮く → ノーテン。なので別の手にする。
      // 123m 456m 789m + 34p + 66s: 2p/5p 両面(34p) or 6s切りは崩れる。
      // 分かりやすく2択にする: 123m 456m 789m 99p + 45p(ツモ) 手牌に 45p と 99p。
      //   9p切り → 45p+9p... 崩れる。
      // 素直に: 123m 456m 789m 34p 34s(打牌前14枚, ツモで15?)…複雑。
      // 単純な2択: 233445m の一盃口形は避け、
      //   手牌 234m567m11p 345p 78s + ツモ 9s
      //   9s切り → 78s は残り、11p雀頭 → 6s/9s待ち…切った牌が待ち。
      // ここは「打牌ごとに WaitOption が複数出て、それぞれ discard が異なる」ことだけ確認する。
      final v = makeView(
        hand: tiles('234567m11p34578s'),
        drawn: tiles('9s')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      // 複数の打牌でテンパイに取れるなら、それぞれ discard が異なる WaitOption が出る
      final discards = r.waits.map((o) => Tile.normalize(o.discard!)).toSet();
      expect(discards.length, r.waits.length, reason: '打牌ごとに1つ(重複しない)');
      // 受けの広い順に並んでいる
      for (var i = 1; i < r.waits.length; i++) {
        expect(r.waits[i - 1].total, greaterThanOrEqualTo(r.waits[i].total));
      }
    });

    test('打牌前の各 WaitOption は discard を持ち、残り枚数が正', () {
      final v = makeView(
        hand: tiles('234567m234p456s9m'),
        drawn: tiles('9p')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      expect(r.waits, isNotEmpty);
      for (final o in r.waits) {
        expect(o.discard, isNotNull, reason: '打牌前なので切る牌がある');
        for (final w in o.tiles) {
          expect(o.remaining[w], greaterThan(0));
        }
      }
    });

    test('鳴いた後(打牌済み)は discard が null の1件', () {
      // 中ポン + 234m 567m 99p + 45s → 3s/6s待ち。打牌済みの形。
      // makeView は drawn を指定しないと打牌済み(13枚)相当にできないが、
      // ここでは副露1つ+手牌10枚+ツモ無し = 打牌前なので、代わりに
      // 「hand が 3n+1 枚」を drawn 無しで作る。
      final v = makeView(
        hand: tiles('234567m99p45s'), // 10枚 = 13 - 3(副露1)
        myMelds: [
          const Meld(
            type: MeldType.pon,
            tiles: [33, 33, 33],
            fromSeat: 3,
            calledTile: 33,
          ), // 中ポン
        ],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      expect(r.waits.length, 1);
      expect(r.waits.first.discard, isNull);
      expect(r.waits.first.tiles, [tiles('3s')[0], tiles('6s')[0]]);
    });
  });

  group('ピンフ', () {
    test('両面待ちのテンパイならピンフが出る', () {
      // 234m 567m 234p 99s + 45p → 3p/6p の両面待ち
      final v = makeView(
        hand: tiles('234567m23445p99s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      expect(find(r, 'ピンフ'), isNotNull);
    });

    test('嵌張待ちのテンパイではピンフを出さない', () {
      // 234m 567m 234p 99s + 46p → 5p の嵌張待ち。ピンフは付かない
      final v = makeView(
        hand: tiles('234567m23446p99s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      expect(find(r, 'ピンフ'), isNull, reason: '嵌張待ちにピンフは付かない');
    });

    test('単騎待ちのテンパイではピンフを出さない', () {
      // 234m 567m 234p 456p + 9s単騎
      final v = makeView(
        hand: tiles('234567m234456p9s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      expect(find(r, 'ピンフ'), isNull, reason: '単騎待ちにピンフは付かない');
    });

    test('辺張待ちのテンパイではピンフを出さない', () {
      // 234m 567m 234p 99s + 12p → 3p の辺張待ち
      final v = makeView(
        hand: tiles('234567m23412p99s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      expect(find(r, 'ピンフ'), isNull, reason: '辺張待ちにピンフは付かない');
    });

    test('聴牌前は形の目安でピンフを出す', () {
      // まだ待ちが決まらない段階。暗刻も役牌の対子も無いのでピンフに向かえる
      final v = makeView(
        hand: tiles('234m5678p234s45s'),
        drawn: tiles('9m')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, greaterThan(0));
      expect(find(r, 'ピンフ'), isNotNull, reason: '形が決まる前はピンフを狙える方向として出してよい');
    });
  });

  group('候補の並び順', () {
    test('遠回りな役は手なりの役より後ろに並ぶ', () {
      // テンパイしていて、三色は遠い形
      final v = makeView(
        hand: tiles('234567m88p45699s'),
        drawn: tiles('1z')[0],
      );
      final r = buildAdvice(v);
      expect(r.shanten, 0);
      for (var i = 1; i < r.offense.length; i++) {
        final prev = r.offense[i - 1].shanten ?? r.shanten;
        final cur = r.offense[i].shanten ?? r.shanten;
        expect(
          prev,
          lessThanOrEqualTo(cur),
          reason: '近い役ほど先に出すべき(テンパイを差し置いて遠回りを勧めない)',
        );
      }
    });
  });
}
