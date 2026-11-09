import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/net/client.dart';
import 'package:mahjong_taku/net/framing.dart';
import 'package:mahjong_taku/net/host.dart';
import 'package:mahjong_taku/net/protocol.dart';
import 'package:mahjong_taku/net/transport.dart';

/// 局面JSONに近い大きさ・内容のメッセージ(数KB、マルチバイト含む)
String sampleView(int seed) {
  final rng = Random(seed);
  final tiles = List.generate(136, (i) => i);
  tiles.shuffle(rng);
  return jsonEncode({
    't': 'view',
    'v': {
      'players': [
        for (var s = 0; s < 4; s++)
          {
            'name': ['東家 太郎', 'B', '南 花子🀄', 'D'][s],
            'score': 25000 - s * 1300,
            'river': tiles.sublist(s * 18, s * 18 + 18),
            'melds': [],
            'riichi': s == 1,
          },
      ],
      'hand': tiles.sublist(72, 86),
      'dora': tiles.sublist(86, 88),
      'wall': 70 - seed % 70,
    },
  });
}

void main() {
  group('encodeFrames / FrameAssembler', () {
    final profiles = <String, LinkProfile>{
      '上限なし・圧縮なし・バイナリ': const LinkProfile(),
      '上限なし・圧縮あり・バイナリ': const LinkProfile(compress: true),
      '上限なし・圧縮なし・テキスト': const LinkProfile(binary: false),
      '上限なし・圧縮あり・テキスト': const LinkProfile(compress: true, binary: false),
      '上限20・圧縮なし・バイナリ': const LinkProfile(maxChunkBytes: 20),
      '上限20・圧縮あり・バイナリ': const LinkProfile(maxChunkBytes: 20, compress: true),
      '上限32・圧縮なし・テキスト': const LinkProfile(maxChunkBytes: 32, binary: false),
      '上限32・圧縮あり・テキスト': const LinkProfile(
        maxChunkBytes: 32,
        compress: true,
        binary: false,
      ),
      '上限185(iOS BLE)・圧縮あり': const LinkProfile(
        maxChunkBytes: 185,
        compress: true,
      ),
    };
    final samples = <String>[
      '',
      'a',
      '{"t":"hello","name":"太郎"}',
      '🀄' * 100,
      sampleView(1),
      sampleView(2) * 8, // 数十KB
    ];

    for (final entry in profiles.entries) {
      test('ラウンドトリップ: ${entry.key}', () {
        final profile = entry.value;
        final assembler = FrameAssembler(binary: profile.binary);
        var id = 0;
        for (final message in samples) {
          final frames = encodeFrames(message, profile, messageId: id++);
          expect(frames, isNotEmpty);
          final max = profile.maxChunkBytes;
          if (max != null) {
            for (final f in frames) {
              expect(f.length, lessThanOrEqualTo(max));
            }
          } else {
            expect(frames.length, 1);
          }
          if (!profile.binary) {
            for (final f in frames) {
              expect(() => base64.decode(ascii.decode(f)), returnsNormally);
            }
          }
          String? result;
          for (var i = 0; i < frames.length; i++) {
            final r = assembler.feed(frames[i]);
            if (i < frames.length - 1) {
              expect(r, isNull, reason: '途中で完成してはいけない');
            }
            result = r;
          }
          expect(result, message);
        }
      });
    }

    test('圧縮で局面JSONが小さくなる', () {
      final message = sampleView(3);
      final raw = encodeFrames(
        message,
        const LinkProfile(),
        messageId: 0,
      ).single.length;
      final packed = encodeFrames(
        message,
        const LinkProfile(compress: true),
        messageId: 0,
      ).single.length;
      final big = sampleView(3) * 8;
      final bigRaw = utf8.encode(big).length;
      final bigPacked = encodeFrames(
        big,
        const LinkProfile(compress: true),
        messageId: 0,
      ).single.length;
      // ignore: avoid_print
      print(
        '局面JSON ${message.length}文字: 非圧縮 $raw B → 圧縮 $packed B'
        ' / 8局面分: $bigRaw B → $bigPacked B',
      );
      expect(packed, lessThan(raw * 2 ~/ 3));
      expect(bigPacked, lessThan(bigRaw ~/ 4));
    });

    test('ヘッダは1チャンクでも常に付く', () {
      final frames = encodeFrames('x', const LinkProfile(), messageId: 7);
      expect(frames.single.length, frameHeaderLength + 1);
      final bd = ByteData.sublistView(frames.single);
      expect(bd.getUint32(1), 7);
      expect(bd.getUint16(5), 1);
      expect(bd.getUint16(7), 0);
    });

    test('途中で切れたメッセージは捨てられ、次のメッセージは正常に組み上がる', () {
      const profile = LinkProfile(maxChunkBytes: 20);
      final assembler = FrameAssembler();
      final first = encodeFrames(sampleView(4), profile, messageId: 1);
      // 半分だけ届いたところで切断
      for (final f in first.take(first.length ~/ 2)) {
        expect(assembler.feed(f), isNull);
      }
      assembler.reset();
      final second = encodeFrames('after-reconnect', profile, messageId: 2);
      String? result;
      for (final f in second) {
        result = assembler.feed(f);
      }
      expect(result, 'after-reconnect');
    });

    test('順序不整合・壊れたチャンクは組み立て中のものごと捨てる', () {
      const profile = LinkProfile(maxChunkBytes: 20);
      final assembler = FrameAssembler();
      final frames = encodeFrames(sampleView(5), profile, messageId: 9);
      expect(frames.length, greaterThan(3));
      expect(assembler.feed(frames[0]), isNull);
      expect(assembler.feed(frames[2]), isNull, reason: '1を飛ばした');
      // 残りを全部入れても完成しない(捨てられたので)
      for (final f in frames.skip(3)) {
        expect(assembler.feed(f), isNull);
      }
      expect(assembler.feed(Uint8List(3)), isNull, reason: 'ヘッダ未満');
      // 先頭からやり直せば復旧する
      String? result;
      for (final f in frames) {
        result = assembler.feed(f);
      }
      expect(result, sampleView(5));
    });
  });

  group('FramedChannel', () {
    test('全プロファイルで双方向にメッセージが届き、順序が保たれる', () async {
      for (final profile in [
        const LinkProfile(),
        const LinkProfile(compress: true, binary: false),
        const LinkProfile(maxChunkBytes: 20),
        const LinkProfile(maxChunkBytes: 185, compress: true),
        const LinkProfile(maxChunkBytes: 64, compress: true, binary: false),
      ]) {
        final (la, lb) = InMemoryLink.pair(profile: profile);
        final a = FramedChannel(la);
        final b = FramedChannel(lb);
        final fromA = <String>[];
        final fromB = <String>[];
        b.messages.listen(fromA.add);
        a.messages.listen(fromB.add);
        final sent = [for (var i = 0; i < 12; i++) sampleView(i)];
        for (final m in sent) {
          a.send(m);
        }
        b.send('reply');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(fromA, sent, reason: '$profile');
        expect(fromB, ['reply']);
        expect(la.oversizedSends, 0);
        expect(lb.oversizedSends, 0);
        await a.close();
      }
    });

    test('送信は直列化される(重なりを捨てるリンクでも全件届く)', () async {
      final (la, lb) = InMemoryLink.pair(
        profile: const LinkProfile(maxChunkBytes: 40),
        sendDelay: const Duration(milliseconds: 1),
        dropOverlapping: true,
      );
      final a = FramedChannel(la);
      final b = FramedChannel(lb);
      final got = <String>[];
      b.messages.listen(got.add);
      final sent = [for (var i = 0; i < 5; i++) sampleView(i)];
      for (final m in sent) {
        a.send(m);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(la.droppedSends, 0);
      expect(got, sent);
      await a.close();
    });

    test('直列化しないと同じリンクで取りこぼす(リンクの模擬が有効なことの確認)', () async {
      final (la, lb) = InMemoryLink.pair(
        profile: const LinkProfile(maxChunkBytes: 40),
        sendDelay: const Duration(milliseconds: 1),
        dropOverlapping: true,
      );
      final frames = encodeFrames(
        sampleView(1),
        const LinkProfile(maxChunkBytes: 40),
        messageId: 1,
      );
      final assembler = FrameAssembler();
      String? result;
      lb.incoming.listen((c) => result = assembler.feed(c) ?? result);
      for (final f in frames) {
        // 完了を待たずに投げる
        // ignore: unawaited_futures
        la.send(f);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(la.droppedSends, greaterThan(0));
      expect(result, isNull);
      await la.close();
    });

    test('切断で done が完了し、組み立て途中は捨てられる', () async {
      final (la, lb) = InMemoryLink.pair();
      final a = FramedChannel(la);
      final b = FramedChannel(lb);
      var aDone = false;
      var bDone = false;
      a.done.then((_) => aDone = true);
      b.done.then((_) => bDone = true);
      await a.close();
      await Future<void>.delayed(Duration.zero);
      expect(aDone, isTrue);
      expect(bDone, isTrue);
    });
  });

  group('ロビー', () {
    test('ワイヤ形式のバージョン違いは hello で弾かれる', () async {
      final server = HostServer(
        roomName: 'テスト卓',
        hostName: 'ホスト',
        config: const GameConfig(rounds: 1),
      );
      final (hostSide, clientSide) = InMemoryChannel.pair();
      server.attachChannel(hostSide);
      final replies = <String>[];
      clientSide.messages.listen(replies.add);
      clientSide.send(encodeMsg('hello', {'name': '旧版', 'pv': 1}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(replies.any((m) => decodeMsg(m)?['t'] == 'kick'), isTrue);
      expect(
        server.lobbyState.players.map((p) => p.name),
        isNot(contains('旧版')),
      );
      await server.shutdown();
    });

    test('BLE相当(上限185・圧縮あり)のリンクでもロビー・対局開始まで通る', () async {
      final server = HostServer(
        roomName: 'BLE卓',
        hostName: 'ホスト',
        config: const GameConfig(rounds: 1),
      );
      final (hostSide, clientSide) = InMemoryChannel.pair(
        profile: const LinkProfile(maxChunkBytes: 185, compress: true),
      );
      server.attachChannel(hostSide);
      final client = await ClientSession.overChannel(
        channel: clientSide,
        playerName: 'ゲストB',
      );
      await client.lobbyStream.first.timeout(const Duration(seconds: 5));
      expect(client.latestLobby!.players[1].name, 'ゲストB');
      final session = server.startGame();
      await client.started.timeout(const Duration(seconds: 5));
      final view = await client.views
          .firstWhere((v) => v.players.isNotEmpty)
          .timeout(const Duration(seconds: 5));
      expect(view.players.map((p) => p.name), contains('ゲストB'));
      await client.dispose();
      await session.dispose();
    });
  });
}
