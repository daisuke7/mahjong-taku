import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/paifu/paifu_store.dart';

/// 牌譜DBダウンロードの再試行(2026-11-09: GitHub から 504 が1回返った件)。
/// 方針: 3回試行(2回リトライ)、全部駄目ならエラー表示してその回は諦める。
void main() {
  late Directory tmp;
  late File dest;
  final uri = Uri.parse('https://example.invalid/database.zip');
  Future<void> noWait(Duration _) async {}

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('paifu_retry_');
    dest = File('${tmp.path}/database.zip.part');
  });
  tearDown(() => tmp.delete(recursive: true));

  PaifuHttpResponse ok(List<int> bytes) =>
      (statusCode: 200, contentLength: bytes.length, body: Stream.value(bytes));
  PaifuHttpResponse status(int code) =>
      (statusCode: code, contentLength: -1, body: const Stream.empty());

  test('1回目 504、2回目 200 なら成功し、再試行の進捗を1回通知する', () async {
    var calls = 0;
    final stages = <String>[];
    await PaifuStore.downloadWithRetry(
      uri,
      dest,
      fetch: (_) async => ++calls == 1 ? status(504) : ok([1, 2, 3]),
      onProgress: (stage, r, t) => stages.add('$stage:$r/$t'),
      wait: noWait,
    );
    expect(calls, 2);
    expect(await dest.readAsBytes(), [1, 2, 3]);
    expect(stages, ['retry:2/3', 'download:3/3']);
  });

  test('3回とも 5xx なら PaifuDownloadFailed(試行回数3)で諦める', () async {
    var calls = 0;
    final waits = <Duration>[];
    await expectLater(
      PaifuStore.downloadWithRetry(
        uri,
        dest,
        fetch: (_) async {
          calls++;
          return status(calls == 2 ? 502 : 504);
        },
        wait: (d) async => waits.add(d),
      ),
      throwsA(
        isA<PaifuDownloadFailed>()
            .having((e) => e.attempts, 'attempts', 3)
            .having((e) => e.message, 'message', contains('HTTP 504'))
            .having((e) => e.message, 'message', contains('3回')),
      ),
    );
    expect(calls, 3);
    // 待ち時間は 2秒・4秒(最後の失敗後は待たない)
    expect(waits, PaifuStore.retryDelays);
  });

  test('接続失敗(SocketException)と途中切断も再試行の対象', () async {
    var calls = 0;
    await PaifuStore.downloadWithRetry(
      uri,
      dest,
      fetch: (_) async {
        calls++;
        if (calls == 1) throw const SocketException('connection refused');
        if (calls == 2) {
          return (
            statusCode: 200,
            contentLength: 6,
            body: Stream<List<int>>.fromFutures([
              Future.value([1, 2, 3]),
              Future.error(const SocketException('reset')),
            ]),
          );
        }
        return ok([4, 5, 6]);
      },
      wait: noWait,
    );
    expect(calls, 3);
    // 途中まで書いた分は次の試行で上書きされる
    expect(await dest.readAsBytes(), [4, 5, 6]);
  });

  test('404 など 4xx は再試行せず即座に失敗する', () async {
    var calls = 0;
    await expectLater(
      PaifuStore.downloadWithRetry(
        uri,
        dest,
        fetch: (_) async {
          calls++;
          return status(404);
        },
        wait: noWait,
      ),
      throwsA(
        isA<Exception>()
            .having((e) => e.toString(), 'msg', contains('HTTP 404'))
            .having(
              (e) => e is PaifuDownloadFailed,
              'not retry-failure',
              false,
            ),
      ),
    );
    expect(calls, 1);
  });

  test('既定値: 3回試行・待ちは2秒と4秒', () {
    expect(PaifuStore.maxAttempts, 3);
    expect(PaifuStore.retryDelays, [
      const Duration(seconds: 2),
      const Duration(seconds: 4),
    ]);
  });
}
