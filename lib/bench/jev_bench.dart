/// Jev ベンチマーク(設計文書(非公開))の局面抽出と問い合わせ生成。
///
/// 牌譜DBの各局をゴースト機構([GhostRun])で実エンジン上に再現し、記録どおりの
/// 手番・反応が返される直前のプロンプトとビューから
/// - 自分視点の state(他家の手牌・山・裏ドラは含めない)
/// - 合法な候補と、エンジンの純粋関数で計算した特徴量(criteria)
/// - プロの実際の選択、同じ局面での CpuAgent の選択
/// を1レコードにまとめる。特徴量の計算は engine/ の純粋関数をそのまま呼び、
/// ベンチマーク用に別実装しない(CLAUDE.md §2)。
library;

import 'dart:async';

import '../engine/advisor.dart';
import '../engine/ai.dart';
import '../engine/display_text.dart';
import '../engine/hand.dart';
import '../engine/meld.dart';
import '../engine/models.dart';
import '../engine/safety.dart';
import '../engine/tile.dart';
import '../paifu/ghost.dart';
import '../paifu/paifu_db.dart';

/// Jev に渡すモデル名
const jevModel = 'jev-latest';

/// 席の相対位置の名前(自分から見て)
String relativeSeatName(int me, int other) =>
    const ['自分', '下家', '対面', '上家'][(other - me + 4) % 4];

String _meldLabel(Meld m, int me) {
  final tiles = m.tiles.map(Tile.dbNotation).join(' ');
  final kind = switch (m.type) {
    MeldType.chi => 'チー',
    MeldType.pon => 'ポン',
    MeldType.ankan => '暗槓',
    MeldType.minkan => '大明槓',
    MeldType.kakan => '加槓',
  };
  final from = m.fromSeat < 0 ? '' : '(${relativeSeatName(me, m.fromSeat)}から)';
  return '$kind $tiles$from';
}

/// 河1枚の表記: 牌 + '*'(リーチ宣言牌) + '~'(ツモ切り)。鳴かれた牌は '(鳴)'。
String riverTileLabel(DiscardInfo d) =>
    '${Tile.dbNotation(d.tile)}${d.riichi ? '*' : ''}${d.tsumogiri ? '~' : ''}${d.calledAway ? '(鳴)' : ''}';

/// 自分視点の state を組み立てる(他家の手牌・山・裏ドラは含めない)。
Map<String, dynamic> buildState(GameView view) {
  final me = view.youSeat;
  final hand = [...view.hand]
    ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
  final myTurn = view.players[me].discards.length + 1;
  Map<String, dynamic> playerEntry(int s) {
    final p = view.players[s];
    return {
      if (s != me) '位置': relativeSeatName(me, s),
      '風': seatWindName(view.seatWind(s)),
      '親': s == view.dealer,
      '点数': view.scores[s],
      'リーチ中': p.riichi,
      '副露': [for (final m in p.melds) _meldLabel(m, me)],
      '河': [for (final d in p.discards) riverTileLabel(d)],
    };
  }

  return {
    'ルール': 'Mリーグルール(赤5各色1枚・一発裏ドラあり・喰いタンあり・途中流局なし)',
    '局': kyokuLabel(
      view.roundWind,
      view.kyoku,
      honba: view.honba,
      alwaysHonba: true,
    ),
    '供託': view.riichiSticks,
    '残り山': view.wallRemaining,
    '自分の巡目': myTurn,
    'ドラ': [
      for (final ind in view.doraIndicators)
        Tile.dbNotation(Tile.doraFromIndicator(ind)),
    ],
    '記法':
        '牌は 1m〜9m 萬子・1p〜9p 筒子・1s〜9s 索子・0=赤5・1z〜7z=東南西北白發中。'
        '河の * はリーチ宣言牌、~ はツモ切り、(鳴) は鳴かれた牌',
    '自分': {
      ...playerEntry(me),
      '手牌': [for (final t in hand) Tile.dbNotation(t)],
      'ツモ牌': view.drawnTile == null ? null : Tile.dbNotation(view.drawnTile!),
    },
    '他家': [for (var i = 1; i <= 3; i++) playerEntry((me + i) % 4)],
  };
}

