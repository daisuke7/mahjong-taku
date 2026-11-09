import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/hand.dart';
import 'package:mahjong_taku/engine/meld.dart';
import 'package:mahjong_taku/engine/models.dart';

/// TurnPrompt と局結果を記録するCPU。
///
/// 牌山を外から差し替える手段が無いため、狙った牌姿をピンポイントで作れない。
/// そこで多数のシードで実際に打たせ、**ルール上あってはならない状態が一度も
/// 出現しないこと**(不変条件)を検証する。
class _RecordingCpu extends CpuAgent {
  _RecordingCpu({super.seed}) : super(thinkMillis: 0);

  GameView? _view;

  /// (山の残り枚数, リーチ可能だったか) の記録
  final List<(int, bool)> riichiOffers = [];

  /// 流局時の (テンパイ席, 手の内, 副露) の記録
  final List<(List<int>, List<int>, List<Meld>)> ryuukyokuTenpai = [];

  @override
  void onView(GameView view) {
    _view = view;
    final r = view.handResult;
    if (view.phase == 'handEnd' && r != null && r.type == 'draw') {
      for (final seat in r.tenpaiSeats) {
        final revealed = r.revealedHands[seat];
        if (revealed != null) {
          ryuukyokuTenpai.add((
            r.tenpaiSeats,
            revealed,
            view.players[seat].melds,
          ));
        }
      }
    }
    super.onView(view);
  }

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) {
    final v = _view;
    if (v != null) {
      riichiOffers.add((v.wallRemaining, prompt.riichiTiles.isNotEmpty));
    }
    return super.onTurn(prompt);
  }
}

Future<List<_RecordingCpu>> _play(int seed) async {
  final engine = GameEngine(
    config: const GameConfig(rounds: 2),
    names: const ['A', 'B', 'C', 'D'],
    isCpu: const [true, true, true, true],
    advanceDelayMs: 0,
    autoPlayDelayMs: 0,
    seed: seed,
  );
  final cpus = List.generate(4, (i) => _RecordingCpu(seed: seed * 10 + i));
  for (var i = 0; i < 4; i++) {
    engine.setAgent(i, cpus[i]);
  }
  await engine.run().timeout(const Duration(seconds: 120));
  return cpus;
}

void main() {
  test('リーチの可否が山の残り枚数ルールに従う(海底のみ不可)', () async {
    var sawRiichiNearWallEnd = false;

    // 2, 9 はCPU改良(押し引き拡張+タイブレーク)後の牌譜で
    // 「山残り4枚未満のリーチ提示」が実際に出るシード
    for (final seed in [1, 2, 3, 7, 9, 11, 42, 99, 123, 777]) {
      for (final cpu in await _play(seed)) {
        for (final (wallRemaining, offered) in cpu.riichiOffers) {
          // Mリーグ:「海底牌を摸した者はリーチを掛ける事はできない。」
          if (wallRemaining == 0) {
            expect(
              offered,
              isFalse,
              reason: 'seed=$seed 海底牌を摸した者にリーチを提示してはいけない',
            );
          }
          // Mリーグ:「ツモ番のないリーチもかける事ができる。」
          // → 山が1〜3枚でもリーチが提示されうる(修正前は4枚未満で一律不可だった)
          if (offered && wallRemaining < 4) sawRiichiNearWallEnd = true;
        }
      }
    }

    // 「ツモ番のないリーチ」が実際に提示されたことを確認する。
    // ここが false なら、修正が効いていないか、サンプルが足りていない。
    expect(sawRiichiNearWallEnd, isTrue, reason: '山残り4枚未満でのリーチ提示が一度も観測されなかった');
  });

  test('流局時のテンパイ判定にアガリ牌を自分で使い切った形が含まれない', () async {
    var checked = 0;

    for (final seed in [1, 3, 7, 11, 42, 99, 123, 777]) {
      for (final cpu in await _play(seed)) {
        for (final (seats, revealed, melds) in cpu.ryuukyokuTenpai) {
          // Mリーグ:「聴牌とはアガリが可能となった状態だが、自己の手牌・副露牌で
          // アガリ牌が消去されている場合は認められない。」
          final live = calcLiveWaits(
            toCounts(revealed),
            toCounts([for (final m in melds) ...m.tiles]),
            meldCount: melds.length,
          );
          expect(
            live,
            isNotEmpty,
            reason:
                'seed=$seed テンパイ料を受け取った席 $seats の手が '
                'アガリ得ない形(自分で待ちを4枚使い切っている)',
          );
          checked++;
        }
      }
    }

    // 流局自体が一度も起きないと検証にならないので、母数を確認しておく
    expect(checked, greaterThan(0), reason: '流局時のテンパイを一度も観測できなかった');
  });
}
