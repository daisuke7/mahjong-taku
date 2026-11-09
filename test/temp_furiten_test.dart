import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/tile.dart';

/// 常に見逃し(ロンせず)、鳴けるときは必ず鳴くCPU。
///
/// 検証したいのは「同巡内フリテン中に鳴いて打牌したとき、フリテンが解消
/// されるか」。この状況を実戦で踏むには
///   1. 聴牌していてロンを見逃す(→ 同巡内フリテン)
///   2. 自分のツモ番が来る前に鳴いて打牌する
/// の両方が必要。通常の [CpuAgent] は `canRon` なら必ずロンするため 1 に
/// 到達せず、鳴きも消極的なので 2 にも到達しない。そこで両方を強制する。
class _NeverRonCpu extends CpuAgent {
  _NeverRonCpu({super.seed}) : super(thinkMillis: 0);

  /// 自分の打牌直後のビューで (フリテンか, 捨て牌で説明できるか) を記録
  final List<(bool, bool)> afterMyDiscard = [];

  /// 同巡内フリテンを実際に観測できたか(テストの母数確認用)
  bool sawTempFuriten = false;

  int _seenDiscards = 0;
  String _hand = '';

  @override
  Future<ReactAction> onReact(ReactPrompt prompt) async {
    if (prompt.canRon) return const ReactAction.pass(); // 見逃し → 同巡内フリテン
    // 鳴けるなら必ず鳴く(ツモ番を経ずに打牌する場面を作るため)
    if (prompt.canPon) return const ReactAction.pon();
    if (prompt.chiOptions.isNotEmpty) {
      return ReactAction.chi(prompt.chiOptions.first);
    }
    return const ReactAction.pass();
  }

  @override
  void onView(GameView view) {
    super.onView(view);
    if (view.phase != 'playing') return;

    final me = view.players[view.youSeat];
    // 自分の捨て牌に待ちがあるか(=見せ牌フリテン。これは永続なので別扱い)
    final discardFuriten = me.discards
        .map((d) => Tile.normalize(d.tile))
        .toSet()
        .any(view.myWaits.contains);

    if (view.myFuriten && !me.riichi && !discardFuriten) {
      sawTempFuriten = true; // 見せ牌でも立直でもない = 同巡内フリテン
    }

    // 局が変わったら捨て牌カウントをリセット
    final key = '${view.roundWind}-${view.kyoku}-${view.honba}';
    if (key != _hand) {
      _hand = key;
      _seenDiscards = 0;
    }

    // 自分の打牌直後(捨て牌が増えた最初のビュー)を捕まえる
    if (me.discards.length > _seenDiscards) {
      _seenDiscards = me.discards.length;
      if (!me.riichi) {
        afterMyDiscard.add((view.myFuriten, discardFuriten));
      }
    }
  }
}

Future<List<_NeverRonCpu>> _play(int seed) async {
  final engine = GameEngine(
    config: const GameConfig(rounds: 2),
    names: const ['A', 'B', 'C', 'D'],
    isCpu: const [true, true, true, true],
    advanceDelayMs: 0,
    autoPlayDelayMs: 0,
    seed: seed,
  );
  final cpus = List.generate(4, (i) => _NeverRonCpu(seed: seed * 10 + i));
  for (var i = 0; i < 4; i++) {
    engine.setAgent(i, cpus[i]);
  }
  await engine.run().timeout(const Duration(seconds: 120));
  return cpus;
}

void main() {
  // Mリーグ:「同巡内フリテンは自己の摸打の完了を経て解消される。」
  test('同巡内フリテンは自分の打牌で解消される(鳴いた後の打牌も含む)', () async {
    var setupOk = false;
    var checked = 0;

    for (final seed in [1, 2, 3, 5, 7, 11, 13, 42, 99, 123, 456, 777]) {
      for (final cpu in await _play(seed)) {
        if (cpu.sawTempFuriten) setupOk = true;

        for (final (furiten, discardFuriten) in cpu.afterMyDiscard) {
          // 打牌が完了した時点で同巡内フリテンは解消されているはず。
          // よって残るフリテンは「自分の捨て牌によるもの」だけ。
          expect(
            furiten,
            discardFuriten,
            reason:
                'seed=$seed 自分の打牌後もフリテンが残っている '
                '(同巡内フリテンが解消されていない)',
          );
          checked++;
        }
      }
    }

    expect(setupOk, isTrue, reason: '同巡内フリテンを一度も観測できず、検証になっていない');
    expect(checked, greaterThan(0));
  });
}
