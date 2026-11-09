/// 中断データ(復帰情報)の**ストレージ保存時だけ**、牌の表現を
/// Mリーグ牌譜DB(konoui/m-league-game-db)と同じ表記へ変換するコーデック。
///
/// - 表記: '1m'〜'9s' / 赤5='0m'・'0p'・'0s' / 字牌='1z'〜'7z'
/// - 対象: ResumeData JSON の山(`wall`)と最新局の牌譜(`actions`)の牌のみ
/// - エンジン内部・対戦時の通信で使う牌表現(int)は一切変えない
///
/// 将来、中断データを牌譜DBへ保存することを見据えた形式合わせ。
/// デコードは int(旧リビジョンの保存)と文字列の両方を受け付ける。
library;

import '../engine/tile.dart';

String _enc(int t) => t < 0 ? '' : Tile.dbNotation(t); // -1(ツモ等)は空文字

int _dec(Object? v) {
  if (v is int) return v; // 旧形式(int保存)もそのまま読める
  final s = v as String;
  return s.isEmpty ? -1 : Tile.fromDbNotation(s);
}

/// ResumeData JSON の牌をDB表記へ変換した新しいマップを返す(保存用)
Map<String, dynamic> encodeEngineTiles(Map<String, dynamic> engine) => {
  ...engine,
  'wall': [for (final t in engine['wall'] as List) _enc(t as int)],
  'actions': [
    for (final a in engine['actions'] as List)
      _convertAction((a as Map).cast<String, dynamic>(), (v) => _enc(v as int)),
  ],
};

/// 保存されていた ResumeData JSON の牌を内部表現(int)へ戻す(読込用)
Map<String, dynamic> decodeEngineTiles(Map<String, dynamic> engine) => {
  ...engine,
  'wall': [for (final t in engine['wall'] as List) _dec(t)],
  'actions': [
    for (final a in engine['actions'] as List)
      _convertAction((a as Map).cast<String, dynamic>(), _dec),
  ],
};

/// RecordedAction JSON の牌フィールドだけを [conv] で変換する。
/// 't'(TurnAction)は `tile`、'r'(ReactAction)は `tiles` が牌。
Map<String, dynamic> _convertAction(
  Map<String, dynamic> rec,
  Object? Function(dynamic) conv,
) {
  final action = (rec['a'] as Map).cast<String, dynamic>();
  final converted = {...action};
  if (rec['k'] == 't') {
    if (action.containsKey('tile')) converted['tile'] = conv(action['tile']);
  } else {
    converted['tiles'] = [
      for (final t in action['tiles'] as List? ?? const []) conv(t),
    ];
  }
  return {...rec, 'a': converted};
}
