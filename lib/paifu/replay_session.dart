/// Mリーグ牌譜の自動再生セッション。
///
/// 牌譜DBのイベント列を [GameView] に変換して観戦モードの対局画面
/// ([GameScreen]) にそのまま流す。操作(打牌・鳴き)のプロンプトは一切
/// 発行しないので、UIは自然に観戦表示になる。
library;

import 'dart:async';

import '../engine/models.dart';
import '../engine/display_text.dart';
import '../engine/paifu_record.dart';
import '../engine/tile.dart';
import '../engine/yaku.dart';
import '../net/protocol.dart';
import '../session/game_session.dart';
import '../session/suspend.dart';
import 'ghost.dart';
import 'ghost_trial_store.dart';
import 'kyoku_state.dart';
import 'paifu_db.dart';

/// ゴーストの局結果と実際の牌譜の結果の比較(局終了時のパネル表示用)。
class GhostCompare {
  final String actualText; // 実際の結果の要約(例 'A ツモ 12000点')
  final int actualDelta; // 観戦席の実際の点数増減
  final String ghostText; // 今回(ゴースト)の結果の要約
  final int ghostDelta; // 観戦席の今回の点数増減
  final String youName; // 観戦席の選手名
  final List<GhostTrial> trials; // この突入点の試行履歴(今回含む)

  const GhostCompare({
    required this.actualText,
    required this.actualDelta,
    required this.ghostText,
    required this.ghostDelta,
    required this.youName,
    required this.trials,
  });
}

class ReplaySession implements GameSession {
  final PaifuSource _db;
  final int gameId;

  @override
  final int youSeat; // 観戦する選手の席(1局目の東南西北順)

  /// 結果画面のタイトルに使う試合名(例: '第2試合(B卓)')
  final String matchLabel;

  /// Mリーグ公式試合ID(お気に入り局キーの一部)
  final String mLeagueGameId;

  /// 遅延の倍率(1.0=標準。テストは 0 で即時再生)
  final double speed;

  /// ゴーストモードの乱数シード(テストの決定性用。通常は null)
  final int? ghostSeed;

  /// 再生を開始する局(kyokus のインデックス)。読みクイズの
  /// 「ビューアで再生」など、特定の局へ直接飛んで開くときに使う。
  final int startKyoku;

  final _views = StreamController<GameView>.broadcast();
  final _turnPrompts = StreamController<TurnPrompt>.broadcast();
  final _reactPrompts = StreamController<ReactPrompt>.broadcast();

  @override
  GameView? latestView;

  bool _disposed = false;

  // --- 試合を通じた状態 ---
  late final List<PaifuPlayer> _players; // 席順(0..3)
  late final Map<int, int> _seatOf; // playerId → 席
  List<int> _scores = [25000, 25000, 25000, 25000];
  final _stats = GameStats.zero();
  int _eventSerial = 0;

  // --- 局中の状態(牌の動きは共有部品 KyokuTileState が持つ) ---
  late KyokuTileState _ks;
  int _sticks = 0;
  int _honba = 0;
  int _dealer = 0;
  int _roundWind = 0;
  int _kyokuNumber = 1;
  GameEvent? _lastEvent;

  // --- 局シーク(◀▶) ---
  int _kyokuIndex = 0; // 再生中の局(kyokus のインデックス)
  int? _pendingJump; // 飛び先の局インデックス(kyokus.length=終局)
  Completer<void>? _wake; // 再生待ちの中断用

  // --- 手動再生(ポーズ・一手送り) ---
  bool _paused = false;
  bool _stepOnce = false; // ポーズ中に1イベントだけ通す
  int _stepCount = 0; // その局で適用済みの手数(一手戻しの基準)
  int? _stepTarget; // 局を再生し直すときの早送り先(この手数までは無表示)
  Completer<void>? _pauseWake; // ポーズ解除・一手送りの待ち受け

