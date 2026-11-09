import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../engine/advisor.dart';
import '../engine/emotes.dart';
import '../engine/furiten_notice.dart';
import '../engine/display_text.dart';
import '../engine/models.dart';
import '../paifu/favorite_store.dart';
import '../paifu/replay_session.dart';
import '../engine/tile.dart';
import '../net/client.dart';
import '../net/protocol.dart';
import '../session/game_session.dart';
import '../session/suspend.dart';
import '../session/suspend_store.dart';
import 'suspend_screen.dart';
import 'widgets/advice_dialog.dart';
import 'widgets/guidebook.dart';
import 'widgets/rank_table.dart';
import 'widgets/result_overlay.dart';
import 'widgets/table_widgets.dart';
import 'widgets/tile_widget.dart';

class GameScreen extends StatefulWidget {
  final GameSession session;

  const GameScreen({super.key, required this.session});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  GameView? _view;
  TurnPrompt? _turnPrompt;
  ReactPrompt? _reactPrompt;
  bool _riichiMode = false;
  bool _connected = true;
  bool _reconnecting = false;
  bool _showScoreboard = false;
  bool _advanceAcked = false; // 局終了確認で自分が「次へ」を押したか
  bool _suspendHandled = false; // 中断処理済み(二重遷移防止)

  String? _banner;
  int _bannerSeat = -1; // 発生した席(相対位置の決定に使う。-1=中央)
  int _lastEventSerial = -1;
  bool _eventsPrimed = false; // 最初のビューのイベントを既読にしたか
  Timer? _bannerTimer;

  // フリテン表示: 他家が自分の当たり牌を捨てたがフリテンでロン不可の瞬間、
  // 進行を止めずにローカルで一瞬だけ表示する。
  bool _furitenFlash = false;
  Timer? _furitenTimer;
  bool _riversPrimed = false; // 最初のビューで河の長さの基準を作ったか
  List<int> _seenDiscardLens = const [0, 0, 0, 0];

  // 顔文字キャスト: 席 → 表示中の絵文字インデックス(数秒で自動消灯)
  final Map<int, int> _activeEmotes = {};
  final Map<int, Timer> _emoteTimers = {};

  final List<StreamSubscription<dynamic>> _subs = [];

  GameSession get session => widget.session;

