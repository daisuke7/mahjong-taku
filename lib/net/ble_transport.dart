/// BLE(Bluetooth Low Energy)リンク。Wi-Fi が無い場所でも iOS/Android 混合で
/// 接続できる経路(docs/transport-design.md §3)。
///
/// 構成: 卓役(ホスト)がペリフェラル=GATTサーバとして広告し、参加者が
/// セントラルとして接続する星型。
/// * TX 特性(notify): 卓→参加者(局面配信)
/// * RX 特性(write with response): 参加者→卓(操作)
///
/// 整形層(framing.dart)には「上限 = 交渉した通知/書き込み長・圧縮あり・
/// バイナリ可」の [LinkProfile] を宣言する。送信の直列化は整形層が守る。
/// 通知キュー満杯の待ち合わせはプラグインが行う(iOS は isReadyToUpdateSubscribers
/// を待って再送、Android は onNotificationSent / onCharacteristicWrite を待つ)。
///
/// プラグインに触れる部分(BleHost / BleBrowser)は PeripheralManager /
/// CentralManager のインタフェース経由なので、テストでは偽物を差し込める。
library;

import 'dart:async';
import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import 'transport.dart';

/// サービス/特性の UUID。**一度決めたら変えない**(バージョン間互換そのもの)。
/// プロトコル改定は protocol.dart の protocolVersion で扱う。
final UUID bleServiceUuid = UUID.fromString(
  '94a49276-9037-492e-9e63-0679116336d3',
);

/// 卓→参加者(notify)
final UUID bleTxUuid = UUID.fromString('bd0d86e2-dced-41c6-8e56-8ca029ec1956');

/// 参加者→卓(write)
final UUID bleRxUuid = UUID.fromString('61e75bf3-8e09-4105-b5fd-af8ef65078b2');

/// 参加者側が要求する MTU(Android のみ有効。iOS は OS が決める)
const int bleRequestedMtu = 512;

/// 交渉した「1件で運べる長さ」から整形層への宣言を作る(純粋関数)。
/// 不明・異常値のときは BLE 最小の 20 バイトに落として必ず届く側に倒す。
LinkProfile bleProfileFor(int maxLength) {
  final n = maxLength < 20 || maxLength > 4096 ? 20 : maxLength;
  return LinkProfile(maxChunkBytes: n, compress: true);
}

bool get bleSupported =>
    bleSupportedOverride ?? (Platform.isIOS || Platform.isAndroid);

/// テスト用: 偽のマネージャで動かすときに対応可否を上書きする
@visibleForTesting
bool? bleSupportedOverride;

/// BLE 上のバイトリンク。送る/切る手段は役割(ホスト側・参加者側)ごとに
/// 注入する。受信はプラグインのイベントから [pushIncoming] で流し込む。
class BleLink implements ByteLink {
  @override
  final LinkProfile profile;
  final Future<void> Function(Uint8List chunk) sender;
  final Future<void> Function() disconnect;
  final _incoming = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();

  BleLink({
    required this.profile,
    required this.sender,
    required this.disconnect,
  });

  bool get isClosed => _done.isCompleted;

  void pushIncoming(Uint8List chunk) {
    if (!_incoming.isClosed) _incoming.add(chunk);
  }

  /// 相手が切れた(または自分から切った)
  void finish() {
    if (!_done.isCompleted) _done.complete();
    if (!_incoming.isClosed) _incoming.close();
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List chunk) => sender(chunk);

  @override
  Future<void> close() async {
    finish();
    try {
      await disconnect();
    } catch (_) {}
  }
}

/// 卓役(ホスト)側: ペリフェラルとして広告し、購読してきた参加者ごとに
/// 通信路を作って [onChannel] へ渡す。
class BleHost {
  final void Function(MessageChannel channel) onChannel;
  final PeripheralManager Function() _managerFactory;
  PeripheralManager? _manager;
  final _links = <UUID, BleLink>{};
  final _subs = <StreamSubscription<dynamic>>[];
  late final GATTCharacteristic _tx;
  late final GATTCharacteristic _rx;
  bool _running = false;

