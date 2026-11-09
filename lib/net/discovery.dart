/// mDNS/Bonjour による同一LAN内の部屋発見
library;

import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

const String serviceType = '_mahjongtaku._tcp';

class RoomInfo {
  final String name;
  final String host;
  final int port;

  const RoomInfo({required this.name, required this.host, required this.port});
}

/// ホスト側: 部屋を広告する
class RoomBroadcaster {
  BonsoirBroadcast? _broadcast;

  Future<void> start({required String roomName, required int port}) async {
    final broadcast = BonsoirBroadcast(
      service: BonsoirService(name: roomName, type: serviceType, port: port),
    );
    _broadcast = broadcast;
    await broadcast.initialize();
    await broadcast.start();
  }

  Future<void> stop() async {
    await _broadcast?.stop();
    _broadcast = null;
  }
}

/// クライアント側: 部屋を探す
class RoomScanner {
  final _controller = StreamController<List<RoomInfo>>.broadcast();
  final Map<String, RoomInfo> _rooms = {};
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;

  Stream<List<RoomInfo>> get rooms => _controller.stream;
  List<RoomInfo> get currentRooms => _rooms.values.toList();

  Future<void> start() async {
    final discovery = BonsoirDiscovery(type: serviceType);
    _discovery = discovery;
    await discovery.initialize();
    _sub = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          discovery.serviceResolver.resolveService(service);
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
          // IPv4を優先(WebSocket接続の宛先にする)
          final addresses = service.hostAddresses;
          final host = addresses.isEmpty
              ? null
              : addresses.firstWhere(
                  (a) => !a.contains(':'),
                  orElse: () => addresses.first,
                );
          if (host != null) {
            _rooms[service.name] = RoomInfo(
              name: service.name,
              host: host,
              port: service.port,
            );
            _controller.add(currentRooms);
          }
        case BonsoirDiscoveryServiceLostEvent(:final service):
          _rooms.remove(service.name);
          _controller.add(currentRooms);
        default:
          break;
      }
    });
    await discovery.start();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _discovery?.stop();
    _discovery = null;
    await _controller.close();
  }
}

/// 手動接続用に自端末のIPv4アドレス一覧を返す
Future<List<String>> localIpAddresses() async {
  final result = <String>[];
  try {
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    for (final ni in interfaces) {
      for (final addr in ni.addresses) {
        if (!addr.isLoopback) result.add(addr.address);
      }
    }
  } catch (_) {}
  return result;
}
