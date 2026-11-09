/// ゴーストモードの試行記録の永続化。
///
/// キーはお気に入り局キーに突入手数を足した
/// `m_league_game_id|round|honba|cutoff`。同じ局面(同じ突入点)から
/// 何度打ち直しても結果が貯まり、「この局面から5回打って
/// 和了2 / 放銃1 / 流局2」のような分布として参照できる。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// ゴースト1回分の結果。[outcome] は観戦席から見た分類
/// ('win'=和了 / 'dealIn'=放銃 / 'draw'=流局 / 'other'=それ以外)。
class GhostTrial {
  final String outcome;
  final int delta; // 観戦席の点数増減
  const GhostTrial(this.outcome, this.delta);
}

class GhostTrialStore {
  static const String _prefsKey = 'paifuGhostTrials';

  static Map<String, List<GhostTrial>>? _cache;

  static Future<void> ensureLoaded() async {
    if (_cache != null) return;
    final prefs = await SharedPreferences.getInstance();
    final map = <String, List<GhostTrial>>{};
    for (final s in prefs.getStringList(_prefsKey) ?? const []) {
      try {
        final m = jsonDecode(s) as Map<String, dynamic>;
        (map[m['k'] as String] ??= []).add(
          GhostTrial(m['o'] as String, m['d'] as int),
        );
      } catch (_) {
        // 壊れた行は読み飛ばす
      }
    }
    _cache = map;
  }

  /// この局面(突入点キー)の試行履歴(古い順)
  static List<GhostTrial> trialsFor(String key) => _cache?[key] ?? const [];

  static Future<void> add(String key, GhostTrial trial) async {
    await ensureLoaded();
    (_cache![key] ??= []).add(trial);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, [
      for (final e in _cache!.entries)
        for (final t in e.value)
          jsonEncode({'k': e.key, 'o': t.outcome, 'd': t.delta}),
    ]);
  }

  /// テスト用: キャッシュを破棄して次回読み直させる
  static void resetForTest() => _cache = null;
}
