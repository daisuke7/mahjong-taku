/// 整形層: すべての通信経路が必ず通る「圧縮→分割 / 再結合→伸長」の1枚。
///
/// 圧縮するか・分割するか・バイナリを運べるかは整形層が決めるのではなく、
/// 下のバイトリンク([ByteLink])が [LinkProfile] として宣言する。整形層は
/// 宣言に従うだけで、経路ごとの分岐を持たない(docs/transport-design.md §4)。
///
/// フレーム形式(全経路共通・1チャンクでも必ず付く):
/// ```
/// byte 0      : flags (bit0 = 圧縮済み)
/// byte 1..4   : メッセージID (uint32 BE)
/// byte 5..6   : 総チャンク数 (uint16 BE)
/// byte 7..8   : チャンク番号 (uint16 BE, 0始まり)
/// byte 9..    : ペイロード
/// ```
/// バイナリを運べないリンクでは、上記フレーム全体を base64 で包む。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'transport.dart';

/// リンク(通信経路)が宣言する能力
class LinkProfile {
  /// 1件で運べる最大バイト数。null なら無制限(分割しない)
  final int? maxChunkBytes;

  /// 帯域が細い経路なら true(zlib で圧縮する)
  final bool compress;

  /// バイナリを運べるか。false ならフレームを base64 で包む
  final bool binary;

  const LinkProfile({
    this.maxChunkBytes,
    this.compress = false,
    this.binary = true,
  }) : assert(maxChunkBytes == null || maxChunkBytes > frameHeaderLength);

  /// 上限なし・圧縮なし・バイナリ可(WebSocket など)
  static const lossless = LinkProfile();

  /// 上限なし・圧縮なし・テキストのみ(近距離P2P など)
  static const textOnly = LinkProfile(binary: false);

  /// 1フレームに入れられるペイロードのバイト数(無制限なら null)
  int? get payloadPerChunk {
    final max = maxChunkBytes;
    if (max == null) return null;
    // base64 は 3バイト→4文字。包んだ後が上限に収まるフレーム長を逆算する
    final frameLimit = binary ? max : (max ~/ 4) * 3;
    final payload = frameLimit - frameHeaderLength;
    assert(payload > 0, 'maxChunkBytes が小さすぎる: $max');
    return payload;
  }
}

/// バイト列を1件ずつ運ぶ通信経路。経路ごとに1実装。
abstract class ByteLink {
  LinkProfile get profile;

  /// 受信したチャンク
  Stream<Uint8List> get incoming;

  /// 切断通知(1度だけ完了する)
  Future<void> get done;

  /// 1チャンク送る。**リンクが受け付けた時点で完了**する(完了前に次を
  /// 送ってはいけない。整形層が直列化を守る)
  Future<void> send(Uint8List chunk);

  Future<void> close();
}

const int frameHeaderLength = 9;
const int _flagCompressed = 0x01;

/// 1メッセージを [LinkProfile] に従ってチャンク列に変換する(純粋関数)
List<Uint8List> encodeFrames(
  String message,
  LinkProfile profile, {
  required int messageId,
}) {
  var payload = Uint8List.fromList(utf8.encode(message));
  var flags = 0;
  if (profile.compress) {
    payload = Uint8List.fromList(zlib.encode(payload));
    flags |= _flagCompressed;
  }
  final per = profile.payloadPerChunk ?? payload.length;
  final total = payload.isEmpty ? 1 : (payload.length + per - 1) ~/ per;
  if (total > 0xFFFF) {
    throw ArgumentError('メッセージが大きすぎる: $total チャンク');
  }
  final frames = <Uint8List>[];
  for (var i = 0; i < total; i++) {
    final start = i * per;
    final end = (start + per).clamp(0, payload.length);
    final frame = Uint8List(frameHeaderLength + (end - start));
    final bd = ByteData.view(frame.buffer);
    frame[0] = flags;
    bd.setUint32(1, messageId & 0xFFFFFFFF);
    bd.setUint16(5, total);
    bd.setUint16(7, i);
    frame.setRange(frameHeaderLength, frame.length, payload, start);
    frames.add(profile.binary ? frame : _wrapText(frame));
  }
  return frames;
}

Uint8List _wrapText(Uint8List frame) =>
    Uint8List.fromList(ascii.encode(base64.encode(frame)));

/// 受信チャンクを組み立ててメッセージに戻す状態機械。
/// 経路は知らない(伸長の要否はフレームのフラグで判断する)。
class FrameAssembler {
  final bool binary;
  int? _messageId;
  int _expectedTotal = 0;
  int _nextIndex = 0;
  bool _compressed = false;
  final _parts = <Uint8List>[];

  FrameAssembler({this.binary = true});

  /// 組み立て途中のメッセージを捨てる(切断時)
  void reset() {
    _messageId = null;
    _expectedTotal = 0;
    _nextIndex = 0;
    _parts.clear();
  }

