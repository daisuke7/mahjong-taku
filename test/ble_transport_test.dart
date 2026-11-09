// BLE リンクをハードウェア無しで検証する。
// プラグインの PeripheralManager / CentralManager を偽物に差し替え、
// 1台のペリフェラル(卓)と複数のセントラル(参加者)を「空中」でつなぐ。
import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/net/ble_transport.dart';
import 'package:mahjong_taku/net/client.dart';
import 'package:mahjong_taku/net/framing.dart';
import 'package:mahjong_taku/net/host.dart';

class FakePeer implements BluetoothLowEnergyPeer, Central, Peripheral {
  @override
  final UUID uuid;
  FakePeer(this.uuid);
}

class _WriteRequest implements GATTWriteRequest {
  @override
  final int offset = 0;
  @override
  final Uint8List value;
  _WriteRequest(this.value);
}

/// 卓とN人の参加者をつなぐ偽の電波空間
class FakeAir {
  final peripheralManager = FakePeripheralManager();
  final centrals = <FakeCentralManager>[];

  /// 参加者を1人増やす(セントラル役のマネージャを返す)
  FakeCentralManager addCentral(String id) {
    final c = FakeCentralManager(this, FakePeer(UUID.fromString(id)));
    centrals.add(c);
    return c;
  }

  FakeCentralManager centralOf(UUID uuid) =>
      centrals.firstWhere((c) => c.self.uuid == uuid);
}

class FakePeripheralManager implements PeripheralManager {
  final _notifyState =
      StreamController<
        GATTCharacteristicNotifyStateChangedEventArgs
      >.broadcast();
  final _writeReq =
      StreamController<GATTCharacteristicWriteRequestedEventArgs>.broadcast();
  final _connState =
      StreamController<CentralConnectionStateChangedEventArgs>.broadcast();
  final _stateChanged =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  GATTService? service;
  Advertisement? advertisement;
  bool advertising = false;
  int maxNotifyLength = 185;
  BluetoothLowEnergyState _state = BluetoothLowEnergyState.poweredOn;

  /// iOS のプラグインと同じく connectionStateChanged で UnsupportedError を投げる
  bool darwinLike = false;

  /// 通知として空中に出たチャンク(セントラル別)
  final notified = <UUID, List<Uint8List>>{};
  FakeAir? air;

  /// 状態を変えて stateChanged に流す(初回許可アラートの再現用)
  void setState(BluetoothLowEnergyState s) {
    _state = s;
    _stateChanged.add(BluetoothLowEnergyStateChangedEventArgs(s));
  }

  @override
  BluetoothLowEnergyState get state => _state;
  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      _stateChanged.stream;
  @override
  Stream<GATTCharacteristicNotifyStateChangedEventArgs>
  get characteristicNotifyStateChanged => _notifyState.stream;
  @override
  Stream<GATTCharacteristicWriteRequestedEventArgs>
  get characteristicWriteRequested => _writeReq.stream;
  @override
  Stream<CentralConnectionStateChangedEventArgs> get connectionStateChanged {
    if (darwinLike) {
      throw UnsupportedError(
        'connectionStateChanged is not supported on Darwin.',
      );
    }
    return _connState.stream;
  }

  @override
  Future<void> addService(GATTService s) async => service = s;
  @override
  Future<void> removeAllServices() async => service = null;

  /// true なら startAdvertising が永久に返らない(Android プラグインの setName 待ち再現)
  bool hangOnAdvertise = false;

  @override
  Future<void> startAdvertising(Advertisement a) async {
    if (hangOnAdvertise) return Completer<void>().future;
    advertisement = a;
    advertising = true;
  }

  @override
  Future<void> stopAdvertising() async => advertising = false;
  @override
  Future<int> getMaximumNotifyLength(Central central) async => maxNotifyLength;
  @override
  Future<void> respondWriteRequest(GATTWriteRequest request) async {}
  @override
  Future<void> disconnect(Central central) async {
    _connState.add(
      CentralConnectionStateChangedEventArgs(
        central,
        ConnectionState.disconnected,
      ),
    );
  }

  @override
  Future<void> notifyCharacteristic(
    Central central,
    GATTCharacteristic characteristic, {
    required Uint8List value,
  }) async {
    (notified[central.uuid] ??= []).add(value);
    // 空中を渡って相手のセントラルに届く(非同期)
    await Future<void>.delayed(Duration.zero);
    air?.centralOf(central.uuid).deliverNotify(characteristic, value);
  }

  // ---- セントラル側から呼ばれる(空中) ----
  void subscribe(Central central, GATTCharacteristic c, bool state) {
    _notifyState.add(
      GATTCharacteristicNotifyStateChangedEventArgs(central, c, state),
    );
  }

