import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/ai.dart';
import 'package:mahjong_taku/engine/game_engine.dart';
import 'package:mahjong_taku/engine/models.dart';

/// 打牌が「ツモ切り(引いた牌をそのまま切る)」か「手出し」かを
/// `DiscardInfo.tsumogiri` に正しく記録しているか。
///
/// 常にツモ切りするエージェントと、常に手出し(手牌の先頭を切る)する
/// エージェントを用意し、河のフラグが実際の打牌と一致することを確かめる。
class _AlwaysTsumogiri extends CpuAgent {
  _AlwaysTsumogiri({super.seed}) : super(thinkMillis: 0);
  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) async {
    // ツモ牌があればそれを切る(=ツモ切り)
    return TurnAction.discard(prompt.drawnTile ?? 0);
  }
}

class _AlwaysTedashi extends CpuAgent {
  _AlwaysTedashi({super.seed}) : super(thinkMillis: 0);
  GameView? _v;
  @override
  void onView(GameView view) {
    _v = view;
    super.onView(view);
  }

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) async {
    final drawn = prompt.drawnTile;
    // ツモ牌以外の手牌を切る(=手出し)
    for (final t in _v?.hand ?? const <int>[]) {
      if (t != drawn) return TurnAction.discard(t);
    }
    return TurnAction.discard(drawn ?? 0);
  }
}

/// ツモ牌と同じ牌が手牌にあるときだけ、その牌を**手牌側から**切る
/// (tsumogiri: false を明示)。それ以外はツモ切り。
class _TedashiOfDuplicate extends CpuAgent {
  _TedashiOfDuplicate({super.seed}) : super(thinkMillis: 0);
  GameView? _v;
  int flaggedTedashi = 0; // 手出しフラグで切った回数

  @override
  void onView(GameView view) {
    _v = view;
    super.onView(view);
  }

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) async {
    final drawn = prompt.drawnTile;
    // view.hand はツモ牌を含まないので、含まれていれば同じ牌の重複がある
    if (drawn != null && (_v?.hand ?? const []).contains(drawn)) {
      flaggedTedashi++;
      return TurnAction.discard(drawn, tsumogiri: false);
    }
    return TurnAction.discard(drawn ?? _v!.hand.first);
  }
}

class _Recorder implements PlayerAgent {
  final List<GameView> views = [];
  @override
  void onView(GameView view) => views.add(view);
  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) async =>
      TurnAction.discard(prompt.drawnTile ?? 0);
  @override
  Future<ReactAction> onReact(ReactPrompt prompt) async =>
      const ReactAction.pass();
  @override
  void onEmote(int seat, int emoji) {}
}

Future<GameView> _finalView(PlayerAgent Function(int) makeCpu, int seed) async {
  final engine = GameEngine(
    config: const GameConfig(rounds: 1),
    names: const ['A', 'B', 'C', 'D'],
    isCpu: const [true, true, true, true],
    advanceDelayMs: 0,
    autoPlayDelayMs: 0,
    seed: seed,
  );
  final rec = _Recorder();
  engine.setAgent(0, rec);
  for (var i = 1; i < 4; i++) {
    engine.setAgent(i, makeCpu(seed * 10 + i));
  }
  await engine.run().timeout(const Duration(seconds: 120));
  // 最後に見たビュー(河が最も進んでいる)
  return rec.views.last;
}

void main() {
  test('全員ツモ切りなら、鳴きの無い河はすべて tsumogiri', () async {
    // 席1-3をツモ切り、席0の Recorder もツモ切り相当
    for (final seed in [1, 2, 3, 5, 7]) {
      final v = await _finalView((s) => _AlwaysTsumogiri(seed: s), seed);
      for (final p in v.players) {
        // 副露が無い席の河はすべてツモ切り
        if (p.melds.isNotEmpty) continue;
        for (final d in p.discards) {
          expect(
            d.tsumogiri,
            isTrue,
            reason: 'seed=$seed ツモ切りのはずが手出し扱い: 牌${d.tile}',
          );
        }
      }
    }
  });

  test('手出しエージェントの打牌は tsumogiri=false になり得る', () async {
    var sawTedashi = false;
    for (final seed in [1, 2, 3, 5, 7, 11, 13]) {
      final v = await _finalView((s) => _AlwaysTedashi(seed: s), seed);
      for (final p in v.players) {
        for (final d in p.discards) {
          if (!d.tsumogiri) sawTedashi = true;
        }
      }
    }
    expect(sawTedashi, isTrue, reason: '手出し(tsumogiri=false)を一度も観測できていない');
  });

  test('ツモ牌と同じ牌を手牌から切ると手出し(tsumogiri=false)になる', () async {
    // フラグ導入前は tile == drawn の値比較しかなく、必ずツモ切り扱いになっていた
    var flagged = 0;
    var sawTedashi = false;
    for (final seed in [1, 2, 3, 5, 7]) {
      final engine = GameEngine(
        config: const GameConfig(rounds: 1),
        names: const ['A', 'B', 'C', 'D'],
        isCpu: const [true, true, true, true],
        advanceDelayMs: 0,
        autoPlayDelayMs: 0,
        seed: seed,
      );
      final rec = _Recorder();
      engine.setAgent(0, rec);
      final cpus = [
        for (var i = 1; i < 4; i++) _TedashiOfDuplicate(seed: seed * 10 + i),
      ];
      for (var i = 1; i < 4; i++) {
        engine.setAgent(i, cpus[i - 1]);
      }
      await engine.run().timeout(const Duration(seconds: 120));
      flagged += cpus.fold(0, (a, c) => a + c.flaggedTedashi);
      // 点数保存 = 手牌枚数が壊れていない(手出し扱いで手牌が増えるバグの検出)
      expect(
        engine.scores.reduce((a, b) => a + b),
        100000,
        reason: 'seed=$seed',
      );
      for (final p in rec.views.last.players) {
        for (final d in p.discards) {
          if (!d.tsumogiri) sawTedashi = true;
        }
      }
    }
    // 重複ツモ→手牌側から切る場面は複数シードで必ず発生する
    expect(flagged, greaterThan(0), reason: 'テストの前提(重複ツモ)が起きていない');
    expect(sawTedashi, isTrue, reason: 'ツモ牌と同じ牌の手出しがツモ切り扱いになっている');
  });
}