  // --- ゴーストモード(👻) ---
  GhostRun? _ghost;
  GameView? _ghostBaseView; // 突入時のポーズ位置ビュー(終了時に戻す)
  bool _ghostCaughtUp = false; // 早送り再現がポーズ位置に追いついたか
  final List<StreamSubscription<dynamic>> _ghostSubs = [];
  List<PaifuEvent> _kyokuEventList = const [];
  PaifuKyoku? _currentKyokuInfo;
  List<int> _kyokuStartScores = const [25000, 25000, 25000, 25000];
  int _appliedEvents = 0; // 局イベント列の適用済み数(=ポーズ位置のカットオフ)
  bool _ghostEveryone = false; // 再突入(もう一度ここから)用に控える
  int _ghostCutoff = 0;
  bool _ghostResultSeen = false; // 局結果の記録は1回だけ
  ({String text, int delta})? _ghostActual; // 実際の牌譜の結果の要約

  /// ゴーストの局結果と実際の結果の比較。局終了(handEnd)の記録後に入り、
  /// ゴースト終了で消える。UIはこれが非nullの間だけ比較パネルを出す。
  GhostCompare? ghostCompare;

  ReplaySession({
    required PaifuSource db,
    required this.gameId,
    required this.youSeat,
    this.matchLabel = '',
    this.mLeagueGameId = '',
    this.speed = 1,
    this.ghostSeed,
    this.startKyoku = 0,
  })
    // ignore: prefer_initializing_formals
    : _db = db {
    _players = _db.gamePlayers(gameId);
    _seatOf = {for (var i = 0; i < _players.length; i++) _players[i].id: i};
    _ks = KyokuTileState(_seatOf);
  }

  /// 再生を開始する(dispose まで自走)。
  Future<void> run() async {
    final kyokus = _db.kyokus(gameId);
    var i = startKyoku < 0 ? 0 : startKyoku;
    while (!_disposed) {
      if (i >= kyokus.length) {
        _emitGameEnd();
        await _waitForJump(); // 結果画面のまま ◀ での戻りを待つ
      } else {
        _kyokuIndex = i;
        // 局開始時の点数・スタッツはDBの記録から引き直す
        // (シークしても正しくつながり、二重加算もしない)
        _scores = i == 0
            ? [25000, 25000, 25000, 25000]
            : _seatScores(_db.kyokuEndScores(kyokus[i - 1].id));
        _loadStats(beforeKyokuId: kyokus[i].id);
        await _playKyoku(kyokus[i]);
      }
      if (_disposed) return;
      final jump = _pendingJump;
      if (jump != null) {
        _pendingJump = null;
        i = jump.clamp(0, kyokus.length);
      } else {
        i++;
      }
    }
  }

  /// 表示中の局のお気に入りキー(m_league_game_id|round|honba)
  String get currentKyokuKey =>
      '$mLeagueGameId|${_roundWind + 1}z$_kyokuNumber|$_honba';

  /// 一局進む。最終局なら終局して結果画面へ。
  void nextKyoku() {
    if (_ghost != null) return;
    _stepTarget = null;
    _requestJump(_kyokuIndex + 1);
  }

  /// 一局戻す。最初の一巡(4回目のツモまで)なら前局へ、それ以降なら局の最初へ。
  void prevKyoku() {
    if (_ghost != null) return;
    _stepTarget = null;
    _requestJump(_ks.drawCount <= 4 ? _kyokuIndex - 1 : _kyokuIndex);
  }

  /// ポーズ中かどうか(一手送りボタンの表示に使う)
  bool get isPaused => _paused;

  /// 自動再生⇄ポーズを切り替える。
  void togglePause() {
    if (_disposed || _ghost != null) return;
    _paused = !_paused;
    _stepOnce = false;
    _wakeDelay(); // 進行中の遅延を切り上げて、次のゲートで即座に止める/動かす
    _wakeGate();
  }

  /// 一手進める(ポーズ中のみ)。
  void stepForward() {
    if (_disposed || !_paused || _ghost != null) return;
    _stepOnce = true;
    _wakeGate();
  }

  /// 一手戻す(ポーズ中のみ)。局頭では前局の結果表示まで戻る。
  void stepBack() {
    if (_disposed || !_paused || _ghost != null) return;
    _stepOnce = false;
    if (_stepCount > 0) {
      _stepTarget = _stepCount - 1;
      _requestJump(_kyokuIndex);
    } else if (_kyokuIndex > 0) {
      _stepTarget = 1 << 30; // 前局の最後(結果表示)で止める
      _requestJump(_kyokuIndex - 1);
    }
  }

  // ---------------- ゴーストモード(👻) ----------------

  /// ゴーストモード(乗り移り)中か
  bool get isGhost => _ghost != null;

