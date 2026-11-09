/// 試合中断・復帰の保存データ(ストレージ実装は suspend_store.dart)
library;

import '../engine/models.dart';
import '../engine/resume.dart';

/// 復帰データの現行リビジョン。
/// 将来データ構造が変わったときに、保存済みデータをマイグレーションで
/// 読めるようにするための版数(構造を変えたらここを上げ、
/// suspend_store.dart のマイグレーションに旧→新の変換を足す)。
///
/// rev2: 牌の保存表記を int から Mリーグ牌譜DB表記('5m'/'0m'/'1z')へ変更
/// (suspend_tile_codec.dart。読み込みは両表記対応なので rev1 もそのまま読める)
const int suspendDataRevision = 2;

/// ホスト側に保存する復帰情報一式。
/// エンジンの復元データに加えて、復帰ロビーを立て直すための部屋情報を持つ。
class SuspendedHostGame {
  final String roomName;
  final String hostName;
  final GameConfig config;

  /// 合流を待つゲスト(ホスト以外の人間メンバー)の名前
  final List<String> guestNames;

  /// GameEngine.fromResume に渡す復元データ(JSON)
  final Map<String, dynamic> engine;

  /// 中断日時
  final DateTime savedAt;

  /// このデータが保存されたときの復帰データリビジョン
  final int revision;

  /// ホストがギャラリー(観戦)だった場合に見ていたプレイヤー名。
  /// null なら通常のプレイヤーとして参加していた。
  final String? watchName;

  /// 中断時に牌譜保存(my_paifu_store.dart)が開いていた試合のID。
  /// 復帰時に同じファイルへの追記を続けるために持ち回る。
  final String? paifuGameId;

  const SuspendedHostGame({
    required this.roomName,
    required this.hostName,
    required this.config,
    required this.guestNames,
    required this.engine,
    required this.savedAt,
    this.revision = suspendDataRevision,
    this.watchName,
    this.paifuGameId,
  });

  factory SuspendedHostGame.capture({
    required String roomName,
    required String hostName,
    required ResumeData data,
    required DateTime savedAt,
    String? watchName,
    String? paifuGameId,
  }) => SuspendedHostGame(
    roomName: roomName,
    hostName: hostName,
    config: data.config,
    guestNames: data.guestNames(hostName),
    engine: data.toJson(),
    savedAt: savedAt,
    watchName: watchName,
    paifuGameId: paifuGameId,
  );

  ResumeData get resumeData => ResumeData.fromJson(engine);

  /// ホストがギャラリー(席に着いていない)だった対局か
  bool get hostIsGallery => !resumeData.names.contains(hostName);

  Map<String, dynamic> toJson() => {
    'rev': revision,
    'room': roomName,
    'hostName': hostName,
    'config': config.toJson(),
    'guests': guestNames,
    'engine': engine,
    'savedAt': savedAt.toIso8601String(),
    if (watchName != null) 'watch': watchName,
    if (paifuGameId != null) 'paifuGameId': paifuGameId,
  };

  factory SuspendedHostGame.fromJson(Map<String, dynamic> json) =>
      SuspendedHostGame(
        roomName: json['room'] as String,
        hostName: json['hostName'] as String,
        config: GameConfig.fromJson(
          (json['config'] as Map).cast<String, dynamic>(),
        ),
        guestNames: (json['guests'] as List).cast<String>(),
        engine: (json['engine'] as Map).cast<String, dynamic>(),
        savedAt: DateTime.parse(json['savedAt'] as String),
        revision: json['rev'] as int? ?? 1, // rev導入前の保存データは1扱い
        watchName: json['watch'] as String?,
        paifuGameId: json['paifuGameId'] as String?,
      );
}

/// ゲスト側に保存する復帰情報(部屋と自分の名前が分かれば合流できる)
class SuspendedGuestGame {
  final String roomName;

  /// ホストが付けた自分の名前(同名重複時の連番込み。合流はこの名前で照合される)
  final String playerName;

  /// 中断日時
  final DateTime savedAt;

  /// このデータが保存されたときの復帰データリビジョン
  final int revision;

  const SuspendedGuestGame({
    required this.roomName,
    required this.playerName,
    required this.savedAt,
    this.revision = suspendDataRevision,
  });

  Map<String, dynamic> toJson() => {
    'rev': revision,
    'room': roomName,
    'name': playerName,
    'savedAt': savedAt.toIso8601String(),
  };

  factory SuspendedGuestGame.fromJson(Map<String, dynamic> json) =>
      SuspendedGuestGame(
        roomName: json['room'] as String,
        playerName: json['name'] as String,
        savedAt: DateTime.parse(json['savedAt'] as String),
        revision: json['rev'] as int? ?? 1, // rev導入前の保存データは1扱い
      );
}
