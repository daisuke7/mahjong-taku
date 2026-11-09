import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/net/client.dart';
import 'package:mahjong_taku/net/host.dart';
import 'package:mahjong_taku/net/transport.dart';

/// ギャラリー(観戦)機能。
/// - エンジン: 観戦者は席に着かず、指定プレイヤーの視点のビューを受け取る
/// - ホスト: ギャラリーとして開始(全席CPU可)・中断・ギャラリーのまま復帰
/// - ネットワーク: 試合中の部屋への観戦希望→ホスト許可→席選択→観戦
void main() {
  test('エンジン: 観戦者は指定プレイヤーの視点を受け取り、席替えでも追いかける', () async {
    var decisions = 0;
    final engine = GameEngine(
      config: const GameConfig(rounds: 1),
      names: const ['A', 'B', 'C', 'D'],
      isCpu: const [true, true, true, true],
      advanceDelayMs: 0,
      autoPlayDelayMs: 0,
      // 1回だけ連戦(場決めで席が変わっても追いかけることの確認)
      waitNextGame: () async => ++decisions == 1,
      seed: 4,
    );
    for (var i = 0; i < 4; i++) {
      engine.setAgent(i, CpuAgent(seed: 40 + i, thinkMillis: 1));
    }
    final spectator = _RecordingSpectator();
    engine.addSpectator(spectator, 'B');
    await engine.run().timeout(const Duration(minutes: 4));

    expect(spectator.prompts, 0, reason: '観戦者に手番・反応が来てはいけない');
    expect(spectator.views, isNotEmpty);
    for (final v in spectator.views) {
      expect(v.players[v.youSeat].name, 'B', reason: '観戦ビューは常にBの視点(席替え後も)');
    }
    // 2試合分のビューを受け取っている(gameIndexに2が現れる)
    expect(spectator.views.map((v) => v.gameIndex).toSet(), contains(2));

    // 観戦をやめると以後のビューは届かない
    final count = spectator.views.length;
    engine.removeSpectator(spectator);
    engine.castEmote(0, 1); // 何か配信イベントを起こしても
    expect(spectator.views.length, count);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('ホストギャラリー: 全席CPUで開始→中断→ギャラリーのまま復帰', () async {
    final server = HostServer(
      roomName: 'ギャラリー卓',
      hostName: 'ホスト',
      config: const GameConfig(rounds: 1),
    );
    final session = server.startGame(asGallery: true, watchSeat: 1);
    expect(session.isSpectator, isTrue);

    // 全席CPUで対局が動き、ホストには席1のプレイヤーの視点が届く
    final view = await awaitDeal(() => session.latestView);
    expect(view.players.every((p) => p.isCpu), isTrue, reason: '全員CPU');
    expect(
      view.players[view.youSeat].name,
      'CPU 南美',
      reason: '席1(CPU 南美)の視点を観戦',
    );

    // 観戦者の advance/emote は席のプレイヤーになりすまさない(何も起きない)
    session.advance();
    session.sendEmote(0);

    // 中断 → ホストが観戦(席に着いていない)ことが保存される
    final saved = await session.suspend();
    expect(saved, isNotNull);
    expect(saved!.hostIsGallery, isTrue);
    expect(saved.watchName, 'CPU 南美');
    expect(saved.guestNames, isEmpty);
    expect(saved.resumeData.names, isNot(contains('ホスト')));
    await session.dispose();

    // 復帰 → ホストはギャラリーとして復帰し、同じプレイヤーを見る
    final resumeServer = HostServer(
      roomName: saved.roomName,
      hostName: saved.hostName,
      config: saved.config,
      resume: saved,
    );
    final resumed = resumeServer.startGame();
    expect(resumed.isSpectator, isTrue);
    final view2 = await awaitDeal(() => resumed.latestView);
    expect(view2.players[view2.youSeat].name, 'CPU 南美');
    // エンジンを止めてから片付ける(放置するとCPU対局が背景で回り続け、
    // 後続テストのタイムアウトを圧迫する)
    await resumed.suspend();
    await resumed.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('ホストギャラリー: ゲスト枠が4になり、4人全員人間で開始できる', () async {
    final server = HostServer(
      roomName: '4人卓',
      hostName: 'ホスト',
      config: const GameConfig(rounds: 1),
    );
    expect(server.setGalleryMode(true), isTrue);
    expect(server.slotCount, 4);

    final clients = <ClientSession>[];
    for (var i = 0; i < 4; i++) {
      final (h, c) = InMemoryChannel.pair();
      server.attachChannel(h);
      final client = await ClientSession.overChannel(
        channel: c,
        playerName: 'ゲスト$i',
      );
      await client.lobbyStream.first.timeout(const Duration(seconds: 5));
      clients.add(client);
    }
    // ロビーには観戦ホスト+4ゲストが並ぶ
    expect(server.lobbyState.players.length, 5);
    expect(server.lobbyState.players.first.gallery, isTrue);
    expect(
      server.lobbyState.players.where((p) => !p.isCpu && !p.gallery).length,
      4,
    );

    // 5人目は満席
    final (h5, c5) = InMemoryChannel.pair();
    server.attachChannel(h5);
    final fifth = await ClientSession.overChannel(
      channel: c5,
      playerName: '5人目',
    );
    expect(
      await fifth.kicked.timeout(const Duration(seconds: 5)),
      contains('満席'),
    );
    await fifth.dispose();

    // 4人目のゲストがいる間はギャラリー解除できない
    expect(server.setGalleryMode(false), isFalse);

    // 開始: ホストは観戦、4席すべて人間ゲスト
    final session = server.startGame(asGallery: true, watchSeat: 0);
    expect(session.isSpectator, isTrue);
    for (final c in clients) {
      await c.started.timeout(const Duration(seconds: 5));
    }
    final v0 = await awaitDeal(() => clients[0].latestView);
    expect(v0.players[v0.youSeat].name, 'ゲスト0');
    expect(v0.players.every((p) => !p.isCpu), isTrue, reason: '全席人間');

    // ホストはゲスト0の視点を観戦
    final hv = await awaitDeal(() => session.latestView);
    expect(hv.players[hv.youSeat].name, 'ゲスト0');

    await session.suspend(); // エンジンを止めてから片付ける
    for (final c in clients) {
      await c.dispose();
    }
    await session.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('ネットワーク観戦: 許可で席を選んで観戦、拒否では入れない', () async {
    final server = HostServer(
      roomName: '観戦テスト卓',
      hostName: 'ホスト',
      config: const GameConfig(rounds: 1),
    );
    // ホスト+CPU3で開始済みの対局
    final session = server.startGame();
    await awaitDeal(() => session.latestView);

    // --- 拒否されるケース ---
    final requestsF = server.spectateRequests.first;
    final (h1, c1) = InMemoryChannel.pair();
    server.attachChannel(h1);
    final denied = await ClientSession.overChannel(
      channel: c1,
      playerName: '拒否される人',
    );
    final req1 = await requestsF.timeout(const Duration(seconds: 5));
    expect(req1.name, '拒否される人');
    await denied.spectatePending.timeout(const Duration(seconds: 5));
    req1.deny();
    final reason = await denied.kicked.timeout(const Duration(seconds: 5));
    expect(reason, contains('観戦'));
    await denied.dispose();

    // --- 許可されるケース ---
    final requestsF2 = server.spectateRequests.first;
    final (h2, c2) = InMemoryChannel.pair();
    server.attachChannel(h2);
    final gallery = await ClientSession.overChannel(
      channel: c2,
      playerName: 'ギャラ子',
    );
    final req2 = await requestsF2.timeout(const Duration(seconds: 5));
    req2.approve();
    final players = await gallery.spectateOffered.timeout(
      const Duration(seconds: 5),
    );
    expect(players.length, 4);
    expect(players.map((p) => p.name), contains('ホスト'));

    // CPU 東子の席を観戦する
    gallery.chooseSpectate('CPU 東子');
    await gallery.started.timeout(const Duration(seconds: 5));
    expect(gallery.isSpectator, isTrue);
    final gv = await awaitDeal(() => gallery.latestView);
    expect(gv.players[gv.youSeat].name, 'CPU 東子');

    // 中断すると観戦者にも通知が届く(観戦者フラグ付き)
    final noticeF = gallery.suspendNotices.first;
    final saved = await session.suspend();
    expect(saved, isNotNull);
    expect(saved!.hostIsGallery, isFalse, reason: 'ホストは席に着いている');
    final notice = await noticeF.timeout(const Duration(seconds: 5));
    expect(notice.spectator, isTrue);

    await gallery.dispose();
    await session.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// 配牌済みのビューを latestView のポーリングで待つ。
/// ストリーム購読はイベントを取りこぼす(初回ビューが started より先に届く、
/// 人間席の応答待ちで配信が止まる等)ため、状態ベースで待つのが確実。
Future<GameView> awaitDeal(GameView? Function() latest) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final v = latest();
    if (v != null && v.hand.isNotEmpty) return v;
    if (DateTime.now().isAfter(deadline)) fail('配牌ビューが届かない');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 観戦専用の記録エージェント(手番・反応が来たらテストを落とすため数える)
class _RecordingSpectator implements PlayerAgent {
  final List<GameView> views = [];
  int prompts = 0;

  @override
  void onView(GameView view) => views.add(view);

  @override
  void onEmote(int seat, int emoji) {}

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) {
    prompts++;
    return Completer<TurnAction>().future;
  }

  @override
  Future<ReactAction> onReact(ReactPrompt prompt) {
    prompts++;
    return Completer<ReactAction>().future;
  }
}
