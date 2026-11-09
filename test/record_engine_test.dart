import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/record/record_engine.dart';

import 'hand_test.dart' show tiles;

RecordEngine makeEngine() => RecordEngine(names: ['東家', '南家', '西家', '北家']);

int t(String s) => tiles(s)[0];

void main() {
  test('ドラ牌そのもの→表示牌の逆変換', () {
    expect(indicatorFromDora(t('6m')), t('5m'));
    expect(indicatorFromDora(t('1p')), t('9p'));
    expect(indicatorFromDora(t('1z')), t('4z')); // 東のドラ表示は北
    expect(indicatorFromDora(t('5z')), t('7z')); // 白のドラ表示は中
    // doraFromIndicator と互いに逆
    for (var k = 0; k < 34; k++) {
      expect(Tile.doraFromIndicator(indicatorFromDora(k)), k);
    }
  });

  test('親のツモ和了: 役・点数の完全自動計算とDB互換エクスポート', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    // 1巡回す(第一ツモ和了だと天和になるため)
    for (var i = 0; i < 4; i++) {
      eng.draw(t('1z'));
      eng.discard(t('1z'), tsumogiri: true);
    }
    eng.draw(t('6s'));
    eng.tsumoWin(hand13: tiles('234m567m345p78s66s'));

    final r = eng.result!;
    expect(r.type, 'win');
    final yaku = r.wins.first.score!.yaku.map((y) => y.name).toList();
    expect(yaku, containsAll(['門前清自摸和', '平和', '断么九']));
    expect(r.scoreChanges, [3900, -1300, -1300, -1300]);
    expect(r.endScores, [28900, 23700, 23700, 23700]);

    final game = eng.buildGameJson(settle: false);
    final kyoku = (game['kyokus'] as List).first as Map;
    expect(kyoku['round'], '1z1');
    expect(kyoku['parent_player_id'], 0);
    final events = (kyoku['events'] as List).cast<Map>();
    expect(events.first['type'], 'dora_indicator');
    expect(events.first['dora_indicator'], '4z');
    final haipai = events.firstWhere((e) => e['type'] == 'haipai');
    expect(haipai['player_id'], 0);
    expect(haipai['hand'], '234567m345p6678s');
    final tsumo = events.firstWhere((e) => e['type'] == 'tsumo');
    expect(tsumo['winning_tile'], 't6s');
    expect(tsumo['points'], 3900);
  });

  test('リーチ・一発・裏ドラのロン和了(供託・リーチ棒の精算込み)', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('1m'));
    eng.discard(t('1m'), tsumogiri: true);
    eng.draw(t('9p'));
    eng.discard(t('9p'), riichi: true, tsumogiri: true);
    expect(eng.displayScore(1), 24000);
    expect(eng.sticksOnTable, 1);
    eng.draw(t('7z'));
    eng.discard(t('7z'), tsumogiri: true);
    eng.ronWin(
      winner: 1,
      hand13: tiles('234m567m345p66s77z'),
      ura: tiles('2p'),
    );

    final r = eng.result!;
    final yaku = r.wins.first.score!.yaku.map((y) => y.name).toList();
    // 1巡目の宣言なのでダブル立直になる
    expect(yaku, containsAll(['ダブル立直', '一発', '役牌 中', '裏ドラ']));
    // 満貫8000 + リーチ棒1000
    expect(r.scoreChanges[1], 9000);
    expect(r.scoreChanges[2], -8000);
    expect(r.endScores[1], 25000 - 1000 + 9000);

    final game = eng.buildGameJson(settle: false);
    final events = ((game['kyokus'] as List).first as Map)['events'] as List;
    final reach = events.cast<Map>().firstWhere((e) => e['type'] == 'reach');
    expect(reach['is_accepted'], true);
    final ura = events.cast<Map>().firstWhere(
      (e) => e['type'] == 'dora_indicator' && e['dora_type'] == 'ura',
    );
    expect(ura['dora_indicator'], '2p');
    final ron = events.cast<Map>().firstWhere((e) => e['type'] == 'ron');
    expect(ron['target_player_id'], 2);
    expect(ron['winning_tile'], '7z');
  });

  test('リーチ宣言牌へのロンはリーチ不成立(reach is_accepted=false)', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('1m'));
    eng.discard(t('1m'), tsumogiri: true);
    eng.draw(t('7z'));
    eng.discard(t('7z'), riichi: true, tsumogiri: true);
    eng.ronWin(winner: 0, hand13: tiles('234m567m345p66s77z'));

    final r = eng.result!;
    // リーチ棒は供託になっていない(和了に乗らない・宣言者も払わない)
    expect(eng.sticksOnTable, 0);
    expect(r.endScores[1], 25000 - r.scoreChanges[0]);
    final game = eng.buildGameJson(settle: false);
    final events = ((game['kyokus'] as List).first as Map)['events'] as List;
    final reach = events.cast<Map>().firstWhere((e) => e['type'] == 'reach');
    expect(reach['is_accepted'], false);
  });

  test('ポン・チーのブロック表記と配牌の自動逆算', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('5m'));
    eng.discard(t('3p')); // 手出し(未知スロットから 3p が確定)
    eng.pon(2); // 対面(席2)がポン
    eng.discard(t('8s')); // 席2の手出し
    eng.chi(tiles('67s')); // 下家(席3)がチー
    eng.discard(t('1z'));
    eng.ryukyoku(const []);

    final game = eng.buildGameJson(settle: false);
    final kyoku = (game['kyokus'] as List).first as Map;
    final events = (kyoku['events'] as List).cast<Map>();
    final pon = events.firstWhere((e) => e['type'] == 'pon');
    expect(pon['actor_player_id'], 2);
    expect(pon['target_player_id'], 0);
    expect(pon['block'], '3p-3p3p'); // 対面からの鳴きは2番目
    final chi = events.firstWhere((e) => e['type'] == 'chi');
    expect(chi['actor_player_id'], 3);
    expect(chi['block'], '-8s6s7s');
    // 逆算: 席0の配牌に3p、席2にポンで晒した3p×2と手出し8s、
    // 席3にチーの67sと手出し1z
    Map h(int seat) => events.firstWhere(
      (e) => e['type'] == 'haipai' && e['player_id'] == seat,
    );
    expect(h(0)['hand'], '3p');
    expect(h(2)['hand'], '33p8s');
    expect(h(3)['hand'], '67s1z');
  });

  test('不明ツモのツモ切りを後から埋めるとツモ・打牌の両方が確定する', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(null);
    eng.discard(null, tsumogiri: true);
    expect(eng.seats[0].river.single.tile, isNull);

    // events: [dora, draw, discard] → 打牌側を埋める
    eng.resolveUnknown(2, t('9p'));
    expect(eng.seats[0].river.single.tile, t('9p'));
    eng.ryukyoku(const []);
    final events =
        (((eng.buildGameJson(settle: false))['kyokus'] as List).first
                as Map)['events']
            as List;
    final draw = events.cast<Map>().firstWhere((e) => e['type'] == 'draw');
    expect(draw['tile'], '9p'); // 対のツモも埋まる
    final discard = events.cast<Map>().firstWhere(
      (e) => e['type'] == 'discard',
    );
    expect(discard['tile'], '9p');
    expect(discard['is_tsumogiri'], true);
  });

  test('不明ツモを既知牌でツモ切りするとツモイベントも同時確定する', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(null);
    // リーチ者のツモ切り記録を想定: ツモは見えなかったが打牌は見えた
    eng.discard(t('5p'), tsumogiri: true);
    final river = eng.seats[0].river.single;
    expect(river.tile, t('5p'));
    expect(river.tsumogiri, true);
    expect(eng.events[1].type, 'draw');
    expect(eng.events[1].tile, t('5p')); // ツモイベントも埋まっている
  });

  test('手牌欠損の和了は手動点数で記録できる', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('1m'));
    eng.discard(t('1m'), tsumogiri: true);
    eng.draw(t('7z'));
    eng.discard(t('7z'), tsumogiri: true);
    eng.ronWin(winner: 3, manualPoints: 12000);

    final r = eng.result!;
    expect(r.scoreChanges[3], 12000);
    expect(r.scoreChanges[1], -12000);
    final events =
        (((eng.buildGameJson(settle: false))['kyokus'] as List).first
                as Map)['events']
            as List;
    final ron = events.cast<Map>().firstWhere((e) => e['type'] == 'ron');
    expect(ron['points'], 12000);
    expect(ron['yaku'], isEmpty);
    expect(ron['winning_tile'], '7z');
  });

  test('流局: ノーテン罰符と親流れ・供託とリーチ棒の持ち越し', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('9p'));
    eng.discard(t('9p'), riichi: true, tsumogiri: true);
    eng.ryukyoku([0], revealedHands: {0: tiles('234m567m345p66s77z')});
    final r = eng.result!;
    expect(r.scoreChanges, [3000, -1000, -1000, -1000]);
    // リーチ者は席0: リーチ-1000(棒は場に残る)+テンパイ料+3000
    expect(r.endScores[0], 25000 - 1000 + 3000);

    eng.nextKyoku();
    expect(eng.roundLabel, '東1局'); // 親テンパイで連荘
    expect(eng.honba, 1);
    expect(eng.carriedSticks, 1); // リーチ棒は持ち越し
    // 逆算: 開示された手牌が配牌に割り付いている
    final kyoku = eng.exportedKyokus.first;
    final haipai = (kyoku['events'] as List).cast<Map>().firstWhere(
      (e) => e['type'] == 'haipai',
    );
    expect(haipai['hand'], '234567m345p66s77z');
  });

  test('局送り: 子の和了で親流れ、東4→南1', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('1m'));
    eng.discard(t('1m'), tsumogiri: true);
    eng.draw(t('6s'));
    eng.tsumoWin(hand13: tiles('234m567m345p78s66s')); // 席1のツモ
    eng.nextKyoku();
    expect(eng.roundLabel, '東2局');
    expect(eng.dealer, 1);
    expect(eng.honba, 0);

    // 東4局まで進める(全員ノーテン流局を3回)
    for (var i = 0; i < 3; i++) {
      eng.tapDora(t('1z'));
      eng.ryukyoku(const []);
      eng.nextKyoku();
    }
    expect(eng.roundLabel, '南1局');
    expect(eng.dealer, 0);
  });

  test('取消はイベント単位で何段でも戻れる', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('5m'));
    eng.discard(t('3p'));
    eng.pon(2);
    expect(eng.seats[2].melds, hasLength(1));
    eng.undo(); // ポン取消
    expect(eng.seats[2].melds, isEmpty);
    expect(eng.seats[0].river.single.called, false);
    eng.undo(); // 打牌取消
    expect(eng.seats[0].river, isEmpty);
    expect(eng.phase, 'discard');
    expect(eng.drawnTile, t('5m'));
    eng.undo(); // ツモ取消
    expect(eng.phase, 'draw');
    eng.undo(); // ドラ取消
    expect(eng.phase, 'dora');
    expect(eng.canUndo, false);
  });

  test('嶺上開花に海底摸月は複合しない(山0の嶺上ツモ)', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    // 山を2枚まで消化する(68回のツモ切り)。ラス牌ツモ後のカンは
    // 嶺上補充ができず不可なので、山が1枚残る巡でカンする。
    for (var i = 0; i < 68; i++) {
      eng.draw(t('1z'));
      eng.discard(t('1z'), tsumogiri: true);
    }
    expect(eng.wallRemaining, 2);
    eng.draw(t('2z')); // 山2→1
    eng.ankan(t('3z')); // 山1→0(嶺上補充)
    expect(eng.wallRemaining, 0);
    eng.draw(t('6s')); // 嶺上ツモ
    eng.tsumoWin(hand13: tiles('234m567m345p6s'));
    final yaku = eng.result!.wins.first.score!.yaku.map((y) => y.name).toList();
    expect(yaku, contains('嶺上開花'));
    expect(yaku, isNot(contains('海底摸月')));
  });

  test('天和・地和の自動判定', () {
    // 天和: 親の第一ツモ和了
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('6s'));
    eng.tsumoWin(hand13: tiles('234m567m345p78s66s'));
    final tenhou = eng.result!.wins.first;
    expect(tenhou.score!.isYakuman, isTrue);
    expect(tenhou.score!.yaku.map((y) => y.name), contains('天和'));

    // 地和: 子の第一ツモ和了(鳴きなし)
    final eng2 = makeEngine();
    eng2.tapDora(t('1z'));
    eng2.draw(t('1m'));
    eng2.discard(t('1m'), tsumogiri: true);
    eng2.draw(t('6s'));
    eng2.tsumoWin(hand13: tiles('234m567m345p78s66s'));
    final chihou = eng2.result!.wins.first;
    expect(chihou.score!.isYakuman, isTrue);
    expect(chihou.score!.yaku.map((y) => y.name), contains('地和'));
  });

  test('アガリ者は一局に1人(頭ハネ): 2人目のロンは記録できない', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('7z'));
    eng.discard(t('7z'), tsumogiri: true); // 席0の放銃
    eng.ronWin(winner: 1, hand13: tiles('234m567m345p66s77z'));
    expect(eng.result!.wins.single.seat, 1);
    // Mリーグ「アガリ者は一局に1人とする」— 局が終わっているので追加不可
    expect(
      () => eng.ronWin(winner: 3, hand13: tiles('234m567m345p66s77z')),
      throwsStateError,
    );
  });

  test('海底牌を摸した者はリーチを掛けられない', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    for (var i = 0; i < 69; i++) {
      eng.draw(t('1z'));
      eng.discard(t('1z'), tsumogiri: true);
    }
    eng.draw(t('9p')); // 海底牌
    expect(eng.wallRemaining, 0);
    expect(
      () => eng.discard(t('9p'), riichi: true, tsumogiri: true),
      throwsStateError,
    );
    eng.discard(t('9p'), tsumogiri: true); // リーチなしなら打牌できる
    expect(eng.phase, 'exhausted');
  });

  test('カンは4回まで・山が無いとカンできない', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    for (var i = 0; i < 4; i++) {
      eng.draw(t('1z'));
      eng.ankan(27 + 1 + i); // 2z,3z,4z,5z の暗槓
      eng.draw(t('9p')); // 嶺上
      eng.discard(t('9p'), tsumogiri: true);
    }
    eng.draw(t('1z'));
    expect(() => eng.ankan(t('7z')), throwsStateError); // 5回目

    // 山0でのカン
    final eng2 = makeEngine();
    eng2.tapDora(t('1z'));
    for (var i = 0; i < 70; i++) {
      eng2.draw(t('1z'));
      eng2.discard(t('1z'), tsumogiri: true);
    }
    expect(eng2.wallRemaining, 0);
    expect(eng2.phase, 'exhausted');

    final eng3 = makeEngine();
    eng3.tapDora(t('1z'));
    for (var i = 0; i < 69; i++) {
      eng3.draw(t('1z'));
      eng3.discard(t('1z'), tsumogiri: true);
    }
    eng3.draw(t('2z')); // 最後の1枚
    expect(() => eng3.ankan(t('3z')), throwsStateError); // 山0になるカンは不可
  });

  test('局の途中で精算しても未保存局のリーチ棒は供託に混ざらない', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('9p'));
    eng.discard(t('9p'), riichi: true, tsumogiri: true); // 成立リーチ(未保存局)
    final game = eng.buildGameJson(settle: true);
    final points = [
      for (final r in (game['results'] as List)) (r as Map)['points'] as num,
    ];
    // 供託が余分に配られると合計が+1になる
    expect(points.reduce((a, b) => a + b), closeTo(0, 0.001));
  });

  test('責任払い(大三元): 3つ目の三元牌を鳴かせた者がツモでも全額払う', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('1m'));
    eng.discard(t('1m'), tsumogiri: true);
    // 席1が白・發・中を切り、席0(親)がすべてポン
    for (final d in ['5z', '6z', '7z']) {
      eng.draw(t('9m'));
      eng.discard(t(d));
      eng.pon(0);
      eng.discard(t('2p'));
    }
    expect(eng.seats[0].paoDaisangen, 1);
    // 席2・3・1が回して席0のツモ番へ
    for (var i = 0; i < 3; i++) {
      eng.draw(t('1s'));
      eng.discard(t('1s'), tsumogiri: true);
    }
    eng.draw(t('9p'));
    eng.tsumoWin(hand13: tiles('234m9p')); // 234m+99p+白發中ポン = 大三元
    final r = eng.result!;
    expect(r.wins.first.score!.yaku.map((y) => y.name), contains('大三元'));
    // 親の役満48000を包(席1)が全額責任払い
    expect(r.scoreChanges, [48000, -48000, 0, 0]);
  });

  test('責任払い(大三元): ロンは包と放銃者で折半', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    eng.draw(t('1m'));
    eng.discard(t('1m'), tsumogiri: true);
    for (final d in ['5z', '6z', '7z']) {
      eng.draw(t('9m'));
      eng.discard(t(d));
      eng.pon(0);
      eng.discard(t('2p'));
    }
    // 席2が9pを打って席0がロン
    eng.draw(t('1s'));
    eng.discard(t('1s'), tsumogiri: true); // 席2ではなく…席1の番
    eng.draw(t('9p'));
    eng.discard(t('9p'), tsumogiri: true); // 席2の放銃
    eng.ronWin(winner: 0, hand13: tiles('234m9p'));
    final r = eng.result!;
    // 放銃者(席2)と包(席1)で24000ずつ折半
    expect(r.scoreChanges, [48000, -24000, -24000, 0]);
  });

  group('ルール準拠レビュー(2026-07-30)の回帰', () {
    test('別種の牌をツモって暗槓しても、ツモ牌が手牌モデルから消えない', () {
      final eng = makeEngine();
      eng.tapDora(t('1z'));
      eng.draw(t('3m')); // 2zと別種のツモ
      eng.ankan(t('2z'));
      eng.draw(t('9p')); // 嶺上
      eng.discard(t('9p'), tsumogiri: true);
      // 手牌: 13 - 暗槓4 + ツモ3m = 10枚(3mは既知として残る)
      expect(eng.seats[0].handSize, 10);
      expect(eng.seats[0].known, contains(t('3m')));
    });

    test('チーは順子の形しか受け付けない', () {
      final eng = makeEngine();
      eng.tapDora(t('1z'));
      eng.draw(t('1m'));
      eng.discard(t('3p'));
      expect(() => eng.chi(tiles('56s')), throwsStateError); // 3p+56s は順子でない
      eng.chi(tiles('45p')); // 345p は正しい形
      expect(eng.seats[1].melds.single.isRun, isTrue);
    });

    test('赤なしポンの5を加槓すると4枚目は必ず赤になる', () {
      final eng = makeEngine();
      eng.tapDora(t('1z'));
      eng.draw(t('1m'));
      eng.discard(t('5s')); // 通常5s
      eng.pon(1); // 赤なしで晒す
      eng.discard(t('1z'));
      // 席2,3,0が回って席1のツモ番
      for (var i = 0; i < 3; i++) {
        eng.draw(t('9p'));
        eng.discard(t('9p'), tsumogiri: true);
      }
      eng.draw(t('5s')); // パレットでは通常5sをタップ(実物は赤しか残っていない)
      eng.kakan(t('5s'));
      final meld = eng.seats[1].melds.single;
      expect(meld.tiles.where(Tile.isRed), hasLength(1));
    });

    test('鳴き直後(ツモ番でない打牌待ち)にカンはできない', () {
      final eng = makeEngine();
      eng.tapDora(t('1z'));
      eng.draw(t('1m'));
      eng.discard(t('3p'));
      eng.pon(2);
      expect(() => eng.ankan(t('7z')), throwsStateError);
    });

    test('リーチ中の手出しはエンジンでも拒否される', () {
      final eng = makeEngine();
      eng.tapDora(t('1z'));
      eng.draw(t('9p'));
      eng.discard(t('9p'), riichi: true, tsumogiri: true);
      for (var i = 0; i < 3; i++) {
        eng.draw(t('1z'));
        eng.discard(t('1z'), tsumogiri: true);
      }
      eng.draw(t('1m'));
      expect(() => eng.discard(t('2p')), throwsStateError); // 手出し
      eng.discard(t('1m'), tsumogiri: true); // ツモ切りは通る
    });

    test('表ドラはカンごとに1枚まで(カンより先に増やせない)', () {
      final eng = makeEngine();
      eng.tapDora(t('1z'));
      expect(() => eng.tapDora(t('2z')), throwsStateError); // カン前の2枚目
      eng.draw(t('1m'));
      eng.ankan(t('2z'));
      eng.tapDora(t('3z')); // カン後はOK
      expect(eng.doraIndicators, hasLength(2));
    });

    test('包が確定している和了は手動点数で記録できない(手牌必須)', () {
      final eng = makeEngine();
      eng.tapDora(t('1z'));
      eng.draw(t('1m'));
      eng.discard(t('1m'), tsumogiri: true);
      for (final d in ['5z', '6z', '7z']) {
        eng.draw(t('9m'));
        eng.discard(t(d));
        eng.pon(0);
        eng.discard(t('2p'));
      }
      expect(eng.seats[0].paoDaisangen, 1);
      for (var i = 0; i < 3; i++) {
        eng.draw(t('1s'));
        eng.discard(t('1s'), tsumogiri: true);
      }
      eng.draw(t('9p'));
      expect(() => eng.tsumoWin(childPay: 16000), throwsStateError);
    });

    test('南4局で親が流れたらnextKyokuできない(西入なし)', () {
      final eng = RecordEngine(
        names: ['東家', '南家', '西家', '北家'],
        roundWind: 1,
        kyokuNum: 4,
      );
      eng.tapDora(t('1z'));
      eng.ryukyoku(const []); // 全員ノーテン=親流れ
      expect(() => eng.nextKyoku(), throwsStateError);
    });
  });

  group('遡り穴埋め(局アーカイブ)', () {
    test('確定済みの局の「?」と手牌を後から埋めて再エクスポートできる', () {
      final eng = makeEngine();
      eng.tapDora(t('1z'));
      eng.draw(null); // 不明ツモ
      eng.discard(null, tsumogiri: true); // 不明打牌
      eng.draw(t('6s'));
      eng.discard(t('6s'), tsumogiri: true);
      eng.ryukyoku(const []);
      eng.nextKyoku();
      expect(eng.archives, hasLength(1));
      expect(eng.roundLabel, '東2局'); // 本体は次局へ進んでいる

      // 遡って「?」を埋める(ツモ切りペアも連動)
      final sub = RecordEngine.replay(eng.archives[0], eng.names);
      expect(sub.unknownCounts.marks, 2);
      sub.resolveUnknown(2, t('9p'));
      expect(sub.unknownCounts.marks, 0);
      // 手牌の写し(配牌へ逆算)も後からできる
      sub.editHand(1, tiles('123m'));

      final json = sub.exportKyokuJson();
      final events = (json['events'] as List).cast<Map>();
      expect(
        events.any((e) => e['type'] == 'discard' && e['tile'] == '9p'),
        isTrue,
      );
      final haipai = events.firstWhere(
        (e) => e['type'] == 'haipai' && e['player_id'] == 1,
      );
      expect(haipai['hand'], '123m');
      // 点数は変わらない(穴埋めは牌の確定だけ)
      expect(json['end_scores'], eng.archives[0].startScores);
    });

    test('生イベント列が保存JSONに同梱され、JSON往復で復元できる', () {
      final eng = makeEngine();
      eng.tapDora(t('1z'));
      eng.draw(t('1m'));
      eng.discard(t('9p'), riichi: true, tsumogiri: false);
      eng.draw(t('7z'));
      eng.discard(t('7z'), tsumogiri: true);
      eng.ronWin(
        winner: 1,
        hand13: tiles('234m567m345p66s77z'),
        ura: tiles('2p'),
      );
      final game = eng.buildGameJson(settle: false);
      final rec = game['rec_kyokus'] as List;
      expect(rec, hasLength(1)); // 進行中(結果確定済み)の局も含む

      // JSONから復元して畳み込み直すと同じ結果になる
      final a = RecKyokuArchive.fromJson(
        (rec.first as Map).cast<String, dynamic>(),
      );
      final sub = RecordEngine.replay(a, eng.names);
      expect(sub.result, isNotNull);
      expect(sub.result!.endScores, eng.result!.endScores);
      expect(sub.result!.wins.single.seat, 1);
    });
  });

  test('試合終了の精算(settle)で順位・ポイントが付く', () {
    final eng = makeEngine();
    eng.tapDora(t('1z'));
    for (var i = 0; i < 4; i++) {
      eng.draw(t('1z'));
      eng.discard(t('1z'), tsumogiri: true);
    }
    eng.draw(t('6s'));
    eng.tsumoWin(hand13: tiles('234m567m345p78s66s'));
    final game = eng.buildGameJson(settle: true);
    final results = (game['results'] as List).cast<Map>();
    expect(results[0]['rank'], 1);
    expect(results[0]['score'], 28900);
    expect(results[0]['points'], closeTo(48.9, 0.001)); // 28.9-30+50
    expect(game['finished'], true);
  });
}
