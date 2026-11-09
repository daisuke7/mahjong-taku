// ignore_for_file: avoid_print
// Jev ベンチマーク CLI(設計文書(非公開) §10)。
//
//   extract <database.sqlite3> <records.jsonl> [--games N] [--seed S] [--season YEAR]
//       牌譜DBから試合をランダムに選び、局面レコードを JSONL に書く(Jev 不要)。
//   query <records.jsonl> <jev.jsonl> [--limit N] [--kind turn|react|all]
//         [--group tune|judge|all] [--concurrency C] [--examples K] [--seed S]
//         [--prompt v1|v2]  (v1=控えめな指示文+受け入れ順位なし、v2=記録どおり)
//         [--threat true]   (他家リーチあり局面だけ)
//       レコードの request を Jev に送り、応答を JSONL に追記する(再開可能)。
//       API キーは環境変数 TYPESAFE_API_KEY_MA(無ければ TYPESAFE_API_KEY)。
//   report <records.jsonl> <jev.jsonl>
//       集計を Markdown で出力する。
//   cpu-report <records.jsonl>
//       Jev 無しで CpuAgent とプロの一致率だけを出す(押し引き方針の校正用)。
//   extract の追加オプション --push-one V --push-two W --push-safe S --push-deep-safe D で
//   CpuAgent の PushPolicy を、--dama-waits N --dama-wall W --dama-lead L --dama-points P で
//   RiichiPolicy を、--attack-loss N で AttackPolicy を、--call legacy / --call-yakuhai-gain G
//   --call-yakuhai-after A --call-yakuhai-value V --call-open-after O --call-threat-after T で
//   CallPolicy を変えて抽出できる(既定は現行の方針)。
//
// 群分け: game_id の偶奇で tune(調整用)/judge(判定用)に分ける。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mahjong_taku/bench/jev_bench.dart';
import 'package:mahjong_taku/bench/jev_client.dart';
import 'package:mahjong_taku/bench/jev_report.dart';
import 'package:mahjong_taku/engine/ai.dart'
    show AttackPolicy, CallPolicy, PushPolicy, RiichiPolicy;
import 'package:mahjong_taku/paifu/paifu_db.dart';
import 'package:sqlite3/sqlite3.dart';

Map<String, String> _opts(List<String> args) {
  final m = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      m[args[i].substring(2)] = i + 1 < args.length ? args[i + 1] : '';
      i++;
    }
  }
  return m;
}

List<String> _positional(List<String> args) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      i++;
    } else {
      out.add(args[i]);
    }
  }
  return out;
}

String groupOf(int gameId) => gameId.isEven ? 'tune' : 'judge';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: extract | query | report (ファイル先頭のコメント参照)');
    exit(64);
  }
  final cmd = args.first;
  final rest = args.sublist(1);
  final pos = _positional(rest);
  final opts = _opts(rest);
  switch (cmd) {
    case 'extract':
      await _extract(pos[0], pos[1], opts);
    case 'query':
      await _query(pos[0], pos[1], opts);
    case 'report':
      _report(pos[0], pos[1]);
    case 'cpu-report':
      _cpuReport(pos[0]);
    default:
      print('unknown command: $cmd');
      exit(64);
  }
}

