/// 中断した対局のストレージ保存(shared_preferences)。
/// アプリを落としても復帰情報が残るよう、端末ローカルに永続化する。
///
/// 保存形式は**復帰データの配列**(各要素に中断日時 `savedAt` と
/// リビジョン `rev` を含む)。現状は1セットしか保存しないが、
/// 将来複数の中断対局を持てるようにするための形式。
/// リビジョンはデータ構造を変えたときのマイグレーション用
/// ([suspendDataRevision] を上げ、[_migrate] に旧→新の変換を足す)。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'suspend.dart';
import 'suspend_tile_codec.dart';

class SuspendStore {
  static const _hostKey = 'suspendedHostGames';
  static const _guestKey = 'suspendedGuestGames';

  /// 旧形式(単一オブジェクト保存)のキー。読み込みだけ後方互換する。
  static const _legacyHostKey = 'suspendedHostGame';
  static const _legacyGuestKey = 'suspendedGuestGame';

  // ---------------- ホスト ----------------

  static Future<void> saveHost(SuspendedHostGame game) async {
    final json = game.toJson();
    // 保存時のみ、牌の表現をMリーグ牌譜DB表記へ変換する(内部表現は不変)
    json['engine'] = encodeEngineTiles(
      (json['engine'] as Map).cast<String, dynamic>(),
    );
    // 現状は1セットのみ保持(新しい中断で置き換える)
    await _writeList(_hostKey, [json]);
  }

  /// 保存されている全ホスト復帰データ(新しい順)
  static Future<List<SuspendedHostGame>> loadHostAll() async =>
      (await _readList(_hostKey, _legacyHostKey))
          .map(
            (m) => SuspendedHostGame.fromJson({
              ...m,
              // 保存表記(DB表記)→内部表現(int)へ。旧int保存もそのまま通る
              if (m['engine'] is Map)
                'engine': decodeEngineTiles(
                  (m['engine'] as Map).cast<String, dynamic>(),
                ),
            }),
          )
          .toList()
        ..sort((a, b) => b.savedAt.compareTo(a.savedAt));

  /// 最新のホスト復帰データ(なければ null)
  static Future<SuspendedHostGame?> loadHost() async {
    final all = await loadHostAll();
    return all.isEmpty ? null : all.first;
  }

  static Future<void> clearHost() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hostKey);
    await prefs.remove(_legacyHostKey);
  }

  // ---------------- ゲスト ----------------

  static Future<void> saveGuest(SuspendedGuestGame game) async {
    await _writeList(_guestKey, [game.toJson()]);
  }

  /// 保存されている全ゲスト復帰データ(新しい順)
  static Future<List<SuspendedGuestGame>> loadGuestAll() async =>
      (await _readList(
          _guestKey,
          _legacyGuestKey,
        )).map(SuspendedGuestGame.fromJson).toList()
        ..sort((a, b) => b.savedAt.compareTo(a.savedAt));

  /// 最新のゲスト復帰データ(なければ null)
  static Future<SuspendedGuestGame?> loadGuest() async {
    final all = await loadGuestAll();
    return all.isEmpty ? null : all.first;
  }

  static Future<void> clearGuest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_guestKey);
    await prefs.remove(_legacyGuestKey);
  }

  // ---------------- 共通 ----------------

  static Future<void> _writeList(
    String key,
    List<Map<String, dynamic>> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(entries));
  }

  /// 配列形式の保存データを読み、各要素を現行リビジョンへ揃えて返す。
  /// 壊れた要素・読めないリビジョンの要素は黙って捨てる(クラッシュさせない)。
  static Future<List<Map<String, dynamic>>> _readList(
    String key,
    String legacyKey,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key) ?? prefs.getString(legacyKey);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      // 旧形式(単一オブジェクト)は1要素の配列として扱う
      final list = decoded is List ? decoded : [decoded];
      return [
        for (final e in list)
          if (e is Map) ?_migrate(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 保存データを現行リビジョン([suspendDataRevision])へマイグレーションする。
  /// 読めない(未知の新しい)リビジョンは null を返して無視する。
  static Map<String, dynamic>? _migrate(Map<String, dynamic> json) {
    var rev = json['rev'] as int? ?? 1; // rev導入前の保存データは1扱い
    var data = json;
    // 将来 rev N → N+1 の変換をここに順番に足していく。
    // rev1 → rev2: 牌の保存表記が int → Mリーグ牌譜DB表記。
    // 読み込み側(suspend_tile_codec の decode)が両表記を受けるので
    // データ自体の変換は不要。
    if (rev == 1) rev = 2;
    if (rev != suspendDataRevision) return null;
    return data;
  }
}
