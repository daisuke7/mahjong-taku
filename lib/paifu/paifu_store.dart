/// Mリーグ牌譜DBファイルの管理(ダウンロード・展開・バージョン確認)。
///
/// 配布元: https://github.com/konoui/m-league-game-db (MITライセンス)
/// 最新リリースの database.zip を取得し、展開した database.sqlite3 を
/// アプリのサポートディレクトリに保存する。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

import 'db_schema.dart';
import 'paifu_db.dart';
import 'paifu_update_check.dart';
import '../features.dart';

/// ダウンロード進捗。total が不明(-1)のこともある。
/// stage が 'retry' のときは received=次に行う試行番号(1始まり)、total=最大試行回数。
typedef PaifuProgress = void Function(String stage, int received, int total);

/// HTTP GET の結果(テストで差し替えるための最小限の形)。
typedef PaifuHttpResponse = ({
  int statusCode,
  int contentLength,
  Stream<List<int>> body,
});

/// HTTP GET を行う関数。リダイレクト追従済みの最終応答を返す。
/// 接続失敗などは例外(IOException 系)で表す。
typedef PaifuFetch = Future<PaifuHttpResponse> Function(Uri uri);

/// 全試行が失敗したときの例外。message にユーザー向け文言を持つ
class PaifuDownloadFailed implements Exception {
  final String message;
  final int attempts;
  PaifuDownloadFailed(this.message, this.attempts);
  @override
  String toString() => message;
}

/// その試行は失敗したが再試行の価値がある(5xx・通信断)ことを表す内部例外
class _RetryableFailure implements Exception {
  final String message;
  _RetryableFailure(this.message);
}

class PaifuStore {
  static const String downloadUrl =
      'https://github.com/konoui/m-league-game-db/releases/latest/download/database.zip';

  /// DBファイルの置き場所。
  /// 再ダウンロードで復旧できるデータなので Caches に置く
  /// (iOS/Androidともバックアップ対象外になり、iCloud容量や
  /// AndroidのAuto Backupクォータ25MBを食わない。OSがストレージ逼迫時に
  /// 削除することがあるが、その場合は既存のDLフローで入れ直せる)。
  static Future<File> dbFile() async {
    final dir = await getApplicationCacheDirectory();
    final f = File('${dir.path}/mleague/database.sqlite3');
    await _migrateFromSupportDir(f);
    return f;
  }

  /// 旧配置(Application Support/mleague)からの移行。
  /// 再ダウンロード(200MB)をさせないため、ファイルを移動して引き継ぐ。
  static Future<void> _migrateFromSupportDir(File target) async {
    try {
      if (await target.exists()) return;
      final oldDir = await getApplicationSupportDirectory();
      final old = File('${oldDir.path}/mleague/database.sqlite3');
      if (!await old.exists()) return;
      await target.parent.create(recursive: true);
      await old.rename(target.path);
      // 空になった旧フォルダは片付ける(失敗しても支障なし)
      try {
        await old.parent.delete();
      } catch (_) {}
    } catch (_) {
      // 移行できない場合はダウンロードフローに任せる
    }
  }

  static Future<bool> exists() async =>
      Features.localFiles && await (await dbFile()).exists();

  /// ダウンロード時のリリースタグを覚えておくファイル(更新確認の比較用)
  static Future<File> tagFile() async =>
      File('${(await dbFile()).parent.path}/database.tag');

