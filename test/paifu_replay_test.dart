import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/engine/yaku.dart';
import 'package:mahjong_taku/paifu/favorite_store.dart';
import 'package:mahjong_taku/paifu/ghost.dart';
import 'package:mahjong_taku/paifu/ghost_trial_store.dart';
import 'package:mahjong_taku/paifu/paifu_db.dart';
import 'package:mahjong_taku/paifu/replay_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'hand_test.dart' show tiles;
import 'paifu_fixture.dart';

/// Mリーグ牌譜ビューア: 牌譜DBの読み込みと再生。
/// 実DB(konoui/m-league-game-db)と同じスキーマの小さなフィクスチャで検証する。
void main() {
  late Directory tmp;
  late String dbPath;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('paifu_test');
    dbPath = '${tmp.path}/fixture.sqlite3';
    buildPaifuFixture(dbPath);
  });

  tearDownAll(() {
    tmp.deleteSync(recursive: true);
  });

  test('ブロック表記のパース(制御文字を無視して牌を取り出す)', () {
    expect(parseBlockTiles('6z6z-6z'), unorderedEquals(tiles('666z')));
    expect(parseBlockTiles('-7p6p8p'), unorderedEquals(tiles('678p')));
    expect(parseBlockTiles('_7z7z_'), unorderedEquals(tiles('77z')));
    expect(parseBlockTiles('88-8-8p'), unorderedEquals(tiles('8888p')));
    // 赤5込みの加槓ブロック
    expect(
      parseBlockTiles('5-5-05p'),
      unorderedEquals([
        tiles('5p')[0],
        tiles('5p')[0],
        Tile.red5p,
        tiles('5p')[0],
      ]),
    );
  });

  test('PaifuDb: シーズン・試合・選手(席順)を読める', () {
    final db = PaifuDb.open(dbPath);
    try {
      expect(db.latestGameDate(), '2025-04-01');

      final seasons = db.seasons();
      expect(seasons.single.label, '2025-26');

      final stages = db.stages(seasons.single.id);
      expect(stages.single.label, 'レギュラーシーズン');

      final dates = db.dates(stages.single.id);
      expect(dates, ['2025-04-01']);

      final games = db.games(stages.single.id, dates.single);
      expect(games.single.label(showTable: false), '第1試合');
      expect(games.single.tableLetter, 'A');

      // 1局目の東南西北順
      final players = db.gamePlayers(games.single.id);
      expect([for (final p in players) p.name], ['A', 'B', 'C', 'D']);
    } finally {
      db.close();
    }
  });

  test('ReplaySession: 牌譜が観戦ビューとして再生される', () async {
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      speed: 0,
    );
    final views = <GameView>[];
    final sub = session.views.listen(views.add);
    // run() は終局後も◀での戻りを待ち続けるので、完了は dispose 後に確認する
    final runF = session.run();
    await _waitPhase(session, 'gameEnd');
    await Future<void>.delayed(Duration.zero);

    expect(session.isSpectator, isTrue);
    expect(views, isNotEmpty);

    // 最初の対局ビュー: 配牌13枚・ドラ表示・親は席0
    final first = views.first;
    expect(first.hand.length, 13);
    expect(first.hand, containsAll(tiles('123m')));
    expect(first.doraIndicators, tiles('6s'));
    expect(first.dealer, 0);
    expect(first.scores, [25000, 25000, 25000, 25000]);
    expect(first.players.map((p) => p.name), ['A', 'B', 'C', 'D']);

    // Aのツモ切り(5z)が河に乗る
    expect(
      views.any(
        (v) =>
            v.players[0].discards.isNotEmpty &&
            v.players[0].discards.first.tile == tiles('5z')[0] &&
            v.players[0].discards.first.tsumogiri,
      ),
      isTrue,
    );

    // Bのリーチ: 宣言牌が横向き、供託+1、1000点払い、リーチバナー
    final riichiView = views.firstWhere((v) => v.players[1].riichi);
    expect(riichiView.players[1].discards.any((d) => d.riichi), isTrue);
    expect(riichiView.riichiSticks, 1);
    expect(riichiView.scores[1], 24000);
    expect(
      views.any((v) => v.lastEvent?.type == 'riichi' && v.lastEvent?.seat == 1),
      isTrue,
    );
    // 所作の順: 発声(リーチ!)の時点ではまだ宣言牌も供託も出ていない。
    // 宣言打牌が出た同じ表示で成立(横向き牌・供託+1・1000点減)する。
    final declView = views.firstWhere(
      (v) => v.lastEvent?.type == 'riichi' && v.lastEvent?.seat == 1,
    );
    expect(declView.players[1].discards.any((d) => d.riichi), isFalse);
    expect(declView.riichiSticks, 0);
    expect(declView.scores[1], 25000);
    expect(declView.players[1].riichi, isFalse);
    final idxDecl = views.indexOf(declView);
    final idxStick = views.indexWhere((v) => v.riichiSticks == 1);
    expect(idxStick, greaterThan(idxDecl));
    expect(views[idxStick].players[1].discards.last.riichi, isTrue);

    // Cのポン: 9筒をBから。Bの河の牌は取られた表示になる
    final ponView = views.firstWhere((v) => v.players[2].melds.isNotEmpty);
    final meld = ponView.players[2].melds.single;
    expect(meld.type, MeldType.pon);
    expect(meld.tiles, tiles('999p'));
    expect(meld.fromSeat, 1);
    expect(ponView.players[1].discards.last.calledAway, isTrue);

    // 局結果: Aのツモ和了。点数はDBの記録どおり
    final end = views.firstWhere((v) => v.phase == 'handEnd');
    final result = end.handResult!;
    expect(result.type, 'win');
    final win = result.wins.single;
    expect(win.seat, 0);
    expect(win.isTsumo, isTrue);
    expect(win.winTile, tiles('2z')[0]);
    expect(win.hand.length, 14);
    expect(win.score.yaku.map((y) => y.name), contains('ダブ東'));
    expect(win.points, 12000);
    expect(win.label, '満貫');
    expect(result.scores, [37000, 20000, 21000, 22000]);
    expect(result.scoreChanges, [12000, -5000, -4000, -3000]);
    expect(result.dealerContinues, isTrue, reason: '親のアガリ');

    // 試合終了: 最終順位と最終ポイント
    final over = views.last;
    expect(over.phase, 'gameEnd');
    expect(over.gameResult!.ranking, [0, 3, 2, 1]);
    expect(over.gameResult!.scores, [37000, 20000, 21000, 22000]);
    expect(over.gameResult!.points[0], closeTo(57.0, 0.001));
    // 結果画面のスタッツ表(history最終分): ポイント・アガリ・リーチがDBから入る
    expect(over.history, hasLength(1));
    expect(over.history.last.points[0], closeTo(57.0, 0.001));
    expect(over.history.last.wins, [1, 0, 0, 0]);
    expect(over.history.last.riichis, [0, 1, 0, 0]);
    expect(over.history.last.dealIns, [0, 0, 0, 0], reason: 'ツモなので放銃なし');

    await sub.cancel();
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  test('▶(一局進む): 最終局でスキップすると終局して結果画面になる', () async {
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      speed: 0,
    );
    final phases = <String>[];
    var jumped = false;
    final sub = session.views.listen((v) {
      phases.add(v.phase);
      if (!jumped && v.phase == 'playing') {
        jumped = true;
        session.nextKyoku(); // 唯一の局(=最終局)をスキップ
      }
    });
    final runF = session.run();
    await _waitPhase(session, 'gameEnd');
    expect(phases, isNot(contains('handEnd')), reason: 'スキップしたので局結果は出ない');
    expect(session.latestView!.gameResult, isNotNull);
    await sub.cancel();
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  test('startKyoku: 指定局から再生を開始する(局数を超えたら終局表示)', () async {
    // フィクスチャは1局のみなので、startKyoku=1 は最初から結果画面になる
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      speed: 0,
      startKyoku: 1,
    );
    final phases = <String>[];
    final sub = session.views.listen((v) => phases.add(v.phase));
    final runF = session.run();
    await _waitPhase(session, 'gameEnd');
    expect(phases, isNot(contains('playing')), reason: '指定局より前は再生しない');
    expect(phases, isNot(contains('handEnd')));
    expect(session.latestView!.gameResult, isNotNull);
    await sub.cancel();
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  test('◀(一局戻す): 結果画面から局を再生し直せる', () async {
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      speed: 0,
    );
    final runF = session.run();
    await _waitPhase(session, 'gameEnd');

    // speed=0 の再生は一瞬なので、ポーリングではなくストリームで観測する
    final replayed = <GameView>[];
    final sub = session.views.listen(replayed.add);
    session.prevKyoku();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!replayed.any((v) => v.phase == 'gameEnd')) {
      if (DateTime.now().isAfter(deadline)) fail('再生し直しが終わらない');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // 局の最初(点数25000)から再生し直されている
    final first = replayed.firstWhere((v) => v.phase == 'playing');
    expect(first.scores, [25000, 25000, 25000, 25000]);
    expect(replayed.any((v) => v.phase == 'handEnd'), isTrue);

    await sub.cancel();
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  test('ポーズと一手送り: 一手ずつ進めて・戻せる', () async {
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      speed: 0,
    );
    session.togglePause(); // 最初からポーズして手動再生
    expect(session.isPaused, isTrue);
    final runF = session.run();

    // 局頭で停止: 配牌13枚・まだ第1ツモ前
    await _waitUntil(() => session.latestView?.phase == 'playing');
    expect(session.latestView!.hand.length, 13);
    expect(session.latestView!.drawnTile, isNull);
    expect(session.latestView!.wallRemaining, 70);

    // 一手進み: Aの第1ツモ
    session.stepForward();
    await _waitUntil(() => session.latestView?.drawnTile != null);
    expect(session.latestView!.wallRemaining, 69);
    expect(session.latestView!.players[0].discards, isEmpty);

    // さらに一手: ツモ切りが河に乗る
    session.stepForward();
    await _waitUntil(() => session.latestView!.players[0].discards.isNotEmpty);

    // 一手戻し: ツモ直後の状態に戻る(ポーズは維持)
    session.stepBack();
    await _waitUntil(
      () =>
          session.latestView!.players[0].discards.isEmpty &&
          session.latestView?.drawnTile != null,
    );
    expect(session.latestView!.wallRemaining, 69);
    expect(session.isPaused, isTrue);

    // もう一手戻すと局頭。第1局の局頭からはそれ以上戻らない
    session.stepBack();
    await _waitUntil(() => session.latestView?.drawnTile == null);
    expect(session.latestView!.wallRemaining, 70);
    session.stepBack();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.latestView!.wallRemaining, 70);
    expect(session.latestView!.phase, 'playing');

    // 自動再生に切り替えると最後(結果画面)まで進む
    session.togglePause();
    expect(session.isPaused, isFalse);
    await _waitPhase(session, 'gameEnd');
    expect(session.latestView!.gameResult, isNotNull);

    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  test('ポーズ中の局結果表示は一手進みするまで次局へ進まない', () async {
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      speed: 0,
    );
    session.togglePause();
    final runF = session.run();
    await _waitUntil(() => session.latestView?.phase == 'playing');

    // 一手ずつ最後まで送ると局結果(handEnd)で止まる
    for (var i = 0; i < 20 && session.latestView?.phase != 'handEnd'; i++) {
      session.stepForward();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(session.latestView!.phase, 'handEnd');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.latestView!.phase, 'handEnd', reason: 'ポーズ中は結果画面のまま');

    // 一手進みで次(最終局のみなので結果画面)へ
    session.stepForward();
    await _waitPhase(session, 'gameEnd');

    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  test('ゴーストモード: 山とスクリプトを牌譜から再構成できる', () async {
    final db = PaifuDb.open(dbPath);
    try {
      final k = db.kyokus(1).single;
      final players = db.gamePlayers(1);
      final seatOf = {for (var i = 0; i < 4; i++) players[i].id: i};
      final wall = buildGhostWall(
        events: db.kyokuEvents(k.id),
        seatOf: seatOf,
        dealer: 0,
        rng: Random(1),
      );
      expect(wall, hasLength(136));
      // 全体として牌の構成は正しい(フル山と同じ多重集合)
      final sortedWall = [...wall]..sort();
      final sortedFull = Tile.fullWall()..sort();
      expect(sortedWall, sortedFull);
      // 配牌: 山の末尾から親→南→西→北の順(1巡目の4枚)
      expect(wall[135], tiles('1m')[0], reason: '親(A)の1枚目');
      // 通常ツモは wall[83] から降順に記録どおり
      expect(wall[83], tiles('5z')[0]);
      expect(wall[82], tiles('7m')[0]);
      expect(wall[81], tiles('4z')[0]);
      expect(wall[80], tiles('2z')[0]);
      // 表ドラ表示は王牌の固定位置
      expect(wall[4], tiles('6s')[0]);
    } finally {
      db.close();
    }
  });

  test('ゴーストモード: 牌譜どおり打てば他家も記録どおり進み、終了で牌譜に戻る', () async {
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      speed: 0,
      ghostSeed: 7,
    );
    session.togglePause();
    final runF = session.run();
    await _waitUntil(() => session.latestView?.phase == 'playing');
    final pausedView = session.latestView!;

    TurnPrompt? prompt;
    final subT = session.turnPrompts.listen((p) => prompt = p);
    final subR = session.reactPrompts.listen(
      (_) => session.sendReact(const ReactAction.pass()),
    );
    expect(session.enterGhost(), isTrue);
    expect(session.isGhost, isTrue);
    expect(session.isSpectator, isFalse, reason: 'ゴースト中は操作UIを出す');

    // 突入点(局頭)からの最初の自分の手番: 記録どおり5zをツモっている
    await _waitUntil(() => prompt != null);
    expect(prompt!.drawnTile, tiles('5z')[0]);
    expect(session.latestView!.players[0].name, '👻A', reason: '乗り移った席には👻が付く');

    // 記録どおりツモ切り → 他家(B/C/D)は記録どおり進み、次の手番で2zをツモる
    final drawn = prompt!.drawnTile!;
    prompt = null;
    session.sendTurn(TurnAction.discard(drawn));
    await _waitUntil(() => prompt != null);
    expect(prompt!.drawnTile, tiles('2z')[0]);
    expect(prompt!.canTsumo, isTrue);
    final v = session.latestView!;
    expect(v.players[1].riichi, isTrue, reason: 'Bは記録どおりリーチ');
    expect(v.players[2].melds, hasLength(1), reason: 'Cは記録どおりポン');
    expect(v.players[1].name, 'B', reason: '記録どおり打てている席に👻は付かない');

    // ツモアガリ → エンジンが計算した局結果が表示される
    session.sendTurn(const TurnAction.tsumo());
    await _waitUntil(() => session.latestView?.phase == 'handEnd');
    final r = session.latestView!.handResult!;
    expect(r.type, 'win');
    expect(r.wins.single.seat, 0);

    // 「次へ」でゴースト終了: 結果は捨てられ、突入時のポーズ位置に戻る
    session.advance();
    expect(session.isGhost, isFalse);
    expect(session.isSpectator, isTrue);
    expect(session.latestView!.phase, 'playing');
    expect(session.latestView!.wallRemaining, pausedView.wallRemaining);
    expect(session.latestView!.scores, pausedView.scores);
    expect(session.latestView!.players[0].name, 'A');
    expect(session.isPaused, isTrue, reason: 'ポーズ状態のまま牌譜再生に戻る');

    await subT.cancel();
    await subR.cancel();
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  test('ゴーストモード: 介入で記録どおり打てなくなった席はCPU代行(👻)になる', () async {
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      speed: 0,
      ghostSeed: 42,
    );
    session.togglePause();
    final runF = session.run();
    await _waitUntil(() => session.latestView?.phase == 'playing');

    TurnPrompt? prompt;
    var autoPlay = false;
    final ghosted = <String>{}; // 途中で👻が付いた他家の名前
    final subV = session.views.listen((v) {
      for (var i = 1; i < 4; i++) {
        if (v.players[i].name.startsWith('👻')) ghosted.add(v.players[i].name);
      }
    });
    final subT = session.turnPrompts.listen((p) {
      prompt = p;
      if (autoPlay) {
        session.sendTurn(
          TurnAction.discard(p.drawnTile ?? session.latestView!.hand.first),
        );
      }
    });
    final subR = session.reactPrompts.listen(
      (_) => session.sendReact(const ReactAction.pass()),
    );
    expect(session.enterGhost(), isTrue);

    // 最初の手番: 記録(5zツモ切り)から逸脱して手牌の1zを切る
    await _waitUntil(() => prompt != null);
    prompt = null;
    session.sendTurn(TurnAction.discard(tiles('1z')[0]));

    // 流れが変わっていないので他家は記録どおり進み、次の手番が来る
    await _waitUntil(() => prompt != null);
    expect(session.latestView!.players[1].riichi, isTrue);
    expect(prompt!.canTsumo, isFalse, reason: '1zを切ったのでツモれない');

    // 以降はツモ切りで流す。記録が尽きた席は順次CPU代行(👻)になり、局が終わる
    autoPlay = true;
    session.sendTurn(TurnAction.discard(prompt!.drawnTile!));
    await _waitUntil(() => session.latestView?.phase == 'handEnd');
    expect(ghosted, isNotEmpty, reason: '記録どおり打てなくなった他家に👻が付く');

    session.advance();
    expect(session.isGhost, isFalse);
    expect(session.latestView!.phase, 'playing');

    await subV.cancel();
    await subT.cancel();
    await subR.cancel();
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  test('全員ゴースト: 手番・反応が来た席に視点が切り替わり全席を操作できる', () async {
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      speed: 0,
      ghostSeed: 7,
    );
    session.togglePause();
    final runF = session.run();
    await _waitUntil(() => session.latestView?.phase == 'playing');

    TurnPrompt? tp;
    ReactPrompt? rp;
    final subT = session.turnPrompts.listen((p) => tp = p);
    final subR = session.reactPrompts.listen((p) => rp = p);
    expect(session.enterGhost(everyone: true), isTrue);
    expect(session.isGhostEveryone, isTrue);

    // A(親)の手番: 記録どおり5zをツモっている。全員に👻が付く
    await _waitUntil(() => tp != null);
    expect(session.latestView!.youSeat, 0);
    expect(session.latestView!.players.map((p) => p.name), [
      '👻A',
      '👻B',
      '👻C',
      '👻D',
    ]);
    expect(tp!.drawnTile, tiles('5z')[0]);
    tp = null;
    session.sendTurn(TurnAction.discard(tiles('5z')[0]));

    // Bの手番に視点が切り替わる(Bの手牌が見え、リーチも自分で選べる)
    await _waitUntil(() => tp != null);
    expect(session.latestView!.youSeat, 1);
    expect(session.latestView!.hand, hasLength(13));
    expect(tp!.drawnTile, tiles('7m')[0]);
    expect(tp!.riichiTiles, contains(tiles('9p')[0]));
    tp = null;
    session.sendTurn(TurnAction.discard(tiles('9p')[0], riichi: true));

    // Cの反応(ポンできる)に視点が切り替わる
    await _waitUntil(() => rp != null);
    expect(session.latestView!.youSeat, 2);
    expect(rp!.canPon, isTrue);
    rp = null;
    session.sendReact(const ReactAction.pon());

    // ポン後のCの打牌 → D → A のツモまで全部自分で操作する
    await _waitUntil(() => tp != null);
    expect(session.latestView!.youSeat, 2);
    expect(tp!.drawnTile, isNull, reason: '鳴き直後はツモなし');
    tp = null;
    session.sendTurn(TurnAction.discard(tiles('7z')[0]));
    await _waitUntil(() => tp != null);
    expect(session.latestView!.youSeat, 3);
    tp = null;
    session.sendTurn(
      TurnAction.discard(session.latestView!.drawnTile ?? tiles('4z')[0]),
    );
    await _waitUntil(() => tp != null);
    expect(session.latestView!.youSeat, 0);
    expect(tp!.canTsumo, isTrue);
    session.sendTurn(const TurnAction.tsumo());
    await _waitUntil(() => session.latestView?.phase == 'handEnd');

    // 終了で牌譜再生(観戦)に戻る
    session.advance();
    expect(session.isGhost, isFalse);
    expect(session.latestView!.youSeat, 0);
    expect(session.latestView!.players[1].name, 'B');

    await subT.cancel();
    await subR.cancel();
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  test('ゴースト局結果: 実際の結果と比較でき、試行が突入点ごとに貯まる', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    GhostTrialStore.resetForTest();
    final session = ReplaySession(
      db: PaifuDb.open(dbPath),
      gameId: 1,
      youSeat: 0,
      mLeagueGameId: 'L001_S001_0001_01A',
      speed: 0,
      ghostSeed: 7,
    );
    session.togglePause();
    final runF = session.run();
    await _waitUntil(() => session.latestView?.phase == 'playing');

    TurnPrompt? prompt;
    final subT = session.turnPrompts.listen((p) => prompt = p);
    final subR = session.reactPrompts.listen(
      (_) => session.sendReact(const ReactAction.pass()),
    );
    expect(session.enterGhost(), isTrue);
    expect(session.ghostCompare, isNull, reason: '比較は局が終わるまで出ない');

    // 記録どおり打ってAのツモ和了まで進める
    await _waitUntil(() => prompt != null);
    prompt = null;
    session.sendTurn(TurnAction.discard(tiles('5z')[0]));
    await _waitUntil(() => prompt != null);
    session.sendTurn(const TurnAction.tsumo());
    await _waitUntil(() => session.ghostCompare != null);

    // 実際の結果はDB記録から(A ツモ 12000点、A +12000)
    final c = session.ghostCompare!;
    expect(c.actualText, 'A ツモ 12000点');
    expect(c.actualDelta, 12000);
    expect(c.youName, 'A');
    // 今回の結果はエンジン計算(記録どおり打ったのでAの和了)
    expect(c.ghostText, contains('A ツモ'));
    expect(c.ghostDelta, greaterThan(0));
    expect(c.trials, hasLength(1));
    expect(c.trials.single.outcome, 'win');

    // 「もう一度ここから」: 同じ突入点から再突入し、試行が積み上がる
    prompt = null;
    expect(session.reenterGhost(), isTrue);
    expect(session.isGhost, isTrue);
    expect(session.ghostCompare, isNull, reason: '打ち直し中は前回の比較を消す');
    await _waitUntil(() => prompt != null);
    expect(prompt!.drawnTile, tiles('5z')[0], reason: '同じ突入点(局頭)から');
    prompt = null;
    session.sendTurn(TurnAction.discard(tiles('5z')[0]));
    await _waitUntil(() => prompt != null);
    session.sendTurn(const TurnAction.tsumo());
    await _waitUntil(() => (session.ghostCompare?.trials.length ?? 0) == 2);
    expect(
      session.ghostCompare!.trials.every((t) => t.outcome == 'win'),
      isTrue,
    );

    // 保存されている(キャッシュを捨てて読み直しても2回分残る)。
    // 突入点キー = 局キー|カットオフ(局頭ポーズ=最初のツモのイベント位置5)
    GhostTrialStore.resetForTest();
    await GhostTrialStore.ensureLoaded();
    expect(
      GhostTrialStore.trialsFor('L001_S001_0001_01A|1z1|0|5'),
      hasLength(2),
    );

    // 「次へ」で牌譜に戻ると比較は消える
    session.advance();
    expect(session.isGhost, isFalse);
    expect(session.ghostCompare, isNull);

    await subT.cancel();
    await subR.cancel();
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });

  _favoriteTests(() => dbPath);

  test('見逃しからのロン和了: 同巡内フリテンになった人が後にロン和了した局を列挙', () {
    final db0 = PaifuDb.open(dbPath);
    try {
      expect(db0.missedRonAgaris(), isEmpty); // フィクスチャには見逃しが無い
    } finally {
      db0.close();
    }
    final path2 = '${tmp.path}/missed.sqlite3';
    File(dbPath).copySync(path2);
    final raw = sqlite3.open(path2);
    // 2局目: Cは 9p・2p 待ちでテンパイ。Bの9pを見逃す。DBの聴牌者の行は「その
    // イベントの後の状態」なので、Bの9pの行ではまだフラグ 0、次の他家(D)の打牌の行で
    // 同巡内フリテンが立つ。Cが手出しすると解消し、その後Dの2pをロン。
    // Aにも別の見逃しがあるが和了していないので対象外
    raw.execute("INSERT INTO kyoku VALUES (2, 1, '2z1', 0, 0, 101)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES "
      "(961, 2, 'discard', 1), (962, 2, 'discard', 2), (963, 2, 'discard', 3), "
      "(964, 2, 'discard', 4), (965, 2, 'ron', 5)",
    );
    raw.execute(
      "INSERT INTO discard_event VALUES (961, 102, '9p', 0, 0), (962, 104, '1z', 0, 0), "
      "(963, 103, '3z', 0, 0), (964, 104, '2p', 0, 1)",
    );
    raw.execute(
      "INSERT INTO player_tenpai_state VALUES "
      "(961, 103, 0, 0, '2p,9p', 'シャンポン'), (962, 103, 0, 1, '2p,9p', 'シャンポン'), "
      "(962, 101, 0, 1, '1z', '単騎'), (963, 103, 1, 0, '2p,9p', 'シャンポン'), "
      "(964, 103, 0, 0, '2p,9p', 'シャンポン')",
    );
    raw.execute(
      "INSERT INTO agari_event VALUES (965, 103, 104, 3900, 3900, '2p', 'ron', "
      "40, 2, 0, 1, 0, 'x')",
    );
    raw.dispose();
    final db = PaifuDb.open(path2);
    try {
      final list = db.missedRonAgaris();
      expect(list, hasLength(1));
      final m = list.single;
      expect(m.winnerName, 'C');
      expect(m.missedTile, '9p');
      expect(m.missedFromName, 'B');
      expect(m.ronTile, '2p');
      expect(m.loserName, 'D');
      expect(m.points, 3900);
      expect(m.sameOpponent, isFalse);
      expect(m.kyokuLabel, '南1局');
    } finally {
      db.close();
    }
  });

  test('全員集合からの決着: 南4局開始時に全員2万点台で、その局で試合が終わった局を列挙', () {
    // フィクスチャ(東1局のみ)では0件
    final db0 = PaifuDb.open(dbPath);
    try {
      expect(db0.zeninShugoFinals(), isEmpty);
    } finally {
      db0.close();
    }
    final path2 = '${tmp.path}/zenin.sqlite3';
    File(dbPath).copySync(path2);
    final raw = sqlite3.open(path2);
    // 1局目の終了時点数(=南4局の開始時点数)を全員2万点台にし、南4局をBのロンで終える
    raw.execute(
      'UPDATE kyoku_player_result SET score = CASE player_id '
      'WHEN 101 THEN 25000 WHEN 102 THEN 24000 WHEN 103 THEN 26000 ELSE 25000 END '
      'WHERE kyoku_id = 1',
    );
    raw.execute("INSERT INTO kyoku VALUES (2, 1, '2z4', 0, 0, 104)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES (971, 2, 'ron', 1)",
    );
    raw.execute(
      "INSERT INTO agari_event VALUES (971, 102, 104, 8000, 8000, '1m', 'ron', "
      "40, 3, 0, 1, 0, 'x')",
    );
    raw.dispose();
    var db = PaifuDb.open(path2);
    try {
      final list = db.zeninShugoFinals();
      expect(list, hasLength(1));
      final z = list.single;
      expect(z.kyokuId, 2);
      expect(z.kyokuLabel, '南4局');
      expect(z.startScores.map((s) => '${s.name} ${s.score}'), [
        'A 25000',
        'B 24000',
        'C 26000',
        'D 25000',
      ]);
      expect(z.startScoresLabel, 'A 25000 / B 24000 / C 26000 / D 25000');
      expect(z.resultLabel, 'B ロン 8000点');
      expect(z.viewPlayerId, 102);
      expect(z.winnerName, 'A'); // 試合1位(game_player_result.rank=1)
      expect(z.agariButNotTop, isTrue); // 和了したBは1位ではない
    } finally {
      db.close();
    }
    // 親が連荘して南4局1本場が続いた: 南4局は最終局でなくなる。1本場の開始時点数
    // (=南4局の終了時点数)にBの31000があるので1本場も対象外 → 0件
    final raw2 = sqlite3.open(path2);
    raw2.execute("INSERT INTO kyoku VALUES (3, 1, '2z4', 1, 0, 104)");
    for (final (pid, score, wind) in [
      (101, 25000, '1z'),
      (102, 31000, '2z'),
      (103, 22000, '3z'),
      (104, 22000, '4z'),
    ]) {
      raw2.execute('INSERT INTO kyoku_player_result VALUES (2, ?, ?, ?, 0)', [
        pid,
        score,
        wind,
      ]);
    }
    raw2.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES (981, 3, 'ryukyoku', 1)",
    );
    raw2.dispose();
    db = PaifuDb.open(path2);
    try {
      expect(db.zeninShugoFinals(), isEmpty);
    } finally {
      db.close();
    }
    // 南4局の終了時点数も全員2万点台なら、流局で終わった1本場が対象(視点は試合1位)
    final raw3 = sqlite3.open(path2);
    raw3.execute(
      'UPDATE kyoku_player_result SET score = 29000 WHERE kyoku_id = 2 AND player_id = 102',
    );
    raw3.dispose();
    db = PaifuDb.open(path2);
    try {
      final z = db.zeninShugoFinals().single;
      expect(z.kyokuId, 3);
      expect(z.kyokuLabel, '南4局1本場');
      expect(z.resultLabel, '流局');
      expect(z.viewPlayerId, 101);
      expect(z.agariButNotTop, isFalse); // 流局には印を付けない
    } finally {
      db.close();
    }
  });

  test('天和・地和チャンス: 配牌テンパイ(tenho/chiho_possible)を第一打・結果付きで列挙', () {
    // フィクスチャ(フラグ全て0)では0件
    final db0 = PaifuDb.open(dbPath);
    try {
      expect(db0.haipaiTenpais(), isEmpty);
    } finally {
      db0.close();
    }
    // 親Aを天和チャンス、子Bを地和チャンスにしたコピーで2件になる
    final path2 = '${tmp.path}/haipai.sqlite3';
    File(dbPath).copySync(path2);
    final raw = sqlite3.open(path2);
    raw.execute(
      'UPDATE haipai_event SET is_tenho_possible = 1 WHERE actor_player_id = 101',
    );
    raw.execute(
      'UPDATE haipai_event SET is_chiho_possible = 1 WHERE actor_player_id = 102',
    );
    raw.dispose();
    final db = PaifuDb.open(path2);
    try {
      final list = db.haipaiTenpais();
      expect(list, hasLength(2));
      final a = list.firstWhere((h) => h.playerId == 101);
      expect(a.gameId, 1);
      expect(a.kyokuId, 1);
      expect(a.kyokuLabel, '東1局');
      expect(a.name, 'A');
      expect(a.isDealer, isTrue);
      expect(a.chanceLabel, '天和チャンス');
      expect(a.hand, '123m456p789s1122z');
      expect(a.firstTile, '5z');
      expect(a.firstActionLabel, 'ツモ切り(ダマ)');
      expect(a.resultLabel, 'ツモ 12000点');
      final b = list.firstWhere((h) => h.playerId == 102);
      expect(b.isDealer, isFalse);
      expect(b.chanceLabel, '地和チャンス');
      expect(b.firstTile, '9p');
      expect(b.firstActionLabel, '手出しリーチ');
      expect(b.resultLabel, '不成就');
      // 局内の出現順(A→B)
      expect(list.map((h) => h.playerId), [101, 102]);
    } finally {
      db.close();
    }
  });

  test('通らなかったリーチ: is_accepted=0 のリーチを宣言牌・討ち取った側・点数付きで列挙', () {
    // フィクスチャ(成立リーチのみ)では0件
    final db0 = PaifuDb.open(dbPath);
    try {
      expect(db0.failedRiichis(), isEmpty);
    } finally {
      db0.close();
    }
    // 2局目に「Bの宣言牌8pをCがロン」を足したコピーで1件になる
    final path2 = '${tmp.path}/failed.sqlite3';
    File(dbPath).copySync(path2);
    final raw = sqlite3.open(path2);
    raw.execute("INSERT INTO kyoku VALUES (2, 1, '2z3', 1, 0, 103)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES "
      "(901, 2, 'reach', 1), (902, 2, 'discard', 2), (903, 2, 'ron', 3)",
    );
    raw.execute('INSERT INTO reach_event VALUES (901, 102, 0)');
    raw.execute("INSERT INTO discard_event VALUES (902, 102, '8p', 1, 0)");
    raw.execute(
      "INSERT INTO agari_event VALUES (903, 103, 102, 10300, 6400, '8p', 'ron', "
      "40, 5, 0, 1, 0, 'x')",
    );
    raw.dispose();
    final db = PaifuDb.open(path2);
    try {
      final list = db.failedRiichis();
      expect(list, hasLength(1));
      final fr = list.single;
      expect(fr.gameId, 1);
      expect(fr.kyokuId, 2);
      expect(fr.date, '2025-04-01');
      expect(fr.kyokuLabel, '南3局1本場');
      expect(fr.riichiName, 'B');
      expect(fr.riichiPlayerId, 102);
      expect(fr.declTile, '8p');
      expect(fr.winnerName, 'C');
      expect(fr.points, 10300);
      // 再生の開始局・視点の導出(ビューアの一覧と同じ計算)
      expect(db.kyokus(1).indexWhere((k) => k.id == fr.kyokuId), 1);
      expect(db.gamePlayers(1).indexWhere((p) => p.id == fr.riichiPlayerId), 1);
    } finally {
      db.close();
    }
  });
  test('アガリ一覧の役表記: 役の後にドラをまとめ、赤→表→裏の順・枚数付き', () {
    const items = [
      YakuItem('立直', 1),
      YakuItem('裏ドラ', 4),
      YakuItem('門前清自摸和', 1),
      YakuItem('ドラ', 2),
      YakuItem('混全帯么九', 2),
      YakuItem('赤ドラ', 1),
    ];
    expect(
      formatAgariYaku(items, isYakuman: false),
      '立直 門前清自摸和 混全帯么九2 赤1 ドラ2 裏4',
    );
    // 役満は翻数を付けない(ドラの枚数は付ける)
    expect(
      formatAgariYaku(const [
        YakuItem('国士無双', 13),
        YakuItem('ドラ', 1),
      ], isYakuman: true),
      '国士無双 ドラ1',
    );
    expect(formatAgariYaku(const [], isYakuman: false), '');
    // 先頭4種は固定順(記録順が逆でも並べ替える)。ツモとピンフだけなら「ツモ ピンフ」
    expect(
      formatAgariYaku(const [
        YakuItem('平和', 1),
        YakuItem('一気通貫', 2),
        YakuItem('一発', 1),
        YakuItem('門前清自摸和', 1),
        YakuItem('断么九', 1),
      ], isYakuman: false),
      '門前清自摸和 断么九 平和 一発 一気通貫2',
    );
    // それ以外は翻数の少ない順。同じ翻数は記録順のまま
    expect(
      formatAgariYaku(const [
        YakuItem('混一色', 3),
        YakuItem('対々和', 2),
        YakuItem('中', 1),
        YakuItem('三暗刻', 2),
      ], isYakuman: false),
      '中 対々和2 三暗刻2 混一色3',
    );
    // ダブル立直は立直の位置
    expect(
      formatAgariYaku(const [
        YakuItem('平和', 1),
        YakuItem('ダブル立直', 2),
      ], isYakuman: false),
      'ダブル立直2 平和',
    );
  });

  test('アガリ検索: 役満・三倍満(11翻以上)・一発をDBから列挙', () {
    final path2 = '${tmp.path}/agari.sqlite3';
    File(dbPath).copySync(path2);
    final raw = sqlite3.open(path2);
    raw.execute(
      "INSERT INTO yaku_name VALUES (3, '立直'), (4, '一発'), (5, '国士無双'), (6, '裏ドラ')",
    );
    // 2局目: Cが Bから 立直一発 ロン(5翻40符 8000+本場)
    raw.execute("INSERT INTO kyoku VALUES (2, 1, '2z1', 1, 0, 102)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES (911, 2, 'ron', 1)",
    );
    raw.execute(
      "INSERT INTO agari_event VALUES (911, 103, 102, 8300, 2000, '3s', 'ron', "
      "40, 5, 0, 1, 0, 'x')",
    );
    raw.execute(
      'INSERT INTO agari_yaku VALUES (911, 3, 1), (911, 4, 1), (911, 2, 3)',
    );
    // 3局目: Dが 国士無双 ツモ(役満)
    raw.execute("INSERT INTO kyoku VALUES (3, 1, '2z2', 0, 0, 103)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES (921, 3, 'tsumo', 1)",
    );
    raw.execute(
      "INSERT INTO agari_event VALUES (921, 104, NULL, 32000, 8000, '1z', 'tsumo', "
      "30, 13, 0, 1, 1, '役満')",
    );
    raw.execute('INSERT INTO agari_yaku VALUES (921, 5, 13)');
    // 4局目: Aが 12翻 三倍満 ツモ(役満ではない)
    raw.execute("INSERT INTO kyoku VALUES (4, 1, '2z3', 0, 0, 104)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES (931, 4, 'tsumo', 1)",
    );
    raw.execute(
      "INSERT INTO agari_event VALUES (931, 101, NULL, 24000, 6000, '5m', 'tsumo', "
      "30, 12, 0, 1, 0, 'x')",
    );
    raw.execute('INSERT INTO agari_yaku VALUES (931, 3, 1), (931, 2, 11)');
    // 5局目: Bが 8翻 倍満 ロン(三倍満・役満には入らない)
    raw.execute("INSERT INTO kyoku VALUES (5, 1, '2z4', 0, 0, 101)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES (941, 5, 'ron', 1)",
    );
    raw.execute(
      "INSERT INTO agari_event VALUES (941, 102, 104, 16000, 4000, '9m', 'ron', "
      "30, 8, 0, 1, 0, 'x')",
    );
    // 立直1 + ドラ4 + 裏ドラ3 = 8翻(ドラ合計7・裏3)
    raw.execute(
      'INSERT INTO agari_yaku VALUES (941, 3, 1), (941, 2, 4), (941, 6, 3)',
    );
    // 6局目: Cが4副露(ポン3+チー1)の裸単騎でロン。Dは3副露で和了していないので対象外
    raw.execute("INSERT INTO kyoku VALUES (6, 1, '2z4', 1, 0, 101)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES "
      "(951, 6, 'pon', 1), (952, 6, 'pon', 2), (953, 6, 'chi', 3), (954, 6, 'pon', 4), "
      "(955, 6, 'pon', 5), (956, 6, 'pon', 6), (957, 6, 'ankan', 7), (958, 6, 'ron', 8)",
    );
    raw.execute(
      "INSERT INTO pon_event VALUES (951, 103, 102, '1z', '1z1z-1z'), "
      "(952, 103, 104, '5z', '5z5z-5z'), (954, 103, 101, '9p', '9p9p-9p'), "
      "(955, 104, 101, '2z', '2z2z-2z'), (956, 104, 102, '6z', '6z6z-6z')",
    );
    raw.execute(
      "INSERT INTO chi_event VALUES (953, 103, 102, '4m', '4m-5m6m')",
    );
    raw.execute("INSERT INTO ankan_event VALUES (957, 104, '7z7z7z7z')");
    raw.execute(
      "INSERT INTO agari_event VALUES (958, 103, 102, 5800, 5800, '3s', 'ron', "
      "30, 3, 1, 0, 0, 'x')",
    );
    raw.execute('INSERT INTO agari_yaku VALUES (958, 2, 3)');
    // 7局目: Bが1z単騎でリーチし、Aから1zをロン。場に2枚見えている(河2枚)ので地獄。
    // available(山の真の残り)は神視点なので判定に使わない
    raw.execute("INSERT INTO kyoku VALUES (7, 1, '1z1', 1, 0, 102)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES "
      "(971, 7, 'reach', 1), (972, 7, 'discard', 2), (973, 7, 'ron', 3)",
    );
    raw.execute('INSERT INTO reach_event VALUES (971, 102, 1)');
    raw.execute("INSERT INTO discard_event VALUES (972, 102, '9m', 1, 0)");
    raw.execute(
      "INSERT INTO player_tenpai_state VALUES (972, 102, 1, 0, '1z', '単騎')",
    );
    raw.execute(
      "INSERT INTO tenpai_agari_matrix VALUES (1, 972, 102, '1z', 3, 2, 0, 1, 1), "
      "(2, 972, 102, '1z', 3, 2, 0, 1, 0)",
    );
    raw.execute(
      "INSERT INTO agari_event VALUES (973, 102, 101, 5200, 5200, '1z', 'ron', "
      "40, 3, 0, 1, 0, 'x')",
    );
    raw.execute('INSERT INTO agari_yaku VALUES (973, 3, 1)');
    // 8局目: Cが5z単騎。河に1枚で見えている残りは2枚(地獄ではない)。available は
    // 他家が1枚持っていて 1 だが、リーチ者からは見えないので対象外
    raw.execute("INSERT INTO kyoku VALUES (8, 1, '1z2', 0, 0, 103)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES "
      "(981, 8, 'reach', 1), (982, 8, 'discard', 2), (983, 8, 'tsumo', 3)",
    );
    raw.execute('INSERT INTO reach_event VALUES (981, 103, 1)');
    raw.execute("INSERT INTO discard_event VALUES (982, 103, '9m', 1, 0)");
    raw.execute(
      "INSERT INTO player_tenpai_state VALUES (982, 103, 1, 0, '5z', '単騎')",
    );
    raw.execute(
      "INSERT INTO tenpai_agari_matrix VALUES (3, 982, 103, '5z', 3, 1, 0, 1, 1), "
      "(4, 982, 103, '5z', 3, 1, 0, 1, 0)",
    );
    raw.execute(
      "INSERT INTO agari_event VALUES (983, 103, NULL, 4000, 4000, 't5z', 'tsumo', "
      "40, 3, 0, 1, 0, 'x')",
    );
    raw.execute('INSERT INTO agari_yaku VALUES (983, 3, 1)');
    // 9局目: Dが3s単騎。河に1枚、さらにAのチー(2s3s4s)に1枚見えているので見える残りは1=地獄。
    // 副露を数えないと「残り2」で漏れる
    raw.execute("INSERT INTO kyoku VALUES (9, 1, '1z3', 0, 0, 104)");
    raw.execute(
      "INSERT INTO event (id, kyoku_id, type, event_order) VALUES "
      "(991, 9, 'chi', 1), (992, 9, 'reach', 2), (993, 9, 'discard', 3), (994, 9, 'ron', 4)",
    );
    raw.execute(
      "INSERT INTO chi_event VALUES (991, 101, 104, '2s', '-2s3s4s')",
    );
    raw.execute('INSERT INTO reach_event VALUES (992, 104, 1)');
    raw.execute("INSERT INTO discard_event VALUES (993, 104, '9m', 1, 0)");
    raw.execute(
      "INSERT INTO player_tenpai_state VALUES (993, 104, 1, 0, '3s', '単騎')",
    );
    raw.execute(
      "INSERT INTO tenpai_agari_matrix VALUES (5, 993, 104, '3s', 3, 1, 0, 1, 1), "
      "(6, 993, 104, '3s', 3, 1, 0, 1, 0)",
    );
    raw.execute(
      "INSERT INTO agari_event VALUES (994, 104, 102, 2600, 2600, '3s', 'ron', "
      "40, 2, 0, 1, 0, 'x')",
    );
    raw.execute('INSERT INTO agari_yaku VALUES (994, 3, 1)');
    raw.dispose();

    final db = PaifuDb.open(path2);
    try {
      final yakuman = db.searchAgari(AgariSearchKind.yakuman);
      expect(yakuman.map((a) => a.winnerName), ['D']);
      expect(yakuman.single.isTsumo, isTrue);
      expect(yakuman.single.isYakuman, isTrue);
      expect(yakuman.single.yaku, '国士無双'); // 役満は翻数を付けない
      expect(yakuman.single.kyokuLabel, '南2局');

      final sanbai = db.searchAgari(AgariSearchKind.sanbaiman);
      expect(sanbai.map((a) => a.winnerName), ['A']); // 役満は含めない
      expect(sanbai.single.han, 12);
      expect(sanbai.single.isYakuman, isFalse);
      expect(sanbai.single.yaku, '立直 ドラ11');

      final hell = db.searchAgari(AgariSearchKind.hellTanki);
      // B: 河2枚で残り1。D: 河1枚+Aのチーに1枚で残り1(副露を数える)。C: 河1枚で残り2
      expect(hell.map((a) => a.winnerName).toSet(), {'B', 'D'});
      expect(db.countAgari(AgariSearchKind.hellTanki), 2);
      expect(db.hellTankiRiichiPairs(), {(7, 102), (9, 104)});

      final hadaka = db.searchAgari(AgariSearchKind.hadakaTanki);
      expect(hadaka.map((a) => a.winnerName), ['C']); // 4副露した和了者だけ
      expect(hadaka.single.loserName, 'B');
      expect(db.countAgari(AgariSearchKind.hadakaTanki), 1);

      final baiman = db.searchAgari(AgariSearchKind.baiman);
      expect(baiman.map((a) => a.winnerName), ['B']);
      expect(baiman.single.han, 8);
      expect(baiman.single.loserName, 'D');
      expect(sanbai.map((a) => a.winnerName), ['A']); // 倍満は三倍満に混ざらない

      // ドラ7以上: A(立直+ドラ11)と B(ドラ4+裏3)。C(ドラ3)・D(役満・ドラ無し)は入らない
      final dora7 = db.searchAgari(AgariSearchKind.dora7);
      expect(dora7.map((a) => a.winnerName), ['A', 'B']);
      // 裏3以上: B だけ
      final ura3 = db.searchAgari(AgariSearchKind.ura3);
      expect(ura3.map((a) => a.winnerName), ['B']);
      expect(ura3.single.yaku, '立直 ドラ4 裏3'); // 役→ドラ、ドラは赤→表→裏

      final ippatsu = db.searchAgari(AgariSearchKind.ippatsu);
      expect(ippatsu.map((a) => a.winnerName), ['C']);
      expect(ippatsu.single.loserName, 'B');
      expect(ippatsu.single.isTsumo, isFalse);
      expect(ippatsu.single.points, 8300);
      expect(ippatsu.single.kyokuLabel, '南1局1本場');
      // シーズン絞り込み(フィクスチャのシーズンは id=1 のみ)
      expect(
        db.searchAgari(AgariSearchKind.ippatsu, seasonId: 1),
        hasLength(1),
      );
      expect(db.searchAgari(AgariSearchKind.ippatsu, seasonId: 99), isEmpty);
      // 件数だけの問い合わせは一覧と一致する
      for (final kind in AgariSearchKind.values) {
        expect(db.countAgari(kind), db.searchAgari(kind).length);
        expect(
          db.countAgari(kind, seasonId: 1),
          db.searchAgari(kind, seasonId: 1).length,
        );
        expect(db.countAgari(kind, seasonId: 99), 0);
      }
      expect(kyokuLabelOf('1z4', 2), '東4局2本場');
    } finally {
      db.close();
    }
  });
}

Future<void> _waitUntil(bool Function() cond) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('条件が満たされない');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

// ---------------- お気に入り局 ----------------

void _favoriteTests(String Function() dbPath) {
  test('お気に入り局: 保存・解除と★マークの対象特定', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    FavoriteStore.resetForTest();
    await FavoriteStore.ensureLoaded();
    expect(FavoriteStore.keys, isEmpty);

    final key = FavoriteStore.keyOf('L001_S001_0001_01A', '1z1', 0);
    await FavoriteStore.toggle(key);
    expect(FavoriteStore.contains(key), isTrue);
    expect(FavoriteStore.gameIds, {'L001_S001_0001_01A'});

    // 保存されている(キャッシュを捨てて読み直しても残る)
    FavoriteStore.resetForTest();
    await FavoriteStore.ensureLoaded();
    expect(FavoriteStore.contains(key), isTrue);

    // ★マークの対象(シーズン/ステージ/日付)をDBから引ける
    final db = PaifuDb.open(dbPath());
    try {
      final locs = db.locateGames(FavoriteStore.gameIds);
      expect(locs, hasLength(1));
      expect(locs.single.seasonId, 1);
      expect(locs.single.stageId, 1);
      expect(locs.single.date, '2025-04-01');
      expect(db.locateGames(const {}), isEmpty);
    } finally {
      db.close();
    }

    // もう一度タップで解除
    await FavoriteStore.toggle(key);
    expect(FavoriteStore.contains(key), isFalse);
  });

  test('ReplaySession: 表示中の局のお気に入りキーを持つ', () async {
    final session = ReplaySession(
      db: PaifuDb.open(dbPath()),
      gameId: 1,
      youSeat: 0,
      mLeagueGameId: 'L001_S001_0001_01A',
      speed: 0,
    );
    final runF = session.run();
    await _waitPhase(session, 'gameEnd');
    expect(session.currentKyokuKey, 'L001_S001_0001_01A|1z1|0');
    await session.dispose();
    await runF.timeout(const Duration(seconds: 5));
  });
}

Future<void> _waitPhase(ReplaySession s, String phase) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (s.latestView?.phase != phase) {
    if (DateTime.now().isAfter(deadline)) fail('phase=$phase にならない');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
