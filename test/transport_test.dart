import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/net/client.dart';
import 'package:mahjong_taku/net/host.dart';
import 'package:mahjong_taku/net/transport.dart';

void main() {
  test('InMemoryChannel: 双方向にメッセージが届き、closeで切断通知', () async {
    final (a, b) = InMemoryChannel.pair();
    final fromA = <String>[];
    final fromB = <String>[];
    b.messages.listen(fromA.add);
    a.messages.listen(fromB.add);

    a.send('hello-from-a');
    b.send('hello-from-b');
    await Future<void>.delayed(Duration.zero);
    expect(fromA, ['hello-from-a']);
    expect(fromB, ['hello-from-b']);

    var aDone = false;
    var bDone = false;
    a.done.then((_) => aDone = true);
    b.done.then((_) => bDone = true);
    await a.close();
    await Future<void>.delayed(Duration.zero);
    expect(aDone, isTrue);
    expect(bDone, isTrue);
  });

  test('ホスト⇔クライアントがチャネル経由でロビー・対局開始まで通る', () async {
    // HttpServerやmDNSは使わず、チャネルを直接つなぐ
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

    // ロビー状態が届く
    await client.lobbyStream.first.timeout(const Duration(seconds: 5));
    expect(client.latestLobby, isNotNull);
    expect(client.latestLobby!.players[1].name, 'ゲストA');
    expect(client.latestLobby!.roomName, 'テスト卓');

    // 対局開始 → クライアントにstartとビューが届く
    final session = server.startGame();
    await client.started.timeout(const Duration(seconds: 5));
    final view = await client.views
        .firstWhere((v) => v.hand.isNotEmpty || v.players.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect(view.players.length, 4);
    // ゲストAがどこかの席にいる(場決めで席は不定)
    expect(view.players.map((p) => p.name), contains('ゲストA'));
    // クライアントには自分の手牌だけが見える
    expect(view.youSeat, isNot(-1));

    await client.dispose();
    await session.dispose();
  });
}