  /// 保存済みのリリースタグ。旧版でダウンロードしたDBには無い(null)
  static Future<String?> savedTag() async {
    try {
      final f = await tagFile();
      if (!await f.exists()) return null;
      final s = (await f.readAsString()).trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  /// 対応外として取り込みを拒否したリリースのタグを覚えておくファイル
  /// (同じリリースに対して「更新あり」を出し続けないため)
  static Future<File> rejectedTagFile() async =>
      File('${(await dbFile()).parent.path}/database.rejected');

  static Future<String?> rejectedTag() async {
    try {
      final f = await rejectedTagFile();
      if (!await f.exists()) return null;
      final s = (await f.readAsString()).trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  /// 今あるDBをこのアプリが読めるか(足りないテーブル・列。空なら可、DB無しも空)
  static Future<List<String>> schemaProblems() async {
    final f = await dbFile();
    if (!await f.exists()) return const [];
    return PaifuDb.schemaProblemsAt(f.path);
  }

  /// 現在の牌譜バージョン(記録されている最終試合日)。未ダウンロードなら null
  static Future<String?> currentVersion() async {
    final f = await dbFile();
    if (!await f.exists()) return null;
    try {
      final db = PaifuDb.open(f.path);
      try {
        return db.latestGameDate();
      } finally {
        db.close();
      }
    } catch (_) {
      return null; // 壊れたファイル等
    }
  }

  /// 既定の HTTP GET(リダイレクト追従は HttpClient が行う)。
  static Future<PaifuHttpResponse> _httpGet(Uri uri) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      final res = await req.close();
      // 本文を読み終えてから client を閉じる
      final body = res.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleDone: (sink) {
            client.close();
            sink.close();
          },
          handleError: (e, st, sink) {
            client.close();
            sink.addError(e, st);
          },
        ),
      );
      return (
        statusCode: res.statusCode,
        contentLength: res.contentLength,
        body: body,
      );
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  /// 最大試行回数(2026-11-09 ユーザー決定: 3回試行=2回リトライ、駄目なら諦める)
  static const int maxAttempts = 3;

  /// 再試行前の待ち時間(試行 n 回目の失敗後は delays[n-1]。足りなければ末尾を使う)
  static const List<Duration> retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  /// [uri] を GET して [dest] に書く。配布元の一時エラー(HTTP 5xx)と通信断
  /// (IOException 系: 接続失敗・途中切断)は最大 [attempts] 回まで試し、全部駄目なら
  /// [PaifuDownloadFailed] を投げる。4xx など恒久的な失敗は即座に投げる。
  /// 途中まで書いた [dest] は試行ごとに上書きされる。
  ///
  /// 経緯: 2026-11-09 iPhone 12 Pro で GitHub から 504 が1回返り、再操作で成功した。
  /// 1回の一時エラーで利用者に再操作させない。
  static Future<void> downloadWithRetry(
    Uri uri,
    File dest, {
    required PaifuFetch fetch,
    PaifuProgress? onProgress,
    int attempts = maxAttempts,
    List<Duration> delays = retryDelays,
    Future<void> Function(Duration)? wait,
  }) async {
    String? lastMessage;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        await _downloadOnce(uri, dest, fetch, onProgress);
        return;
      } on _RetryableFailure catch (e) {
        lastMessage = e.message;
        if (attempt == attempts) break;
        onProgress?.call('retry', attempt + 1, attempts);
        final d = delays.isEmpty
            ? Duration.zero
            : delays[attempt - 1 < delays.length
                  ? attempt - 1
                  : delays.length - 1];
        await (wait ?? Future<void>.delayed)(d);
      }
    }
    throw PaifuDownloadFailed(
      '$lastMessage。$attempts回試しましたが失敗しました。'
      'しばらくしてからもう一度お試しください',
      attempts,
    );
  }

