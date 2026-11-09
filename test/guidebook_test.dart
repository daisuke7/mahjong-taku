import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/hand.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/ui/widgets/guidebook.dart';

/// 3枚の副露が刻子または順子か
bool _isValidMeld(List<int> tiles) {
  if (tiles.length != 3) return false;
  final k = tiles.map(Tile.normalize).toList()..sort();
  if (k[0] == k[1] && k[1] == k[2]) return true; // 刻子
  // 順子(同一スート・連番・数牌)
  if (k[0] < 27 &&
      Tile.suit(k[0]) == Tile.suit(k[2]) &&
      k[1] == k[0] + 1 &&
      k[2] == k[0] + 2) {
    return true;
  }
  return false;
}

void main() {
  group('点数表: 存在しない符・翻の組合せ', () {
    test('20符ロンは無い(平和ツモ限定)', () {
      for (final han in [1, 2, 3, 4]) {
        expect(
          scoreImpossible(fu: 20, han: han, isTsumo: false),
          isTrue,
          reason: '20符ロン $han翻',
        );
      }
    });
    test('20符ツモの1翻は無い(平和ツモは必ず2翻以上)', () {
      expect(scoreImpossible(fu: 20, han: 1, isTsumo: true), isTrue);
      // 2翻以上は存在する(平和ツモ)
      expect(scoreImpossible(fu: 20, han: 2, isTsumo: true), isFalse);
      expect(scoreImpossible(fu: 20, han: 3, isTsumo: true), isFalse);
    });
    test('25符の1翻は無い(七対子は2翻)', () {
      expect(scoreImpossible(fu: 25, han: 1, isTsumo: false), isTrue);
      expect(scoreImpossible(fu: 25, han: 1, isTsumo: true), isTrue);
    });
    test('25符ツモの2翻は無い(七対子ツモは必ず3翻以上)', () {
      expect(scoreImpossible(fu: 25, han: 2, isTsumo: true), isTrue);
      // 3翻以上は存在する(七対子ツモ)
      expect(scoreImpossible(fu: 25, han: 3, isTsumo: true), isFalse);
      // ロンの2翻(七対子ロン)は存在する
      expect(scoreImpossible(fu: 25, han: 2, isTsumo: false), isFalse);
    });
    test('30符などの通常の組合せは存在する', () {
      expect(scoreImpossible(fu: 30, han: 1, isTsumo: true), isFalse);
      expect(scoreImpossible(fu: 30, han: 1, isTsumo: false), isFalse);
      expect(scoreImpossible(fu: 40, han: 4, isTsumo: true), isFalse);
    });
  });

  group('Tile.parse', () {
    test('記法をパースできる', () {
      expect(Tile.parse('123m'), [0, 1, 2]);
      expect(Tile.parse('1z'), [Tile.east]);
      expect(Tile.parse('7z'), [Tile.chun]);
      expect(Tile.parse('0m'), [Tile.red5m]);
    });
  });

  test('役一覧の牌姿例は14枚の和了形(門前・鳴き両方)', () {
    // (手の内, 副露[null=門前])。ガイドブックの例と一致させる
    const examples = <(String, String?)>[
      ('234m567m22p345s678s', null), // 平和
      ('234m567m345s88p', '222p'), // タンヤオ(鳴き)
      ('223344m567p88s678s', null), // 一盃口
      ('234m567m789m55p', '555z'), // 役牌(鳴き)
      ('234m234s678p55z', '234p'), // 三色同順(鳴き)
      ('123456m678s22p', '789m'), // 一気通貫(鳴き)
      ('123m789m111z99s', '123p'), // チャンタ(鳴き)
      ('1122m4455p3377s66z', null), // 七対子
      ('333m888s333z22p', '555m'), // トイトイ(鳴き)
      ('111m333m555p22z', '678s'), // 三暗刻(鳴き)
      ('333m333p678s55z', '333s'), // 三色同刻(鳴き)
      ('234m555z66z678s', '777z'), // 小三元(鳴き)
      ('111m999m111z99s', '999p'), // 混老頭(鳴き)
      ('223344m556677p88s', null), // 二盃口
      ('123m789m789s99s', '123p'), // 純チャン(鳴き)
      ('123456s555z11z', '789s'), // ホンイツ(鳴き)
      ('234567888s99s', '123s'), // チンイツ(鳴き)
      ('19m19p19s1234567z1z', null), // 国士無双
      ('111m333m555p888s22z', null), // 四暗刻
      ('234m555z666z11p', '777z'), // 大三元(鳴き)
      ('111z222z333z11p', '444z'), // 大四喜(鳴き)
      ('111z222z333z55z', '666z'), // 字一色(鳴き)
      ('111m999m111p99s', '999p'), // 清老頭(鳴き)
      ('222s333s444s66s', '666z'), // 緑一色(鳴き)
      ('1112345678999s5s', null), // 九蓮宝燈
    ];
    final seen = <String>{};
    for (final (concealed, meld) in examples) {
      final hand = Tile.parse(concealed);
      final meldTiles = meld == null ? const <int>[] : Tile.parse(meld);
      final meldCount = meld == null ? 0 : 1;
      // 合計14枚
      expect(
        hand.length + meldTiles.length,
        14,
        reason: '$concealed/$meld が14枚でない',
      );
      // 手の内が(副露を除いて)和了形
      expect(
        isWinningHand(toCounts(hand), meldCount: meldCount),
        isTrue,
        reason: '$concealed/$meld が和了形でない',
      );
      // 副露は刻子または順子
      if (meldTiles.isNotEmpty) {
        expect(
          _isValidMeld(meldTiles),
          isTrue,
          reason: '$meld が正しい副露(刻子/順子)でない',
        );
      }
      // まったく同じ牌姿の重複がない
      final key = '$concealed|${meld ?? ""}';
      expect(seen.add(key), isTrue, reason: '牌姿例が重複: $key');
    }
  });

  testWidgets('早見表: 点数表と役一覧をページめくりで表示', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showGuidebook(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 1ページ目=役一覧
    expect(find.text('役一覧'), findsOneWidget);
    expect(find.text('1 / 6'), findsOneWidget);
    expect(find.text('役満'), findsWidgets);

    // 2〜6ページ目
    Future<void> next() async {
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
    }

    await next();
    expect(find.text('点数表'), findsOneWidget);
    expect(find.text('2 / 6'), findsOneWidget);
    expect(find.text('満貫以上'), findsOneWidget);

    await next();
    expect(find.text('符計算'), findsOneWidget);
    expect(find.text('3 / 6'), findsOneWidget);
    expect(find.textContaining('副底'), findsWidgets);

    await next();
    expect(find.text('牌一覧'), findsOneWidget);
    expect(find.text('4 / 6'), findsOneWidget);
    expect(find.textContaining('萬子'), findsWidgets);

    await next();
    // 5ページ目=基本用語集(aboutの直前)
    expect(find.text('基本用語集'), findsOneWidget);
    expect(find.text('5 / 6'), findsOneWidget);
    expect(find.text('テンパイ(聴牌)'), findsOneWidget);

    await next();
    // 6ページ目=このアプリについて
    expect(find.text('5 / 6'), findsNothing);
    expect(find.text('6 / 6'), findsOneWidget);
    expect(find.text('麻雀卓'), findsWidgets);
    expect(find.text('© Daisuke Sawada'), findsOneWidget);
    expect(find.text('@daisuke7'), findsNothing);
    expect(find.text('素材ページ'), findsOneWidget);
    expect(find.text('ファンアートの取り扱いに関するガイドライン'), findsOneWidget);

    // 最終ページでは右ボタンは無効(タップしても進まない)
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('6 / 6'), findsOneWidget);

    // 左ボタンで役一覧まで戻る
    for (final page in ['5 / 6', '4 / 6', '3 / 6', '2 / 6', '1 / 6']) {
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.text(page), findsOneWidget);
    }

    // 閉じる
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('役一覧'), findsNothing);
  });

  testWidgets('各ページが実寸でオーバーフローしない', (tester) async {
    // 横画面の実寸相当(SE横)で各ページを描画し、例外が出ないか確認
    tester.view.physicalSize = const Size(1334, 750);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    for (final page in const [
      TileListPage(),
      YakuListPage(),
      ScoreTablePage(),
      FuTablePage(),
      GlossaryPage(),
      AboutPage(),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: const Color(0xFF12331E),
            body: SafeArea(child: SingleChildScrollView(child: page)),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: '${page.runtimeType} でレイアウトエラー',
      );
    }
  });

  testWidgets('牌一覧: 読み方一覧と発音付き読み例を表示', (tester) async {
    tester.view.physicalSize = const Size(1334, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: TileListPage())),
      ),
    );
    await tester.pump();

    // 読み方(発音)
    expect(find.textContaining('読み方(発音)'), findsOneWidget);
    expect(find.textContaining('トン'), findsWidgets); // 東
    expect(find.textContaining('チュン'), findsWidgets); // 中
    // 読み例に発音が付く
    expect(find.text('スーマン'), findsOneWidget); // 中張牌の萬子=4m
    expect(find.text('キューソー'), findsOneWidget); // 老頭牌の索子=9s
    expect(tester.takeException(), isNull);
  });

  testWidgets('基本用語集: カタカナ(漢字)+説明の並びで、他ページの内容と重複しない', (tester) async {
    tester.view.physicalSize = const Size(1334, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: GlossaryPage())),
      ),
    );
    await tester.pump();

    // セクションと代表的な用語(カタカナ(漢字)形式)
    for (final s in ['進行', '手牌の形', '鳴き', '攻めと守り', '場']) {
      expect(find.text(s), findsOneWidget, reason: 'セクション: $s');
    }
    for (final term in [
      'ハンチャン(半荘)',
      'テンパイ(聴牌)',
      'マチ(待ち)',
      'シャンテン(向聴)',
      'フリテン(振聴)',
      'ターチャ(他家)',
      'テハイ(手牌)',
      'メンゼン(門前清)', // Mリーグルールの表記(門前清)
      'ポン(碰)',
      'チー(吃)',
      'クイカエ(食い換え)', // Mリーグルールの表記(食い換え)
      'ゲンブツ(現物)',
      'スジ(筋)',
      'ワンパイ(王牌)',
      'ジュンイテン(順位点)', // Mリーグルールの用語(俗称はウマ)
    ]) {
      expect(find.text(term), findsOneWidget, reason: '用語: $term');
    }

    // Mリーグルールと異なる慣習表記を使わない
    for (final wrong in ['喰い替え', '喰い換え', 'ノーテン罰符', '罰符']) {
      expect(
        find.textContaining(wrong),
        findsNothing,
        reason: 'Mリーグルールの表記に合わせる: $wrong',
      );
    }
    // 聴牌料(Mリーグルールの語)で説明している
    expect(find.textContaining('聴牌料'), findsWidgets);

    // 他ページに詳細がある項目は載せない(役一覧・牌一覧・符計算と重複させない)
    for (final dup in [
      '立直(リーチ)', // 役一覧
      '平和(ピンフ)', // 役一覧
      '幺九牌(ヤオチュー牌)', // 牌一覧
      '嵌張(かんちゃん)', // 符計算
    ]) {
      expect(find.textContaining(dup), findsNothing, reason: '重複: $dup');
    }
    expect(tester.takeException(), isNull);
  });
}
