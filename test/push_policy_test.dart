import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/advisor.dart';
import 'package:mahjong_taku/engine/ai.dart';

/// CPU の押し引き方針(PushPolicy)。値の根拠は CPU 校正記録(非公開文書)§11.3。
void main() {
  test('既定(校正後): テンパイは押す、1シャンテンは価値4以上か安全な攻め牌、'
      '2シャンテン以上は現物のみ', () {
    const p = PushPolicy();
    expect(p.shouldPush(shanten: 0, handValue: 0), isTrue);
    expect(p.shouldPush(shanten: -1, handValue: 0), isTrue);
    expect(p.shouldPush(shanten: 1, handValue: 3), isFalse);
    expect(p.shouldPush(shanten: 1, handValue: 4), isTrue);
    expect(p.shouldPush(shanten: 1, handValue: 0, attackRisk: 90), isTrue);
    expect(p.shouldPush(shanten: 1, handValue: 0, attackRisk: 70), isFalse);
    expect(p.shouldPush(shanten: 2, handValue: 10), isFalse);
    expect(p.shouldPush(shanten: 2, handValue: 0, attackRisk: 100), isTrue);
    expect(p.shouldPush(shanten: 3, handValue: 10, attackRisk: 90), isFalse);
  });

  test('旧方針(legacy): 1シャンテンは価値3以上、安全な攻め牌の特例なし', () {
    const p = PushPolicy.legacy;
    expect(p.shouldPush(shanten: 1, handValue: 3), isTrue);
    expect(p.shouldPush(shanten: 1, handValue: 2, attackRisk: 100), isFalse);
    expect(p.shouldPush(shanten: 2, handValue: 9, attackRisk: 100), isFalse);
  });

  test('safePushRisk: 攻めの打牌が十分安全なら手の価値に関わらず押す(1シャンテン)', () {
    const p = PushPolicy(safePushRisk: 90, deepSafePushRisk: 100);
    expect(p.shouldPush(shanten: 1, handValue: 0, attackRisk: 90), isTrue);
    expect(p.shouldPush(shanten: 1, handValue: 0, attackRisk: 89), isFalse);
    // 2シャンテン以上は deepSafePushRisk(現物のみ)
    expect(p.shouldPush(shanten: 3, handValue: 0, attackRisk: 100), isTrue);
    expect(p.shouldPush(shanten: 3, handValue: 0, attackRisk: 90), isFalse);
    // 0 なら無効(現物でも手の価値で判定)
    const off = PushPolicy(safePushRisk: 0, deepSafePushRisk: 0);
    expect(off.shouldPush(shanten: 1, handValue: 0, attackRisk: 100), isFalse);
    expect(off.shouldPush(shanten: 2, handValue: 0, attackRisk: 100), isFalse);
  });

  test('twoShantenValue: 2シャンテンでも価値が高ければ押す', () {
    const p = PushPolicy(twoShantenValue: 4);
    expect(p.shouldPush(shanten: 2, handValue: 3), isFalse);
    expect(p.shouldPush(shanten: 2, handValue: 4), isTrue);
    expect(p.shouldPush(shanten: 3, handValue: 9), isFalse);
  });

  group('RiichiPolicy(ダマ判断)', () {
    const yaku = DamaInfo(waitCount: 3, yakuWaitCount: 3, maxRonPoints: 2000);
    const noYaku = DamaInfo(waitCount: 3, yakuWaitCount: 0, maxRonPoints: 0);
    const wide = DamaInfo(waitCount: 8, yakuWaitCount: 8, maxRonPoints: 2000);

    test('役の無い(取りこぼす)聴牌は常にリーチ', () {
      const p = RiichiPolicy();
      expect(
        p.shouldDama(
          dama: noYaku,
          wall: 5,
          southRound: true,
          isTop: true,
          lead: 9000,
        ),
        isFalse,
      );
    });

    test('既定: 役ありで待ち4枚以下・残り山10未満・南場トップ4000点差のいずれかでダマ', () {
      const p = RiichiPolicy();
      bool d(
        DamaInfo i, {
        int wall = 40,
        bool south = false,
        bool top = false,
        int lead = 0,
      }) => p.shouldDama(
        dama: i,
        wall: wall,
        southRound: south,
        isTop: top,
        lead: lead,
      );
      expect(d(yaku), isTrue); // 待ち3枚
      expect(d(wide), isFalse); // 待ち8枚・山あり・東場
      expect(d(wide, wall: 9), isTrue);
      expect(d(wide, wall: 10), isFalse);
      expect(d(wide, south: true, top: true, lead: 4000), isTrue);
      expect(d(wide, south: false, top: true, lead: 9000), isFalse);
      expect(d(wide, south: true, top: false, lead: 0), isFalse);
    });

    test('alwaysRiichi: 役があってもダマにしない', () {
      const p = RiichiPolicy.alwaysRiichi;
      expect(
        p.shouldDama(
          dama: yaku,
          wall: 3,
          southRound: true,
          isTop: true,
          lead: 9000,
        ),
        isFalse,
      );
    });
  });

  group('AttackPolicy(攻めの打牌)', () {
    test('既定は受け入れ損失0(同枚数のときだけ打点で選ぶ)、legacy は常に打点重視', () {
      expect(const AttackPolicy().maxUkeireLoss, 0);
      expect(AttackPolicy.legacy.maxUkeireLoss, 99);
    });
  });

  group('CallPolicy(鳴き判断)', () {
    const p = CallPolicy();
    bool call({
      bool yakuhai = false,
      bool menzen = true,
      int before = 2,
      int after = 1,
      int value = 0,
      bool threat = false,
    }) => p.shouldCall(
      yakuhai: yakuhai,
      menzen: menzen,
      before: before,
      after: after,
      handValue: value,
      threat: threat,
    );

    test('役牌: シャンテンが進んで鳴いた後2シャンテン以内ならポン', () {
      expect(call(yakuhai: true, before: 2, after: 1), isTrue);
      expect(call(yakuhai: true, before: 3, after: 2), isTrue);
      expect(call(yakuhai: true, before: 4, after: 3), isFalse); // 深すぎる
      expect(call(yakuhai: true, before: 2, after: 2), isFalse); // 進まない
      expect(call(yakuhai: true, before: 1, after: 2), isFalse); // 戻る
    });

    test('役牌: ドラ+赤が3枚以上なら進まなくてもポン(戻るなら不可)', () {
      expect(call(yakuhai: true, before: 3, after: 3, value: 3), isTrue);
      expect(call(yakuhai: true, before: 1, after: 2, value: 5), isFalse);
    });

    test('役牌以外: 門前は鳴かない、副露済みは進んで2シャンテン以内なら鳴く', () {
      expect(call(menzen: true, before: 1, after: 0), isFalse);
      expect(call(menzen: false, before: 2, after: 1), isTrue);
      expect(call(menzen: false, before: 3, after: 2), isTrue);
      expect(call(menzen: false, before: 4, after: 3), isFalse);
      expect(call(menzen: false, before: 2, after: 2), isFalse);
    });

    test('他家リーチ中は鳴いてテンパイするときだけ', () {
      expect(call(yakuhai: true, before: 1, after: 0, threat: true), isTrue);
      expect(call(yakuhai: true, before: 2, after: 1, threat: true), isFalse);
      expect(call(menzen: false, before: 1, after: 0, threat: true), isTrue);
    });

    test('legacy: 役牌は常にポン、副露済みは進めば鳴く', () {
      const l = CallPolicy.legacy;
      expect(
        l.shouldCall(
          yakuhai: true,
          menzen: true,
          before: 4,
          after: 4,
          handValue: 0,
          threat: false,
        ),
        isTrue,
      );
      expect(
        l.shouldCall(
          yakuhai: false,
          menzen: false,
          before: 4,
          after: 3,
          handValue: 0,
          threat: false,
        ),
        isTrue,
      );
    });
  });
}
