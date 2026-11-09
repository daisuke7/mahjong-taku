/// Jev ベンチマークの集計(設計文書(非公開) §7)。
/// 入力はレコード(jev_bench.dart の出力)と、id ごとの Jev 応答。
library;

import 'dart:math';

import 'jev_bench.dart' show riichiKeyPrefix;

/// 単価(USD / 100万入力トークン)。docs.typesafe.ai/models(2026-09-19)
const jevUsdPerMillionInputTokens = 0.042;

class Tally {
  int n = 0;
  int hit = 0;
  double get rate => n == 0 ? 0 : hit / n;
  void add(bool ok) {
    n++;
    if (ok) hit++;
  }

  String get label =>
      n == 0 ? '-' : '${(rate * 100).toStringAsFixed(1)}% ($hit/$n)';
}

/// 2×2 表(プロが「する」か × 判定が「する」か)
class Confusion {
  int tt = 0, tf = 0, ft = 0, ff = 0;
  void add({required bool actual, required bool predicted}) {
    if (actual && predicted) {
      tt++;
    } else if (actual) {
      tf++;
    } else if (predicted) {
      ft++;
    } else {
      ff++;
    }
  }

  int get n => tt + tf + ft + ff;
  double get accuracy => n == 0 ? 0 : (tt + ff) / n;
}

/// 最効率(ベースライン下限): シャンテン後が最小、同値なら受け入れ枚数が最大の候補
String? mostEfficientCandidate(Map<String, dynamic> candidates) {
  String? best;
  int? bestShanten;
  int bestUkeire = -1;
  for (final e in candidates.entries) {
    final f = e.value as Map;
    final s = f['切った後のシャンテン数'] as int;
    final u = f['受け入れ枚数'] as int;
    if (bestShanten == null ||
        s < bestShanten ||
        (s == bestShanten && u > bestUkeire)) {
      best = e.key;
      bestShanten = s;
      bestUkeire = u;
    }
  }
  return best;
}

/// 選択肢キーから打牌(リーチ接頭辞を除いた牌)を取り出す
String tileOfKey(String key) => key.startsWith(riichiKeyPrefix)
    ? key.substring(riichiKeyPrefix.length)
    : key;

bool isRiichiKey(String key) => key.startsWith(riichiKeyPrefix);

/// 緩和一致: 選んだ候補の特徴量(シャンテン後・受け入れ枚数・安全度)がプロの候補と同じ
/// (リーチ有無は一致していること)
bool relaxedMatch(Map<String, dynamic> candidates, String pro, String chosen) {
  if (pro == chosen) return true;
  if (isRiichiKey(pro) != isRiichiKey(chosen)) return false;
  final a = candidates[tileOfKey(pro)] as Map?;
  final b = candidates[tileOfKey(chosen)] as Map?;
  if (a == null || b == null) return false;
  const keys = ['切った後のシャンテン数', '受け入れ枚数', 'リーチ者への安全度(100=現物)'];
  for (final k in keys) {
    if ('${a[k]}' != '${b[k]}') return false;
  }
  return true;
}

String shantenBucket(int s) => s <= 0
    ? '0(テンパイ)'
    : s == 1
    ? '1'
    : s == 2
    ? '2'
    : '3+';
String turnBucket(int t) => t <= 6
    ? '序盤(〜6巡)'
    : t <= 12
    ? '中盤(7〜12巡)'
    : '終盤(13巡〜)';

class BenchSummary {
  final turn = Tally(); // Jev top-1
  final turnTop3 = Tally();
  final turnRelaxed = Tally();
  final turnCpu = Tally();
  final turnEfficient = Tally();
  final byShanten = <String, (Tally, Tally)>{}; // (jev, cpu)
  final byThreat = <String, (Tally, Tally)>{};
  final byTurn = <String, (Tally, Tally)>{};
  final riichiJev = Confusion();
  final riichiCpu = Confusion();
  final react = Tally();
  final reactCpu = Tally();
  final reactCallJev = Confusion(); // 鳴く/見送る
  final reactCallCpu = Confusion();
  final calibHit = List<int>.filled(10, 0);
  final calibN = List<int>.filled(10, 0);
  final calibConf = List<double>.filled(10, 0);
  final latencies = <int>[];
  int inputTokens = 0;
  int errors = 0;
  int missing = 0;

