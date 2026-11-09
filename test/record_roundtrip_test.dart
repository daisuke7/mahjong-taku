import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/paifu/my_paifu_source.dart';
import 'package:mahjong_taku/paifu/replay_session.dart';
import 'package:mahjong_taku/record/rec_paifu_store.dart';
import 'package:mahjong_taku/record/record_engine.dart';

import 'hand_test.dart' show tiles;

int t(String s) => tiles(s)[0];

/// 手動牌譜記録のラウンドトリップ:
/// RecordEngine で記録 → RecPaifuStore(JSON) → MyPaifuSource →
/// ReplaySession が完走再生できることを検証する。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rec_paifu_test');
    RecPaifuStore.dirOverride = tmp;
  });

  tearDown(() {
    RecPaifuStore.dirOverride = null;
    tmp.deleteSync(recursive: true);
  });

  test('記録した2局(リーチロン・鳴き流局)をビューアで完走再生できる', () async {
    final eng = RecordEngine(names: ['佐々木', '高宮', '松本', '伊達']);

    // 東1局: 席1が1巡目リーチ → 席2から一発ロン(裏1)
    eng.tapDora(t('1z'));
    eng.draw(t('1m'));
    eng.discard(t('1m'), tsumogiri: true);
    eng.draw(t('9p'));
    eng.discard(t('9p'), riichi: true, tsumogiri: true);
    eng.draw(t('7z'));
    eng.discard(t('7z'), tsumogiri: true);
    eng.ronWin(
      winner: 1,
      hand13: tiles('234m567m345p66s77z'),
      ura: tiles('2p'),
    );
    eng.nextKyoku();
    expect(eng.roundLabel, '東2局');

    // 東2局: 鳴き(ポン・チー)と不明ツモを含む流局
    eng.tapDora(t('5p'));
    eng.draw(null); // 不明ツモ
    eng.discard(t('3p')); // 手出し
    eng.pon(3);
    eng.discard(t('8s'));
    eng.chi(tiles('67s')); // 席0がチー
    eng.discard(t('1z'));
    eng.ryukyoku([1], revealedHands: {1: tiles('234m567m345p66s77z')});
    eng.nextKyoku();

    // 保存(記録だけ終了 = 順位なし)→ 読み出し
    final id = RecPaifuStore.newId();
    expect(
      await RecPaifuStore.save(id, eng.buildGameJson(settle: false)),
      isTrue,
    );
    final games = await RecPaifuStore.listGames();
    expect(games.single.id, id);
    expect(games.single.kyokuCount, 2);
    expect(games.single.finished, isFalse);
    expect(games.single.names, ['佐々木', '高宮', '松本', '伊達']);

    final raw = await RecPaifuStore.loadGame(id);
    final source = MyPaifuSource(raw!);
    final kyokus = source.kyokus(MyPaifuSource.soloGameId);
    expect(kyokus, hasLength(2));
    expect(kyokus[0].round, '1z1');
    expect(kyokus[1].round, '1z2');

    // ReplaySession で最後まで再生できる(欠損牌譜への耐性込み)
    final session = ReplaySession(
      db: source,
      gameId: MyPaifuSource.soloGameId,
      youSeat: 1,
      matchLabel: '記録した牌譜',
      mLeagueGameId: id,
      speed: 0,
    );
    final views = <GameView>[];
    final sub = session.views.listen(views.add);
    unawaited(session.run());
    await _waitUntil(() => session.latestView?.phase == 'gameEnd');
    expect(views.where((v) => v.phase == 'handEnd').length, 2);
    // 席1: 東1局 リーチ-1000+満貫8000+リーチ棒1000、東2局 テンパイ料+3000
    final end = session.latestView!;
    expect(end.scores[1], 25000 - 1000 + 9000 + 3000);
    await sub.cancel();
    await session.dispose();
  });
}

Future<void> _waitUntil(bool Function() cond) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('条件が満たされない');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
