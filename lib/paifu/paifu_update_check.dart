/// 牌譜DBの更新有無を、ダウンロードせずに確かめる。
///
/// 配布元の `releases/latest/download/database.zip` に HEAD を投げると、
/// GitHub は `releases/download/<タグ>/database.zip` へ 302 で誘導する。
/// リダイレクトを追わずに Location ヘッダのタグを読めば、通信はヘッダ1往復で済む。
///
/// 方針(2026-09-16 ユーザー決定):
/// - 確認は起動後1回だけ(画面を開くたびには行わない)
/// - DBが無い(インストール直後)なら確認しない
/// - オフラインらしければ確認しない(名前解決・接続に失敗したら黙って何もしない)
/// - 更新がありそうなら「更新あり」程度の控えめな表示にとどめ、誘導はしない
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'paifu_store.dart';

/// リダイレクト先URLからリリースタグを取り出す(純粋関数)。
/// 例: `.../releases/download/20260915-2050-1e8b74ea/database.zip` → `20260915-2050-1e8b74ea`
String? releaseTagFromLocation(String? location) {
  if (location == null) return null;
  final m = RegExp(r'/releases/download/([^/?#]+)/').firstMatch(location);
  return m?.group(1);
}

class PaifuUpdateCheck {
  /// 「更新がありそう」の状態。UIはこれを購読して控えめな表示を出す
  static final ValueNotifier<bool> updateAvailable = ValueNotifier(false);

  /// 最新リリースがこのアプリの対応外(取り込みを拒否した版)と分かっているとき、
  /// そのタグ。「更新あり」の代わりに「未対応の更新あり」を出す
  static final ValueNotifier<String?> unsupportedTag = ValueNotifier(null);

  static bool _done = false;

  /// 起動後1回だけ確認する。2回目以降の呼び出しは何もしない。
  /// [fetchLatestTag] 等はテストで差し替える。
  static Future<void> runOnce({
    Future<String?> Function()? fetchLatestTag,
    Future<bool> Function()? hasDb,
    Future<String?> Function()? savedTag,
    Future<String?> Function()? rejectedTag,
  }) async {
    if (_done) return;
    _done = true;
    try {
      if (!await (hasDb ?? PaifuStore.exists)()) return; // インストール直後
      final saved = await (savedTag ?? PaifuStore.savedTag)();
      if (saved == null) return; // タグ未保存(旧版でDLしたDB)は比較できない
      final latest =
          await (fetchLatestTag ?? PaifuUpdateCheck.fetchLatestTag)();
      if (latest == null) return; // オフライン・到達不能
      if (latest == saved) return;
      // 以前に取り込みを拒否した版なら、再び促さず「未対応」とだけ知らせる
      final rejected = await (rejectedTag ?? PaifuStore.rejectedTag)();
      if (rejected != null && rejected == latest) {
        unsupportedTag.value = latest;
        return;
      }
      updateAvailable.value = true;
    } catch (_) {
      // 確認に失敗しても何もしない(表示を出さない側に倒す)
    }
  }

  /// 配布元に HEAD を投げて最新リリースのタグを得る。
  /// オフライン・タイムアウト・想定外の応答では null。
  static Future<String?> fetchLatestTag({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      // オフラインなら名前解決の時点で失敗する → null
      await InternetAddress.lookup('github.com').timeout(timeout);
      final req = await client
          .headUrl(Uri.parse(PaifuStore.downloadUrl))
          .timeout(timeout);
      req.followRedirects = false;
      final res = await req.close().timeout(timeout);
      final location = res.headers.value(HttpHeaders.locationHeader);
      await res.drain<void>();
      return releaseTagFromLocation(location);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// ダウンロードが完了したら呼ぶ(表示を消す)
  static void markUpToDate() {
    updateAvailable.value = false;
    unsupportedTag.value = null;
  }

  /// 取り込みを拒否した(対応外の版だった)ときに呼ぶ
  static void markUnsupported(String? tag) {
    updateAvailable.value = false;
    unsupportedTag.value = tag ?? '?';
  }

  @visibleForTesting
  static void resetForTest() {
    _done = false;
    updateAvailable.value = false;
    unsupportedTag.value = null;
  }
}
