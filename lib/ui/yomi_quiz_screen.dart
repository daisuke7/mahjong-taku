import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../engine/tile.dart';
import '../paifu/paifu_db.dart';
import '../paifu/paifu_store.dart';
import '../paifu/replay_session.dart';
import '../paifu/yomi_quiz.dart';
import 'game_screen.dart';
import 'widgets/table_widgets.dart';
import 'widgets/tile_widget.dart';

/// 読みクイズ: Mリーグ牌譜の流局局を、4家全員の手牌を伏せた流局時点の
/// 卓として出題する。河(手出し/ツモ切りの色分け)・副露・リーチ・ドラを
/// 読みの材料に、各家の「テンパイ / イーシャンテン / それ以外」と、
/// テンパイなら待ち牌を当てる。
class YomiQuizScreen extends StatefulWidget {
  /// テスト用: DBの代わりにこの問題リストを順番に(循環して)出題する
  @visibleForTesting
  final List<YomiQuizProblem>? debugProblems;

  const YomiQuizScreen({super.key, this.debugProblems});

  @override
  State<YomiQuizScreen> createState() => _YomiQuizScreenState();
}

class _YomiQuizScreenState extends State<YomiQuizScreen> {
  PaifuDb? _db;
  YomiQuizDeck? _deck;
  YomiQuizProblem? _problem;
  String? _error;

  /// 選択中の難易度(null=難易度選択画面)
  YomiQuizLevel? _level;

  /// 席ごとの解答(0=テンパイ 1=イーシャンテン 2=それ以外 / null=未回答)
  List<int?> _ans = List.filled(4, null);

  /// テンパイと答えた席の待ち牌(牌種・正規化)
  List<Set<int>> _waitAns = List.generate(4, (_) => <int>{});

  bool _revealed = false;
  bool _overlayOpen = false;

  // セッション通算(席単位)
  int _seatTotal = 0;
  int _stateCorrect = 0;
  int _waitExact = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _debugIndex = 0;

  Future<void> _load() async {
    if (widget.debugProblems != null) {
      _level = YomiQuizLevel.normal;
      _nextProblem();
      return;
    }
    try {
      final f = await PaifuStore.dbFile();
      final db = PaifuDb.open(f.path);
      if (!mounted) {
        db.close();
        return;
      }
      _db = db;
      _deck = YomiQuizDeck(db);
      // 難易度選択が済んでいれば出題、まだなら選択待ち
      if (_level != null) {
        _nextProblem();
      } else {
        setState(() {});
      }
    } catch (e) {
      if (mounted) setState(() => _error = '牌譜DBを開けません: $e');
    }
  }

  void _pickLevel(YomiQuizLevel level) {
    setState(() => _level = level);
    if (_deck != null || widget.debugProblems != null) _nextProblem();
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }

  void _nextProblem() {
    final dbg = widget.debugProblems;
    final p = dbg != null
        ? dbg[_debugIndex++ % dbg.length]
        : _deck?.nextProblem(_level ?? YomiQuizLevel.normal);
    setState(() {
      _problem = p;
      if (p == null) _error = '出題できる流局局が見つかりません';
      // リーチ者はテンパイ確定なので3択は自明 → 自動で「テンパイ」にして
      // 待ち当てだけ解答してもらう
      _ans = [
        for (var s = 0; s < 4; s++) (p != null && p.riichi[s]) ? 0 : null,
      ];
      _waitAns = List.generate(4, (_) => <int>{});
      _revealed = false;
      _overlayOpen = false;
    });
  }

  bool get _allAnswered {
    final p = _problem;
    if (p == null) return false;
    for (var s = 0; s < 4; s++) {
      if (_ans[s] == null) return false;
      if (p.riichi[s] && _waitAns[s].isEmpty) return false;
    }
    return true;
  }

  void _reveal() {
    final p = _problem!;
    for (var s = 0; s < 4; s++) {
      if (p.riichi[s]) {
        // リーチ者は状態が自明なので待ち当てのみ集計する
        if (setEquals(_waitAns[s], p.waits[s].toSet())) _waitExact++;
        continue;
      }
      _seatTotal++;
      if (_ans[s] == p.category(s)) {
        _stateCorrect++;
        if (p.category(s) == 0 && setEquals(_waitAns[s], p.waits[s].toSet())) {
          _waitExact++;
        }
      }
    }
    setState(() {
      _revealed = true;
      _overlayOpen = true;
    });
  }

  // ---------------- 解答入力 ----------------