  void write(Central central, GATTCharacteristic c, Uint8List value) {
    _writeReq.add(
      GATTCharacteristicWriteRequestedEventArgs(
        central,
        c,
        _WriteRequest(value),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class FakeCentralManager implements CentralManager {
  final FakeAir air;
  final FakePeer self;
  final _discovered = StreamController<DiscoveredEventArgs>.broadcast();
  final _notified =
      StreamController<GATTCharacteristicNotifiedEventArgs>.broadcast();
  final _connState =
      StreamController<PeripheralConnectionStateChangedEventArgs>.broadcast();
  final _stateChanged =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  final hostPeer = FakePeer(
    UUID.fromString('00000000-0000-0000-0000-00000000aaaa'),
  );
  bool discovering = false;
  int maxWriteLength = 185;

  /// 書き込みとして空中に出たチャンク
  final written = <Uint8List>[];

  FakeCentralManager(this.air, this.self) {
    air.peripheralManager.air = air;
  }

  @override
  BluetoothLowEnergyState get state => BluetoothLowEnergyState.poweredOn;
  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get stateChanged =>
      _stateChanged.stream;
  @override
  Stream<DiscoveredEventArgs> get discovered => _discovered.stream;
  @override
  Stream<GATTCharacteristicNotifiedEventArgs> get characteristicNotified =>
      _notified.stream;
  @override
  Stream<PeripheralConnectionStateChangedEventArgs>
  get connectionStateChanged => _connState.stream;

  @override
  Future<void> startDiscovery({List<UUID>? serviceUUIDs}) async {
    discovering = true;
    final adv = air.peripheralManager.advertisement;
    if (adv != null && air.peripheralManager.advertising) {
      // 広告が見える
      scheduleMicrotask(
        () => _discovered.add(DiscoveredEventArgs(hostPeer, -50, adv)),
      );
    }
  }

  @override
  Future<void> stopDiscovery() async => discovering = false;
  @override
  Future<void> connect(Peripheral p) async {}
  @override
  Future<void> disconnect(Peripheral p) async {
    _connState.add(
      PeripheralConnectionStateChangedEventArgs(
        p,
        ConnectionState.disconnected,
      ),
    );
    // 卓側は購読解除として観測する
    final tx = air.peripheralManager.service?.characteristics.firstWhere(
      (c) => c.uuid == bleTxUuid,
    );
    if (tx != null) air.peripheralManager.subscribe(self, tx, false);
  }

  @override
  Future<List<GATTService>> discoverGATT(Peripheral p) async => [
    air.peripheralManager.service!,
  ];
  @override
  Future<int> requestMTU(Peripheral p, {required int mtu}) async => mtu;
  @override
  Future<int> getMaximumWriteLength(
    Peripheral p, {
    required GATTCharacteristicWriteType type,
  }) async => maxWriteLength;

  @override
  Future<void> setCharacteristicNotifyState(
    Peripheral p,
    GATTCharacteristic c, {
    required bool state,
  }) async {
    air.peripheralManager.subscribe(self, c, state);
  }

  @override
  Future<void> writeCharacteristic(
    Peripheral p,
    GATTCharacteristic c, {
    required Uint8List value,
    required GATTCharacteristicWriteType type,
  }) async {
    written.add(value);
    await Future<void>.delayed(Duration.zero);
    air.peripheralManager.write(self, c, value);
  }

  void deliverNotify(GATTCharacteristic c, Uint8List value) {
    _notified.add(GATTCharacteristicNotifiedEventArgs(hostPeer, c, value));
  }

  /// 卓側から切られた(Android)
  void dropped() {
    _connState.add(
      PeripheralConnectionStateChangedEventArgs(
        hostPeer,
        ConnectionState.disconnected,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  setUp(() => bleSupportedOverride = true);
  tearDown(() => bleSupportedOverride = null);

  test('bleProfileFor: 交渉長をそのまま上限に、異常値は20に落とす', () {
    expect(bleProfileFor(185).maxChunkBytes, 185);
    expect(bleProfileFor(185).compress, isTrue);
    expect(bleProfileFor(185).binary, isTrue);
    expect(bleProfileFor(0).maxChunkBytes, 20);
    expect(bleProfileFor(5).maxChunkBytes, 20);
    expect(bleProfileFor(99999).maxChunkBytes, 20);
  });

  test('UUID は固定値(変えるとバージョン間で見つけ合えなくなる)', () {
    expect(bleServiceUuid.toString(), '94a49276-9037-492e-9e63-0679116336d3');
    expect(bleTxUuid.toString(), 'bd0d86e2-dced-41c6-8e56-8ca029ec1956');
    expect(bleRxUuid.toString(), '61e75bf3-8e09-4105-b5fd-af8ef65078b2');
    expect(bleServiceUuid.isShort, isFalse);
  });

  test('BleHost: iOS のように connectionStateChanged が非対応でも待ち受けできる', () async {
    final pm = FakePeripheralManager()..darwinLike = true;
    final host = BleHost(onChannel: (_) {}, manager: () => pm);
    expect(await host.start(roomName: 'iOSの卓'), isNull);
    expect(pm.advertising, isTrue);
    await host.stop();
  });

  test('BleHost: 初回許可アラート中(unknown)は待ち、許可後に待ち受けを始める', () async {
    final pm = FakePeripheralManager()
      .._state = BluetoothLowEnergyState.unknown;
    final host = BleHost(onChannel: (_) {}, manager: () => pm);
    final starting = host.start(roomName: '卓');
    // 利用者が 3秒より長く考えてから許可しても諦めない(旧実装は 3秒で諦めていた)
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pm.advertising, isFalse);
    pm.setState(BluetoothLowEnergyState.poweredOn);
    expect(await starting, isNull);
    expect(pm.advertising, isTrue);
    await host.stop();
  });

  test('BleHost: unknown のまま上限を過ぎたら「状態を取得できません」', () async {
    final saved = bleUnknownStateTimeout;
    bleUnknownStateTimeout = const Duration(milliseconds: 30);
    try {
      final pm = FakePeripheralManager()
        .._state = BluetoothLowEnergyState.unknown;
      final host = BleHost(onChannel: (_) {}, manager: () => pm);
      expect(await host.start(roomName: '卓'), 'Bluetooth の状態を取得できません');
      expect(pm.advertising, isFalse);
    } finally {
      bleUnknownStateTimeout = saved;
    }
  });

  test('BleHost: 許可を拒否(unauthorized)されたら権限の案内', () async {
    final pm = FakePeripheralManager()
      .._state = BluetoothLowEnergyState.unknown;
    final host = BleHost(onChannel: (_) {}, manager: () => pm);
    final starting = host.start(roomName: '卓');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    pm.setState(BluetoothLowEnergyState.unauthorized);
    expect(await starting, 'Bluetooth の権限が必要です');
  });

  test('BleHost: 広告開始が返って来なければ上限で諦めて理由を返す(画面を止めない)', () async {
    final saved = bleAdvertiseTimeout;
    bleAdvertiseTimeout = const Duration(milliseconds: 30);
    try {
      final pm = FakePeripheralManager()..hangOnAdvertise = true;
      final host = BleHost(onChannel: (_) {}, manager: () => pm);
      final result = await host.start(roomName: '卓');
      expect(result, startsWith('BLE の待ち受けを開始できませんでした'));
      expect(pm.advertising, isFalse);
    } finally {
      bleAdvertiseTimeout = saved;
    }
  });

  test('BleHost: 広告にサービスUUIDと部屋名、GATTにTX(notify)/RX(write)', () async {
    final air = FakeAir();
    final host = BleHost(
      onChannel: (_) {},
      manager: () => air.peripheralManager,
    );
    expect(await host.start(roomName: 'BLE卓'), isNull);
    final pm = air.peripheralManager;
    expect(pm.advertising, isTrue);
    expect(pm.advertisement!.name, 'BLE卓');
    expect(pm.advertisement!.serviceUUIDs, [bleServiceUuid]);
    final chars = pm.service!.characteristics;
    expect(chars.map((c) => c.uuid), containsAll([bleTxUuid, bleRxUuid]));
    expect(
      chars.firstWhere((c) => c.uuid == bleTxUuid).properties,
      contains(GATTCharacteristicProperty.notify),
    );
    expect(
      chars.firstWhere((c) => c.uuid == bleRxUuid).properties,
      contains(GATTCharacteristicProperty.write),
    );
    await host.stop();
    expect(pm.advertising, isFalse);
  });

  test('BLE 経由でロビー入室→対局開始→局面配信、チャンクは交渉長以内', () async {
    final air = FakeAir();
    final server = HostServer(
      roomName: 'BLE卓',
      hostName: 'ホスト',
      config: const GameConfig(rounds: 1),
    );
    final bleHost = BleHost(
      onChannel: server.attachChannel,
      manager: () => air.peripheralManager,
    );
    expect(await bleHost.start(roomName: 'BLE卓'), isNull);

    final cm = air.addCentral('00000000-0000-0000-0000-000000000001');
    final browser = BleBrowser(manager: () => cm);
    expect(await browser.start(), isNull);
    final rooms = await browser.rooms.first.timeout(const Duration(seconds: 2));
    expect(rooms.single.name, 'BLE卓');

    final channel = await browser.join(rooms.single.id);
    final client = await ClientSession.overChannel(
      channel: channel,
      playerName: 'BLEゲスト',
    );
    await client.lobbyStream.first.timeout(const Duration(seconds: 5));
    expect(client.latestLobby!.players[1].name, 'BLEゲスト');
    expect(bleHost.connectedCount, 1);

    final session = server.startGame();
    await client.started.timeout(const Duration(seconds: 5));
    final view = await client.views
        .firstWhere((v) => v.players.isNotEmpty)
        .timeout(const Duration(seconds: 5));
    expect(view.players.map((p) => p.name), contains('BLEゲスト'));

    // 空中に出たチャンクはどれも交渉長(185)以内・ヘッダ付き
    final tx = air.peripheralManager.notified[cm.self.uuid]!;
    expect(tx, isNotEmpty);
    for (final c in tx) {
      expect(c.length, lessThanOrEqualTo(185));
      expect(c.length, greaterThanOrEqualTo(frameHeaderLength));
    }
    for (final c in cm.written) {
      expect(c.length, lessThanOrEqualTo(185));
    }
    // 局面は複数チャンクに分割されている(圧縮しても185Bは超える)
    expect(tx.length, greaterThan(1));

    await client.dispose();
    await session.dispose();
    await bleHost.stop();
    await browser.stop();
  });

  test('参加者が切断(購読解除)するとホスト側の通信路も閉じ、CPU代打になる', () async {
    final air = FakeAir();
    final server = HostServer(
      roomName: 'BLE卓',
      hostName: 'ホスト',
      config: const GameConfig(rounds: 1),
    );
    final bleHost = BleHost(
      onChannel: server.attachChannel,
      manager: () => air.peripheralManager,
    );
    await bleHost.start(roomName: 'BLE卓');
    final cm = air.addCentral('00000000-0000-0000-0000-000000000002');
    final browser = BleBrowser(manager: () => cm);
    await browser.start();
    final rooms = await browser.rooms.first;
    final channel = await browser.join(rooms.single.id);
    final client = await ClientSession.overChannel(
      channel: channel,
      playerName: '切れる人',
    );
    await client.lobbyStream.first.timeout(const Duration(seconds: 5));
    expect(bleHost.connectedCount, 1);

    await client.dispose(); // → BleLink.close → central.disconnect → 購読解除
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(bleHost.connectedCount, 0);
    expect(
      server.lobbyState.players.map((p) => p.name),
      isNot(contains('切れる人')),
    );
    await bleHost.stop();
    await browser.stop();
  });

  test('参加者2人が同時にBLEで入室できる(セントラル別に通知が分かれる)', () async {
    final air = FakeAir();
    final server = HostServer(
      roomName: 'BLE卓',
      hostName: 'ホスト',
      config: const GameConfig(rounds: 1),
    );
    final bleHost = BleHost(
      onChannel: server.attachChannel,
      manager: () => air.peripheralManager,
    );
    await bleHost.start(roomName: 'BLE卓');
    final clients = <ClientSession>[];
    for (var i = 0; i < 2; i++) {
      final cm = air.addCentral('00000000-0000-0000-0000-00000000001$i');
      final browser = BleBrowser(manager: () => cm);
      await browser.start();
      final rooms = await browser.rooms.first;
      final channel = await browser.join(rooms.single.id);
      final c = await ClientSession.overChannel(
        channel: channel,
        playerName: 'G$i',
      );
      await c.lobbyStream.first.timeout(const Duration(seconds: 5));
      clients.add(c);
    }
    expect(bleHost.connectedCount, 2);
    final names = server.lobbyState.players.map((p) => p.name).toList();
    expect(names, containsAll(['G0', 'G1']));
    expect(air.peripheralManager.notified.length, 2);
    for (final c in clients) {
      await c.dispose();
    }
    await bleHost.stop();
  });

  test('ホスト側から切られた参加者は done になる', () async {
    final air = FakeAir();
    final cm = air.addCentral('00000000-0000-0000-0000-000000000003');
    final bleHost = BleHost(
      onChannel: (_) {},
      manager: () => air.peripheralManager,
    );
    await bleHost.start(roomName: 'x');
    final browser = BleBrowser(manager: () => cm);
    await browser.start();
    final rooms = await browser.rooms.first;
    final channel = await browser.join(rooms.single.id);
    var done = false;
    channel.done.then((_) => done = true);
    cm.dropped();
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue);
    await bleHost.stop();
  });
}