/// 打牌候補1つの特徴量(criteria の説明に使う)。
Map<String, dynamic> candidateFeatures({
  required GameView view,
  required List<int> fullHand,
  required int tile,
  required List<int> threats,
}) {
  final me = view.youSeat;
  final meldCount = view.players[me].melds.length;
  final after = List<int>.from(fullHand)..remove(tile);
  final counts = toCounts(after);
  final shanten = calcShanten(counts, meldCount: meldCount);
  final ukeire = ukeireMap(
    counts,
    meldCount: meldCount,
    shanten: shanten,
    remainingOf: (k) => remainingOf(k, view, after),
  );
  final tiles = ukeire.values.fold(0, (a, b) => a + b);
  final doraKinds = Tile.doraKinds(view.doraIndicators);
  final kind = Tile.normalize(tile);
  return {
    '切った後のシャンテン数': shanten,
    '受け入れ種類数': ukeire.length,
    '受け入れ枚数': tiles,
    if (shanten == 0)
      '待ち': [
        for (final w in calcWaits(counts, meldCount: meldCount))
          '${Tile.dbNotation(w)}(残り${ukeire[w] ?? 0}枚)',
      ],
    if (shanten == 0)
      ...() {
        final d = damaInfo(view, fullHand, tile);
        return {'ダマで役が付く待ち枚数': d.yakuWaitCount, 'ダマのロン打点(最大)': d.maxRonPoints};
      }(),
    if (threats.isNotEmpty)
      'リーチ者への安全度(100=現物)': {
        for (final t in threats)
          relativeSeatName(me, t): safetyVs(kind, t, after, view),
      },
    if (doraKinds.contains(kind)) 'ドラ': true,
    if (Tile.isRed(tile)) '赤ドラ': true,
    if (view.drawnTile == tile) 'ツモ切り': true,
  };
}

/// リーチ中の他家の席
List<int> riichiThreats(GameView view) => [
  for (var s = 0; s < 4; s++)
    if (s != view.youSeat && view.players[s].riichi) s,
];

/// 打牌選択の候補(実牌値。赤と通常は別候補。喰い替え禁止は除く)
List<int> discardCandidates(GameView view, TurnPrompt prompt) {
  final full = [...view.hand, ?prompt.drawnTile];
  final seen = <int>{};
  final out = <int>[];
  for (final t in full..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b))) {
    if (prompt.forbiddenDiscards.contains(Tile.normalize(t))) continue;
    if (seen.add(t)) out.add(t);
  }
  return out;
}

const _discardInstructions = {
  '課題':
      'Mリーグのプロ選手として、この局面の行動を1つ選ぶ。行動は「牌を1枚切る」か、'
      'テンパイできる場合は「リーチを宣言してその牌を切る」(選択肢名が リーチ_ で始まるもの)。',
  '選択肢の説明':
      '各候補には、切った後のシャンテン数(0=テンパイ)・受け入れ(有効牌の種類数と残り枚数、'
      '受け入れ順位 1 が最大)・テンパイなら待ち牌と残り枚数・'
      'リーチ者に対する安全度(100=現物、高いほど安全)・ドラかどうか、が付いている。',
  '判断の観点':
      'プロは基本的にシャンテン数を落とさず受け入れが最大の牌を切る。そこから外れるのは、'
      '他家のリーチに対して安全牌を切る(降りる)、ドラや赤を残して打点を作る、'
      '良形の待ちを作る、点差と残り局数から押し引きを変える、といった理由がある場合。'
      'リーチとダマは、待ちの良さ・打点・巡目・点差で決まる。'
      '実際のプロが最も高い確率で選ぶ行動を答える。',
};