Future<void> _extract(
  String dbPath,
  String outPath,
  Map<String, String> opts,
) async {
  final games = int.tryParse(opts['games'] ?? '') ?? 50;
  final seed = int.tryParse(opts['seed'] ?? '') ?? 1;
  final season = int.tryParse(opts['season'] ?? '');
  // 既定値はクラスの既定(校正済みの現行方針)。オプションで上書き
  const p0 = PushPolicy();
  final policy = PushPolicy(
    oneShantenValue: int.tryParse(opts['push-one'] ?? '') ?? p0.oneShantenValue,
    twoShantenValue: int.tryParse(opts['push-two'] ?? '') ?? p0.twoShantenValue,
    safePushRisk: int.tryParse(opts['push-safe'] ?? '') ?? p0.safePushRisk,
    deepSafePushRisk:
        int.tryParse(opts['push-deep-safe'] ?? '') ?? p0.deepSafePushRisk,
  );
  const r0 = RiichiPolicy();
  final riichiPolicy = RiichiPolicy(
    damaMaxWaits: int.tryParse(opts['dama-waits'] ?? '') ?? r0.damaMaxWaits,
    damaWallBelow: int.tryParse(opts['dama-wall'] ?? '') ?? r0.damaWallBelow,
    damaLeadTop: int.tryParse(opts['dama-lead'] ?? '') ?? r0.damaLeadTop,
    damaMinPoints: int.tryParse(opts['dama-points'] ?? '') ?? r0.damaMinPoints,
  );
  const a0 = AttackPolicy();
  final attackPolicy = AttackPolicy(
    maxUkeireLoss: int.tryParse(opts['attack-loss'] ?? '') ?? a0.maxUkeireLoss,
  );
  const c0 = CallPolicy();
  final callPolicy = opts['call'] == 'legacy'
      ? CallPolicy.legacy
      : CallPolicy(
          yakuhaiMinGain:
              int.tryParse(opts['call-yakuhai-gain'] ?? '') ??
              c0.yakuhaiMinGain,
          yakuhaiMaxAfter:
              int.tryParse(opts['call-yakuhai-after'] ?? '') ??
              c0.yakuhaiMaxAfter,
          yakuhaiMinValue:
              int.tryParse(opts['call-yakuhai-value'] ?? '') ??
              c0.yakuhaiMinValue,
          openMaxAfter:
              int.tryParse(opts['call-open-after'] ?? '') ?? c0.openMaxAfter,
          threatMaxAfter:
              int.tryParse(opts['call-threat-after'] ?? '') ??
              c0.threatMaxAfter,
        );
  print('CpuAgent の方針: $policy / $riichiPolicy / $attackPolicy / $callPolicy');
  final raw = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  final ids = [
    for (final r in raw.select(
      season == null
          ? 'SELECT id FROM game ORDER BY id'
          : 'SELECT g.id FROM game g JOIN season_stage s ON s.id = g.season_stage_id '
                'JOIN league_season l ON l.id = s.league_season_id '
                'WHERE l.start_year = ? ORDER BY g.id',
      [?season],
    ))
      r['id'] as int,
  ];
  raw.dispose();
  ids.shuffle(Random(seed));
  final chosen = ids.take(games).toList()..sort();
  final db = PaifuDb.open(dbPath);
  final sink = File(outPath).openWrite();
  var total = 0, turns = 0, reacts = 0;
  final sw = Stopwatch()..start();
  try {
    for (var i = 0; i < chosen.length; i++) {
      final records = await extractGame(
        db,
        chosen[i],
        seed: seed,
        policy: policy,
        riichiPolicy: riichiPolicy,
        attackPolicy: attackPolicy,
        callPolicy: callPolicy,
      );
      for (final r in records) {
        sink.writeln(jsonEncode(r));
        total++;
        if (r['kind'] == 'turn') {
          turns++;
        } else {
          reacts++;
        }
      }
      stderr.write(
        '\r試合 ${i + 1}/${chosen.length} (id=${chosen[i]}) レコード $total  ${sw.elapsed.inSeconds}s',
      );
    }
  } finally {
    await sink.close();
    db.close();
  }
  stderr.writeln();
  print(
    '試合 ${chosen.length} / 手番 $turns / 反応 $reacts / 合計 $total / 飛ばした局 $skippedKyokus → $outPath',
  );
}

Iterable<Map<String, dynamic>> _readJsonl(String path) sync* {
  final f = File(path);
  if (!f.existsSync()) return;
  for (final line in f.readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    yield (jsonDecode(line) as Map).cast<String, dynamic>();
  }
}

/// 指示文の変種 v1(控えめ。初回試走と同じ文面にリーチ選択肢の説明を足したもの)
const _plainDiscardInstructions = {
  '課題':
      'Mリーグのプロ選手として、この局面の行動を1つ選ぶ。行動は「牌を1枚切る」か、'
      'テンパイできる場合は「リーチを宣言してその牌を切る」(選択肢名が リーチ_ で始まるもの)。',
  '選択肢の説明':
      '各候補には、切った後のシャンテン数・受け入れ(有効牌の種類数と残り枚数)・'
      'テンパイなら待ち牌と残り枚数・リーチ者に対する安全度(100=現物、高いほど安全)・'
      'ドラかどうか、が付いている。',
  '判断の観点':
      '牌効率だけでなく、点差・巡目・残り山・相手のリーチや副露・自分の打点を踏まえ、'
      '実際のプロが最も高い確率で選ぶ行動を答える。',
};

