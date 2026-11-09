/// ホスト⇔クライアント間の通信路の抽象化。
///
/// 上位(host/client)が見るのは JSON 文字列を送受する [MessageChannel] だけ。
/// 実体は必ず整形層 [FramedChannel](framing.dart)で、その下に経路ごとの
/// バイトリンク(WebSocket / 近距離P2P / BLE / プロセス内)が付く。
/// 圧縮・分割の要否はリンクの [LinkProfile] で決まる。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'framing.dart';

export 'framing.dart' show FramedChannel, LinkProfile, ByteLink, InMemoryLink;

/// 双方向メッセージ通信路
abstract class MessageChannel {
  /// 受信メッセージ(JSON文字列)
  Stream<String> get messages;

  /// 切断通知(1度だけ完了する)
  Future<void> get done;

  void send(String message);

  Future<void> close();
}

/// WebSocket リンク(LAN・テザリング経由)。バイナリフレームで運ぶ。
/// 宣言: 上限なし・圧縮なし・バイナリ可
class WsLink implements ByteLink {
  final WebSocket _ws;
  final _incoming = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();

  @override
  LinkProfile get profile => LinkProfile.lossless;

  WsLink(this._ws) {
    _ws.listen(
      (data) {
        if (_incoming.isClosed) return;
        if (data is List<int>) {
          _incoming.add(data is Uint8List ? data : Uint8List.fromList(data));
        }
      },
      onDone: _finish,
      onError: (_) => _finish(),
    );
  }

  /// クライアント側: ホストのWebSocketサーバーへ接続して通信路を返す
  static Future<MessageChannel> connect(String host, int port) async {
    final ws = await WebSocket.connect(
      'ws://$host:$port',
    ).timeout(const Duration(seconds: 8));
    return FramedChannel(WsLink(ws));
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
    _incoming.close();
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List chunk) async {
    _ws.add(chunk);
  }

  @override
  Future<void> close() async {
    try {
      await _ws.close();
    } catch (_) {}
    _finish();
  }
}

/// テスト用: プロセス内でつながった通信路のペア(整形層を通る)
class InMemoryChannel {
  InMemoryChannel._();

  static (MessageChannel, MessageChannel) pair({
    LinkProfile profile = LinkProfile.lossless,
  }) {
    final (a, b) = InMemoryLink.pair(profile: profile);
    return (FramedChannel(a), FramedChannel(b));
  }
}