/// リーチ宣言の選択肢キー(打牌キーに接頭辞を付ける)
const riichiKeyPrefix = 'リーチ_';

/// 手番1件のレコード。対象外(ツモ和了・リーチ中・カン等)なら null。
Future<Map<String, dynamic>?> buildTurnRecord({
  required String id,
  required int gameId,
  required int kyokuId,
  required int seat,
  required TurnPrompt prompt,
  required GameView? view,
  required TurnAction scripted,
  required CpuAgent cpu,
}) async {
  if (view == null) return null;
  if (prompt.canTsumo || prompt.riichiLocked) return null;
  if (scripted.type != 'discard') return null;
  final candidates = discardCandidates(view, prompt);
  if (candidates.length < 2) return null;
  final full = [...view.hand, ?prompt.drawnTile];
  final threats = riichiThreats(view);
  final features = <String, dynamic>{};
  for (final t in candidates) {
    features[Tile.dbNotation(t)] = candidateFeatures(
      view: view,
      fullHand: full,
      tile: t,
      threats: threats,
    );
  }
  // 受け入れ順位(シャンテン後が小さく、受け入れ枚数が多い順に 1, 2, …)
  final ranked = features.keys.toList()
    ..sort((a, b) {
      final fa = features[a] as Map, fb = features[b] as Map;
      final s = (fa['切った後のシャンテン数'] as int).compareTo(fb['切った後のシャンテン数'] as int);
      if (s != 0) return s;
      return (fb['受け入れ枚数'] as int).compareTo(fa['受け入れ枚数'] as int);
    });
  for (var i = 0; i < ranked.length; i++) {
    (features[ranked[i]] as Map<String, dynamic>)['受け入れ順位'] = i + 1;
  }
  final riichiKeys = {for (final t in prompt.riichiTiles) Tile.dbNotation(t)};
  final criteria = <String, dynamic>{
    for (final e in features.entries) e.key: e.value,
    for (final k in riichiKeys)
      '$riichiKeyPrefix$k': {'リーチ宣言': true, ...features[k] as Map},
  };
  final proTile = Tile.dbNotation(scripted.tile);
  final proKey = scripted.riichi ? '$riichiKeyPrefix$proTile' : proTile;
  if (!criteria.containsKey(proKey)) return null; // 記録と候補が食い違う局面は除外
  final cpuAction = await cpu.onTurn(prompt);
  final cpuTile = cpuAction.type == 'discard'
      ? Tile.dbNotation(cpuAction.tile)
      : null;
  final cpuKey = cpuTile == null
      ? null
      : cpuAction.riichi
      ? '$riichiKeyPrefix$cpuTile'
      : cpuTile;
  final meldCount = view.players[seat].melds.length;
  final shantenNow = calcShanten(toCounts(full), meldCount: meldCount);
  final questions = <String, dynamic>{
    'discard': {
      'type': 'choice',
      'instructions': _discardInstructions,
      'criteria': criteria,
    },
  };
  return {
    'id': id,
    'kind': 'turn',
    'game_id': gameId,
    'kyoku_id': kyokuId,
    'seat': seat,
    'request': {
      'model': jevModel,
      'state': buildState(view),
      'questions': questions,
    },
    'pro': {
      'discard': proKey,
      if (prompt.riichiTiles.isNotEmpty) 'riichi': scripted.riichi,
    },
    'cpu': {
      'discard': cpuKey,
      if (prompt.riichiTiles.isNotEmpty) 'riichi': cpuAction.riichi,
    },
    'meta': {
      'shanten': shantenNow,
      'threat': threats.isNotEmpty,
      'wall': view.wallRemaining,
      'turn': view.players[seat].discards.length + 1,
      'can_riichi': prompt.riichiTiles.isNotEmpty,
      'candidates': features,
    },
  };
}

String reactKey(ReactAction a) => switch (a.type) {
  'chi' => 'chi_${(a.tiles.map(Tile.dbNotation).toList()..sort()).join('')}',
  _ => a.type,
};