  Future<void> _editAnswer(int seat) async {
    if (_revealed) return;
    final p = _problem!;
    // リーチ者はテンパイ確定 → 待ち牌選択に直行
    if (p.riichi[seat]) {
      final waits = await _pickWaits(seat);
      if (waits == null || !mounted) return;
      setState(() {
        _ans[seat] = 0;
        _waitAns[seat] = waits;
      });
      return;
    }
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('${p.names[seat]} の手は?'),
        children: [
          for (final v in [0, 1, 2])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, v),
              child: Text(
                YomiQuizProblem.categoryLabel(v),
                style: const TextStyle(fontSize: 16),
              ),
            ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice != 0) {
      setState(() {
        _ans[seat] = choice;
        _waitAns[seat] = {};
      });
      return;
    }
    final waits = await _pickWaits(seat);
    if (waits == null || !mounted) return;
    setState(() {
      _ans[seat] = 0;
      _waitAns[seat] = waits;
    });
  }

  /// 待ち牌の複数選択(34種のグリッド)
  Future<Set<int>?> _pickWaits(int seat) {
    final sel = {..._waitAns[seat]};
    return showDialog<Set<int>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('${_problem!.names[seat]} の待ち牌は?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final row in const [
                  [0, 1, 2, 3, 4, 5, 6, 7, 8],
                  [9, 10, 11, 12, 13, 14, 15, 16, 17],
                  [18, 19, 20, 21, 22, 23, 24, 25, 26],
                  [27, 28, 29, 30, 31, 32, 33],
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final t in row)
                        InkWell(
                          onTap: () => setLocal(() {
                            if (!sel.remove(t)) sel.add(t);
                          }),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: sel.contains(t)
                                    ? const Color(0xFFFFC400)
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                            child: TileWidget(tile: t, width: 26),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: sel.isEmpty ? null : () => Navigator.pop(ctx, sel),
              child: const Text('決定'),
            ),
          ],
        ),
      ),
    );
  }

  /// 出典の試合を、この局の頭から牌譜ビューアで開く(視点の選手を選んでから)。
  Future<void> _openInViewer(YomiQuizProblem p) async {
    final seat = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('どの選手の視点で見る?'),
        children: [
          for (var s = 0; s < 4; s++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Text(p.names[s], style: const TextStyle(fontSize: 16)),
            ),
        ],
      ),
    );
    if (seat == null || !mounted) return;
    // 再生セッションは自前のDB接続を持つ(クイズ用と寿命を分ける)
    final f = await PaifuStore.dbFile();
    final session = ReplaySession(
      db: PaifuDb.open(f.path),
      gameId: p.gameId,
      youSeat: seat,
      matchLabel: p.sourceLabel,
      mLeagueGameId: p.mLeagueGameId,
      startKyoku: p.kyokuIndex,
    );
    unawaited(session.run());
    if (!mounted) {
      await session.dispose();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => GameScreen(session: session)),
    );
  }

  // ---------------- 描画 ----------------

  GameView _tableView(YomiQuizProblem p) => GameView(
    youSeat: 0,
    dealer: p.dealer,
    roundWind: p.roundWind,
    kyoku: p.kyokuNumber,
    honba: p.honba,
    riichiSticks: p.sticks,
    wallRemaining: p.wallRemaining,
    // 巻き戻し出題では次にツモる席(最終打牌者の下家)を手番として
    // ハイライトする(中央パネルのチップ黄枠)
    currentSeat: p.nextDrawSeat,
    scores: p.scores,
    doraIndicators: p.doraIndicators,
    hand: const [],
    players: [
      for (var s = 0; s < 4; s++)
        PlayerView(
          name: p.names[s],
          isCpu: false,
          connected: true,
          riichi: p.riichi[s],
          handCount: p.hands[s].length,
          melds: p.melds[s],
          discards: p.rivers[s],
        ),
    ],
    phase: 'playing',
    currentStats: GameStats.zero(),
    memberNames: p.names,
  );

  @override
  Widget build(BuildContext context) {
    if (_level == null) return _levelSelect();
    final p = _problem;
    if (p == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('読みクイズ')),
        body: Center(
          child: Text(
            _error ?? '問題を準備中…',
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    final view = _tableView(p);
    final doraKinds = TileWidget.doraKindsFrom(p.doraIndicators);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            final riverW = h / 24;
            final centerScale = min(w * 0.34, h * 0.54);
            const barH = 60.0;

            Widget seatArea(int seat) => SeatArea(
              player: view.players[seat],
              seat: seat,
              riverTileWidth: riverW,
              showHiddenHand: true,
              doraKinds: doraKinds,
              revealHand: _revealed ? p.hands[seat] : null,
            );

            return Stack(
              children: [
                // 左(席3)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: RotatedBox(quarterTurns: 1, child: seatArea(3)),
                  ),
                ),
                // 右(席1)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: RotatedBox(quarterTurns: 3, child: seatArea(1)),
                  ),
                ),
                // 中央: 対面の河 → パネル → 下家側の河。河や開いた手牌で
                // 縦に伸びても、セットごと縮小して解答バーの上に必ず収める
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  bottom: barH,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RotatedBox(quarterTurns: 2, child: seatArea(2)),
                        SizedBox(height: riverW * 0.25),
                        CenterPanel(view: view, scale: centerScale),
                        SizedBox(height: riverW * 0.25),
                        seatArea(0),
                      ],
                    ),
                  ),
                ),
                // 解答バー(狭い画面ではバーごと縮小して横あふれを防ぐ)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    height: barH,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          for (var s = 0; s < 4; s++) ...[
                            _answerChip(view, s),
                            const SizedBox(width: 6),
                          ],
                          const SizedBox(width: 8),
                          if (!_revealed)
                            FilledButton(
                              onPressed: _allAnswered ? _reveal : null,
                              child: const Text('答え合わせ'),
                            )
                          else ...[
                            FilledButton.tonal(
                              onPressed: () =>
                                  setState(() => _overlayOpen = true),
                              child: const Text('結果'),
                            ),
                            const SizedBox(width: 6),
                            FilledButton(
                              onPressed: _nextProblem,
                              child: const Text('次の問題'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                // 閉じる
                Positioned(
                  top: 2,
                  left: 2,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white38),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                // 難易度(タップで選び直し)
                Positioned(
                  top: 6,
                  left: 44,
                  child: TextButton(
                    onPressed: () => setState(() {
                      _level = null;
                      _problem = null;
                    }),
                    child: Text(
                      '難易度: ${_level!.label}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
                // 右上: 出典(当時の映像を見に行けるように常時表示)
                // → 次のツモ番(巻き戻し出題のみ) → 通算成績
                Positioned(
                  top: 8,
                  right: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (p.sourceLabel.isNotEmpty)
                        Text(
                          p.sourceLabel,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      if (p.nextDrawSeat >= 0)
                        Text(
                          '次のツモ: ${windNames[view.seatWind(p.nextDrawSeat)]}'
                          ' ${p.names[p.nextDrawSeat]}',
                          style: const TextStyle(
                            color: Color(0xFFFFC400),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      if (_seatTotal > 0)
                        Text(
                          '状態 $_stateCorrect/$_seatTotal・待ちピタリ $_waitExact',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_overlayOpen) _resultOverlay(p, view),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 難易度選択画面
  Widget _levelSelect() {
    return Scaffold(
      appBar: AppBar(title: const Text('読みクイズ 難易度を選ぶ')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 14,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                for (final level in YomiQuizLevel.values)
                  SizedBox(
                    width: 200,
                    height: 92,
                    child: FilledButton.tonal(
                      onPressed: () => _pickLevel(level),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B4D2B),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: const BorderSide(color: Color(0xFF2E7D32)),
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            level.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            level.description,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 席1つ分の解答チップ(タップで3択→待ち牌選択)
  Widget _answerChip(GameView view, int seat) {
    final p = _problem!;
    final wind = windNames[view.seatWind(seat)];
    final ans = _ans[seat];
    // リーチ者はテンパイ確定(自動解答済み)なので、待ちを選んで初めて解答扱い
    final answered =
        ans != null && (!p.riichi[seat] || _waitAns[seat].isNotEmpty);
    final correct =
        _revealed &&
        (p.riichi[seat]
            ? setEquals(_waitAns[seat], p.waits[seat].toSet())
            : ans == p.category(seat));
    final String ansText = p.riichi[seat]
        ? (_waitAns[seat].isEmpty ? 'リーチ: 待ちは?' : 'テンパイ')
        : (ans == null ? 'タップで解答' : YomiQuizProblem.categoryLabel(ans));
    return InkWell(
      onTap: _revealed ? null : () => _editAnswer(seat),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 118,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF14401F),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _revealed
                ? (correct ? const Color(0xFF81C784) : const Color(0xFFEF5350))
                : answered
                ? const Color(0xFFFFC400)
                : Colors.white24,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$wind ${p.names[seat]}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    ansText,
                    style: TextStyle(
                      color: answered ? Colors.white : Colors.white38,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (ans == 0 && _waitAns[seat].isNotEmpty) ...[
                    const SizedBox(width: 4),
                    for (final t in _waitAns[seat].toList()..sort())
                      Padding(
                        padding: const EdgeInsets.only(right: 1),
                        child: TileWidget(tile: t, width: 12),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 答え合わせの結果パネル(全員の手牌を開いて正解と解答を並べる)
  Widget _resultOverlay(YomiQuizProblem p, GameView view) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.88),
        child: SafeArea(
          child: Center(
            // 縦にあふれる場合はパネルごと縮小して1画面に収める
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '答え合わせ ${p.sourceLabel}'
                      '${p.cutoffDiscards > 0 ? ' (流局${p.cutoffDiscards}打牌前)' : ''}',
                      style: const TextStyle(
                        color: Color(0xFFFFE082),
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (var s = 0; s < 4; s++) _resultRow(p, view, s),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (p.gameId >= 0) ...[
                          // 出典の試合をこの局から牌譜ビューアで開く
                          FilledButton.tonal(
                            onPressed: () => _openInViewer(p),
                            child: const Text('ビューアで再生'),
                          ),
                          const SizedBox(width: 10),
                        ],
                        FilledButton.tonal(
                          onPressed: () => setState(() => _overlayOpen = false),
                          child: const Text('卓を確認'),
                        ),
                        const SizedBox(width: 10),
                        FilledButton(
                          onPressed: _nextProblem,
                          child: const Text('次の問題'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _resultRow(YomiQuizProblem p, GameView view, int seat) {
    final doraKinds = TileWidget.doraKindsFrom(p.doraIndicators);
    final cat = p.category(seat);
    final ans = _ans[seat];
    // リーチ者は状態が自明なので、正否は待ち当てのみで判定する
    final riichi = p.riichi[seat];
    final stateOk = riichi || ans == cat;
    final waitOk =
        cat == 0 &&
        ans == 0 &&
        setEquals(_waitAns[seat], p.waits[seat].toSet());
    final ok = riichi ? waitOk : stateOk;
    String catText(int c, {required bool actual}) =>
        YomiQuizProblem.categoryLabel(c) +
        (actual && c == 2 ? '(${p.shanten[seat]}シャンテン)' : '');
    final mark = riichi
        ? (waitOk ? '◎' : '✕')
        : !stateOk
        ? '✕'
        : cat == 0
        ? (waitOk ? '◎' : '○')
        : '○';
    // 全行を同一サイズの3カラム(名前 / 手牌 / 正解)に揃える。
    // 各セルは幅・高さ固定で、あふれる中身だけセル内で縮小する。
    const cellH = 48.0;
    Widget cell(double width, Widget child) => SizedBox(
      width: width,
      height: cellH,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: child,
        ),
      ),
    );
    return Container(
      key: ValueKey('resultRow$seat'),
      width: 620,
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0B2B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: ok ? const Color(0xFF2E7D32) : const Color(0xFF7A2E2E),
        ),
      ),
      child: Row(
        children: [
          cell(
            120,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$mark ${windNames[view.seatWind(seat)]} ${p.names[seat]}'
                  '${p.riichi[seat] ? ' 立直' : ''}',
                  maxLines: 1,
                  style: TextStyle(
                    color: ok
                        ? const Color(0xFF81C784)
                        : const Color(0xFFEF9A9A),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      riichi
                          ? 'あなた:'
                          : 'あなた: ${ans == null ? '-' : catText(ans, actual: false)}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10.5,
                      ),
                    ),
                    // テンパイと答えた席は選んだ待ちも見せる(正解との見比べ用)
                    if (ans == 0 && _waitAns[seat].isNotEmpty) ...[
                      const SizedBox(width: 3),
                      for (final t in _waitAns[seat].toList()..sort())
                        Padding(
                          padding: const EdgeInsets.only(right: 1),
                          child: TileWidget(tile: t, width: 12),
                        ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          cell(
            280,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TileRow(
                  tiles: p.hands[seat],
                  tileWidth: 17,
                  doraKinds: doraKinds,
                ),
                if (p.melds[seat].isNotEmpty) ...[
                  const SizedBox(width: 6),
                  MeldRow(
                    melds: p.melds[seat],
                    tileWidth: 15,
                    ownerSeat: seat,
                    doraKinds: doraKinds,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: cellH,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '正解: ${catText(cat, actual: true)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                      if (cat == 0) ...[
                        const SizedBox(width: 4),
                        const Text(
                          '待ち',
                          style: TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                        const SizedBox(width: 3),
                        TileRow(
                          tiles: p.waits[seat],
                          tileWidth: 15,
                          doraKinds: doraKinds,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