  BleHost({required this.onChannel, PeripheralManager Function()? manager})
    : _managerFactory = manager ?? PeripheralManager.new;

  /// 接続中の参加者数(表示用)
  int get connectedCount => _links.length;

  /// 待ち受けを開始する。失敗理由を文字列で返す(null なら成功)
  Future<String?> start({required String roomName}) async {
    if (!bleSupported) return 'この端末では利用できません';
    final manager = _manager ??= _managerFactory();
    final ready = await _waitPoweredOn(manager);
    if (ready != null) return ready;

    _tx = GATTCharacteristic.mutable(
      uuid: bleTxUuid,
      properties: [GATTCharacteristicProperty.notify],
      permissions: [GATTCharacteristicPermission.read],
      descriptors: [],
    );
    _rx = GATTCharacteristic.mutable(
      uuid: bleRxUuid,
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );
    final service = GATTService(
      uuid: bleServiceUuid,
      isPrimary: true,
      includedServices: [],
      characteristics: [_tx, _rx],
    );

    _subs.add(
      manager.characteristicNotifyStateChanged.listen((e) {
        if (e.characteristic.uuid != bleTxUuid) return;
        if (e.state) {
          _attach(manager, e.central);
        } else {
          _detach(e.central.uuid);
        }
      }),
    );
    _subs.add(
      manager.characteristicWriteRequested.listen((e) async {
        if (e.characteristic.uuid == bleRxUuid) {
          _links[e.central.uuid]?.pushIncoming(e.request.value);
        }
        try {
          await manager.respondWriteRequest(e.request);
        } catch (_) {}
      }),
    );
    // Android のみ流れる(iOS は購読解除で検知する)。iOS のプラグイン
    // (bluetooth_low_energy_darwin 6.2.1)はこの getter 自体が UnsupportedError を
    // 投げるので、購読できなければ黙って使わない(2026-11-09 iPhone 12 Pro で
    // 「BLE を開始できませんでした」になっていた原因)。
    try {
      _subs.add(
        manager.connectionStateChanged.listen((e) {
          if (e.state == ConnectionState.disconnected) _detach(e.central.uuid);
        }),
      );
    } on UnsupportedError {
      // iOS: 切断は characteristicNotifyStateChanged(購読解除)で検知する
    }

    try {
      await manager.removeAllServices();
      await manager.addService(service);
      // Android では部屋名を広告に載せない。プラグイン(bluetooth_low_energy_android
      // 6.2.1)は name があると端末の Bluetooth 名そのものを部屋名に書き換え
      // (BluetoothAdapter.setName)、名前変更の通知を待ってから広告を始める。
      // 利用者の端末名を勝手に変える上、既に同じ名前だと通知が来ず永久に待つ
      // (2026-11-09 Pixel 6 で部屋作成のインジケータが止まらなかった原因)。
      // 参加者側は name 無しなら「BLEの卓」と表示し、入室後に本当の部屋名を受け取る。
      await manager
          .startAdvertising(
            Advertisement(
              name: Platform.isAndroid ? null : roomName,
              serviceUUIDs: [bleServiceUuid],
            ),
          )
          .timeout(bleAdvertiseTimeout);
    } catch (e) {
      await stop();
      return 'BLE の待ち受けを開始できませんでした: $e';
    }
    _running = true;
    return null;
  }

  Future<void> _attach(PeripheralManager manager, Central central) async {
    if (_links.containsKey(central.uuid)) return;
    int maxLen;
    try {
      maxLen = await manager.getMaximumNotifyLength(central);
    } catch (_) {
      maxLen = 20;
    }
    final link = BleLink(
      profile: bleProfileFor(maxLen),
      sender: (chunk) =>
          manager.notifyCharacteristic(central, _tx, value: chunk),
      disconnect: () async {
        // iOS のペリフェラルは相手を切断できない(購読解除を待つ)
        if (Platform.isAndroid) await manager.disconnect(central);
      },
    );
    _links[central.uuid] = link;
    link.done.then((_) {
      if (identical(_links[central.uuid], link)) _links.remove(central.uuid);
    });
    onChannel(FramedChannel(link));
  }

