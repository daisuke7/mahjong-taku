import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/paifu/paifu_update_check.dart';

void main() {
  setUp(PaifuUpdateCheck.resetForTest);

  test('リダイレクト先URLからリリースタグを取り出す', () {
    expect(
      releaseTagFromLocation(
        'https://github.com/konoui/m-league-game-db/releases/download/20260915-2050-1e8b74ea/database.zip',
      ),
      '20260915-2050-1e8b74ea',
    );
    expect(releaseTagFromLocation(null), isNull);
    expect(releaseTagFromLocation('https://github.com/'), isNull);
    expect(
      releaseTagFromLocation('https://x/releases/download/tag-1/a.zip?x=1'),
      'tag-1',
    );
  });

  test('DBが無ければ確認しない', () async {
    var calls = 0;
    await PaifuUpdateCheck.runOnce(
      hasDb: () async => false,
      savedTag: () async => 'a',
      fetchLatestTag: () async {
        calls++;
        return 'b';
      },
    );
    expect(calls, 0);
    expect(PaifuUpdateCheck.updateAvailable.value, isFalse);
  });

  test('保存タグと最新タグが違えば「更新あり」、同じなら出さない', () async {
    await PaifuUpdateCheck.runOnce(
      hasDb: () async => true,
      savedTag: () async => '20260914-2123-33191c39',
      fetchLatestTag: () async => '20260915-2050-1e8b74ea',
    );
    expect(PaifuUpdateCheck.updateAvailable.value, isTrue);

    PaifuUpdateCheck.resetForTest();
    await PaifuUpdateCheck.runOnce(
      hasDb: () async => true,
      savedTag: () async => '20260915-2050-1e8b74ea',
      fetchLatestTag: () async => '20260915-2050-1e8b74ea',
    );
    expect(PaifuUpdateCheck.updateAvailable.value, isFalse);
  });

  test('オフライン(タグが取れない)・タグ未保存なら表示しない', () async {
    await PaifuUpdateCheck.runOnce(
      hasDb: () async => true,
      savedTag: () async => 'a',
      fetchLatestTag: () async => null,
    );
    expect(PaifuUpdateCheck.updateAvailable.value, isFalse);

    PaifuUpdateCheck.resetForTest();
    var calls = 0;
    await PaifuUpdateCheck.runOnce(
      hasDb: () async => true,
      savedTag: () async => null,
      fetchLatestTag: () async {
        calls++;
        return 'b';
      },
    );
    expect(calls, 0, reason: '比較できないので問い合わせもしない');
    expect(PaifuUpdateCheck.updateAvailable.value, isFalse);
  });

  test('確認は1回だけ(2回目以降は問い合わせない)', () async {
    var calls = 0;
    Future<String?> fetch() async {
      calls++;
      return 'b';
    }

    await PaifuUpdateCheck.runOnce(
      hasDb: () async => true,
      savedTag: () async => 'a',
      fetchLatestTag: fetch,
    );
    await PaifuUpdateCheck.runOnce(
      hasDb: () async => true,
      savedTag: () async => 'a',
      fetchLatestTag: fetch,
    );
    expect(calls, 1);
    expect(PaifuUpdateCheck.updateAvailable.value, isTrue);
    PaifuUpdateCheck.markUpToDate();
    expect(PaifuUpdateCheck.updateAvailable.value, isFalse);
  });

  test('取り込みを拒否した版が最新のままなら「更新あり」ではなく「未対応」を出す', () async {
    await PaifuUpdateCheck.runOnce(
      hasDb: () async => true,
      savedTag: () async => '20260917-2056-e87c68c5',
      fetchLatestTag: () async => '20261001-2219-d157d710',
      rejectedTag: () async => '20261001-2219-d157d710',
    );
    expect(PaifuUpdateCheck.updateAvailable.value, isFalse);
    expect(PaifuUpdateCheck.unsupportedTag.value, '20261001-2219-d157d710');
    // さらに新しい版が出たら(拒否した版と違う)通常の「更新あり」に戻る
    PaifuUpdateCheck.resetForTest();
    await PaifuUpdateCheck.runOnce(
      hasDb: () async => true,
      savedTag: () async => '20260917-2056-e87c68c5',
      fetchLatestTag: () async => '20261003-0600-ffffffff',
      rejectedTag: () async => '20261001-2219-d157d710',
    );
    expect(PaifuUpdateCheck.updateAvailable.value, isTrue);
    expect(PaifuUpdateCheck.unsupportedTag.value, isNull);
  });

  test('例外が出ても表示しない側に倒す', () async {
    await PaifuUpdateCheck.runOnce(hasDb: () async => throw StateError('x'));
    expect(PaifuUpdateCheck.updateAvailable.value, isFalse);
  });
}