  double get ece {
    final total = calibN.fold(0, (a, b) => a + b);
    if (total == 0) return 0;
    var e = 0.0;
    for (var i = 0; i < 10; i++) {
      if (calibN[i] == 0) continue;
      final acc = calibHit[i] / calibN[i];
      final conf = calibConf[i] / calibN[i];
      e += calibN[i] / total * (acc - conf).abs();
    }
    return e;
  }

  int _percentile(double p) {
    if (latencies.isEmpty) return 0;
    final s = [...latencies]..sort();
    return s[min(s.length - 1, (s.length * p).floor())];
  }

  int get latencyMedian => _percentile(0.5);
  int get latencyP95 => _percentile(0.95);
  double get costUsd => inputTokens / 1e6 * jevUsdPerMillionInputTokens;
}

(Tally, Tally) _pair(Map<String, (Tally, Tally)> m, String k) =>
    m.putIfAbsent(k, () => (Tally(), Tally()));

/// 集計本体。[jevById] は id → {'answers': …, 'usage': …, 'latency_ms': …} または
/// {'error': …}。Jev 応答の無いレコードは missing に数え、CPU/最効率の集計にも入れない
/// (同じ局面集合で比較するため)。
BenchSummary summarize(
  Iterable<Map<String, dynamic>> records,
  Map<String, Map<String, dynamic>> jevById,
) {
  final s = BenchSummary();
  for (final r in records) {
    final j = jevById[r['id'] as String];
    if (j == null) {
      s.missing++;
      continue;
    }
    if (j['error'] != null) {
      s.errors++;
      continue;
    }
    final answers = (j['answers'] as Map).cast<String, dynamic>();
    s.latencies.add(j['latency_ms'] as int);
    s.inputTokens += (j['usage']?['input_tokens'] as int?) ?? 0;
    final pro = (r['pro'] as Map).cast<String, dynamic>();
    final cpu = (r['cpu'] as Map).cast<String, dynamic>();
    final meta = (r['meta'] as Map).cast<String, dynamic>();
    if (r['kind'] == 'turn') {
      final ans = (answers['discard'] as Map).cast<String, dynamic>();
      final chosen = ans['choice'] as String;
      final probs = (ans['probabilities'] as Map).cast<String, num>();
      final proKey = pro['discard'] as String;
      final candidates = (meta['candidates'] as Map).cast<String, dynamic>();
      final hit = chosen == proKey;
      s.turn.add(hit);
      final ranked = probs.keys.toList()
        ..sort((a, b) => probs[b]!.compareTo(probs[a]!));
      s.turnTop3.add(ranked.take(3).contains(proKey));
      s.turnRelaxed.add(relaxedMatch(candidates, proKey, chosen));
      final cpuHit = cpu['discard'] == proKey;
      s.turnCpu.add(cpuHit);
      // 最効率はリーチ有無を判断しない: プロと同じリーチ有無を付けて比較する
      final eff = mostEfficientCandidate(candidates);
      s.turnEfficient.add(
        eff != null &&
            (isRiichiKey(proKey) ? '$riichiKeyPrefix$eff' : eff) == proKey,
      );
      final conf = (probs[chosen] ?? 0).toDouble();
      final bin = min(9, (conf * 10).floor());
      s.calibN[bin]++;
      s.calibConf[bin] += conf;
      if (hit) s.calibHit[bin]++;
      for (final (key, m) in [
        (shantenBucket(meta['shanten'] as int), s.byShanten),
        ((meta['threat'] as bool) ? 'リーチ者あり' : 'リーチ者なし', s.byThreat),
        (turnBucket(meta['turn'] as int), s.byTurn),
      ]) {
        final (jt, ct) = _pair(m, key);
        jt.add(hit);
        ct.add(cpuHit);
      }
      if (meta['can_riichi'] == true) {
        final actual = pro['riichi'] as bool;
        s.riichiJev.add(actual: actual, predicted: isRiichiKey(chosen));
        s.riichiCpu.add(actual: actual, predicted: cpu['riichi'] as bool);
      }
    } else {
      final ans = (answers['call'] as Map).cast<String, dynamic>();
      final chosen = ans['choice'] as String;
      final proCall = pro['call'] as String;
      s.react.add(chosen == proCall);
      s.reactCpu.add(cpu['call'] == proCall);
      s.reactCallJev.add(
        actual: proCall != 'pass',
        predicted: chosen != 'pass',
      );
      s.reactCallCpu.add(
        actual: proCall != 'pass',
        predicted: cpu['call'] != 'pass',
      );
    }
  }
  return s;
}

