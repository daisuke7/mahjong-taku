/// 牌譜ビューアの「お気に入り局」の永続化。
///
/// キーは `m_league_game_id|round|honba`(例: 'L001_S022_0036_01B|2z3|1')。
/// DBは更新のたびに作り直されて内部IDが変わり得るので、公式試合ID+局+本場の
/// 自然キーで持つ。
library;

import 'package:shared_preferences/shared_preferences.dart';

class FavoriteStore {
  static const String _prefsKey = 'paifuFavoriteKyokus';

  static Set<String>? _cache;

  /// お気に入り局キー(メモリキャッシュ。[ensureLoaded] 後に有効)
  static Set<String> get keys => _cache ?? const {};

  /// お気に入り局を含む試合の m_league_game_id 一覧
  static Set<String> get gameIds => {for (final k in keys) k.split('|').first};

  static bool contains(String key) => keys.contains(key);

  static String keyOf(String mLeagueGameId, String round, int honba) =>
      '$mLeagueGameId|$round|$honba';

  static Future<void> ensureLoaded() async {
    if (_cache != null) return;
    final prefs = await SharedPreferences.getInstance();
    _cache = (prefs.getStringList(_prefsKey) ?? const []).toSet();
  }

  static Future<void> toggle(String key) async {
    await ensureLoaded();
    final c = _cache!;
    if (!c.remove(key)) c.add(key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, c.toList()..sort());
  }

  /// テスト用: キャッシュを破棄して次回読み直させる
  static void resetForTest() => _cache = null;
}