/// 反応1件のレコード(ロンできる局面と、鳴ける形が無い局面は対象外)。
Future<Map<String, dynamic>?> buildReactRecord({
  required String id,
  required int gameId,
  required int kyokuId,
  required int seat,
  required ReactPrompt prompt,
  required GameView? view,
  required ReactAction scripted,
  required CpuAgent cpu,
}) async {
  if (view == null || prompt.canRon) return null;
  if (!prompt.canPon && !prompt.canKan && prompt.chiOptions.isEmpty) {
    return null;
  }
  final me = view.youSeat;
  final criteria = <String, dynamic>{
    'pass': '鳴かずに見送る',
    if (prompt.canPon) 'pon': 'ポンする',
    if (prompt.canKan) 'kan': '大明槓する',
    for (final o in prompt.chiOptions)
      'chi_${(o.map(Tile.dbNotation).toList()..sort()).join('')}':
          '手牌の ${o.map(Tile.dbNotation).join(' ')} でチーする',
  };
  final proKey = reactKey(scripted);
  if (!criteria.containsKey(proKey)) return null;
  final cpuAction = await cpu.onReact(prompt);
  final state = buildState(view);
  // 選択肢ごとの特徴量: 鳴いた後(打牌込み)の最良シャンテン数
  final meldCountNow = view.players[me].melds.length;
  final kind = Tile.normalize(prompt.tile);
  List<int> without(List<int> hand, List<int> kinds) {
    final h = List<int>.from(hand);
    for (final k in kinds) {
      final i = h.indexWhere((t) => Tile.normalize(t) == k);
      if (i >= 0) h.removeAt(i);
    }
    return h;
  }

  final shantenAfter = <String, int>{
    if (prompt.canPon)
      'pon': bestShantenAfterDiscard(
        without(view.hand, [kind, kind]),
        meldCount: meldCountNow + 1,
      ),
    for (final o in prompt.chiOptions)
      'chi_${(o.map(Tile.dbNotation).toList()..sort()).join('')}':
          bestShantenAfterDiscard(
            without(view.hand, o.map(Tile.normalize).toList()),
            meldCount: meldCountNow + 1,
          ),
  };
  final isYakuhai =
      Tile.isDragon(kind) ||
      kind == windTile(view.seatWind(me)) ||
      kind == windTile(view.roundWind);
  final doraKinds = Tile.doraKinds(view.doraIndicators);
  final allTiles = [
    ...view.hand,
    for (final m in view.players[me].melds) ...m.tiles,
  ];
  final handValue =
      allTiles.where((t) => doraKinds.contains(Tile.normalize(t))).length +
      allTiles.where(Tile.isRed).length;
  state['他家の打牌'] = {
    '誰': relativeSeatName(me, prompt.fromSeat),
    '牌': Tile.dbNotation(prompt.tile),
  };
  final meldCount = view.players[me].melds.length;
  final shantenNow = calcShanten(toCounts(view.hand), meldCount: meldCount);
  return {
    'id': id,
    'kind': 'react',
    'game_id': gameId,
    'kyoku_id': kyokuId,
    'seat': seat,
    'request': {
      'model': jevModel,
      'state': state,
      'questions': {
        'call': {
          'type': 'choice',
          'instructions': {
            '課題': 'Mリーグのプロ選手として、他家が切った牌に対して鳴くかどうか(鳴くならどの形か)を決める。',
            '判断の観点': '役の有無・打点・速度・点差・巡目・相手の状況を踏まえ、実際のプロが最も高い確率で選ぶ行動を答える。',
          },
          'criteria': criteria,
        },
      },
    },
    'pro': {'call': proKey},
    'cpu': {'call': reactKey(cpuAction)},
    'meta': {
      'shanten': shantenNow,
      'threat': riichiThreats(view).isNotEmpty,
      'wall': view.wallRemaining,
      'turn': view.players[seat].discards.length + 1,
      'shanten_after': shantenAfter,
      'yakuhai': isYakuhai,
      'menzen': meldCountNow == 0,
      'hand_value': handValue,
      'tile_is_dora': doraKinds.contains(kind) || Tile.isRed(prompt.tile),
    },
  };
}