  static Future<void> _setWakelock(bool on) async {
    // テスト環境などプラグインがない場合は無視する
    try {
      await (on ? WakelockPlus.enable() : WakelockPlus.disable());
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _setWakelock(true);
    // ☆(お気に入り局)の初期状態を出すために読み込んでおく
    FavoriteStore.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    _view = session.latestView;
    _turnPrompt = session.activeTurnPrompt;
    _reactPrompt = session.activeReactPrompt;
    _connected = session.isConnected;
    if (_view != null) _handleEvent(_view!);

    // 動作確認用: --dart-define=OPEN_RANK=true で順位表を自動で開く
    if (const bool.fromEnvironment('OPEN_RANK')) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted && _view != null) showRankTable(context, _view!);
      });
    }

    _subs.add(
      session.views.listen((v) {
        setState(() {
          // 局が進んだら確認済みフラグをリセット
          if (v.phase == 'playing') _advanceAcked = false;
          _view = v;
          _handleEvent(v);
          _checkFuriten(v);
        });
      }),
    );
    _subs.add(
      session.turnPrompts.listen((p) {
        setState(() {
          _turnPrompt = p;
          _reactPrompt = null;
          _riichiMode = false;
        });
      }),
    );
    _subs.add(
      session.reactPrompts.listen((p) {
        setState(() => _reactPrompt = p);
      }),
    );
    _subs.add(
      session.connectionState.listen((c) {
        setState(() => _connected = c);
      }),
    );
    _subs.add(session.emotes.listen(_onEmote));
    // ホストが中断した通知(クライアントのみ)。復帰情報を保存して中断画面へ。
    _subs.add(session.suspendNotices.listen(_onSuspended));
    // 観戦希望(ホストのみ)。許可/拒否のダイアログを出す。
    _subs.add(session.spectateRequests.listen(_onSpectateRequest));
  }

  Future<void> _onSuspended(SuspendNotice notice) async {
    if (_suspendHandled) return;
    _suspendHandled = true;
    // 観戦者は対局のメンバーではないので復帰情報は保存しない
    if (!notice.spectator && !session.isSpectator) {
      await SuspendStore.saveGuest(
        SuspendedGuestGame(
          roomName: notice.roomName,
          playerName: notice.playerName,
          savedAt: DateTime.now(),
        ),
      );
    }
    if (!mounted) return;
    final wasSpectator = notice.spectator || session.isSpectator;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => SuspendScreen(spectator: wasSpectator)),
    );
  }

  /// 観戦希望への許可/拒否(ホストのみ届く)
  Future<void> _onSpectateRequest(SpectateRequest req) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('観戦の希望'),
        content: Text('「${req.name}」さんが観戦(ギャラリー)を希望しています。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('拒否'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('許可'),
          ),
        ],
      ),
    );
    if (ok == true) {
      req.approve();
    } else {
      req.deny();
    }
  }

  void _handleEvent(GameView v) {
    final ev = v.lastEvent;
    // 最初のビューに乗っているイベントは入室前に起きた過去のもの
    // (再入室・観戦開始・復帰時に前局のロン等が残っている)なので、
    // 表示せずに既読だけにする。
    if (!_eventsPrimed) {
      _eventsPrimed = true;
      if (ev != null) _lastEventSerial = ev.serial;
      return;
    }
    if (ev == null || ev.serial == _lastEventSerial) return;
    _lastEventSerial = ev.serial;
    final text = switch (ev.type) {
      'pon' => 'ポン!',
      'chi' => 'チー!',
      'kan' => 'カン!',
      'riichi' => 'リーチ!',
      'tsumo' => 'ツモ!',
      'ron' => 'ロン!',
      'draw' => '流局',
      _ => null,
    };
    if (text == null) return;
    // 発生した席の近くに出すので、名前は入れない(位置で誰か分かる)。
    _banner = text;
    _bannerSeat = ev.seat;
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _banner = null);
    });
  }

  /// 他家が自分の当たり牌を捨てたが、フリテンでロンできない瞬間を検知して
  /// 「フリテン」を一瞬表示する。進行は一切止めない(純ローカル・非ブロッキング)。
  void _checkFuriten(GameView v) {
    // 最初のビューは基準の河の長さを覚えるだけ。再入室・復帰時に既に伸びた
    // 河を「新しい捨て牌」と誤認してフリテン表示が誤発火しないようにする。
    if (!_riversPrimed) {
      _riversPrimed = true;
      _seenDiscardLens = [for (final p in v.players) p.discards.length];
      return;
    }
    if (furitenNotice(prevDiscardLens: _seenDiscardLens, v: v)) {
      _furitenFlash = true;
      _furitenTimer?.cancel();
      _furitenTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) setState(() => _furitenFlash = false);
      });
    }
    _seenDiscardLens = [for (final p in v.players) p.discards.length];
  }

  /// 顔文字キャストを受信 → その席の近くに数秒表示する。
  void _onEmote(EmoteCast e) {
    setState(() => _activeEmotes[e.seat] = e.emoji);
    _emoteTimers[e.seat]?.cancel();
    _emoteTimers[e.seat] = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _activeEmotes.remove(e.seat));
    });
  }

  /// 顔文字パレット(3x3)を開いて選んだ表情を全席に送る。
  Future<void> _openEmotePalette() async {
    final idx = await showDialog<int>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.25),
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF0B2B14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF2E7D32)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: 232,
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (var i = 0; i < emoteFaces.length; i++)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.of(ctx).pop(i),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF14401F),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF2E7D32)),
                      ),
                      child: Text(
                        emoteFaces[i],
                        style: const TextStyle(fontSize: 34),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (idx != null) session.sendEmote(idx);
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _furitenTimer?.cancel();
    for (final t in _emoteTimers.values) {
      t.cancel();
    }
    for (final s in _subs) {
      s.cancel();
    }
    _setWakelock(false);
    session.dispose();
    super.dispose();
  }

  // ---------------- アクション ----------------

  void _discard(int tile, {bool riichi = false, bool fromDrawn = false}) {
    if (_turnPrompt == null) return;
    // タップ位置(手牌/ツモ牌)がツモ切りの正: 同じ牌をツモっていても
    // 手牌側をタップしたなら手出し(河でグレーにしない)
    session.sendTurn(
      TurnAction.discard(tile, riichi: riichi, tsumogiri: fromDrawn),
    );
    setState(() {
      _turnPrompt = null;
      _riichiMode = false;
    });
  }

  void _tsumo() {
    session.sendTurn(const TurnAction.tsumo());
    setState(() => _turnPrompt = null);
  }

  Future<void> _kan() async {
    final prompt = _turnPrompt;
    if (prompt == null) return;
    final options = <(String, int)>[
      for (final k in prompt.ankanKinds) ('ankan', k),
      for (final k in prompt.kakanKinds) ('kakan', k),
    ];
    (String, int)? chosen;
    if (options.length == 1) {
      chosen = options.first;
    } else {
      chosen = await _choose<(String, int)>(
        title: 'カンする牌',
        options: options,
        builder: (o) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TileWidget(tile: o.$2, width: 30),
            const SizedBox(width: 8),
            Text(o.$1 == 'ankan' ? '暗槓' : '加槓'),
          ],
        ),
      );
    }
    if (chosen == null) return;
    session.sendTurn(
      chosen.$1 == 'ankan'
          ? TurnAction.ankan(chosen.$2)
          : TurnAction.kakan(chosen.$2),
    );
    setState(() => _turnPrompt = null);
  }

  void _react(ReactAction action) {
    if (_reactPrompt == null) return;
    session.sendReact(action);
    setState(() => _reactPrompt = null);
  }

  Future<void> _chi() async {
    final prompt = _reactPrompt;
    if (prompt == null) return;
    List<int>? chosen;
    if (prompt.chiOptions.length == 1) {
      chosen = prompt.chiOptions.first;
    } else {
      chosen = await _choose<List<int>>(
        title: 'チーの形',
        options: prompt.chiOptions,
        builder: (o) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TileWidget(tile: prompt.tile, width: 30, highlighted: true),
            const SizedBox(width: 4),
            TileWidget(tile: o[0], width: 30),
            TileWidget(tile: o[1], width: 30),
          ],
        ),
      );
    }
    if (chosen == null) return;
    _react(ReactAction.chi(chosen));
  }

  Future<void> _pon() async {
    final prompt = _reactPrompt;
    if (prompt == null) return;
    final opts = prompt.ponOptions;
    // 赤の選択が無ければそのままポン(既定=赤温存)
    if (opts.length <= 1) {
      _react(ReactAction.pon(opts.isNotEmpty ? opts.first : const []));
      return;
    }
    final chosen = await _choose<List<int>>(
      title: 'ポンで晒す牌(赤の選択)',
      options: opts,
      builder: (o) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TileWidget(tile: prompt.tile, width: 30, highlighted: true),
          const SizedBox(width: 4),
          TileWidget(tile: o[0], width: 30),
          TileWidget(tile: o[1], width: 30),
        ],
      ),
    );
    if (chosen == null) return;
    _react(ReactAction.pon(chosen));
  }

  Future<T?> _choose<T>({
    required String title,
    required List<T> options,
    required Widget Function(T) builder,
  }) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o),
              child: builder(o),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmExit() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('対局から退出しますか?'),
        content: session.isHost
            ? const Text('ホストが退出すると部屋は解散されます。')
            : session.isSpectator
            ? const Text('観戦を終了します(対局は続きます)。')
            : const Text('退出後はCPUが代わりに打ちます(同じ名前で再入室できます)。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  /// 対局の中断(ホストのみ)。状況を保存して全員を中断画面へ送る。
  Future<void> _confirmSuspend() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('対局を中断しますか?'),
        content: const Text(
          '現在の状況を保存します。'
          'あとで「部屋を作る」の復帰ボタンから再開でき、'
          'ゲストは「部屋に入る」から合流し直せます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('中断する'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted || _suspendHandled) return;
    final saved = await session.suspend();
    if (saved == null) return;
    _suspendHandled = true;
    await SuspendStore.saveHost(saved);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => SuspendScreen(hostGame: saved)),
    );
  }

  /// 👻: ゴーストモードの範囲(観戦中プレイヤーだけ/全員)を選んで突入する。
  /// 全員ゴーストは手番・反応が来た席へ視点が切り替わり、全席を自分で打てる
  /// (「もしここでこれを切ったら」の検証用)。
  Future<void> _startGhost(ReplaySession replay) async {
    final everyone = await showDialog<bool>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('ゴーストモード'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('👻 観戦中プレイヤーだけゴースト'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('👻👻 全員ゴースト(全席を自分で操作)'),
          ),
        ],
      ),
    );
    if (everyone == null || !mounted) return;
    if (replay.enterGhost(everyone: everyone)) {
      setState(() {});
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ここからはゴーストモードを開始できません')));
    }
  }

  /// ゴーストの局結果パネル: 実際の牌譜の結果と今回の結果の比較、
  /// この突入点の試行分布、「もう一度ここから」(同じ局面からの打ち直し)。
  Widget _ghostComparePanel(ReplaySession replay) {
    final c = replay.ghostCompare!;
    String sign(int d) => formatSignedPoints(d);
    final tally = <String, int>{};
    for (final t in c.trials) {
      tally[t.outcome] = (tally[t.outcome] ?? 0) + 1;
    }
    const labels = [
      ('win', '和了'),
      ('dealIn', '放銃'),
      ('draw', '流局'),
      ('other', '他'),
    ];
    final tallyText = [
      for (final (key, label) in labels)
        if (tally[key] != null) '$label${tally[key]}',
    ].join(' ');
    return Container(
      width: 250,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '📜 実際: ${c.actualText}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          Text(
            '👻 今回: ${c.ghostText}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            '${c.youName}: 実際 ${sign(c.actualDelta)} / 今回 ${sign(c.ghostDelta)}',
            style: TextStyle(
              color: c.ghostDelta >= c.actualDelta
                  ? const Color(0xFF81C784)
                  : const Color(0xFFFFB74D),
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'この局面 ${c.trials.length}回: $tallyText',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 30,
            child: FilledButton.tonal(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: () => setState(() => replay.reenterGhost()),
              child: const Text('👻 もう一度ここから', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reconnect() async {
    final s = session;
    if (s is! ClientSession) return;
    setState(() => _reconnecting = true);
    try {
      await s.reconnect();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('再接続に失敗しました')));
      }
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  // ---------------- 描画 ----------------

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Scaffold(
      body: view == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;
                  final handW = min(w / 16.2, h / 6.2);
                  // 河牌はやや小さめにして、3段でも「対面河+パネル+自分河」の
                  // セット全体が縦に収まるようにする(手牌・壁とも重ならない)。
                  final riverW = h / 24;
                  // 中央パネルの基準幅(卓型レイアウト)。河が伸びても縮ませない
                  // ので、常に読みやすい大きめの固定サイズにする。
                  final centerScale = min(w * 0.36, h * 0.58);

                  return Stack(
                    children: [
                      // 左
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: RotatedBox(
                            quarterTurns: 1,
                            child: _seatArea(view, 3, riverW, showHidden: true),
                          ),
                        ),
                      ),
                      // 右
                      Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: _seatArea(view, 1, riverW, showHidden: true),
                          ),
                        ),
                      ),
                      // 中央: 「対面の河 → 中央パネル → 自分の河」をひとつのセットと
                      // して手牌の上の領域に垂直中央寄せする。OverflowBox で高さ制約を
                      // 外すため、河がどれだけ伸びてもセットごと広がるだけで、パネルは
                      // 一切縮まない(左右の河とも重ならない)。
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        bottom: handW * TileWidget.aspect + 12,
                        child: OverflowBox(
                          minHeight: 0,
                          maxHeight: double.infinity,
                          alignment: Alignment.center,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              RotatedBox(
                                quarterTurns: 2,
                                child: _seatArea(
                                  view,
                                  2,
                                  riverW,
                                  showHidden: true,
                                ),
                              ),
                              SizedBox(height: riverW * 0.25),
                              GestureDetector(
                                onTap: () => showRankTable(context, view),
                                child: CenterPanel(
                                  view: view,
                                  scale: centerScale,
                                ),
                              ),
                              SizedBox(height: riverW * 0.25),
                              _seatArea(view, 0, riverW, showHidden: false),
                            ],
                          ),
                        ),
                      ),
                      // 自分の手牌
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: _myHand(view, handW),
                        ),
                      ),
                      // アクションボタン。
                      // リーチ選択中は候補牌の上に待ち表示が出るので、その高さぶん
                      // ボタンを持ち上げて重ならないようにする(_riichiWaitLabel の
                      // ミニ牌+残り枚数の高さ ≒ handW * 1.2)。
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: EdgeInsets.only(
                            bottom:
                                handW * TileWidget.aspect +
                                14 +
                                (_riichiMode ? handW * 1.2 : 0),
                            right: 8,
                          ),
                          child: _actionBar(view),
                        ),
                      ),
                      // 退出ボタン
                      Positioned(
                        top: 2,
                        left: 2,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white38),
                          onPressed: _confirmExit,
                        ),
                      ),
                      // 総合成績表ボタン
                      Positioned(
                        top: 2,
                        right: 2,
                        child: IconButton(
                          icon: const Icon(
                            Icons.leaderboard,
                            color: Colors.white38,
                          ),
                          tooltip: '総合成績表',
                          onPressed: () =>
                              setState(() => _showScoreboard = true),
                        ),
                      ),
                      // 中断ボタン(ホストのみ。状況を保存してあとで復帰できる)
                      if (session.isHost)
                        Positioned(
                          top: 2,
                          right: 50,
                          child: IconButton(
                            icon: const Icon(
                              Icons.pause_circle_outline,
                              color: Colors.white38,
                            ),
                            tooltip: '対局を中断',
                            onPressed: _confirmSuspend,
                          ),
                        ),
                      // 観戦中: ガイドボタンと観戦表示(操作はこれと点数確認のみ)
                      if (session.isSpectator) ...[
                        Positioned(
                          top: 2,
                          right: session.isHost ? 98 : 50,
                          child: IconButton(
                            icon: const Icon(
                              Icons.menu_book,
                              color: Colors.white38,
                            ),
                            tooltip: '早見表',
                            onPressed: () => showGuidebook(context),
                          ),
                        ),
                        Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            margin: const EdgeInsets.only(top: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '観戦中: ${view.players[view.youSeat].name} の視点',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                      // イベントバナー(リーチ・ポン等)。発生した席の近くに出す。
                      if (_banner != null)
                        Align(
                          alignment: _bannerAlignment(
                            _bannerSeat,
                            view.youSeat,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: const Color(0xFFFFC400),
                              ),
                            ),
                            child: Text(
                              _banner!,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFFFC400),
                              ),
                            ),
                          ),
                        ),
                      // フリテン表示(自分の当たり牌が出たがロン不可)。自席側に一瞬。
                      if (_furitenFlash)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: EdgeInsets.only(
                              bottom: handW * TileWidget.aspect + 20,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFB71C1C),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: const Color(0xFFFF8A80),
                                ),
                              ),
                              child: const Text(
                                'フリテン',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      // 結果オーバーレイ(観戦者は確認ボタンを持たない=押し済み扱い)
                      if (view.phase == 'handEnd' && view.handResult != null)
                        HandResultOverlay(
                          view: view,
                          acked: _advanceAcked || session.isSpectator,
                          onAdvance: () {
                            session.advance();
                            setState(() => _advanceAcked = true);
                          },
                        ),
                      if (view.phase == 'gameEnd' && view.gameResult != null)
                        GameResultOverlay(
                          view: view,
                          isHost: session.isHost,
                          onNextGame: session.nextGame,
                          matchLabel: switch (session) {
                            ReplaySession(:final matchLabel) => matchLabel,
                            _ => null,
                          },
                          onExit: () =>
                              Navigator.of(context).popUntil((r) => r.isFirst),
                        ),
                      // 顔文字キャスト(各プレイヤーの牌姿の近く・結果画面より前面)
                      ..._emoteBubbles(view),
                      // 牌譜再生中: 左上に局シーク・ポーズ・一手送り、右に☆(お気に入り局)。
                      // ポーズ中でも局結果・試合結果のオーバーレイ越しに操作できるよう、
                      // オーバーレイより前面(Stackの後ろ)に置く。
                      if (session case final ReplaySession replay
                          when replay.isGhost) ...[
                        // ゴーストモード中: 操作ボタンの代わりにチップ表示
                        Positioned(
                          top: 8,
                          left: 50,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Text(
                              replay.isGhostEveryone
                                  ? '👻全員ゴーストモード中'
                                  : '👻ゴーストモード中',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                        // ゴーストの局結果: 実際の牌譜の結果との比較と打ち直し
                        if (view.phase == 'handEnd' &&
                            replay.ghostCompare != null)
                          Positioned(
                            left: 8,
                            bottom: 8,
                            child: _ghostComparePanel(replay),
                          ),
                      ] else if (session case final ReplaySession replay) ...[
                        Positioned(
                          top: 2,
                          right: 98,
                          child: IconButton(
                            icon: Icon(
                              FavoriteStore.contains(replay.currentKyokuKey)
                                  ? Icons.star
                                  : Icons.star_border,
                              color:
                                  FavoriteStore.contains(replay.currentKyokuKey)
                                  ? const Color(0xFFFFD54F)
                                  : Colors.white38,
                            ),
                            tooltip: 'お気に入り局',
                            onPressed: () async {
                              await FavoriteStore.toggle(
                                replay.currentKyokuKey,
                              );
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                        Positioned(
                          top: 2,
                          left: 50,
                          child: IconButton(
                            icon: const Icon(
                              Icons.skip_previous,
                              color: Colors.white38,
                            ),
                            tooltip: '一局戻す',
                            onPressed: replay.prevKyoku,
                          ),
                        ),
                        Positioned(
                          top: 2,
                          left: 98,
                          child: IconButton(
                            icon: Icon(
                              replay.isPaused ? Icons.play_arrow : Icons.pause,
                              color: replay.isPaused
                                  ? const Color(0xFFFFD54F)
                                  : Colors.white38,
                            ),
                            tooltip: replay.isPaused ? '自動再生' : 'ポーズ',
                            onPressed: () => setState(replay.togglePause),
                          ),
                        ),
                        Positioned(
                          top: 2,
                          left: 146,
                          child: IconButton(
                            icon: const Icon(
                              Icons.skip_next,
                              color: Colors.white38,
                            ),
                            tooltip: '一局進む',
                            onPressed: replay.nextKyoku,
                          ),
                        ),
                        // ポーズ中のみ: 一手戻し/一手進み(横幅が足りないので二段目)と、
                        // 少し離して👻(ゴーストモード=この手巡から自分で打つ)
                        if (replay.isPaused) ...[
                          Positioned(
                            top: 50,
                            left: 74,
                            child: IconButton(
                              icon: const Icon(
                                Icons.chevron_left,
                                color: Colors.white38,
                              ),
                              tooltip: '一手戻す',
                              onPressed: replay.stepBack,
                            ),
                          ),
                          Positioned(
                            top: 50,
                            left: 122,
                            child: IconButton(
                              icon: const Icon(
                                Icons.chevron_right,
                                color: Colors.white38,
                              ),
                              tooltip: '一手進む',
                              onPressed: replay.stepForward,
                            ),
                          ),
                          Positioned(
                            top: 50,
                            left: 210,
                            child: IconButton(
                              icon: const Text(
                                '👻',
                                style: TextStyle(fontSize: 20),
                              ),
                              tooltip: 'ゴーストモード(この手巡から自分で打つ)',
                              onPressed: () => _startGhost(replay),
                            ),
                          ),
                        ],
                      ],
                      // 総合成績表(いつでも開ける・最前面)
                      if (_showScoreboard)
                        ScoreboardOverlay(
                          view: view,
                          onClose: () =>
                              setState(() => _showScoreboard = false),
                        ),
                      // 切断オーバーレイ(クライアントのみ)
                      if (!_connected) _disconnectedOverlay(),
                    ],
                  );
                },
              ),
            ),
    );
  }

  /// イベントバナー(リーチ・ポン等)を出す位置。発生席の相対位置に寄せる。
  /// 同席で顔文字も出る(リーチ時のドヤ顔など)ので、顔文字と重ならないよう
  /// 各席で明確にずらす。参考: 顔文字の位置は
  ///   自分(-0.5,0.52) 下家(0.85,0.02) 対面(0.0,-0.74) 上家(-0.85,0.02)。
  /// 席が -1(流局など特定の席が無い場合)は中央。
  Alignment _bannerAlignment(int seat, int youSeat) {
    if (seat < 0) return const Alignment(0.0, -0.15);
    return switch ((seat - youSeat + 4) % 4) {
      // 自分: 顔文字は左下。バナーは右下にずらす
      0 => const Alignment(0.45, 0.52),
      // 下家(右): 顔文字は右の中段。バナーは右の上段へ
      1 => const Alignment(0.85, -0.45),
      // 対面(上): 顔文字は上の横中央。バナーは横を左へずらす
      2 => const Alignment(-0.5, -0.62),
      // 上家(左): 顔文字は左の中段。バナーは左の上段へ
      _ => const Alignment(-0.85, -0.45),
    };
  }

  /// 各席の顔文字キャストを、そのプレイヤーの牌姿の近くに表示する。
  List<Widget> _emoteBubbles(GameView view) {
    return [
      for (final entry in _activeEmotes.entries)
        Align(
          alignment: switch ((entry.key - view.youSeat + 4) % 4) {
            0 => const Alignment(-0.5, 0.52), // 自分(下・左寄せで手牌/ボタンを避ける)
            1 => const Alignment(0.85, 0.02), // 下家(右)
            2 => const Alignment(0.0, -0.74), // 対面(上)
            _ => const Alignment(-0.85, 0.02), // 上家(左)
          },
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0x66FFFFFF)),
            ),
            child: Text(
              entry.value >= 0 && entry.value < emoteFaces.length
                  ? emoteFaces[entry.value]
                  : '',
              style: const TextStyle(fontSize: 44),
            ),
          ),
        ),
    ];
  }

  Widget _seatArea(
    GameView view,
    int rel,
    double riverW, {
    required bool showHidden,
  }) {
    final seat = (view.youSeat + rel) % 4;
    final react = _reactPrompt;
    return SeatArea(
      player: view.players[seat],
      seat: seat,
      riverTileWidth: riverW,
      showHiddenHand: showHidden,
      doraKinds: TileWidget.doraKindsFrom(view.doraIndicators),
      highlightTile: react != null && react.fromSeat == seat
          ? react.tile
          : null,
    );
  }

  Widget _myHand(GameView view, double tileW) {
    final prompt = _turnPrompt;
    final myTurn = prompt != null;
    final doraKinds = TileWidget.doraKindsFrom(view.doraIndicators);
    // 他家リーチ時、手牌の現物牌種。守備アドバイスと基準をそろえた2段階:
    // 濃い青=全脅威(リーチ+危険な鳴き)に100%通る / 薄い青=リーチにだけは通る
    final genbutsu = genbutsuTiersInHand(view);

    // 最も攻撃的な打牌(最良シャンテン維持+ウケ最大、テンパイなら待ち最広)を
    // 赤く光らせる。リーチ選択中(黄枠)・リーチ後(ツモ切りのみ)は出さない。
    int? attackTile;
    if (myTurn && !_riichiMode && !prompt.riichiLocked) {
      final t = attackGlowTile(view);
      // 喰い替え禁止で切れない牌は光らせない
      if (t != null && !prompt.forbiddenDiscards.contains(Tile.normalize(t))) {
        attackTile = t;
      }
    }

    // リーチ選択中は、切る牌ごとに待ちが変わるので候補牌の上に待ちを表示する。
    // 牌種 → その牌を切ったときの待ち。
    final riichiWaits = <int, WaitOption>{};
    if (_riichiMode) {
      for (final o in tenpaiWaits(view)) {
        if (o.discard != null) {
          riichiWaits.putIfAbsent(Tile.normalize(o.discard!), () => o);
        }
      }
    }

    bool isForbidden(int tile) =>
        myTurn && prompt.forbiddenDiscards.contains(Tile.normalize(tile));

    bool canDiscard(int tile, bool isDrawn) {
      if (!myTurn) return false;
      if (prompt.riichiLocked && !isDrawn) return false;
      if (_riichiMode && !prompt.riichiTiles.contains(tile)) return false;
      if (prompt.forbiddenDiscards.contains(Tile.normalize(tile))) {
        return false;
      }
      return true;
    }

    Widget tileButton(int tile, {bool isDrawn = false}) {
      final enabled = canDiscard(tile, isDrawn);
      final wait = _riichiMode ? riichiWaits[Tile.normalize(tile)] : null;
      final forbidden = isForbidden(tile);
      return GestureDetector(
        onTap: enabled
            ? () => _discard(tile, riichi: _riichiMode, fromDrawn: isDrawn)
            : null,
        // 待ち表示は牌の上へのオーバーレイ(clipなしStack)。Columnに積むと
        // ラベル幅が列幅を押し広げ、候補が多い小画面で手牌Rowが右にあふれる。
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 縦位置は常に固定。手番になった瞬間に持ち上げると手牌全体が上へ
            // ずれて、切ろうとしていた牌が動いてしまう(誤タップの原因)。
            // 手番・打てる/打てないは色(ツモ=緑/禁止=灰/現物=青)と操作ボタンで示す。
            TileWidget(
              tile: tile,
              width: tileW,
              // 喰い替え禁止は薄い灰色で示すので、二重に暗くはしない
              dimmed: myTurn && !enabled && !forbidden,
              highlighted: _riichiMode && enabled,
              drawn: isDrawn, // ツモ牌 → 緑の点滅
              forbidden: forbidden, // 切れない牌 → 薄い灰色
              // 現物 → 青の点滅(全脅威に通る=濃い/リーチにのみ現物=薄い)
              glowSafe: genbutsu.strong.contains(Tile.normalize(tile)),
              glowSafeFaint: genbutsu.faint.contains(Tile.normalize(tile)),
              // 最攻撃打牌 → 赤の点滅。濃い青(現物)と同時なら攻守一致の
              // 回転ボーダー、薄い青と同時なら赤優先(TileWidget側で解決)
              glowAttack: attackTile != null && tile == attackTile,
              dora: doraKinds.contains(Tile.normalize(tile)),
            ),
            if (wait != null)
              Positioned(
                bottom: tileW * TileWidget.aspect + tileW * 0.08,
                left: tileW / 2,
                // 牌の中心に合わせてラベルを中央寄せ
                child: FractionalTranslation(
                  translation: const Offset(-0.5, 0),
                  child: _riichiWaitLabel(wait, tileW),
                ),
              ),
          ],
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end, // 牌の下端をそろえる
      children: [
        for (final t in view.hand)
          Padding(
            padding: EdgeInsets.only(right: tileW * 0.055),
            child: tileButton(t),
          ),
        // ツモ牌の枠は常に確保する。ツモ牌の有無で手牌の中央寄せ位置がずれると、
        // 切ろうとしていた牌が動いて誤タップの原因になるため。
        SizedBox(width: tileW * 0.4),
        if (view.drawnTile != null)
          tileButton(view.drawnTile!, isDrawn: true)
        else
          SizedBox(width: tileW), // ツモ牌ぶんの空き
      ],
    );
  }

  /// リーチ選択中、候補牌の上に出す待ち表示(待ち牌のミニ画像 + 残り枚数)。
  /// オーバーレイ表示なので幅は牌からはみ出せるが、隣の候補のラベルと
  /// 重なりすぎないよう上限を付けて折り返す。
  Widget _riichiWaitLabel(WaitOption wait, double tileW) {
    final miniW = tileW * 0.5;
    return Container(
      constraints: BoxConstraints(maxWidth: tileW * 2.2),
      padding: EdgeInsets.symmetric(
        horizontal: tileW * 0.06,
        vertical: tileW * 0.04,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0x66FFD54F)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 1,
            runSpacing: 1,
            alignment: WrapAlignment.center,
            children: [
              for (final w in wait.tiles) TileWidget(tile: w, width: miniW),
            ],
          ),
          SizedBox(height: tileW * 0.03),
          Text(
            '残${wait.total}',
            style: TextStyle(
              color: const Color(0xFFFFCC80),
              fontSize: tileW * 0.24,
              fontWeight: FontWeight.bold,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionBar(GameView view) {
    // 観戦中は打牌等のプロンプトが届かないうえ、顔文字も出せない
    // (許可されるのは中央パネルの点数確認とガイド表示のみ)
    if (session.isSpectator) return const SizedBox.shrink();
    final turn = _turnPrompt;
    final react = _reactPrompt;
    final buttons = <Widget>[];

    if (turn != null) {
      // 自分の打牌前(ツモ後・鳴いた直後)にアドバイスを出せる
      if (!_riichiMode) {
        buttons.add(
          _actionButton(
            '💡',
            const Color(0xFF37474F),
            () => showAdviceDialog(context, view),
          ),
        );
      }
      if (turn.canTsumo) {
        buttons.add(_actionButton('ツモ', const Color(0xFFD84315), _tsumo));
      }
      if (turn.ankanKinds.isNotEmpty || turn.kakanKinds.isNotEmpty) {
        buttons.add(_actionButton('カン', const Color(0xFF5D4037), _kan));
      }
      if (turn.riichiTiles.isNotEmpty && !_riichiMode) {
        buttons.add(
          _actionButton(
            'リーチ',
            const Color(0xFFC62828),
            () => setState(() => _riichiMode = true),
          ),
        );
      }
      if (_riichiMode) {
        buttons.add(
          _actionButton(
            'キャンセル',
            const Color(0xFF455A64),
            () => setState(() => _riichiMode = false),
          ),
        );
      }
    } else if (react != null) {
      if (react.canRon) {
        buttons.add(
          _actionButton(
            'ロン',
            const Color(0xFFD84315),
            () => _react(const ReactAction.ron()),
          ),
        );
      }
      if (react.canPon) {
        buttons.add(_actionButton('ポン', const Color(0xFF6A1B9A), _pon));
      }
      if (react.canKan) {
        buttons.add(
          _actionButton(
            'カン',
            const Color(0xFF5D4037),
            () => _react(const ReactAction.kan()),
          ),
        );
      }
      if (react.chiOptions.isNotEmpty) {
        buttons.add(_actionButton('チー', const Color(0xFF00695C), _chi));
      }
      buttons.add(
        _actionButton(
          'パス',
          const Color(0xFF455A64),
          () => _react(const ReactAction.pass()),
        ),
      );
    }

    // 顔文字ボタン(常に一番右・いつでも押せる)
    buttons.add(
      _actionButton('😀', const Color(0xFF00695C), _openEmotePalette),
    );

    return Wrap(spacing: 8, children: buttons);
  }

  Widget _actionButton(String label, Color color, VoidCallback onPressed) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }

  Widget _disconnectedOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.7),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'ホストとの接続が切れました',
              style: TextStyle(fontSize: 20, color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              '接続が戻るまではCPUが代わりに打ちます',
              style: TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: _reconnecting ? null : _reconnect,
                  child: Text(_reconnecting ? '再接続中…' : '再接続'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () =>
                      Navigator.of(context).popUntil((r) => r.isFirst),
                  child: const Text('退出'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