  /// 全員ゴースト(全席を自分で操作)中か
  bool get isGhostEveryone => _ghost?.everyone ?? false;

  /// ゴーストモードへ突入する(ポーズ中の対局中のみ)。
  /// この手巡から局が終わるまで、観戦対象の席([everyone] なら全席)を
  /// 自分で打てる。牌譜が欠損している局などで開始できない場合は false。
  bool enterGhost({bool everyone = false}) {
    if (_disposed || _ghost != null || !_paused) return false;
    final base = latestView;
    final k = _currentKyokuInfo;
    if (base == null || base.phase != 'playing' || k == null) return false;
    final GhostRun ghost;
    try {
      ghost = GhostRun(
        events: _kyokuEventList,
        cutoff: _appliedEvents,
        seatOf: _seatOf,
        names: [for (final p in _players) p.name],
        youSeat: youSeat,
        everyone: everyone,
        dealer: _dealer,
        roundWind: _roundWind,
        kyoku: _kyokuNumber,
        honba: _honba,
        riichiSticks: k.reachSticks,
        scores: _kyokuStartScores,
        baseWallRemaining: base.wallRemaining,
        baseDiscards: base.players.fold(0, (n, p) => n + p.discards.length),
        statWins: [..._stats.wins],
        statRiichis: [..._stats.riichis],
        statDealIns: [..._stats.dealIns],
        seed: ghostSeed,
        cpuThinkMillis: speed == 0 ? 0 : 550,
        autoPlayDelayMs: (250 * speed).round(),
        // 自動再生(ツモ250ms+打牌650ms)と同程度の体感になるウェイト
        scriptActionDelayMs: (650 * speed).round(),
      );
    } catch (_) {
      return false; // 配牌欠損などで再構成できない局
    }
    _ghost = ghost;
    _ghostBaseView = base;
    _ghostCaughtUp = false;
    _ghostEveryone = everyone;
    _ghostCutoff = _appliedEvents;
    _ghostResultSeen = false;
    ghostCompare = null;
    _ghostActual = _actualResultSummary(k);
    _ghostSubs.add(ghost.views.listen(_onGhostView));
    _ghostSubs.add(
      ghost.turnPrompts.listen((p) {
        if (!_turnPrompts.isClosed) _turnPrompts.add(p);
      }),
    );
    _ghostSubs.add(
      ghost.reactPrompts.listen((p) {
        if (!_reactPrompts.isClosed) _reactPrompts.add(p);
      }),
    );
    ghost.start();
    return true;
  }

  /// ゴーストのビュー。突入点(ポーズ位置)までの早送り再現は表示しない。
  void _onGhostView(GameView v) {
    if (_disposed || _ghost == null) return;
    if (!_ghostCaughtUp) {
      final base = _ghostBaseView!;
      int discards(GameView g) =>
          g.players.fold(0, (n, p) => n + p.discards.length);
      if (v.wallRemaining < base.wallRemaining ||
          (v.wallRemaining == base.wallRemaining &&
              discards(v) >= discards(base))) {
        _ghostCaughtUp = true;
      } else {
        return;
      }
    }
    if (v.phase == 'handEnd' && v.handResult != null && !_ghostResultSeen) {
      _ghostResultSeen = true;
      unawaited(_recordGhostResult(v));
    }
    latestView = v;
    if (!_views.isClosed) _views.add(v);
  }

  /// 実際の牌譜の結果の要約(誰が何点で和了したか・観戦席の増減)。
  /// 点数はDB記録の局終了時点数から引く(供託・本場・積み棒込みで一致する)。
  ({String text, int delta}) _actualResultSummary(PaifuKyoku k) {
    final end = _seatScores(_db.kyokuEndScores(k.id));
    final delta = end[youSeat] - _kyokuStartScores[youSeat];
    final parts = <String>[];
    for (final ev in _kyokuEventList) {
      switch (ev.type) {
        case 'ron' || 'tsumo':
          parts.add(
            winSummary(
              name: _players[_seatOf[ev.actorPlayerId]!].name,
              isTsumo: ev.type == 'tsumo',
              points: ev.points ?? 0,
            ),
          );
        case 'ryukyoku':
          parts.add('流局');
      }
    }
    return (text: parts.isEmpty ? '記録なし' : parts.join(' / '), delta: delta);
  }