String _conf(Confusion c) =>
    '一致 ${(c.accuracy * 100).toStringAsFixed(1)}% (n=${c.n}) / '
    'プロする×判定する ${c.tt}・プロする×判定しない ${c.tf}・'
    'プロしない×判定する ${c.ft}・プロしない×判定しない ${c.ff}';

String renderMarkdown(BenchSummary s) {
  final b = StringBuffer();
  b.writeln('| 指標 | Jev | CpuAgent | 最効率 |');
  b.writeln('|---|---|---|---|');
  b.writeln(
    '| 打牌 top-1 一致率 | ${s.turn.label} | ${s.turnCpu.label} | ${s.turnEfficient.label} |',
  );
  b.writeln('| 打牌 top-3 一致率 | ${s.turnTop3.label} | - | - |');
  b.writeln('| 打牌 緩和一致率 | ${s.turnRelaxed.label} | - | - |');
  b.writeln('| 鳴き 一致率 | ${s.react.label} | ${s.reactCpu.label} | - |');
  b.writeln();
  b.writeln('較正: ECE = ${s.ece.toStringAsFixed(3)}');
  b.writeln();
  b.writeln('| 確率区間 | 件数 | 平均確率 | 実一致率 |');
  b.writeln('|---|---|---|---|');
  for (var i = 0; i < 10; i++) {
    if (s.calibN[i] == 0) continue;
    b.writeln(
      '| ${(i / 10).toStringAsFixed(1)}〜${((i + 1) / 10).toStringAsFixed(1)} | ${s.calibN[i]} | '
      '${(s.calibConf[i] / s.calibN[i]).toStringAsFixed(2)} | '
      '${(s.calibHit[i] / s.calibN[i] * 100).toStringAsFixed(1)}% |',
    );
  }
  b.writeln();
  void strata(String title, Map<String, (Tally, Tally)> m) {
    b.writeln('| $title | Jev | CpuAgent |');
    b.writeln('|---|---|---|');
    final keys = m.keys.toList()..sort();
    for (final k in keys) {
      final (j, c) = m[k]!;
      b.writeln('| $k | ${j.label} | ${c.label} |');
    }
    b.writeln();
  }

  strata('シャンテン数', s.byShanten);
  strata('他家リーチ', s.byThreat);
  strata('巡目', s.byTurn);
  b.writeln('リーチ判断(Jev の選択がリーチ宣言か): ${_conf(s.riichiJev)}');
  b.writeln();
  b.writeln('リーチ判断(CpuAgent): ${_conf(s.riichiCpu)}');
  b.writeln();
  b.writeln('鳴く/見送る(Jev): ${_conf(s.reactCallJev)}');
  b.writeln();
  b.writeln('鳴く/見送る(CpuAgent): ${_conf(s.reactCallCpu)}');
  b.writeln();
  b.writeln(
    '遅延: 中央値 ${s.latencyMedian}ms / p95 ${s.latencyP95}ms、'
    '入力トークン ${s.inputTokens}(約 \$${s.costUsd.toStringAsFixed(2)})、'
    'エラー ${s.errors}、応答なし ${s.missing}',
  );
  return b.toString();
}
