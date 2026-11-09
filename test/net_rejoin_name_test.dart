import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/net/client.dart';
import 'package:mahjong_taku/net/host.dart';
import 'package:mahjong_taku/net/transport.dart';

/// 同名衝突で改名された参加者の再接続(2026-11-09 実機: ホスト「プレイヤー」と
/// 参加者「プレイヤー」→参加者は「プレイヤー2」に改名→切断後「プレイヤー」で
/// 入り直すと席に戻れず観戦候補になった)。
void main() {
  Future<(HostServer, ClientSession)> hostAndRenamedGuest() async {
    final server = HostServer(
      roomName: 'プレイヤーの卓',
      hostName: 'プレイヤー',
      config: const GameConfig(rounds: 1),
    );
    final (h, c) = InMemoryChannel.pair();
    server.attachChannel(h);
    final client = await ClientSession.overChannel(
      channel: c,
      playerName: 'プレイヤー',
    );
    await client.lobbyStream.first.timeout(const Duration(seconds: 5));
    return (server, client);
  }

  test('入室時に改名されたら参加者は確定した名前を知る', () async {
    final (server, client) = await hostAndRenamedGuest();
    expect(client.playerName, 'プレイヤー');
    expect(client.name, 'プレイヤー2');
    expect(server.lobbyState.players.map((p) => p.name), contains('プレイヤー2'));
    await client.dispose();
    await server.shutdown();
  });

  test('切断後、確定した名前(プレイヤー2)で名乗れば席に戻る', () async {
    final (server, client) = await hostAndRenamedGuest();
    final session = server.startGame();
    await client.started.timeout(const Duration(seconds: 5));
    await client.dispose(); // 切断 → CPU 代打
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // アプリ内の自動再接続に相当: ClientSession が覚えている確定名で hello
    final (h2, c2) = InMemoryChannel.pair();
    server.attachChannel(h2);
    final again = await ClientSession.overChannel(
      channel: c2,
      playerName: client.name,
    );
    await again.started.timeout(const Duration(seconds: 5));
    expect(again.spectatePending, doesNotComplete);
    expect(again.name, 'プレイヤー2');
    await again.dispose();
    await session.dispose();
    await server.shutdown();
  });

  test('アプリを入れ直して元の名前(プレイヤー)で名乗っても席に戻る', () async {
    final (server, client) = await hostAndRenamedGuest();
    final session = server.startGame();
    await client.started.timeout(const Duration(seconds: 5));
    await client.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final (h2, c2) = InMemoryChannel.pair();
    server.attachChannel(h2);
    final again = await ClientSession.overChannel(
      channel: c2,
      playerName: 'プレイヤー', // 改名を知らない新しいアプリ
    );
    await again.started.timeout(const Duration(seconds: 5));
    expect(again.spectatePending, doesNotComplete);
    await again.dispose();
    await session.dispose();
    await server.shutdown();
  });

  test('改名の候補が複数いる(プレイヤー2 と プレイヤー3 が両方切断)なら戻さず観戦候補', () async {
    final server = HostServer(
      roomName: 'プレイヤーの卓',
      hostName: 'プレイヤー',
      config: const GameConfig(rounds: 1),
    );
    final clients = <ClientSession>[];
    for (var i = 0; i < 2; i++) {
      final (h, c) = InMemoryChannel.pair();
      server.attachChannel(h);
      final cl = await ClientSession.overChannel(
        channel: c,
        playerName: 'プレイヤー',
      );
      await cl.lobbyStream.first.timeout(const Duration(seconds: 5));
      clients.add(cl);
    }
    expect(clients.map((c) => c.name), ['プレイヤー2', 'プレイヤー3']);
    final session = server.startGame();
    for (final cl in clients) {
      await cl.started.timeout(const Duration(seconds: 5));
      await cl.dispose();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final (h2, c2) = InMemoryChannel.pair();
    server.attachChannel(h2);
    final again = await ClientSession.overChannel(
      channel: c2,
      playerName: 'プレイヤー',
    );
    await again.spectatePending.timeout(const Duration(seconds: 5));
    expect(again.started, doesNotComplete);
    await again.dispose();
    await session.dispose();
    await server.shutdown();
  });
}