  /// ゴーストの局結果を分類して試行として保存し、比較([ghostCompare])を出す。
  Future<void> _recordGhostResult(GameView v) async {
    final r = v.handResult!;
    final delta = r.scoreChanges[youSeat];
    final String outcome;
    final String text;
    if (r.type == 'win') {
      outcome = r.wins.any((w) => w.seat == youSeat)
          ? 'win'
          : r.wins.any((w) => w.fromSeat == youSeat)
          ? 'dealIn'
          : 'other';
      text = [
        for (final w in r.wins)
          winSummary(
            name: _players[w.seat].name,
            isTsumo: w.isTsumo,
            points: w.points,
          ),
      ].join(' / ');
    } else {
      outcome = 'draw';
      text = '流局';
    }
    final key = '$currentKyokuKey|$_ghostCutoff';
    final trial = GhostTrial(outcome, delta);
    List<GhostTrial> trials;
    try {
      await GhostTrialStore.add(key, trial);
      trials = GhostTrialStore.trialsFor(key);
    } catch (_) {
      trials = [trial]; // 保存できなくても今回分の比較は出す
    }
    if (_disposed || _ghost == null) return; // 保存中にゴーストを抜けた
    final actual = _ghostActual;
    ghostCompare = GhostCompare(
      actualText: actual?.text ?? '記録なし',
      actualDelta: actual?.delta ?? 0,
      ghostText: text,
      ghostDelta: delta,
      youName: _players[youSeat].name,
      trials: trials,
    );
    // 比較パネルを描かせるため、結果ビューをもう一度流す
    final lv = latestView;
    if (lv != null && lv.phase == 'handEnd' && !_views.isClosed) {
      _views.add(lv);
    }
  }

  /// 同じ突入点からもう一度打ち直す(ゴースト局結果の「もう一度ここから」)。
  /// ポーズ位置は動いていないので、いったん牌譜に戻って即再突入する。
  bool reenterGhost() {
    if (_ghost == null) return false;
    final everyone = _ghostEveryone;
    _exitGhost();
    return enterGhost(everyone: everyone);
  }

  /// ゴースト終了: 結果は捨てて、突入時のポーズ位置(牌譜どおりの状態)へ戻る。
  void _exitGhost() {
    for (final s in _ghostSubs) {
      s.cancel();
    }
    _ghostSubs.clear();
    _ghost?.dispose();
    _ghost = null;
    ghostCompare = null;
    _ghostActual = null;
    final v = _ghostBaseView;
    _ghostBaseView = null;
    if (v != null && !_disposed) {
      latestView = v;
      if (!_views.isClosed) _views.add(v);
    }
  }

  void _requestJump(int target) {
    if (_disposed) return;
    _pendingJump = target < 0 ? 0 : target;
    _wakeDelay();
    _wakeGate();
  }