  static Future<void> _downloadOnce(
    Uri uri,
    File dest,
    PaifuFetch fetch,
    PaifuProgress? onProgress,
  ) async {
    final PaifuHttpResponse res;
    try {
      res = await fetch(uri);
    } on IOException catch (e) {
      throw _RetryableFailure('接続できませんでした(${_shortError(e)})');
    }
    if (res.statusCode >= 500) {
      throw _RetryableFailure('配布元が一時的に応答しません(HTTP ${res.statusCode})');
    }
    if (res.statusCode != 200) {
      throw Exception('ダウンロードに失敗しました(HTTP ${res.statusCode})');
    }
    final total = res.contentLength;
    var received = 0;
    final sink = dest.openWrite();
    try {
      await for (final chunk in res.body) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call('download', received, total);
      }
    } on IOException catch (e) {
      throw _RetryableFailure('通信が途中で切れました(${_shortError(e)})');
    } finally {
      await sink.close();
    }
  }

  static String _shortError(Object e) {
    final s = e.toString();
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  /// 最新の database.zip をダウンロードして展開し、DBファイルを置き換える。
  /// 進捗は onProgress(stage, received, total) で通知
  /// (stage: 'download' | 'extract' | 'verify')。
  static Future<void> downloadLatest({PaifuProgress? onProgress}) async {
    final target = await dbFile();
    await target.parent.create(recursive: true);
    final zipPath = '${target.parent.path}/database.zip.part';
    final zipFile = File(zipPath);
    // これから取るリリースのタグ(更新確認の比較に使う)。取れなくても続行
    final tag = await PaifuUpdateCheck.fetchLatestTag();

    // ダウンロード(5xx・通信断は少し待って最大3回まで試す)
    await downloadWithRetry(
      Uri.parse(downloadUrl),
      zipFile,
      fetch: _httpGet,
      onProgress: onProgress,
    );

    // 展開(別Isolateで実行してUIを止めない。ストリーミング展開でメモリ節約)。
    // extractFileToDisk は拡張子で形式判定するので .zip に揃えてから渡す。
    onProgress?.call('extract', 0, -1);
    final completeZip = File('${target.parent.path}/database.zip');
    if (await completeZip.exists()) await completeZip.delete();
    await zipFile.rename(completeZip.path);
    final extractDir = Directory('${target.parent.path}/extract');
    if (await extractDir.exists()) await extractDir.delete(recursive: true);
    await extractDir.create(recursive: true);
    final extractPath = extractDir.path;
    final completeZipPath = completeZip.path;
    await Isolate.run(() => extractFileToDisk(completeZipPath, extractPath));

    // 展開結果から .sqlite3 を探して所定の場所へ
    File? found;
    await for (final e in extractDir.list(recursive: true)) {
      if (e is File && e.path.endsWith('.sqlite3')) {
        found = e;
        break;
      }
    }
    if (found == null) {
      throw Exception('zip内に .sqlite3 ファイルが見つかりません');
    }

    // 取り込む前に、このアプリが読めるスキーマか検査する。配布元はシーズン中でも
    // テーブル名・列名を改名するので(2026-10-01 リリースで実際に起きた)、
    // 読めない版を置き換えてしまうと復旧不能になる。足りなければ今の DB を保持し、
    // 拒否したタグを覚えて同じ版に「更新あり」を出し続けない。
    onProgress?.call('verify', 0, -1);
    final problems = PaifuDb.schemaProblemsAt(found.path);
    if (problems.isNotEmpty) {
      await completeZip.delete();
      await extractDir.delete(recursive: true);
      try {
        final rf = await rejectedTagFile();
        if (tag != null) await rf.writeAsString(tag);
      } catch (_) {}
      PaifuUpdateCheck.markUnsupported(tag);
      throw PaifuSchemaUnsupported(tag, problems);
    }

    if (await target.exists()) await target.delete();
    await found.rename(target.path);

    // 後片付け
    await completeZip.delete();
    await extractDir.delete(recursive: true);
    try {
      final rf = await rejectedTagFile();
      if (await rf.exists()) await rf.delete();
    } catch (_) {}

    // タグを保存し、「更新あり」表示を消す
    try {
      final tf = await tagFile();
      if (tag != null) {
        await tf.writeAsString(tag);
      } else if (await tf.exists()) {
        await tf.delete(); // 不明なら古いタグを残さない
      }
    } catch (_) {}
    PaifuUpdateCheck.markUpToDate();
  }
}