  /// チャンクを1つ取り込み、メッセージが完成したらそれを返す。
  /// 壊れたチャンク・順序不整合は組み立て中のものごと捨てて null。
  String? feed(Uint8List chunk) {
    Uint8List frame;
    try {
      frame = binary ? chunk : base64.decode(ascii.decode(chunk));
    } catch (_) {
      reset();
      return null;
    }
    if (frame.length < frameHeaderLength) {
      reset();
      return null;
    }
    final bd = ByteData.sublistView(frame);
    final flags = frame[0];
    final id = bd.getUint32(1);
    final total = bd.getUint16(5);
    final index = bd.getUint16(7);
    if (total == 0) {
      reset();
      return null;
    }
    if (index == 0) {
      // 新しいメッセージの先頭。途中のものがあれば捨てる
      reset();
      _messageId = id;
      _expectedTotal = total;
      _compressed = (flags & _flagCompressed) != 0;
    } else if (id != _messageId ||
        total != _expectedTotal ||
        index != _nextIndex) {
      reset();
      return null;
    }
    _parts.add(Uint8List.sublistView(frame, frameHeaderLength));
    _nextIndex = index + 1;
    if (_nextIndex < _expectedTotal) return null;

    final builder = BytesBuilder(copy: false);
    for (final p in _parts) {
      builder.add(p);
    }
    var payload = builder.takeBytes();
    final compressed = _compressed;
    reset();
    try {
      if (compressed) payload = Uint8List.fromList(zlib.decode(payload));
      return utf8.decode(payload);
    } catch (_) {
      return null;
    }
  }
}

/// バイトリンクを [MessageChannel] に見せるアダプタ(全経路で1実装)。
/// 送信は直列化し「1件送って完了を待つ」を守る。
class FramedChannel implements MessageChannel {
  final ByteLink link;
  final _messages = StreamController<String>.broadcast();
  final _done = Completer<void>();
  late final FrameAssembler _assembler;
  final _queue = <String>[];
  Future<void>? _pumping;
  bool _closing = false;
  bool _closed = false;
  int _nextId = 0;
  StreamSubscription<Uint8List>? _sub;

  FramedChannel(this.link) {
    _assembler = FrameAssembler(binary: link.profile.binary);
    _sub = link.incoming.listen(
      (chunk) {
        final msg = _assembler.feed(chunk);
        if (msg != null && !_messages.isClosed) _messages.add(msg);
      },
      onDone: _finish,
      onError: (_) => _finish(),
    );
    link.done.then((_) => _finish());
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    _assembler.reset();
    _queue.clear();
    if (!_done.isCompleted) _done.complete();
    if (!_messages.isClosed) _messages.close();
    _sub?.cancel();
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(String message) {
    if (_closed || _closing) return;
    _queue.add(message);
    _pumping ??= _pump();
  }

  Future<void> _pump() async {
    try {
      while (_queue.isNotEmpty && !_closed) {
        final message = _queue.removeAt(0);
        final frames = encodeFrames(
          message,
          link.profile,
          messageId: _nextId++,
        );
        for (final frame in frames) {
          if (_closed) return;
          try {
            await link.send(frame);
          } catch (_) {
            // 送れなかった分は諦める(切断は link.done で別途通知される)
            break;
          }
        }
      }
    } finally {
      _pumping = null;
    }
  }

  /// 送信待ちを流し切ってから閉じる(kick 等の最後の1通を落とさない)
  @override
  Future<void> close() async {
    if (_closed) return;
    _closing = true;
    final pending = _pumping;
    if (pending != null) {
      try {
        await pending.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    _finish();
    await link.close();
  }
}

/// テスト用: プロセス内でつながったバイトリンクのペア。
/// 任意の [LinkProfile] を注入できる。[dropOverlapping] を true にすると
/// 前の送信完了前の送信を黙って捨てる(実機の通知キュー満杯を模す)。
class InMemoryLink implements ByteLink {
  @override
  final LinkProfile profile;
  final Duration sendDelay;
  final bool dropOverlapping;
  final _incoming = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();
  InMemoryLink? _peer;
  bool _busy = false;

  /// 上限を超えたチャンクを送ろうとした回数(テストの検証用)
  int oversizedSends = 0;

  /// 重なりで捨てた回数(テストの検証用)
  int droppedSends = 0;

  InMemoryLink._(this.profile, this.sendDelay, this.dropOverlapping);

  static (InMemoryLink, InMemoryLink) pair({
    LinkProfile profile = LinkProfile.lossless,
    Duration sendDelay = Duration.zero,
    bool dropOverlapping = false,
  }) {
    final a = InMemoryLink._(profile, sendDelay, dropOverlapping);
    final b = InMemoryLink._(profile, sendDelay, dropOverlapping);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List chunk) async {
    final max = profile.maxChunkBytes;
    if (max != null && chunk.length > max) oversizedSends++;
    if (_busy) {
      if (dropOverlapping) {
        droppedSends++;
        return;
      }
    }
    _busy = true;
    try {
      if (sendDelay == Duration.zero) {
        // 実ネットワークと同じく非同期に届ける(マイクロタスク)
        await Future<void>.value();
      } else {
        await Future<void>.delayed(sendDelay);
      }
      final peer = _peer;
      if (peer != null && !peer._incoming.isClosed) {
        peer._incoming.add(chunk);
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
    await _incoming.close();
    final peer = _peer;
    _peer = null;
    if (peer != null && peer._peer != null) {
      peer._peer = null;
      await peer.close();
    }
  }
}