/// 参考例(few-shot 相当): 別の試合の手番レコードから、局面の要約とプロの打牌を作る
Map<String, dynamic> _exampleOf(Map<String, dynamic> r) {
  final state = (r['request']['state'] as Map).cast<String, dynamic>();
  final me = (state['自分'] as Map).cast<String, dynamic>();
  return {
    '局': state['局'],
    '残り山': state['残り山'],
    'ドラ': state['ドラ'],
    '自分': {'風': me['風'], '点数': me['点数'], '手牌': me['手牌'], 'ツモ牌': me['ツモ牌']},
    '他家のリーチ': (r['meta'] as Map)['threat'],
    'プロが切った牌': (r['pro'] as Map)['discard'],
  };
}

Future<void> _query(
  String recordsPath,
  String outPath,
  Map<String, String> opts,
) async {
  final apiKey =
      Platform.environment['TYPESAFE_API_KEY_MA'] ??
      Platform.environment['TYPESAFE_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    print('環境変数 TYPESAFE_API_KEY_MA(または TYPESAFE_API_KEY)が未設定');
    exit(2);
  }
  final limit = int.tryParse(opts['limit'] ?? '') ?? 100;
  final kind = opts['kind'] ?? 'all';
  final group = opts['group'] ?? 'tune';
  final concurrency = int.tryParse(opts['concurrency'] ?? '') ?? 4;
  final examples = int.tryParse(opts['examples'] ?? '') ?? 0;
  final promptVariant = opts['prompt'] ?? 'v2';

  final all = _readJsonl(recordsPath).toList();
  final done = {for (final j in _readJsonl(outPath)) j['id'] as String};
  final seed = int.tryParse(opts['seed'] ?? '') ?? 1;
  final threatOnly = opts['threat'] == 'true';
  final pool =
      all
          .where((r) => kind == 'all' || r['kind'] == kind)
          .where((r) => group == 'all' || groupOf(r['game_id'] as int) == group)
          .where((r) => !threatOnly || (r['meta'] as Map)['threat'] == true)
          .where((r) => !done.contains(r['id']))
          .toList()
        ..shuffle(Random(seed)); // 試合をまたいで無作為に選ぶ(同じ seed なら同じ並び)
  final targets = pool.take(limit).toList();
  print(
    '対象 ${targets.length} 件(既存 ${done.length} 件は再利用、並列 $concurrency、参考例 $examples)',
  );

  final client = JevClient(apiKey: apiKey);
  final sink = File(outPath).openWrite(mode: FileMode.append);
  var ok = 0, ng = 0;
  final sw = Stopwatch()..start();
  try {
    final queue = List<Map<String, dynamic>>.from(targets);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final r = queue.removeAt(0);
        final request =
            jsonDecode(jsonEncode(r['request'])) as Map<String, dynamic>;
        if (promptVariant == 'v1' && r['kind'] == 'turn') {
          // 調整用の変種: 指示文を控えめな版に戻し、受け入れ順位を外す
          final q = (request['questions'] as Map)['discard'] as Map;
          q['instructions'] = _plainDiscardInstructions;
          for (final v in (q['criteria'] as Map).values) {
            (v as Map).remove('受け入れ順位');
          }
        }
        if (examples > 0 && r['kind'] == 'turn') {
          final ex = all
              .where((o) => o['kind'] == 'turn' && o['game_id'] != r['game_id'])
              .take(examples)
              .map(_exampleOf)
              .toList();
          (request['state'] as Map<String, dynamic>)['参考例(別の局面でプロが実際に切った牌)'] =
              ex;
        }
        Map<String, dynamic> line;
        try {
          final res = await client.ask(request);
          line = {
            'id': r['id'],
            'answers': res.answers,
            'usage': res.body['usage'],
            'latency_ms': res.latencyMs,
            'attempts': res.attempts,
            'examples': examples,
          };
          ok++;
        } on JevException catch (e) {
          line = {'id': r['id'], 'error': '$e', 'examples': examples};
          ng++;
          if (e.status == 401 || e.status == 422) {
            stderr.writeln('\n$e');
            queue.clear();
          }
        }
        sink.writeln(jsonEncode(line));
        stderr.write(
          '\r成功 $ok / 失敗 $ng / 残り ${queue.length}  ${sw.elapsed.inSeconds}s',
        );
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  } finally {
    await sink.close();
    client.close();
  }
  stderr.writeln();
  print('成功 $ok / 失敗 $ng → $outPath');
}

