import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/paifu_record.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/paifu/ghost.dart';
import 'package:mahjong_taku/paifu/my_paifu_source.dart';
import 'package:mahjong_taku/paifu/my_paifu_store.dart';
import 'package:mahjong_taku/paifu/replay_session.dart';

import 'hand_test.dart' show tiles;

/// 自分の対局の牌譜保存(提案3):
/// エンジンの牌譜レコーダ → MyPaifuStore(JSON) → MyPaifuSource →
/// ReplaySession のラウンドトリップを検証する。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('my_paifu_test');
    MyPaifuStore.dirOverride = tmp;
    MyPaifuStore.instance.resetForTest();
  });

  tearDown(() {
    MyPaifuStore.dirOverride = null;
    tmp.deleteSync(recursive: true);
  });

  group('paifu_record 部品', () {
    test('手牌のDB圧縮表記', () {
      expect(tilesToDbString(tiles('123m456p789s1122z')), '123m456p789s1122z');
      expect(tilesToDbString([Tile.red5m]), '0m');
      // 赤5は5の位置に '0' で入る(本家DBの表記と同じ)
      expect(
        tilesToDbString(tiles('44m') + [Tile.red5m] + tiles('6m')),
        '4406m',
      );
    });

    test('ポンのブロック表記は鳴き元で - の位置が変わる', () {
      final t = tiles('555z');
      // 上家(relative 3)= 先頭
      expect(callBlock(tiles: t, calledTile: t[0], relative: 3), '-5z5z5z');
      // 対面(relative 2)= 2番目
      expect(callBlock(tiles: t, calledTile: t[0], relative: 2), '5z-5z5z');
      // 下家(relative 1)= 末尾
      expect(callBlock(tiles: t, calledTile: t[0], relative: 1), '5z5z-5z');
    });

    test('大明槓・チー・暗槓・加槓のブロック表記', () {
      final k = tiles('1111s');
      expect(callBlock(tiles: k, calledTile: k[0], relative: 1), '1s1s1s-1s');
      expect(
        chiBlock(tiles: tiles('678p'), calledTile: tiles('7p')[0]),
        '-7p6p8p',
      );
      expect(ankanBlock(tiles('7777z')), '_7z7z_');
      // 赤入りの暗槓はエンジンが赤を2枚目に置く → 表向き2枚に赤が出る
      expect(ankanBlock([tiles('5s')[0], Tile.red5s] + tiles('55s')), '_0s5s_');
    });

    test('役名はDBの表記に収まる(2026-09-12リリースで表記癖は解消)', () {
      expect(dbYakuName('役牌 白'), '白');
      expect(dbYakuName('自風 東'), '自風');
      expect(dbYakuName('場風 南'), '場風');
      expect(dbYakuName('全帯么九'), '混全帯么九');
      expect(dbYakuName('純全帯么九'), '純全帯么九');
      expect(dbYakuName('二盃口'), '二盃口');
      expect(dbYakuName('立直'), '立直');
      // エンジンが出しうる役名を一通り変換してDBの語彙に収まることを確認
      const engineNames = [
        '立直',
        'ダブル立直',
        '門前清自摸和',
        '平和',
        '断么九',
        '一盃口',
        '自風 東',
        '自風 南',
        '場風 東',
        '場風 西',
        '役牌 白',
        '役牌 發',
        '役牌 中',
        '一発',
        '嶺上開花',
        '搶槓',
        '海底摸月',
        '河底撈魚',
        'ドラ',
        '赤ドラ',
        '裏ドラ',
        '七対子',
        '三色同順',
        '対々和',
        '三暗刻',
        '三槓子',
        '三色同刻',
        '小三元',
        '混老頭',
        '全帯么九',
        '一気通貫',
        '混一色',
        '純全帯么九',
        '二盃口',
        '清一色',
        '国士無双',
        '九蓮宝燈',
        '四暗刻',
        '大三元',
        '字一色',
        '清老頭',
        '四槓子',
        '小四喜',
        '大四喜',
        '緑一色',
        '天和',
        '地和',
      ];
      for (final n in engineNames) {
        expect(
          dbYakuNames.contains(dbYakuName(n)),
          isTrue,
          reason: '$n → ${dbYakuName(n)} がDBの語彙にない',
        );
      }
    });
  });

  group('MyPaifuStore', () {
    Map<String, dynamic> kyoku(String round, int honba) => {
      'round': round,
      'honba_count': honba,
      'reach_stick_count': 0,
      'parent_player_id': 0,
      'start_scores': [25000, 25000, 25000, 25000],
      'end_scores': [26000, 25000, 25000, 24000],
      'names': ['A', 'B', 'C', 'D'],
      'events': [
        {'type': 'ryukyoku', 'players': [], 'event_order': 0},
      ],
    };

    test('局ごとに追記保存され、復帰の重複局は置き換えられる', () async {
      final store = MyPaifuStore.instance;
      store.onKyoku(kyoku('1z1', 0));
      store.onKyoku(kyoku('1z1', 0)); // 中断→復帰で同じ局がもう一度来た
      store.onKyoku(kyoku('1z2', 0));
      await store.flush();

      final games = await MyPaifuStore.listGames();
      expect(games.length, 1);
      expect(games.single.kyokuCount, 2); // 重複は1つに
      expect(games.single.finished, isFalse); // 途中終了扱い

      store.onGameEnd([
        for (var i = 0; i < 4; i++)
          {'player_id': i, 'score': 25000, 'points': 0.0, 'rank': i + 1},
      ]);
      await store.flush();
      expect((await MyPaifuStore.listGames()).single.finished, isTrue);

      // 連戦: 次の局は新しい試合ファイルになる
      store.onKyoku(kyoku('1z1', 0));
      await store.flush();
      expect((await MyPaifuStore.listGames()).length, 2);
    });
  });

  test('ラウンドトリップ: CPU対局を保存 → 自分牌譜ビューアで完走再生できる', () async {
    // 1) 東風戦をCPU4人で1試合打つ(レコーダ付き)
    final engine = GameEngine(
      config: const GameConfig(rounds: 1),
      names: const ['あ', 'い', 'う', 'え'],
      isCpu: const [true, true, true, true],
      advanceDelayMs: 0,
      autoPlayDelayMs: 0,
      seed: 42,
    );
    engine.paifuRecorder = MyPaifuStore.instance;
    for (var i = 0; i < 4; i++) {
      engine.setAgent(i, CpuAgent(thinkMillis: 0, seed: 420 + i));
    }
    await engine.run().timeout(const Duration(seconds: 120));
    await MyPaifuStore.instance.flush();

    // 2) 保存された試合を読み出す
    final games = await MyPaifuStore.listGames();
    expect(games.length, 1);
    final summary = games.single;
    expect(summary.finished, isTrue);
    // 場決めで席順はシャッフルされる(名前の対応は席順で保存される)
    expect(summary.names, unorderedEquals(['あ', 'い', 'う', 'え']));
    expect(summary.lastScores, engine.scores);

    final raw = await MyPaifuStore.loadGame(summary.id);
    final source = MyPaifuSource(raw!);
    final kyokus = source.kyokus(MyPaifuSource.soloGameId);
    expect(kyokus, isNotEmpty);

    // 3) 各局: 点数収支の整合と、ゴースト用の山再構成が通ること
    var prevScores = const [25000, 25000, 25000, 25000];
    for (final k in kyokus) {
      final events = source.kyokuEvents(k.id);
      // 局頭は本家DBと同じ「表ドラ→配牌×4」
      expect(events.first.type, 'dora_indicator');
      expect([
        for (final e in events.take(5).skip(1)) e.type,
      ], everyElement('haipai'));
      // 結果イベントで終わる
      expect(['ron', 'tsumo', 'ryukyoku'], contains(events.last.type));

      final end = source.kyokuEndScores(k.id);
      // リーチ供託ぶんを除けば収支は繋がる(局をまたぐ供託は end に現れる)
      final sticksDelta = [
        for (var i = 0; i < 4; i++) end[i]! - prevScores[i],
      ].reduce((a, b) => a + b);
      expect(sticksDelta % 1000, 0, reason: '${k.round} の収支が1000点単位でない');

      // ゴーストモードの山再構成(完全情報なので必ず成功する)
      final wall = buildGhostWall(
        events: events,
        seatOf: {0: 0, 1: 1, 2: 2, 3: 3},
        dealer: k.parentPlayerId, // playerId=席なのでそのまま
        rng: Random(1),
      );
      expect(wall.length, 136, reason: '${k.round} の山が136枚にならない');
      prevScores = [for (var i = 0; i < 4; i++) end[i]!];
    }

    // 4) スタッツ集計が最終局まで矛盾なく数えられる
    final stats = source.statCounts(MyPaifuSource.soloGameId);
    final totalWins = stats.wins.values.fold(0, (a, b) => a + b);
    final agariKyoku = kyokus.where((k) {
      final last = source.kyokuEvents(k.id).last.type;
      return last == 'ron' || last == 'tsumo';
    }).length;
    expect(totalWins, agariKyoku);

    // 5) ReplaySession で最初から最後まで再生できる
    final session = ReplaySession(
      db: MyPaifuSource(raw),
      gameId: MyPaifuSource.soloGameId,
      youSeat: 0,
      matchLabel: '自分の対局',
      mLeagueGameId: summary.id,
      speed: 0,
    );
    final views = <GameView>[];
    final sub = session.views.listen(views.add);
    unawaited(session.run());
    await _waitUntil(() => session.latestView?.phase == 'gameEnd');
    final end = session.latestView!;
    expect(end.gameResult, isNotNull);
    expect(end.scores, engine.scores);
    expect(end.gameResult!.points.reduce((a, b) => a + b), closeTo(0, 0.001));
    // 途中の再生ビューも出ている(観戦UIに流れている)
    expect(views.where((v) => v.phase == 'playing'), isNotEmpty);
    expect(views.where((v) => v.phase == 'handEnd').length, kyokus.length);
    await sub.cancel();
    await session.dispose();

    // 6) 保存JSONのイベントは本家スキーマのフィールド名(スナップショット)
    final firstEvents =
        ((raw['kyokus'] as List).first as Map)['events'] as List;
    final draw = firstEvents.cast<Map>().firstWhere((e) => e['type'] == 'draw');
    expect(
      draw.keys,
      containsAll(['actor_player_id', 'tile', 'is_rinshan', 'event_order']),
    );
    final agariOrRyukyoku = firstEvents.cast<Map>().last;
    if (agariOrRyukyoku['type'] != 'ryukyoku') {
      expect(
        agariOrRyukyoku.keys,
        containsAll([
          'actor_player_id',
          'target_player_id',
          'points',
          'winning_tile',
          'fu',
          'han',
          'is_yakuman',
          'description',
          'yaku',
        ]),
      );
      for (final y in agariOrRyukyoku['yaku'] as List) {
        expect(
          dbYakuNames.contains((y as Map)['name']),
          isTrue,
          reason: '${y['name']} がDBの語彙にない',
        );
      }
      // ツモ和了牌は本家同様 t プレフィックス
      if (agariOrRyukyoku['type'] == 'tsumo') {
        expect(
          (agariOrRyukyoku['winning_tile'] as String).startsWith('t'),
          isTrue,
        );
      }
    }
    // JSONとして往復できる(ファイル実体の検証)
    final file = File('${tmp.path}/${summary.id}.json');
    expect(file.existsSync(), isTrue);
    expect(jsonDecode(file.readAsStringSync()), isA<Map<String, dynamic>>());
  });
}

Future<void> _waitUntil(bool Function() cond) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('条件が満たされない');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