  void _detach(UUID uuid) {
    _links.remove(uuid)?.finish();
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final l in _links.values.toList()) {
      l.finish();
    }
    _links.clear();
    final manager = _manager;
    if (manager != null && _running) {
      try {
        await manager.stopAdvertising();
      } catch (_) {}
      try {
        await manager.removeAllServices();
      } catch (_) {}
    }
    _running = false;
  }
}

/// 参加者から見た BLE の部屋
class BleRoom {
  final String id;
  final String name;

  const BleRoom({required this.id, required this.name});
}

/// 参加者側: サービス UUID で卓を探し、接続して通信路を返す。
class BleBrowser {
  final CentralManager Function() _managerFactory;
  CentralManager? _manager;
  final _rooms = StreamController<List<BleRoom>>.broadcast();
  final _found = <String, ({Peripheral peripheral, String name})>{};
  StreamSubscription<dynamic>? _discoverSub;

  BleBrowser({CentralManager Function()? manager})
    : _managerFactory = manager ?? CentralManager.new;

  Stream<List<BleRoom>> get rooms => _rooms.stream;

  /// 探索を開始する。失敗理由を文字列で返す(null なら成功)
  Future<String?> start() async {
    if (!bleSupported) return 'この端末では利用できません';
    final manager = _manager ??= _managerFactory();
    final ready = await _waitPoweredOn(manager);
    if (ready != null) return ready;
    _discoverSub = manager.discovered.listen((e) {
      if (!e.advertisement.serviceUUIDs.contains(bleServiceUuid)) return;
      final id = e.peripheral.uuid.toString();
      final name = e.advertisement.name ?? _found[id]?.name ?? 'BLEの卓';
      _found[id] = (peripheral: e.peripheral, name: name);
      if (!_rooms.isClosed) {
        _rooms.add([
          for (final f in _found.entries)
            BleRoom(id: f.key, name: f.value.name),
        ]);
      }
    });
    try {
      await manager.startDiscovery(serviceUUIDs: [bleServiceUuid]);
    } catch (e) {
      return 'BLE の探索を開始できませんでした: $e';
    }
    return null;
  }

  /// 部屋(=卓役の端末)に接続して通信路を返す
  Future<MessageChannel> join(String id) async {
    final manager = _manager;
    final found = _found[id];
    if (manager == null || found == null) {
      throw Exception('接続先が見つかりません');
    }
    final peripheral = found.peripheral;
    try {
      await manager.stopDiscovery();
    } catch (_) {}
    await manager.connect(peripheral).timeout(const Duration(seconds: 15));
    final services = await manager.discoverGATT(peripheral);
    final service = services.where((s) => s.uuid == bleServiceUuid).firstOrNull;
    if (service == null) {
      await manager.disconnect(peripheral);
      throw Exception('麻雀卓のサービスが見つかりません');
    }
    final tx = service.characteristics.where((c) => c.uuid == bleTxUuid).first;
    final rx = service.characteristics.where((c) => c.uuid == bleRxUuid).first;
    if (Platform.isAndroid) {
      try {
        await manager.requestMTU(peripheral, mtu: bleRequestedMtu);
      } catch (_) {}
    }
    int maxLen;
    try {
      maxLen = await manager.getMaximumWriteLength(
        peripheral,
        type: GATTCharacteristicWriteType.withResponse,
      );
    } catch (_) {
      maxLen = 20;
    }
    final link = BleLink(
      profile: bleProfileFor(maxLen),
      sender: (chunk) => manager.writeCharacteristic(
        peripheral,
        rx,
        value: chunk,
        type: GATTCharacteristicWriteType.withResponse,
      ),
      disconnect: () => manager.disconnect(peripheral),
    );
    final notifySub = manager.characteristicNotified.listen((e) {
      if (e.peripheral.uuid == peripheral.uuid &&
          e.characteristic.uuid == bleTxUuid) {
        link.pushIncoming(e.value);
      }
    });
    final stateSub = manager.connectionStateChanged.listen((e) {
      if (e.peripheral.uuid == peripheral.uuid &&
          e.state == ConnectionState.disconnected) {
        link.finish();
      }
    });
    link.done.then((_) {
      notifySub.cancel();
      stateSub.cancel();
    });
    // 購読してから hello を送る(整形層が最初のメッセージを送る前に確立する)
    await manager.setCharacteristicNotifyState(peripheral, tx, state: true);
    return FramedChannel(link);
  }