/// 山を再構成できず飛ばした局の累計(extract の報告用)
int skippedKyokus = 0;

/// 1試合の全局を実エンジンで再現し、手番・反応のレコードを集める。
/// 山を再構成できない局(配牌欠損等)は飛ばして [skippedKyokus] に数える。
Future<List<Map<String, dynamic>>> extractGame(
  PaifuDb db,
  int gameId, {
  int seed = 1,
  Duration kyokuTimeout = const Duration(seconds: 60),
  PushPolicy policy = const PushPolicy(),
  RiichiPolicy riichiPolicy = const RiichiPolicy(),
  AttackPolicy attackPolicy = const AttackPolicy(),
  CallPolicy callPolicy = const CallPolicy(),
}) async {
  final players = db.gamePlayers(gameId);
  if (players.length != 4) return [];
  final seatOf = {for (var i = 0; i < 4; i++) players[i].id: i};
  var scores = List<int>.filled(4, 25000);
  final out = <Map<String, dynamic>>[];
  for (final k in db.kyokus(gameId)) {
    final events = db.kyokuEvents(k.id);
    final dealer = seatOf[k.parentPlayerId] ?? 0;
    final endScores = db.kyokuEndScores(k.id);
    final nextScores = [
      for (var i = 0; i < 4; i++) endScores[players[i].id] ?? scores[i],
    ];
    var n = 0;
    final done = Completer<void>();
    final GhostRun run;
    try {
      run = GhostRun(
        events: events,
        cutoff: events.length,
        seatOf: seatOf,
        names: [for (final p in players) p.name],
        youSeat: -1,
        dealer: dealer,
        roundWind: k.roundWind,
        kyoku: k.kyokuNumber,
        honba: k.honba,
        riichiSticks: k.reachSticks,
        scores: scores,
        baseWallRemaining: -1,
        baseDiscards: 0,
        seed: seed,
        cpuThinkMillis: 0,
        autoPlayDelayMs: 0,
        cpuFactory: (s) => CpuAgent(
          thinkMillis: 0,
          seed: seed + s,
          policy: policy,
          riichiPolicy: riichiPolicy,
          attackPolicy: attackPolicy,
          callPolicy: callPolicy,
        ),
        onScriptedTurn: (seat, prompt, view, scripted, cpu) async {
          final r = await buildTurnRecord(
            id: '$gameId-${k.id}-$seat-${n++}',
            gameId: gameId,
            kyokuId: k.id,
            seat: seat,
            prompt: prompt,
            view: view,
            scripted: scripted,
            cpu: cpu,
          );
          if (r != null) out.add(r);
        },
        onScriptedReact: (seat, prompt, view, scripted, cpu) async {
          final r = await buildReactRecord(
            id: '$gameId-${k.id}-$seat-${n++}',
            gameId: gameId,
            kyokuId: k.id,
            seat: seat,
            prompt: prompt,
            view: view,
            scripted: scripted,
            cpu: cpu,
          );
          if (r != null) out.add(r);
        },
      );
    } on StateError {
      // 山を再構成できない局(配牌欠損・第1ツモ未記録の補完が矛盾する等)は飛ばす
      skippedKyokus++;
      scores = nextScores;
      continue;
    }
    final sub = run.views.listen((v) {
      if (v.phase == 'handEnd' && !done.isCompleted) done.complete();
    });
    run.start();
    try {
      await done.future.timeout(kyokuTimeout);
    } on TimeoutException {
      // 記録が途中で終わっている等で局が終わらない: この局の分は捨てる
      out.removeWhere((r) => r['kyoku_id'] == k.id);
    }
    await sub.cancel();
    run.dispose();
    scores = nextScores;
  }
  return out;
}
