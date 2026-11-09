import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/bench/jev_bench.dart' show riichiKeyPrefix;
import 'package:mahjong_taku/bench/jev_report.dart';

/// Jev ベンチマークの集計(設計文書(非公開) §7)の仕様
void main() {
  Map<String, dynamic> turn({
    required String id,
    required String pro,
    required String cpu,
    required Map<String, dynamic> candidates,
    int shanten = 1,
    bool threat = false,
    int turnNo = 5,
    bool? proRiichi,
    bool? cpuRiichi,
  }) => {
    'id': id,
    'kind': 'turn',
    'game_id': 2,
    'pro': {'discard': pro, 'riichi': ?proRiichi},
    'cpu': {'discard': cpu, 'riichi': ?cpuRiichi},
    'meta': {
      'shanten': shanten,
      'threat': threat,
      'wall': 40,
      'turn': turnNo,
      'can_riichi': proRiichi != null,
      'candidates': candidates,
    },
  };

  Map<String, dynamic> jev(
    String id,
    String choice,
    Map<String, num> probs, {
    double? riichi,
    int latency = 300,
    int tokens = 1000,
  }) => {
    'id': id,
    'answers': {
      'discard': {'type': 'choice', 'choice': choice, 'probabilities': probs},
      if (riichi != null) 'riichi': {'type': 'noul', 'noul': riichi},
    },
    'usage': {'input_tokens': tokens},
    'latency_ms': latency,
  };

  const cands = {
    '1m': {'切った後のシャンテン数': 1, '受け入れ枚数': 20},
    '9s': {'切った後のシャンテン数': 1, '受け入れ枚数': 20},
    '5p': {'切った後のシャンテン数': 2, '受け入れ枚数': 30},
  };

  test('最効率はシャンテン後が最小、同値なら受け入れ枚数が最大の候補', () {
    expect(mostEfficientCandidate(cands), '1m');
    expect(
      mostEfficientCandidate({
        'a': {'切った後のシャンテン数': 1, '受け入れ枚数': 5},
        'b': {'切った後のシャンテン数': 1, '受け入れ枚数': 9},
      }),
      'b',
    );
  });

  test('緩和一致: 特徴量が同値の候補なら一致扱い', () {
    expect(relaxedMatch(cands, '1m', '9s'), isTrue);
    expect(relaxedMatch(cands, '1m', '5p'), isFalse);
    expect(relaxedMatch(cands, '1m', '1m'), isTrue);
  });

  test('打牌の一致率・top-3・較正・層別・リーチ判断を集計する', () {
    final records = [
      turn(
        id: 'a',
        pro: '${riichiKeyPrefix}1m',
        cpu: '1m',
        candidates: cands,
        proRiichi: true,
        cpuRiichi: false,
      ),
      turn(id: 'b', pro: '9s', cpu: '1m', candidates: cands, threat: true),
      turn(
        id: 'c',
        pro: '5p',
        cpu: '5p',
        candidates: cands,
        shanten: 0,
        turnNo: 14,
      ),
      turn(id: 'd', pro: '1m', cpu: '9s', candidates: cands), // 応答なし
    ];
    final jevById = {
      'a': jev('a', '${riichiKeyPrefix}1m', {
        '${riichiKeyPrefix}1m': 0.8,
        '9s': 0.1,
        '5p': 0.1,
      }),
      'b': jev('b', '1m', {'1m': 0.5, '9s': 0.3, '5p': 0.2}),
      'c': jev('c', '1m', {'1m': 0.5, '9s': 0.3, '5p': 0.2}, latency: 900),
    };
    final s = summarize(records, jevById);
    expect(s.missing, 1);
    expect(s.turn.n, 3);
    expect(s.turn.hit, 1); // a のみ
    expect(s.turnTop3.hit, 3); // 候補3つなので全部 top-3
    expect(s.turnRelaxed.hit, 2); // a と、b(9s と 1m は同値)
    expect(s.turnCpu.hit, 1); // c(a は CPU がダマ)
    expect(s.turnEfficient.hit, 1); // 最効率 1m はプロの a のみ
    expect(s.byThreat['リーチ者あり']!.$1.n, 1);
    expect(s.byShanten['0(テンパイ)']!.$2.hit, 1);
    expect(s.byTurn['終盤(13巡〜)']!.$1.n, 1);
    expect(s.riichiJev.tt, 1); // プロする×判定する
    expect(s.riichiCpu.tf, 1); // プロする×CPUしない
    // 較正: 0.8 の区間に1件(当たり)、0.5 の区間に2件(外れ)
    expect(s.calibN[8], 1);
    expect(s.calibHit[8], 1);
    expect(s.calibN[5], 2);
    expect(s.calibHit[5], 0);
    expect(s.ece, closeTo(1 / 3 * 0.2 + 2 / 3 * 0.5, 1e-9));
    expect(s.latencyMedian, 300);
    expect(s.inputTokens, 3000);
    expect(s.costUsd, closeTo(3000 / 1e6 * jevUsdPerMillionInputTokens, 1e-12));
    final md = renderMarkdown(s);
    expect(
      md,
      contains('| 打牌 top-1 一致率 | 33.3% (1/3) | 33.3% (1/3) | 33.3% (1/3) |'),
    );
  });

  test('鳴きの一致と「鳴く/見送る」の2×2', () {
    final records = [
      {
        'id': 'r1',
        'kind': 'react',
        'game_id': 2,
        'pro': {'call': 'pon'},
        'cpu': {'call': 'pass'},
        'meta': {'shanten': 1, 'threat': false, 'wall': 30, 'turn': 3},
      },
      {
        'id': 'r2',
        'kind': 'react',
        'game_id': 2,
        'pro': {'call': 'pass'},
        'cpu': {'call': 'pass'},
        'meta': {'shanten': 1, 'threat': false, 'wall': 30, 'turn': 3},
      },
    ];
    final jevById = {
      'r1': {
        'id': 'r1',
        'answers': {
          'call': {'type': 'choice', 'choice': 'chi_4m5m', 'probabilities': {}},
        },
        'usage': {'input_tokens': 10},
        'latency_ms': 100,
      },
      'r2': {
        'id': 'r2',
        'answers': {
          'call': {'type': 'choice', 'choice': 'pass', 'probabilities': {}},
        },
        'usage': {'input_tokens': 10},
        'latency_ms': 100,
      },
    };
    final s = summarize(records, jevById);
    expect(s.react.hit, 1); // r2
    expect(s.reactCpu.hit, 1); // r2
    expect(s.reactCallJev.tt, 1); // r1: プロ鳴く×Jev鳴く(形は違う)
    expect(s.reactCallCpu.tf, 1); // r1: プロ鳴く×CPU見送り
  });
}
