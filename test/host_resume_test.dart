import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/net/client.dart';
import 'package:mahjong_taku/net/host.dart';
import 'package:mahjong_taku/net/protocol.dart';
import 'package:mahjong_taku/net/transport.dart';

/// ホスト主導の中断→復帰ロビー→再開(通信はInMemoryChannel直結)
void main() {
  test('中断: クライアントに通知が届き、復帰情報にゲスト名が残る', () async {
    final server = HostServer(
      roomName: 'テスト卓',
      hostName: 'ホスト',
      config: const GameConfig(rounds: 1),
    );
    final (hostSide, clientSide) = InMemoryChannel.pair();
    server.attachChannel(hostSide);
    final client = await ClientSession.overChannel(
      channel: clientSide,
      playerName: 'ゲストA',
    );
    await client.lobbyStream.first.timeout(const Duration(seconds: 5));

    final session = server.startGame();
    await client.started.timeout(const Duration(seconds: 5));
    await client.views.first.timeout(const Duration(seconds: 5));

    final noticeF = client.suspendNotices.first;
    final saved = await session.suspend();
    expect(saved, isNotNull);
    expect(saved!.roomName, 'テスト卓');
    expect(saved.hostName, 'ホスト');
    expect(saved.guestNames, ['ゲストA']);
    // メンバー4人: ホスト+ゲストA+CPU2
    expect(saved.resumeData.names, contains('ホスト'));
    expect(saved.resumeData.names, contains('ゲストA'));
    expect(saved.resumeData.isCpu.where((c) => c).length, 2);

    final notice = await noticeF.timeout(const Duration(seconds: 5));
    expect(notice.roomName, 'テスト卓');
    expect(notice.playerName, 'ゲストA');

    await client.dispose();
    await session.dispose();
  });

  test('復帰ロビー: 中断メンバーだけが入れ、再開で元の状態から続く', () async {
    // ---- まず対局を作って中断する ----
    final server = HostServer(
      roomName: 'テスト卓',
      hostName: 'ホスト',
      config: const GameConfig(rounds: 1),
    );
    final (h1, c1) = InMemoryChannel.pair();
    server.attachChannel(h1);
    final client = await ClientSession.overChannel(
      channel: c1,
      playerName: 'ゲストA',
    );
    await client.lobbyStream.first.timeout(const Duration(seconds: 5));
    final session = server.startGame();
    await client.started.timeout(const Duration(seconds: 5));
    final beforeView = await client.views
        .firstWhere((v) => v.hand.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    final saved = (await session.suspend())!;
    await client.dispose();
    await session.dispose();

    // ---- 復帰ロビー ----
    final resumeServer = HostServer(
      roomName: saved.roomName,
      hostName: saved.hostName,
      config: saved.config,
      resume: saved,
    );

    // 部外者は入れない
    final (h2, c2) = InMemoryChannel.pair();
    resumeServer.attachChannel(h2);
    final outsider = await ClientSession.overChannel(
      channel: c2,
      playerName: 'ヨソ者',
    );
    final reason = await outsider.kicked.timeout(const Duration(seconds: 5));
    expect(reason, contains('中断した対局のメンバー'));
    await outsider.dispose();

    // ロビーには合流待ちのゲスト名が出る
    final waiting = resumeServer.lobbyState.players
        .where((p) => p.waiting)
        .toList();
    expect(waiting.map((p) => p.name), ['ゲストA']);

    // 本人は入れる
    final (h3, c3) = InMemoryChannel.pair();
    resumeServer.attachChannel(h3);
    final rejoin = await ClientSession.overChannel(
      channel: c3,
      playerName: 'ゲストA',
    );
    await rejoin.lobbyStream.first.timeout(const Duration(seconds: 5));
    expect(resumeServer.lobbyState.players.any((p) => p.waiting), isFalse);

    // ---- 再開: 中断時の状態(局・本場・持ち点)から続く ----
    final resumedSession = resumeServer.startGame();
    await rejoin.started.timeout(const Duration(seconds: 5));
    final view = await rejoin.views
        .firstWhere((v) => v.hand.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect(view.players[view.youSeat].name, 'ゲストA', reason: '元の席に本人として戻る');
    expect(view.kyoku, beforeView.kyoku);
    expect(view.honba, beforeView.honba);
    expect(
      [for (final p in view.players) p.name],
      [for (final p in beforeView.players) p.name],
      reason: '席順は中断時のまま(場決めし直さない)',
    );

    await rejoin.dispose();
    await resumedSession.dispose();
  });

  test('未合流のまま再開するとCPUが代打し、遅れて合流すると本人に戻る', () async {
    // 中断済みデータを作る
    final server = HostServer(
      roomName: 'テスト卓',
      hostName: 'ホスト',
      config: const GameConfig(rounds: 1),
    );
    final (h1, c1) = InMemoryChannel.pair();
    server.attachChannel(h1);
    final client = await ClientSession.overChannel(
      channel: c1,
      playerName: 'ゲストA',
    );
    await client.lobbyStream.first.timeout(const Duration(seconds: 5));
    final session = server.startGame();
    await client.started.timeout(const Duration(seconds: 5));
    await client.views.first.timeout(const Duration(seconds: 5));
    final saved = (await session.suspend())!;
    await client.dispose();
    await session.dispose();

    // ゲストなしで再開 → CPUが代打(接続なし・人間メンバーのまま)
    final resumeServer = HostServer(
      roomName: saved.roomName,
      hostName: saved.hostName,
      config: saved.config,
      resume: saved,
    );
    final resumedSession = resumeServer.startGame();
    final hostView = await resumedSession.views
        .firstWhere((v) => v.hand.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    final guest = hostView.players.firstWhere((p) => p.name == 'ゲストA');
    expect(guest.connected, isFalse, reason: '未合流はCPU代打(切断扱い)');
    expect(guest.isCpu, isFalse, reason: '人間メンバーであることは保持');

    // 開始後の遅れた合流 → 本人の席に戻る
    final (h2, c2) = InMemoryChannel.pair();
    resumeServer.attachChannel(h2);
    final late_ = await ClientSession.overChannel(
      channel: c2,
      playerName: 'ゲストA',
    );
    await late_.started.timeout(const Duration(seconds: 5));
    final lateView = await late_.views
        .firstWhere((v) => v.hand.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect(lateView.players[lateView.youSeat].name, 'ゲストA');
    expect(lateView.players[lateView.youSeat].connected, isTrue);

    await late_.dispose();
    await resumedSession.dispose();
  });

  test('LobbyPlayer.waiting はJSONを往復しても保たれる', () {
    final p = LobbyPlayer.fromJson(
      const LobbyPlayer(name: 'x', waiting: true).toJson(),
    );
    expect(p.waiting, isTrue);
    final q = LobbyPlayer.fromJson(const LobbyPlayer(name: 'y').toJson());
    expect(q.waiting, isFalse);
  });
}