  Future<void> stop() async {
    await _discoverSub?.cancel();
    _discoverSub = null;
    await _rooms.close();
    final manager = _manager;
    if (manager != null) {
      try {
        await manager.stopDiscovery();
      } catch (_) {}
    }
  }
}

/// 状態が unknown のまま待つ上限。初回は Bluetooth 許可のアラートが出ている間
/// unknown が続く(iOS は許可するまで CoreBluetooth が状態を返さない)ので、
/// 利用者がアラートを読んで答える時間を十分に取る(2026-11-09: 3秒だと
/// アラートを押す前にタイムアウトして「状態を取得できません」になっていた)。
@visibleForTesting
Duration bleUnknownStateTimeout = const Duration(seconds: 60);

/// 広告開始の応答を待つ上限。プラグインがコールバックを待ったまま返って来ない
/// 事例(上記 setName)があるので、部屋作成の画面を道連れにしないために切る。
@visibleForTesting
Duration bleAdvertiseTimeout = const Duration(seconds: 10);

/// Bluetooth が使える状態になるまで待つ(Android は権限要求も行う)。
/// 使えない理由があれば文字列で返す。
Future<String?> _waitPoweredOn(BluetoothLowEnergyManager manager) async {
  var state = manager.state;
  final role = manager is PeripheralManager ? 'host' : 'browser';
  debugPrint('[BLE $role] 初期状態: $state');
  if (state == BluetoothLowEnergyState.unknown) {
    try {
      state = await manager.stateChanged
          .map((e) {
            debugPrint('[BLE $role] 状態変化: ${e.state}');
            return e.state;
          })
          .firstWhere((s) => s != BluetoothLowEnergyState.unknown)
          .timeout(bleUnknownStateTimeout);
    } catch (e) {
      debugPrint('[BLE $role] unknown のまま諦めた: $e');
      return 'Bluetooth の状態を取得できません';
    }
  }
  if (state == BluetoothLowEnergyState.unauthorized && Platform.isAndroid) {
    try {
      final ok = await manager.authorize();
      if (!ok) return 'Bluetooth の権限が必要です';
      state = manager.state;
      if (state == BluetoothLowEnergyState.unauthorized) {
        state = await manager.stateChanged
            .map((e) => e.state)
            .firstWhere((s) => s != BluetoothLowEnergyState.unauthorized)
            .timeout(const Duration(seconds: 3), onTimeout: () => state);
      }
    } catch (_) {
      return 'Bluetooth の権限が必要です';
    }
  }
  switch (state) {
    case BluetoothLowEnergyState.poweredOn:
      return null;
    case BluetoothLowEnergyState.poweredOff:
      return 'Bluetooth を ON にしてください';
    case BluetoothLowEnergyState.unauthorized:
      return 'Bluetooth の権限が必要です';
    case BluetoothLowEnergyState.unsupported:
      return 'この端末は BLE に対応していません';
    case BluetoothLowEnergyState.unknown:
      return 'Bluetooth の状態を取得できません';
  }
}
