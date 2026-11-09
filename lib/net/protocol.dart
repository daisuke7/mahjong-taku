/// ホスト⇔クライアント間のメッセージ定義
library;

import 'dart:convert';

import '../engine/models.dart';

const int defaultPort = 47654;

/// ワイヤ形式のバージョン。整形層(framing.dart)の導入で 2。
/// 通信できない版どうしはロビーの hello で検出して弾く。
const int protocolVersion = 2;

String encodeMsg(String type, [Map<String, dynamic>? body]) =>
    jsonEncode({'t': type, ...?body});

Map<String, dynamic>? decodeMsg(dynamic data) {
  try {
    final map = jsonDecode(data as String);
    if (map is Map<String, dynamic> && map['t'] is String) return map;
  } catch (_) {}
  return null;
}

class LobbyPlayer {
  final String name;
  final bool isHost;
  final bool isCpu;

  /// 中断した対局のメンバーで、まだ合流していない(復帰ロビーのみ)
  final bool waiting;

  /// ホストが席に着かず観戦する予定(ギャラリー)
  final bool gallery;

  const LobbyPlayer({
    required this.name,
    this.isHost = false,
    this.isCpu = false,
    this.waiting = false,
    this.gallery = false,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': isHost,
    'cpu': isCpu,
    if (waiting) 'w': true,
    if (gallery) 'gal': true,
  };

  factory LobbyPlayer.fromJson(Map<String, dynamic> json) => LobbyPlayer(
    name: json['name'] as String,
    isHost: json['host'] as bool? ?? false,
    isCpu: json['cpu'] as bool? ?? false,
    waiting: json['w'] as bool? ?? false,
    gallery: json['gal'] as bool? ?? false,
  );
}

/// ホストが対局を中断した通知(クライアントが復帰情報の保存に使う)
class SuspendNotice {
  final String roomName;

  /// ホストが付けたこのクライアントの名前(復帰時の照合に使う)
  final String playerName;

  /// 観戦者への通知(復帰情報の保存対象ではない)
  final bool spectator;

  const SuspendNotice({
    required this.roomName,
    required this.playerName,
    this.spectator = false,
  });
}

/// 試合中の部屋への観戦(ギャラリー)希望。ホストが許可/拒否を決める。
class SpectateRequest {
  final String name;
  final void Function() approve;
  final void Function() deny;

  const SpectateRequest({
    required this.name,
    required this.approve,
    required this.deny,
  });
}

class LobbyState {
  final String roomName;
  final List<LobbyPlayer> players; // index = 席
  final GameConfig config;

  const LobbyState({
    required this.roomName,
    required this.players,
    required this.config,
  });

  Map<String, dynamic> toJson() => {
    'room': roomName,
    'players': players.map((p) => p.toJson()).toList(),
    'config': config.toJson(),
  };

  factory LobbyState.fromJson(Map<String, dynamic> json) => LobbyState(
    roomName: json['room'] as String,
    players: (json['players'] as List)
        .map((p) => LobbyPlayer.fromJson((p as Map).cast<String, dynamic>()))
        .toList(),
    config: GameConfig.fromJson(
      (json['config'] as Map).cast<String, dynamic>(),
    ),
  );
}
