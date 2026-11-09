/// 近距離P2Pトランスポート(nearby_service)。
///
/// 共通のWi-Fiがなくても接続できる:
/// * iOS同士: Multipeer Connectivity(Bluetooth/直接Wi-Fi)。
///   生メッセージストリームを送信者IDで振り分けることで、
///   ホストは複数クライアントと同時通信できる。
/// * Android同士: Wi-Fi Direct。プラグインの制約(1対1ソケット)により
///   ホストが近距離で受けられるのは1人まで。
/// * iOS⇔Androidの近距離直結はプラットフォーム制約で不可
///   (その場合はテザリングでWi-Fi経由に)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nearby_service/nearby_service.dart';

import 'transport.dart';

bool get nearbySupported => Platform.isIOS || Platform.isAndroid;

NearbyService? _instance;

NearbyService get _service => _instance ??= NearbyService.getInstance();

/// 近距離ピアを部屋として表示するための情報
class NearbyRoom {
  final String id;
  final String name;

  const NearbyRoom({required this.id, required this.name});
}

/// iOS: 生ストリームを送信者IDごとのチャネルに振り分けるデマルチプレクサ
class _DarwinDemux {
  static _DarwinDemux? _shared;

  static _DarwinDemux get shared => _shared ??= _DarwinDemux._();

  final _channels = <String, NearbyLink>{};
  StreamSubscription<dynamic>? _sub;

  _DarwinDemux._();

  void ensureListening() {
    _sub ??= NearbyServiceIOSPlatform.instance.messagesStream.listen((event) {
      try {
        final map = event is String
            ? jsonDecode(event) as Map<String, dynamic>
            : (event as Map).cast<String, dynamic>();
        final message = ReceivedNearbyMessage.fromJson(map);
        final content = message.content;
        if (content is NearbyMessageTextRequest) {
          _channels[message.sender.id]?.pushIncoming(content.value);
        }
      } catch (_) {
        // 解釈できないイベントは無視
      }
    });
  }

  void register(NearbyLink channel) {
    ensureListening();
    _channels[channel.peer.id] = channel;
  }

  void unregister(NearbyLink channel) {
    if (identical(_channels[channel.peer.id], channel)) {
      _channels.remove(channel.peer.id);
    }
  }
}

/// nearby_service 上のバイトリンク。テキストしか運べないので
/// 宣言は「上限なし・圧縮なし・テキストのみ」(整形層が base64 で包む)。
class NearbyLink implements ByteLink {
  final NearbyDeviceInfo peer;
  final _incoming = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();
  StreamSubscription<NearbyDevice?>? _deviceSub;

  @override
  LinkProfile get profile => LinkProfile.textOnly;

  NearbyLink(this.peer) {
    if (Platform.isIOS || Platform.isMacOS) {
      _DarwinDemux.shared.register(this);
    }
    // 相手のロストを監視
    _deviceSub = _service.getConnectedDeviceStreamById(peer.id).listen((d) {
      if (d == null || !d.status.isConnected) {
        _finish();
      }
    });
  }

  void pushIncoming(String message) {
    if (!_incoming.isClosed) {
      _incoming.add(Uint8List.fromList(latin1.encode(message)));
    }
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
    if (!_incoming.isClosed) _incoming.close();
    _deviceSub?.cancel();
    if (Platform.isIOS || Platform.isMacOS) {
      _DarwinDemux.shared.unregister(this);
    }
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List chunk) async {
    await _service.send(
      OutgoingNearbyMessage(
        content: NearbyMessageTextRequest.create(value: latin1.decode(chunk)),
        receiver: peer,
      ),
    );
  }

  @override
  Future<void> close() async {
    _finish();
    try {
      await _service.disconnectById(peer.id);
    } catch (_) {}
  }
}

/// 初期化と(Androidの)権限確認。失敗理由を文字列で返す(nullなら成功)
Future<String?> prepareNearby({String? deviceName}) async {
  if (!nearbySupported) return 'この端末では近距離接続を利用できません';
  try {
    await _service.initialize(
      data: NearbyInitializeData(darwinDeviceName: deviceName),
    );
    final android = _service.android;
    if (android != null) {
      final granted = await android.requestPermissions();
      if (!(granted)) return '近距離接続には位置情報などの権限が必要です';
      final wifiOn = await android.checkWifiService();
      if (!(wifiOn)) return 'Wi-FiをONにしてください(接続先は不要です)';
    }
    return null;
  } catch (e) {
    return '近距離接続を初期化できませんでした: $e';
  }
}

