/// 鳴き(副露)の表現
library;

enum MeldType { chi, pon, ankan, minkan, kakan }

class Meld {
  final MeldType type;

  /// 構成牌種(チーは昇順3枚、ポン3枚、カン4枚)
  final List<int> tiles;

  /// 鳴いた相手の席(絶対席 0..3)。暗槓は -1
  final int fromSeat;

  /// 鳴いた牌(暗槓は tiles[0])
  final int calledTile;

  const Meld({
    required this.type,
    required this.tiles,
    required this.fromSeat,
    required this.calledTile,
  });

  bool get isKan =>
      type == MeldType.ankan ||
      type == MeldType.minkan ||
      type == MeldType.kakan;

  /// 門前を崩さない副露か(暗槓のみ true)
  bool get keepsConcealed => type == MeldType.ankan;

  /// 面子として見たときに暗刻扱いか
  bool get countsAsClosedTriplet => type == MeldType.ankan;

  bool get isRun => type == MeldType.chi;

  Map<String, dynamic> toJson() => {
    'type': type.index,
    'tiles': tiles,
    'from': fromSeat,
    'called': calledTile,
  };

  factory Meld.fromJson(Map<String, dynamic> json) => Meld(
    type: MeldType.values[json['type'] as int],
    tiles: (json['tiles'] as List).cast<int>(),
    fromSeat: json['from'] as int,
    calledTile: json['called'] as int,
  );
}