  void _wakeDelay() {
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _wakeGate() {
    final g = _pauseWake;
    if (g != null && !g.isCompleted) g.complete();
  }

  /// ポーズ中はここで止まる。一手送り(_stepOnce)なら1イベントだけ通す。
  Future<void> _pauseGate() async {
    while (_paused && !_disposed && _pendingJump == null) {
      if (_stepOnce) {
        _stepOnce = false;
        return;
      }
      final gate = _pauseWake = Completer<void>();
      await gate.future;
      if (identical(_pauseWake, gate)) _pauseWake = null;
    }
  }

  Future<void> _waitForJump() async {
    if (_pendingJump != null || _disposed) return;
    _wake = Completer<void>();
    await _wake!.future;
    _wake = null;
  }

  Future<void> _playKyoku(PaifuKyoku k) async {
    _ks = KyokuTileState(_seatOf);
    _sticks = k.reachSticks;
    _honba = k.honba;
    _dealer = _seatOf[k.parentPlayerId] ?? 0;
    _roundWind = k.roundWind;
    _kyokuNumber = k.kyokuNumber;
    _lastEvent = null;
    // 一手戻し: この手数までは無表示・無遅延で早送りして再現する
    final ff = _stepTarget ?? 0;
    _stepTarget = null;
    _stepCount = 0;

    final startScores = [..._scores];
    // ゴーストモード用: 局のイベント列と開始時状態を持っておく
    final evs = _db.kyokuEvents(k.id);
    _kyokuEventList = evs;
    _currentKyokuInfo = k;
    _kyokuStartScores = startScores;
    _appliedEvents = 0;
    final wins = <WinInfo>[];
    List<(int, bool, int)> ryukyokuPlayers = const [];
    var ended = false;
    // 所作に合わせたリーチの並べ替え: DBは reach → discard の順だが、
    // 表示は「発声(reach)」→「宣言打牌(discard)」→「宣言牌が通ったので供託」。
    // reach イベントは発声だけ出して保留し、宣言打牌の直後に成立処理を行う。
    PaifuEvent? pendingReach;

    for (var ei = 0; ei < evs.length; ei++) {
      final ev = evs[ei];
      if (_disposed || _pendingJump != null) return;
      _appliedEvents = ei; // ポーズ中は「次に適用するイベント」の位置
      // 配牌がそろう前のイベントはポーズ・一手送りの対象にしない
      final steppable =
          ev.type != 'haipai' && _ks.hands.any((h) => h.isNotEmpty);
      if (steppable && _stepCount >= ff) {
        if (_stepCount == 0 && _paused) _emitPlaying(); // 局頭に戻った直後の表示
        await _pauseGate();
        if (_disposed || _pendingJump != null) return;
      }
      var delayMs = 0;
      switch (ev.type) {
        case 'haipai':
          _ks.apply(ev);
          continue; // 4人分そろってから最初のビューを出す
        case 'draw':
          _ks.apply(ev);
          delayMs = 250;
        case 'discard':
          _ks.apply(ev);
          final reach = pendingReach;
          if (reach != null && reach.actorPlayerId == ev.actorPlayerId) {
            // 宣言打牌が出た。成立(is_accepted)なら供託と1000点を反映する
            // (宣言牌ロンなら不成立=供託なし。対戦エンジンと同じ順序)
            pendingReach = null;
            _applyReach(reach);
          }
          delayMs = 650;
        case 'reach':
          final seat = _seatOf[ev.actorPlayerId]!;
          final river = _ks.rivers[seat];
          if (river.isNotEmpty && river.last.riichi && !_ks.riichi[seat]) {
            // 変則順(宣言打牌が先に記録されている)なら、ここで成立処理
            _applyReach(ev);
          } else {
            // 発声だけ。成立処理は宣言打牌の後(上の discard 側)で行う
            pendingReach = ev;
          }
          _lastEvent = GameEvent('riichi', seat, _eventSerial++);
          delayMs = 500;
        case 'pon' || 'chi' || 'daiminkan':
          _ks.apply(ev);
          _lastEvent = GameEvent(
            ev.type == 'daiminkan' ? 'kan' : ev.type,
            _seatOf[ev.actorPlayerId]!,
            _eventSerial++,
          );
          delayMs = 900;
        case 'shominkan' || 'ankan':
          _ks.apply(ev);
          _lastEvent = GameEvent(
            'kan',
            _seatOf[ev.actorPlayerId]!,
            _eventSerial++,
          );
          delayMs = 900;
        case 'dora_indicator':
          _ks.apply(ev);
          delayMs = 250;
        case 'ron' || 'tsumo':
          wins.add(_buildWin(ev));
          ended = true;
          continue; // まとめて結果表示(ダブロン対応)
        case 'ryukyoku':
          ryukyokuPlayers = ev.ryukyokuPlayers;
          ended = true;
          continue;
      }
      if (steppable) _stepCount++;
      if (_stepCount >= ff) {
        _emitPlaying();
        await _delay(delayMs);
      } else {
        _lastEvent = null; // 早送り中に積んだ吹き出しは表示しない
      }
    }
    _appliedEvents = evs.length;
    if (pendingReach != null) _applyReach(pendingReach); // 宣言打牌の欠損対策

    if (_disposed || _pendingJump != null || !ended) return;

    // 局結果: 終了時点数はDBの記録をそのまま使う
    final endScores = _seatScores(_db.kyokuEndScores(k.id));
    final tenpaiSeats = [
      for (final (pid, tenpai, _) in ryukyokuPlayers)
        if (tenpai) _seatOf[pid]!,
    ]..sort();
    final revealed = <int, List<int>>{
      for (final w in wins) w.seat: w.hand,
      for (final s in tenpaiSeats) s: _ks.handWithDrawn(s),
    };
    final dealerContinues = wins.isNotEmpty
        ? wins.any((w) => w.seat == _dealer)
        : tenpaiSeats.contains(_dealer);
    final result = HandResult(
      type: wins.isNotEmpty ? 'win' : 'draw',
      wins: wins,
      tenpaiSeats: tenpaiSeats,
      scoreChanges: [for (var i = 0; i < 4; i++) endScores[i] - startScores[i]],
      scores: endScores,
      uraIndicators: _ks.uraInds,
      revealedHands: revealed,
      dealerContinues: dealerContinues,
    );
    if (wins.isNotEmpty) {
      _lastEvent = GameEvent(
        wins.first.isTsumo ? 'tsumo' : 'ron',
        wins.first.seat,
        _eventSerial++,
      );
    } else {
      _lastEvent = GameEvent('draw', -1, _eventSerial++);
    }
    _scores = endScores;
    _emit(phase: 'handEnd', handResult: result);
    await _delay(9000);
    await _pauseGate(); // ポーズ中は結果表示のまま次局へ進めない
  }

  /// スタッツ(アガリ・リーチ・放銃回数)をDB集計から入れ直す
  void _loadStats({int? beforeKyokuId}) {
    final c = _db.statCounts(gameId, beforeKyokuId: beforeKyokuId);
    for (var i = 0; i < 4; i++) {
      final pid = _players[i].id;
      _stats.wins[i] = c.wins[pid] ?? 0;
      _stats.riichis[i] = c.riichis[pid] ?? 0;
      _stats.dealIns[i] = c.dealIns[pid] ?? 0;
    }
  }

  void _emitGameEnd() {
    _loadStats(); // 全局分の確定値
    final results = _db.gameResults(gameId);
    if (results.isEmpty) {
      // 結果未記録(中断データ等)ならそのまま終了表示だけ
      _emit(phase: 'gameEnd');
      return;
    }
    final bySeat = {for (final r in results) _seatOf[r.playerId]!: r};
    final ranking = [for (var i = 0; i < 4; i++) i]
      ..sort((a, b) => bySeat[a]!.rank - bySeat[b]!.rank);
    _scores = [for (var i = 0; i < 4; i++) bySeat[i]!.score];
    for (var i = 0; i < 4; i++) {
      _stats.points[i] = bySeat[i]!.points;
    }
    // 結果画面のスタッツ表は history の最終試合分を見るので、そこに載せる
    _emit(
      phase: 'gameEnd',
      gameResult: GameResult(
        ranking: ranking,
        scores: _scores,
        points: [for (var i = 0; i < 4; i++) bySeat[i]!.points],
      ),
      history: [_statsCopy()],
    );
  }

  GameStats _statsCopy() => GameStats(
    points: [..._stats.points],
    wins: [..._stats.wins],
    riichis: [..._stats.riichis],
    dealIns: [..._stats.dealIns],
  );

  WinInfo _buildWin(PaifuEvent ev) {
    final seat = _seatOf[ev.actorPlayerId]!;
    final isTsumo = ev.type == 'tsumo';
    final from = isTsumo ? -1 : (_seatOf[ev.targetPlayerId] ?? -1);
    // ツモ和了の winning_tile は 't' プレフィックス付き(例 't3m')
    final winTile = Tile.parse(
      ev.winningTile!.replaceFirst(RegExp('^t'), ''),
    ).single;
    // 手の内: ツモならツモ牌が和了牌なので手牌+和了牌でそろう
    final hand = [..._ks.hands[seat], winTile]
      ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
    final label = limitLabelFromDescription(ev.description);
    _stats.wins[seat]++;
    if (!isTsumo && from >= 0) _stats.dealIns[from]++;
    return WinInfo(
      seat: seat,
      fromSeat: from,
      winTile: winTile,
      score: WinScore(
        yaku: ev.yaku,
        han: ev.isYakuman ? 0 : (ev.han ?? 0),
        fu: ev.fu ?? 30,
        yakuman: ev.isYakuman ? ((ev.han ?? 13) >= 26 ? 2 : 1) : 0,
      ),
      points: ev.points ?? 0,
      label: label,
      hand: hand,
      melds: _ks.melds[seat],
    );
  }

  // ---------------- 内部ユーティリティ ----------------

  List<int> _seatScores(Map<int, int> byPlayer) => [
    for (var i = 0; i < 4; i++) byPlayer[_players[i].id] ?? _scores[i],
  ];

  /// 再生待ち。◀▶(_requestJump)や dispose で即座に切り上げる。
  /// リーチ成立処理(フラグ・供託・1000点・統計)。宣言打牌の直後に呼ぶ。
  void _applyReach(PaifuEvent reach) {
    _ks.apply(reach);
    if (reach.reachAccepted) {
      final seat = _seatOf[reach.actorPlayerId]!;
      _scores[seat] -= 1000;
      _sticks++;
      _stats.riichis[seat]++;
    }
  }

  Future<void> _delay(int ms) async {
    final scaled = (ms * speed).round();
    if (scaled <= 0 || _pendingJump != null || _disposed || _paused) {
      // テスト(speed=0)でもイベントループへ制御を返す
      await Future<void>.delayed(Duration.zero);
      return;
    }
    final wake = _wake = Completer<void>();
    await Future.any([
      Future<void>.delayed(Duration(milliseconds: scaled)),
      wake.future,
    ]);
    if (identical(_wake, wake)) _wake = null;
  }

  void _emitPlaying() {
    // 実DBはドラ表示イベントが配牌より先に来る。配牌前の空ビューは出さない
    if (_ks.hands.every((h) => h.isEmpty)) return;
    _emit(phase: 'playing');
  }

  void _emit({
    required String phase,
    HandResult? handResult,
    GameResult? gameResult,
    List<GameStats> history = const [],
  }) {
    if (_disposed) return;
    final view = GameView(
      youSeat: youSeat,
      dealer: _dealer,
      roundWind: _roundWind,
      kyoku: _kyokuNumber,
      honba: _honba,
      riichiSticks: _sticks,
      wallRemaining: _ks.wall,
      currentSeat: _ks.currentSeat,
      scores: [..._scores],
      doraIndicators: [..._ks.doraInds],
      hand: [..._ks.hands[youSeat]],
      drawnTile: _ks.drawn[youSeat],
      players: [
        for (var i = 0; i < 4; i++)
          PlayerView(
            name: _players[i].name,
            isCpu: false,
            connected: true,
            riichi: _ks.riichi[i],
            handCount: _ks.hands[i].length + (_ks.drawn[i] != null ? 1 : 0),
            melds: [..._ks.melds[i]],
            discards: [..._ks.rivers[i]],
          ),
      ],
      phase: phase,
      handResult: handResult,
      gameResult: gameResult,
      lastEvent: _lastEvent,
      history: history,
      currentStats: _statsCopy(),
      memberNames: [for (final p in _players) p.name],
    );
    latestView = view;
    if (!_views.isClosed) _views.add(view);
  }

  // ---------------- GameSession ----------------

  @override
  bool get isHost => false;

  @override
  bool get isSpectator => _ghost == null; // ゴースト中は操作UIを出す

  @override
  Stream<SpectateRequest> get spectateRequests => const Stream.empty();

  @override
  TurnPrompt? get activeTurnPrompt => _ghost?.activeTurnPrompt;

  @override
  ReactPrompt? get activeReactPrompt => _ghost?.activeReactPrompt;

  @override
  Stream<GameView> get views => _views.stream;

  @override
  Stream<TurnPrompt> get turnPrompts => _turnPrompts.stream;

  @override
  Stream<ReactPrompt> get reactPrompts => _reactPrompts.stream;

  @override
  Stream<EmoteCast> get emotes => const Stream.empty();

  @override
  Stream<bool> get connectionState => const Stream.empty();

  @override
  bool get isConnected => true;

  @override
  void sendTurn(TurnAction action) => _ghost?.submitTurn(action);

  @override
  void sendReact(ReactAction action) => _ghost?.submitReact(action);

  @override
  void sendEmote(int emoji) {}

  @override
  void advance() {
    // ゴーストの局結果で「次へ」= ゴースト終了して牌譜再生に戻る
    if (_ghost != null) _exitGhost();
  }

  @override
  void nextGame() {}

  @override
  Future<SuspendedHostGame?> suspend() async => null;

  @override
  Stream<SuspendNotice> get suspendNotices => const Stream.empty();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _exitGhost();
    _wakeDelay(); // 再生ループを起こして終了させる
    _wakeGate();
    await _views.close();
    await _turnPrompts.close();
    await _reactPrompts.close();
    _db.close();
  }
}