/// ホスト側: 近距離の待ち受けを開始する。
/// クライアントがつながるたびに [onChannel] を呼ぶ。
class NearbyHost {
  final void Function(MessageChannel channel) onChannel;
  StreamSubscription<List<NearbyDevice>>? _peersSub;
  final _handled = <String>{};
  bool _androidBusy = false;

  NearbyHost({required this.onChannel});

  Future<String?> start({required String roomName}) async {
    final error = await prepareNearby(deviceName: roomName);
    if (error != null) return error;

    // iOS: ホストは広告側(Advertiser)
    _service.darwin?.setIsBrowser(value: false);
    await _service.discover();

    _peersSub = _service.getPeersStream().listen((peers) {
      for (final device in peers) {
        if (_handled.contains(device.info.id)) continue;
        if (device.status.isConnected) {
          _handled.add(device.info.id);
          _attach(device);
        } else if (Platform.isIOS || Platform.isMacOS) {
          // Browserからの接続要求を自動で受け入れる
          _service.connectById(device.info.id).catchError((_) => false);
        }
      }
    });
    return null;
  }

  Future<void> _attach(NearbyDevice device) async {
    if (_service.android != null) {
      // Androidは通信チャネルが1本しか張れない
      if (_androidBusy) {
        await _service.disconnectById(device.info.id).catchError((_) => false);
        return;
      }
      _androidBusy = true;
      final channel = NearbyLink(device.info);
      channel.done.then((_) => _androidBusy = false);
      await _service.startCommunicationChannel(
        NearbyCommunicationChannelData(
          device.info.id,
          messagesListener: NearbyServiceMessagesListener(
            onData: (message) {
              final content = message.content;
              if (content is NearbyMessageTextRequest) {
                channel.pushIncoming(content.value);
              }
            },
          ),
        ),
      );
      onChannel(FramedChannel(channel));
    } else {
      onChannel(FramedChannel(NearbyLink(device.info)));
    }
  }

  Future<void> stop() async {
    await _peersSub?.cancel();
    try {
      await _service.stopDiscovery();
    } catch (_) {}
  }
}

/// クライアント側: 近距離の部屋を探す
class NearbyBrowser {
  final _rooms = StreamController<List<NearbyRoom>>.broadcast();
  StreamSubscription<List<NearbyDevice>>? _peersSub;
  List<NearbyDevice> _lastPeers = const [];

  Stream<List<NearbyRoom>> get rooms => _rooms.stream;

  Future<String?> start() async {
    final error = await prepareNearby();
    if (error != null) return error;

    _service.darwin?.setIsBrowser(value: true);
    await _service.discover();

    _peersSub = _service.getPeersStream().listen((peers) {
      _lastPeers = peers;
      if (!_rooms.isClosed) {
        _rooms.add([
          for (final d in peers)
            NearbyRoom(id: d.info.id, name: d.info.displayName),
        ]);
      }
    });
    return null;
  }

  /// 部屋(=ホスト端末)に接続してチャネルを返す
  Future<MessageChannel> join(String deviceId) async {
    final device = _lastPeers.where((d) => d.info.id == deviceId).firstOrNull;
    if (device == null) {
      throw Exception('接続先が見つかりません');
    }
    await _service.connectById(deviceId);

    // 接続完了を待つ
    final connected = await _service
        .getConnectedDeviceStreamById(deviceId)
        .firstWhere((d) => d != null && d.status.isConnected)
        .timeout(const Duration(seconds: 20));

    final channel = NearbyLink(connected!.info);
    if (_service.android != null) {
      await _service.startCommunicationChannel(
        NearbyCommunicationChannelData(
          deviceId,
          messagesListener: NearbyServiceMessagesListener(
            onData: (message) {
              final content = message.content;
              if (content is NearbyMessageTextRequest) {
                channel.pushIncoming(content.value);
              }
            },
          ),
        ),
      );
    }
    return FramedChannel(channel);
  }

  Future<void> stop() async {
    await _peersSub?.cancel();
    await _rooms.close();
    try {
      await _service.stopDiscovery();
    } catch (_) {}
  }
}