void _report(String recordsPath, String jevPath) {
  final jev = {for (final j in _readJsonl(jevPath)) j['id'] as String: j};
  final records = _readJsonl(recordsPath).toList();
  final tune = records.where((r) => groupOf(r['game_id'] as int) == 'tune');
  final judge = records.where((r) => groupOf(r['game_id'] as int) == 'judge');
  for (final (name, rs) in [('調整用(tune)', tune), ('判定用(judge)', judge)]) {
    final s = summarize(rs, jev);
    if (s.turn.n + s.react.n == 0) continue;
    print('## $name\n');
    print(renderMarkdown(s));
  }
}

/// CpuAgent とプロの一致率だけを出す(Jev 不要)。群・他家リーチ・シャンテン数で分ける。
void _cpuReport(String recordsPath) {
  final records = _readJsonl(recordsPath).where((r) => r['kind'] == 'turn');
  final tallies = <String, Tally>{};
  Tally t(String k) => tallies.putIfAbsent(k, Tally.new);
  for (final r in records) {
    final hit = (r['cpu'] as Map)['discard'] == (r['pro'] as Map)['discard'];
    final meta = (r['meta'] as Map).cast<String, dynamic>();
    final g = groupOf(r['game_id'] as int);
    final threat = meta['threat'] == true;
    t('$g/全体').add(hit);
    t('$g/${threat ? 'リーチ者あり' : 'リーチ者なし'}').add(hit);
    if (threat) {
      t('$g/リーチ者あり/シャンテン${shantenBucket(meta['shanten'] as int)}').add(hit);
    }
  }
  print('| 条件 | CpuAgent 一致率 |');
  print('|---|---|');
  for (final k in tallies.keys.toList()..sort()) {
    print('| $k | ${tallies[k]!.label} |');
  }
  // リーチ判断: プロがテンパイを取った(リーチできる牌を切った)局面で、
  // CPU のリーチ有無がプロと一致するか(牌の一致は問わない)
  final conf = <String, Confusion>{};
  for (final r in _readJsonl(recordsPath).where((r) => r['kind'] == 'turn')) {
    if ((r['meta'] as Map)['can_riichi'] != true) continue;
    final criteria =
        ((r['request'] as Map)['questions'] as Map)['discard']['criteria']
            as Map;
    final pro = (r['pro'] as Map)['discard'] as String;
    final proRiichi = isRiichiKey(pro);
    if (!criteria.containsKey('$riichiKeyPrefix${tileOfKey(pro)}')) continue;
    final g = groupOf(r['game_id'] as int);
    conf
        .putIfAbsent(g, Confusion.new)
        .add(actual: proRiichi, predicted: (r['cpu'] as Map)['riichi'] == true);
  }
  for (final g in conf.keys.toList()..sort()) {
    final c = conf[g]!;
    print(
      'リーチ判断($g、プロがテンパイを取った局面): 一致 ${(c.accuracy * 100).toStringAsFixed(1)}% (n=${c.n}) / '
      'プロリーチ×CPUリーチ ${c.tt}・プロリーチ×CPUダマ ${c.tf}・'
      'プロダマ×CPUリーチ ${c.ft}・プロダマ×CPUダマ ${c.ff}',
    );
  }
  // 鳴き判断: 鳴く/見送るの2×2と、形まで含めた一致
  final callConf = <String, Confusion>{};
  final callExact = <String, Tally>{};
  for (final r in _readJsonl(recordsPath).where((r) => r['kind'] == 'react')) {
    final g = groupOf(r['game_id'] as int);
    final pro = (r['pro'] as Map)['call'] as String;
    final cpu = (r['cpu'] as Map)['call'] as String;
    callConf
        .putIfAbsent(g, Confusion.new)
        .add(actual: pro != 'pass', predicted: cpu != 'pass');
    callExact.putIfAbsent(g, Tally.new).add(pro == cpu);
  }
  for (final g in callConf.keys.toList()..sort()) {
    final c = callConf[g]!;
    print(
      '鳴き判断($g): 形込み一致 ${callExact[g]!.label} / 鳴く・見送る一致 ${(c.accuracy * 100).toStringAsFixed(1)}% / '
      'プロ鳴く×CPU鳴く ${c.tt}・プロ鳴く×CPU見送り ${c.tf}・'
      'プロ見送り×CPU鳴く ${c.ft}・プロ見送り×CPU見送り ${c.ff}',
    );
  }
}
