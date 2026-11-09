/// 局進行の状態機械(マスター端末上で動く権威エンジン)
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'call_options.dart';
import 'hand.dart';
import 'kuikae.dart';
import 'meld.dart';
import 'models.dart';
import 'paifu_record.dart';
import 'payout.dart';
import 'resume.dart';
import 'score.dart';
import 'tile.dart';
import 'yaku.dart';

/// 席に着くプレイヤー(人間UI・CPU・ネットワーク越しの誰か)の抽象
abstract class PlayerAgent {
  void onView(GameView view);
  Future<TurnAction> onTurn(TurnPrompt prompt);
  Future<ReactAction> onReact(ReactPrompt prompt);

  /// 顔文字キャストの受信(表示のみ・進行に影響しない)。既定は何もしない。
  void onEmote(int seat, int emoji) {}
}

class _SeatState {
  String name;
  bool isCpu;
  bool connected;
  List<int> hand = [];
  List<Meld> melds = [];
  List<DiscardInfo> discards = [];
  bool riichi = false;
  bool doubleRiichi = false;
  bool ippatsu = false;
  bool tempFuriten = false;
  bool riichiFuriten = false;
  List<int> waits = [];
  int score;

  // 責任払い(包): 該当役満を確定させた放銃者の席(-1=なし)
  int paoDaisangen = -1;
  int paoDaisuushi = -1;
  int paoSuukantsu = -1;

  _SeatState(this.name, this.isCpu, this.connected, this.score);

  bool get isMenzen => melds.every((m) => m.keepsConcealed);

  void sortHand() => hand.sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));

  /// 副露牌(暗槓の4枚も含む)の牌種カウント
  List<int> get meldCounts => toCounts([for (final m in melds) ...m.tiles]);

  /// 実際にアガれる待ち(Mリーグの聴牌定義)。
  /// 自己の手牌・副露牌でアガリ牌を4枚使い切っている待ちは認められない。
  List<int> calcMyWaits() =>
      calcLiveWaits(toCounts(hand), meldCounts, meldCount: melds.length);

  /// 見せ牌フリテン(自分の捨て牌に待ちがある)
  bool get discardFuriten {
    final set = discards.map((d) => Tile.normalize(d.tile)).toSet();
    return waits.any(set.contains);
  }

  bool get isFuriten => tempFuriten || riichiFuriten || discardFuriten;
}

class _Pending<P, A> {
  final P prompt;
  final Completer<A> completer = Completer<A>();
  _Pending(this.prompt);
}

class GameEngine {
  final GameConfig config;
  final Random _rng;

  /// 試合終了後に次の試合を始めるか(true=連戦)。null なら1試合で終了
  final Future<bool> Function()? waitNextGame;

  /// リーチ中の自動ツモ切りなど演出用ディレイ(テストでは 0)
  final int autoPlayDelayMs;

  /// 局終了確認で全員CPUの場合に自動遷移するまでの待ち(テストでは 0)
  final int advanceDelayMs;

  // 局終了の確認ゲート
  Completer<void>? _advanceCompleter;
  final Set<int> _advanceAcked = {}; // 確認済みの席

  final List<_SeatState> _seats;
  final List<PlayerAgent?> _agents = List.filled(4, null);
  final List<_Pending<TurnPrompt, TurnAction>?> _pendingTurn = List.filled(
    4,
    null,
  );
  final List<_Pending<ReactPrompt, ReactAction>?> _pendingReact = List.filled(
    4,
    null,
  );

  // 場決め: メンバー = 1試合目の席順(東南西北順)で固定した個人ID。
  // 2試合目以降はプレイヤーを席にシャッフル配置し、_seatMember[席] = メンバーID で追跡する
  final List<int> _seatMember = [0, 1, 2, 3];
  bool _membersInitialized = false;

  // 局の進行状態
  int _dealer = 0;
  int _roundWind = 0;
  int _kyoku = 1;
  int _honba = 0;
  int _riichiSticks = 0;
  List<int> _liveWall = [];
  List<int> _rinshanTiles = [];
  List<int> _doraIndicators = [];
  List<int> _uraIndicators = [];
  int _kanCount = 0;
  int _current = 0;
  int? _currentDrawn;
  bool _anyCall = false;
  String _phase = 'playing';
  HandResult? _handResult;
  GameResult? _gameResult;
  GameEvent? _lastEvent;
  int _eventSerial = 0;
  int _handsPlayed = 0;
  int _discardOrder = 0;

  // 試合スタッツ(席順)
  final List<GameStats> _historyStats = [];
  List<int> _statWins = List.filled(4, 0);
  List<int> _statRiichis = List.filled(4, 0);
  List<int> _statDealIns = List.filled(4, 0);

  // ---- 中断・復帰(resume.dart の方式コメント参照) ----
  bool _suspended = false; // 中断済み: これ以上進行しない
  bool _resumed = false; // 復帰起動: 初回の場決め・山生成をスキップ
  List<int>? _resumeWall; // 復帰する局の山(1局分だけ使って破棄)
  final List<Queue<TurnAction>> _replayTurn = List.generate(
    4,
    (_) => Queue<TurnAction>(),
  );
  final List<Queue<ReactAction>> _replayReact = List.generate(
    4,
    (_) => Queue<ReactAction>(),
  );

  // 進行中の局の記録(中断時に保存する牌譜)
  List<int> _recordedWall = [];
  final List<RecordedAction> _recordedActions = [];

  // ---- 牌譜記録(「自分の対局」保存。paifu_record.dart 参照) ----
  /// 局ごとの牌譜を受け取るレコーダ。null なら記録しない(ゲスト・テスト)。
  PaifuRecorder? paifuRecorder;
  final List<Map<String, dynamic>> _paifuEvents = [];
  int _paifuOrder = 0;
  int _paifuReachIdx = -1; // 直近のリーチイベント(宣言牌ロンで不成立にする)

  // 局開始時点の試合状態スナップショット(中断時の保存基準)
  List<int> _handStartScores = [];
  int _handStartSticks = 0;
  int _handStartHandsPlayed = 0;
  List<int> _handStartWins = List.filled(4, 0);
  List<int> _handStartRiichis = List.filled(4, 0);
  List<int> _handStartDealIns = List.filled(4, 0);
  int _handStartHistoryLen = 0;

  GameEngine({
    required this.config,
    required List<String> names,
    required List<bool> isCpu,
    this.waitNextGame,
    this.autoPlayDelayMs = 500,
    this.advanceDelayMs = 3000,
    int? seed,
  }) : _rng = Random(seed),
       _seats = List.generate(
         4,
         (i) => _SeatState(names[i], isCpu[i], !isCpu[i], 25000),
       ) {
    for (final s in _seats) {
      s.score = config.startScore;
    }
    _handStartScores = scores;
  }

  /// 中断した対局を復元する。局開始時点の状態を戻し、run() が牌譜を
  /// リプレイして中断時点まで進める(未記録の応答からライブ進行に戻る)。
  GameEngine.fromResume(
    ResumeData data, {
    this.waitNextGame,
    this.autoPlayDelayMs = 500,
    this.advanceDelayMs = 3000,
    int? seed,
  }) : config = data.config,
       _rng = Random(seed),
       // connected は通常起動と同じく一旦 false(setAgent で上書きされる)
       _seats = List.generate(
         4,
         (i) => _SeatState(data.names[i], data.isCpu[i], false, data.scores[i]),
       ) {
    _resumed = true;
    _membersInitialized = true;
    for (var i = 0; i < 4; i++) {
      _seatMember[i] = data.seatMember[i];
    }
    _dealer = data.dealer;
    _roundWind = data.roundWind;
    _kyoku = data.kyoku;
    _honba = data.honba;
    _handsPlayed = data.handsPlayed;
    _riichiSticks = data.riichiSticks;
    _historyStats.addAll(data.history);
    _statWins = List.of(data.statWins);
    _statRiichis = List.of(data.statRiichis);
    _statDealIns = List.of(data.statDealIns);
    _resumeWall = List.of(data.wall);
    for (final a in data.actions) {
      if (a.kind == 't') {
        _replayTurn[a.seat].add(TurnAction.fromJson(a.action));
      } else {
        _replayReact[a.seat].add(ReactAction.fromJson(a.action));
      }
    }
    _handStartScores = scores;
  }

  /// 牌譜リプレイ中か(復帰直後、記録済みアクションを流し込んでいる間)。
  /// リプレイ中は演出ディレイを飛ばして一気に中断時点まで進める。
  bool get isReplaying =>
      _replayTurn.any((q) => q.isNotEmpty) ||
      _replayReact.any((q) => q.isNotEmpty);

  /// 中断: 現時点までの復帰情報を取り出し、以後の進行を止める。
  /// (同期処理なので、取り出した情報とエンジン状態がずれることはない)
  ResumeData suspendAndCapture() {
    final data = buildResumeData();
    _suspended = true;
    return data;
  }

  /// 現在の局開始時点+牌譜からなる復帰情報を作る(エンジンは止めない)
  ResumeData buildResumeData() => ResumeData(
    config: config,
    names: [for (final s in _seats) s.name],
    isCpu: [for (final s in _seats) s.isCpu],
    seatMember: List.of(_seatMember),
    dealer: _dealer,
    roundWind: _roundWind,
    kyoku: _kyoku,
    honba: _honba,
    handsPlayed: _handStartHandsPlayed,
    scores: List.of(_handStartScores),
    riichiSticks: _handStartSticks,
    statWins: List.of(_handStartWins),
    statRiichis: List.of(_handStartRiichis),
    statDealIns: List.of(_handStartDealIns),
    history: _historyStats.take(_handStartHistoryLen).toList(),
    wall: List.of(_recordedWall),
    actions: List.of(_recordedActions),
  );

  int get dealer => _dealer;
  List<int> get scores => _seats.map((s) => s.score).toList();

  /// 席のエージェントを差し替える(切断→CPU代打、再接続→復帰)
  void setAgent(
    int seat,
    PlayerAgent agent, {
    String? name,
    bool? isCpu,
    bool? connected,
  }) {
    _agents[seat] = agent;
    if (name != null) _seats[seat].name = name;
    if (isCpu != null) _seats[seat].isCpu = isCpu;
    if (connected != null) _seats[seat].connected = connected;
    // 応答待ちのプロンプトがあれば新しいエージェントに出し直す
    final pt = _pendingTurn[seat];
    if (pt != null) _dispatchTurn(seat, pt);
    final pr = _pendingReact[seat];
    if (pr != null) _dispatchReact(seat, pr);
    // 局終了確認の待機中に人間が切断→CPU化したら、その分の確認要求を外す
    _checkAdvanceComplete();
    agent.onView(_buildView(seat));
    _pushViews();
  }

  void setSeatStatus(int seat, {String? name, bool? connected, bool? isCpu}) {
    if (name != null) _seats[seat].name = name;
    if (connected != null) _seats[seat].connected = connected;
    if (isCpu != null) _seats[seat].isCpu = isCpu;
    _checkAdvanceComplete();
    _pushViews();
  }

  // ---------------- プロンプト配送(差し替え対応) ----------------

  Future<TurnAction> _askTurn(int seat, TurnPrompt prompt) async {
    // 復帰リプレイ: 記録済みのアクションがあればエージェントに聞かず再生する
    if (_replayTurn[seat].isNotEmpty) {
      final action = _replayTurn[seat].removeFirst();
      _recordedActions.add(RecordedAction(seat, 't', action.toJson()));
      return action;
    }
    final pending = _Pending<TurnPrompt, TurnAction>(prompt);
    _pendingTurn[seat] = pending;
    _dispatchTurn(seat, pending);
    try {
      final action = await pending.completer.future;
      // 牌譜記録(中断時の復帰情報)。sanitize 前の生アクションを記録し、
      // リプレイ時も同じ生アクションを sanitize に通すことで一致させる。
      _recordedActions.add(RecordedAction(seat, 't', action.toJson()));
      return action;
    } finally {
      _pendingTurn[seat] = null;
    }
  }

  void _dispatchTurn(int seat, _Pending<TurnPrompt, TurnAction> pending) {
    if (_suspended) return; // 中断済み: 応答待ちのまま止める
    final agent = _agents[seat];
    if (agent == null) return;
    agent
        .onTurn(pending.prompt)
        .then((action) {
          // 中断後に着弾した応答は捨てる(捨てないと中断時に取り出した
          // 復帰情報より先へ状態が進み、復帰時の再現とずれてしまう)
          if (!_suspended &&
              !pending.completer.isCompleted &&
              identical(_pendingTurn[seat], pending) &&
              identical(_agents[seat], agent)) {
            pending.completer.complete(action);
          }
        })
        .catchError((Object e) {
          // エージェント側エラーはツモ切り相当にフォールバック
          if (!_suspended &&
              !pending.completer.isCompleted &&
              identical(_pendingTurn[seat], pending)) {
            pending.completer.complete(
              TurnAction.discard(
                pending.prompt.drawnTile ?? _seats[seat].hand.first,
              ),
            );
          }
        });
  }

  Future<ReactAction> _askReact(int seat, ReactPrompt prompt) async {
    if (_replayReact[seat].isNotEmpty) {
      final action = _replayReact[seat].removeFirst();
      _recordedActions.add(RecordedAction(seat, 'r', action.toJson()));
      return action;
    }
    final pending = _Pending<ReactPrompt, ReactAction>(prompt);
    _pendingReact[seat] = pending;
    _dispatchReact(seat, pending);
    try {
      final action = await pending.completer.future;
      _recordedActions.add(RecordedAction(seat, 'r', action.toJson()));
      return action;
    } finally {
      _pendingReact[seat] = null;
    }
  }

  void _dispatchReact(int seat, _Pending<ReactPrompt, ReactAction> pending) {
    if (_suspended) return;
    final agent = _agents[seat];
    if (agent == null) return;
    agent
        .onReact(pending.prompt)
        .then((action) {
          if (!_suspended &&
              !pending.completer.isCompleted &&
              identical(_pendingReact[seat], pending) &&
              identical(_agents[seat], agent)) {
            pending.completer.complete(action);
          }
        })
        .catchError((Object e) {
          if (!_suspended &&
              !pending.completer.isCompleted &&
              identical(_pendingReact[seat], pending)) {
            pending.completer.complete(const ReactAction.pass());
          }
        });
  }

  // ---------------- ビュー構築・配信 ----------------

  GameView _buildView(int seat) {
    final s = _seats[seat];
    return GameView(
      youSeat: seat,
      dealer: _dealer,
      roundWind: _roundWind,
      kyoku: _kyoku,
      honba: _honba,
      riichiSticks: _riichiSticks,
      wallRemaining: _liveWall.length,
      currentSeat: _phase == 'playing' ? _current : -1,
      scores: scores,
      doraIndicators: _doraIndicators.take(1 + _kanCount).toList(),
      hand: List<int>.from(s.hand),
      drawnTile: seat == _current ? _currentDrawn : null,
      players: List.generate(4, (i) {
        final p = _seats[i];
        return PlayerView(
          name: p.name,
          isCpu: p.isCpu,
          connected: p.connected,
          riichi: p.riichi,
          handCount:
              p.hand.length + (i == _current && _currentDrawn != null ? 1 : 0),
          melds: List<Meld>.from(p.melds),
          discards: List<DiscardInfo>.from(p.discards),
        );
      }),
      phase: _phase,
      handResult: _handResult,
      gameResult: _gameResult,
      lastEvent: _lastEvent,
      history: List<GameStats>.from(_historyStats),
      gameIndex: _phase == 'gameEnd'
          ? _historyStats.length
          : _historyStats.length + 1,
      currentStats: GameStats(
        points: _byMember(_provisionalPoints()),
        wins: _byMember(_statWins),
        riichis: _byMember(_statRiichis),
        dealIns: _byMember(_statDealIns),
      ),
      memberNames: [for (var m = 0; m < 4; m++) _seats[_seatOfMember(m)].name],
      memberSeats: [for (var m = 0; m < 4; m++) _seatOfMember(m)],
      myWaits: List<int>.from(s.waits),
      myFuriten: s.isFuriten,
    );
  }

  /// 対局中の暫定ポイント(ウマ・オカは加算せず素点の増減のみ)
  List<double> _provisionalPoints() => [
    for (final s in _seats) (s.score - config.startScore) / 1000.0,
  ];

  // ---------------- ギャラリー(観戦) ----------------

  /// 観戦者: 席に着かず、指定プレイヤーの視点のビューだけを受け取る。
  /// キーはエージェント、値は見ているプレイヤーの名前。
  /// (場決めで席が動いてもプレイヤーを追いかけるため、席ではなく名前で持つ)
  final Map<PlayerAgent, String> _spectators = {};

  /// 観戦者を追加する。以後 watchName のプレイヤーと同じビューが届く。
  void addSpectator(PlayerAgent agent, String watchName) {
    _spectators[agent] = watchName;
    agent.onView(_buildView(_watchSeat(watchName)));
  }

  void removeSpectator(PlayerAgent agent) => _spectators.remove(agent);

  int _watchSeat(String name) {
    final s = seatOfName(name);
    return s >= 0 ? s : 0;
  }

  void _pushViews() {
    for (var i = 0; i < 4; i++) {
      _agents[i]?.onView(_buildView(i));
    }
    _spectators.forEach((agent, name) {
      agent.onView(_buildView(_watchSeat(name)));
    });
  }

  void _emitEvent(String type, int seat) {
    _lastEvent = GameEvent(type, seat, _eventSerial++);
  }

  // ---------------- 牌譜記録(自分の対局) ----------------

  bool get _recordingPaifu => paifuRecorder != null;

  void _paifu(Map<String, dynamic> event) {
    _paifuEvents.add({...event, 'event_order': _paifuOrder++});
  }

  /// カン成立後の新ドラ即めくり(表示と同じタイミングで記録する)
  void _paifuKanDora() {
    if (_kanCount < _doraIndicators.length) {
      _paifu({
        'type': 'dora_indicator',
        'dora_type': 'omote',
        'dora_indicator': Tile.dbNotation(_doraIndicators[_kanCount]),
      });
    }
  }

  void _paifuUraDora(List<int> uraIndicators) {
    for (final t in uraIndicators) {
      _paifu({
        'type': 'dora_indicator',
        'dora_type': 'ura',
        'dora_indicator': Tile.dbNotation(t),
      });
    }
  }

  Map<String, dynamic> _paifuAgari({
    required String type, // 'tsumo' | 'ron'
    required int seat,
    required int? fromSeat,
    required int winTile,
    required WinScore score,
    required String label,
    required int declared,
    required int total,
  }) {
    final desc = agariDescription(
      isYakuman: score.isYakuman,
      fu: score.fu,
      han: score.han,
      label: label,
      declared: declared,
    );
    return {
      'type': type,
      'actor_player_id': seat,
      'target_player_id': fromSeat,
      'points': total, // 本家DB同様、供託・本場込みの総取得点
      'winning_tile': type == 'tsumo'
          ? 't${Tile.dbNotation(winTile)}'
          : Tile.dbNotation(winTile),
      'fu': score.fu,
      'han': score.isYakuman ? 13 * score.yakuman : score.han,
      'is_yakuman': score.isYakuman,
      'description': desc,
      'yaku': yakuToJson(score.yaku),
    };
  }

  /// 局の牌譜をレコーダへ渡す(局結果確定・点数適用済みの時点で呼ぶ)
  void _reportPaifuKyoku() {
    final rec = paifuRecorder;
    if (rec == null || _paifuEvents.isEmpty) return;
    rec.onKyoku({
      'round': '${_roundWind + 1}z$_kyoku',
      'honba_count': _honba,
      'reach_stick_count': _handStartSticks,
      'parent_player_id': _dealer,
      'start_scores': List.of(_handStartScores),
      'end_scores': scores,
      'names': [for (final s in _seats) s.name],
      'events': List.of(_paifuEvents),
    });
    _paifuEvents.clear();
  }

  /// アガリ牌が出たのにロンしなかった者にフリテンを立てる。
  ///
  /// Mリーグ:「「摸打の一巡」の間に、自己のアガリ牌が出、その牌でロンをしなかった
  /// 場合、フリテン（同巡内フリテン）となる。」
  /// 「リーチ後にアガリ牌が出た場合に、リーチ者はロンをしない（見逃す）ことが
  /// できる。その後はフリテンとなりツモアガリのみ有効となる。」
  ///
  /// 打牌だけでなく**加槓(搶槓)の見逃しでも立てる**。加槓牌は副露面子へ移り
  /// どの河にも残らないため、ここで立てないと捨て牌フリテンでも捕捉できず、
  /// 同じ牌で後からロンできてしまう。
  ///
  /// フリテンは待ち(アガリ形を構成できる牌)で決まり、役の有無は問わない。
  void _markMissedRonFuriten(int fromSeat, int tileKind) {
    for (var i = 0; i < 4; i++) {
      if (i == fromSeat) continue;
      final s = _seats[i];
      if (!s.waits.contains(tileKind)) continue;
      if (s.riichi) {
        s.riichiFuriten = true;
      } else {
        s.tempFuriten = true;
      }
    }
  }

  /// 顔文字キャストを全席+観戦者に配信する(表示のみ・非ブロッキング)。
  void castEmote(int seat, int emoji) {
    for (var i = 0; i < 4; i++) {
      _agents[i]?.onEmote(seat, emoji);
    }
    for (final a in _spectators.keys) {
      a.onEmote(seat, emoji);
    }
  }

  /// エージェント自身の**現在の席**から顔文字を配信する。
  ///
  /// 場決め(`_randomizeSeating`)でエージェントの席は試合ごとに動くので、
  /// セットアップ時の席インデックスを固定で使うと別の席に顔文字が出てしまう。
  /// 席はここで都度エージェントの同一性から引き直す。
  void castEmoteFrom(PlayerAgent agent, int emoji) {
    final seat = _agents.indexWhere((a) => identical(a, agent));
    if (seat >= 0) castEmote(seat, emoji);
  }

  // ---------------- ゲーム全体の進行 ----------------

  Future<void> run() async {
    // 復帰起動: 場決めは中断時の席順をそのまま使う(fromResume で復元済み)
    if (_resumed) {
      _resumed = false;
    } else {
      _randomizeSeating();
    }
    while (true) {
      await _runOneGame();
      if (_suspended) return;
      // 連戦: ホストが「次の試合へ」を選んだら新しい試合を始める
      if (waitNextGame == null) return;
      final again = await waitNextGame!();
      if (!again || _suspended) return;
      _resetForNextGame();
    }
  }

  /// 場決め: プレイヤー(エージェント・名前・接続状態)を4席に完全ランダムに配置する。
  /// 24通りの並びが等確率で現れる。起家は常に席0(=東)
  void _randomizeSeating() {
    final perm = List.generate(4, (i) => i)..shuffle(_rng);
    final oldSeats = List<_SeatState>.from(_seats);
    final oldAgents = List<PlayerAgent?>.from(_agents);
    final oldMembers = List<int>.from(_seatMember);
    for (var i = 0; i < 4; i++) {
      _seats[i] = oldSeats[perm[i]];
      _agents[i] = oldAgents[perm[i]];
      _seatMember[i] = oldMembers[perm[i]];
    }
    if (!_membersInitialized) {
      // 1試合目の席順(東南西北)がそのままメンバーの並びになる
      _membersInitialized = true;
      for (var i = 0; i < 4; i++) {
        _seatMember[i] = i;
      }
    }
    _dealer = 0;
  }

  /// メンバーID → 現在の席
  int _seatOfMember(int member) => _seatMember.indexOf(member);

  /// 席順の配列をメンバー順に並べ替える
  List<T> _byMember<T>(List<T> seatIndexed) => [
    for (var m = 0; m < 4; m++) seatIndexed[_seatOfMember(m)],
  ];

  /// 名前から現在の席を引く(再接続用)
  int seatOfName(String name) => _seats.indexWhere((s) => s.name == name);

  /// 席のプレイヤー名(観戦席の選択肢の列挙などに使う)
  String nameOfSeat(int seat) => _seats[seat].name;

  /// 中断済みなら永久に停止する(以後の進行を完全に止める)。
  /// 中断後のエンジンは破棄される前提なので、Future を完了させずに放置する。
  Future<void> _parkIfSuspended() async {
    if (_suspended) await Completer<void>().future;
  }

  Future<void> _runOneGame() async {
    while (true) {
      await _parkIfSuspended();
      _phase = 'playing';
      _handResult = null;
      final result = await _playHand();
      _handsPlayed++;
      _handResult = result;
      _phase = 'handEnd';
      _reportPaifuKyoku();
      _pushViews();
      await _awaitAdvance();
      await _parkIfSuspended(); // 確認待ちの間に中断されたら進めない
      if (_isGameOver(result)) {
        _finishGame();
        return;
      }
      _nextHand(result);
    }
  }

  /// 局終了確認の待機。
  /// 人間プレイヤーが1人でもいれば全員の確認を待つ。
  /// 全員CPU(または人間が全員切断)なら [advanceDelayMs] 後に自動遷移。
  Future<void> _awaitAdvance() async {
    if (_humanSeats().isEmpty) {
      if (advanceDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: advanceDelayMs));
      }
      return;
    }
    _advanceAcked.clear();
    final completer = Completer<void>();
    _advanceCompleter = completer;
    _checkAdvanceComplete();
    await completer.future;
    _advanceCompleter = null;
  }

  /// 確認が必要な人間プレイヤーの席(接続中かつ非CPU)
  Set<int> _humanSeats() => {
    for (var i = 0; i < 4; i++)
      if (!_seats[i].isCpu && _seats[i].connected) i,
  };

  /// 局終了確認: 席 seat の人間が「次へ」を押した
  void ackAdvance(int seat) {
    if (_suspended) return;
    if (_advanceCompleter == null) return;
    if (seat < 0 || seat > 3) return;
    _advanceAcked.add(seat);
    _checkAdvanceComplete();
  }

  void _checkAdvanceComplete() {
    final completer = _advanceCompleter;
    if (completer == null || completer.isCompleted) return;
    // 必要な人間が全員確認済みなら遷移
    if (_humanSeats().difference(_advanceAcked).isEmpty) {
      completer.complete();
    }
  }

  void _resetForNextGame() {
    for (final s in _seats) {
      s.score = config.startScore;
    }
    _randomizeSeating();
    _roundWind = 0;
    _kyoku = 1;
    _honba = 0;
    _riichiSticks = 0;
    _handsPlayed = 0;
    _gameResult = null;
    _handResult = null;
    _statWins = List.filled(4, 0);
    _statRiichis = List.filled(4, 0);
    _statDealIns = List.filled(4, 0);
  }

  bool _isGameOver(HandResult r) {
    // Mリーグルール: トビなし(マイナスでも続行)・アガリやめなし
    if (_handsPlayed >= 50) return true; // 安全弁
    final isLastHand = _roundWind >= config.rounds - 1 && _kyoku == 4;
    return isLastHand && !r.dealerContinues;
  }

  void _nextHand(HandResult r) {
    if (r.type == 'win') {
      _honba = r.dealerContinues ? _honba + 1 : 0;
    } else {
      _honba++;
    }
    if (!r.dealerContinues) {
      _dealer = (_dealer + 1) % 4;
      _kyoku++;
      if (_kyoku > 4) {
        _kyoku = 1;
        _roundWind++;
      }
    }
  }

  void _finishGame() {
    // 精算は settleGame(score.dart) に集約している。
    // リーチ棒を配る前の持ち点で順位・同点を判定する順序が肝なので、
    // 純粋関数に切り出してテストできるようにしてある。
    // 和了で半荘が終わった場合は _winByRon/_winByTsumo が既に和了者へ供託を
    // 渡しているため、ここに残っているのは「流局で半荘が終了した」場合だけ。
    final settled = settleGame(scores: scores, pot: _riichiSticks * 1000);
    _riichiSticks = 0;
    for (var i = 0; i < 4; i++) {
      _seats[i].score = settled.finalScores[i];
    }
    final ranking = settled.ranking;
    final points = settled.points;
    _gameResult = GameResult(ranking: ranking, scores: scores, points: points);
    paifuRecorder?.onGameEnd([
      for (var i = 0; i < 4; i++)
        {
          'player_id': i,
          'score': _seats[i].score,
          'points': points[i],
          'rank': ranking.indexOf(i) + 1,
        },
    ]);
    // スタッツは席順ではなくメンバー順で記録する(席は毎試合変わるため)
    _historyStats.add(
      GameStats(
        points: _byMember(points),
        wins: _byMember(_statWins),
        riichis: _byMember(_statRiichis),
        dealIns: _byMember(_statDealIns),
      ),
    );
    _phase = 'gameEnd';
    _pushViews();
  }

  // ---------------- 1局の進行 ----------------

  Future<HandResult> _playHand() async {
    // 配牌。復帰直後の1局だけは保存されていた山を使う(牌譜リプレイ用)。
    final wall = _resumeWall ?? (Tile.fullWall()..shuffle(_rng));
    _resumeWall = null;

    // 中断・復帰用の記録を開始する(山の全量と、局開始時点の試合状態)
    _recordedWall = List.of(wall);
    _recordedActions.clear();
    _handStartScores = scores;
    _handStartSticks = _riichiSticks;
    _handStartHandsPlayed = _handsPlayed;
    _handStartWins = List.of(_statWins);
    _handStartRiichis = List.of(_statRiichis);
    _handStartDealIns = List.of(_statDealIns);
    _handStartHistoryLen = _historyStats.length;

    final dead = wall.sublist(0, 14);
    _liveWall = wall.sublist(14);
    _rinshanTiles = dead.sublist(0, 4);
    _doraIndicators = dead.sublist(4, 9);
    _uraIndicators = dead.sublist(9, 14);
    _kanCount = 0;
    _anyCall = false;
    _currentDrawn = null;
    _discardOrder = 0;

    for (final s in _seats) {
      s.hand = [];
      s.melds = [];
      s.discards = [];
      s.riichi = false;
      s.doubleRiichi = false;
      s.ippatsu = false;
      s.tempFuriten = false;
      s.riichiFuriten = false;
      s.waits = [];
      s.paoDaisangen = -1;
      s.paoDaisuushi = -1;
      s.paoSuukantsu = -1;
    }
    for (var i = 0; i < 13; i++) {
      for (var seat = 0; seat < 4; seat++) {
        _seats[(_dealer + seat) % 4].hand.add(_liveWall.removeLast());
      }
    }
    for (final s in _seats) {
      s.sortHand();
      s.waits = s.calcMyWaits();
    }

    // 牌譜記録: 局頭は本家DBと同じ「表ドラ→配牌(東南西北順)」
    _paifuEvents.clear();
    _paifuOrder = 0;
    _paifuReachIdx = -1;
    if (_recordingPaifu) {
      _paifu({
        'type': 'dora_indicator',
        'dora_type': 'omote',
        'dora_indicator': Tile.dbNotation(_doraIndicators[0]),
      });
      for (var i = 0; i < 4; i++) {
        final seat = (_dealer + i) % 4;
        _paifu({
          'type': 'haipai',
          'player_id': seat,
          'hand': tilesToDbString(_seats[seat].hand),
        });
      }
    }

    _current = _dealer;
    var afterCall = false; // ポン・チー直後(ツモなしで打牌)
    int? carriedDrawn; // 大明槓の嶺上牌
    var carriedRinshan = false;
    var forbidden = <int>[]; // 喰い替え禁止

    _pushViews();

    while (true) {
      await _parkIfSuspended();
      final me = _seats[_current];
      int? drawn = carriedDrawn;
      var isRinshan = carriedRinshan;
      carriedDrawn = null;
      carriedRinshan = false;

      if (drawn == null && !afterCall) {
        if (_liveWall.isEmpty) return _ryuukyoku();
        drawn = _liveWall.removeLast();
        if (_recordingPaifu) {
          _paifu({
            'type': 'draw',
            'actor_player_id': _current,
            'tile': Tile.dbNotation(drawn),
            'is_rinshan': false,
          });
        }
      }
      _currentDrawn = drawn;
      _pushViews();

      // ---- 手番(カンで繰り返す) ----
      TurnAction action;
      while (true) {
        final prompt = _buildTurnPrompt(_current, drawn, isRinshan, forbidden);

        if (me.riichi &&
            drawn != null &&
            !prompt.canTsumo &&
            prompt.ankanKinds.isEmpty) {
          // リーチ中は自動ツモ切り(復帰リプレイ中はディレイなしで再現)
          if (autoPlayDelayMs > 0 && !isReplaying) {
            await Future<void>.delayed(Duration(milliseconds: autoPlayDelayMs));
            await _parkIfSuspended(); // ディレイ中に中断されたら進めない
          }
          action = TurnAction.discard(drawn);
        } else {
          action = _sanitizeTurnAction(
            await _askTurn(_current, prompt),
            prompt,
            drawn,
          );
        }

        if (action.type == 'tsumo') {
          return _winByTsumo(_current, drawn!, isRinshan);
        }
        if (action.type == 'ankan' || action.type == 'kakan') {
          final kind = action.tile;
          // Mリーグ 第5条-6 の要旨: 暗槓に対する搶槓はどんな場合も成立しない
          // → 搶槓の確認は加槓のときだけ行う。
          if (action.type == 'kakan') {
            // 搶槓の確認(一発は保持したまま判定)
            final robbers = await _collectRons(_current, kind, chankan: true);
            if (robbers.isNotEmpty) {
              // 頭ハネ(和了者は1人)
              return _winByRon([robbers.first], _current, kind, chankan: true);
            }
            // 見逃した者にフリテンを立てる(打牌の見逃しと同じ扱い)。
            // 加槓牌は _applyKan で副露面子へ移り河に残らないため、ここで
            // 立てないと捨て牌フリテンでも捕捉できない。
            _markMissedRonFuriten(_current, kind);
          }
          _applyKan(_current, action.type, kind, drawn);
          if (_recordingPaifu) {
            if (action.type == 'ankan') {
              _paifu({
                'type': 'ankan',
                'actor_player_id': _current,
                'block': ankanBlock(me.melds.last.tiles),
              });
            } else {
              final m = me.melds.firstWhere(
                (m) =>
                    m.type == MeldType.kakan &&
                    Tile.normalize(m.calledTile) == kind,
              );
              _paifu({
                'type': 'shominkan',
                'actor_player_id': _current,
                'tile': Tile.dbNotation(m.tiles.last),
                'block': shominkanBlock(meld: m, actorSeat: _current),
              });
            }
            _paifuKanDora();
          }
          for (final s in _seats) {
            s.ippatsu = false;
          }
          _anyCall = true;
          _emitEvent('kan', _current);
          if (_liveWall.isNotEmpty) _liveWall.removeAt(0); // 王牌補充分
          drawn = _rinshanTiles[_kanCount - 1];
          if (_recordingPaifu) {
            _paifu({
              'type': 'draw',
              'actor_player_id': _current,
              'tile': Tile.dbNotation(drawn),
              'is_rinshan': true,
            });
          }
          isRinshan = true;
          _currentDrawn = drawn;
          me.waits = me.calcMyWaits();
          _pushViews();
          continue;
        }
        break; // discard
      }

      // ---- 打牌 ----
      final tile = action.tile;
      final declaringRiichi = action.riichi;
      // ツモ切り判定: 牌は同種同値なので「ツモ牌と同じ牌を手牌から手出し」は
      // 値だけでは区別できない。アクションのフラグ(UIのタップ位置)を優先し、
      // フラグ無し(CPU・旧データ)は従来どおり値の一致で推定する。
      // 手出し扱いは手牌に実際に同じ牌があるときだけ(無いのに手出し扱いに
      // すると下の分岐で手牌が1枚増えてしまう)。
      var isTsumogiri = drawn != null && tile == drawn;
      if (isTsumogiri && action.tsumogiri == false && me.hand.contains(tile)) {
        isTsumogiri = false;
      }
      if (isTsumogiri) {
        // ツモ切り
      } else {
        me.hand.remove(tile);
        if (drawn != null) me.hand.add(drawn);
        me.sortHand();
      }
      if (me.riichi && !declaringRiichi) me.ippatsu = false;
      if (declaringRiichi) {
        // Mリーグ:「リーチは、門前清であればかける事ができ、リーチ宣言牌に
        // 対してロンがなければ成立する。」
        // ここではまだ成立が確定しないので、供託(1000点)は出さない。
        // 宣言牌が通ってから下で確定させる。
        me.riichi = true;
        me.doubleRiichi = me.discards.isEmpty && !_anyCall;
        me.ippatsu = true;
        _emitEvent('riichi', _current);
      }
      me.discards.add(
        DiscardInfo(
          tile,
          riichi: declaringRiichi,
          tsumogiri: isTsumogiri,
          order: _discardOrder++,
        ),
      );
      if (_recordingPaifu) {
        // 本家DBはリーチイベントが宣言打牌の**前**に来る。成立(is_accepted)は
        // まだ分からないので true で置き、宣言牌ロンなら後から倒す。
        if (declaringRiichi) {
          _paifuReachIdx = _paifuEvents.length;
          _paifu({
            'type': 'reach',
            'actor_player_id': _current,
            'is_accepted': true,
          });
        }
        _paifu({
          'type': 'discard',
          'actor_player_id': _current,
          'tile': Tile.dbNotation(tile),
          'is_reach_declaration': declaringRiichi,
          'is_tsumogiri': isTsumogiri,
        });
      }
      // Mリーグ:「同巡内フリテンは自己の摸打の完了を経て解消される。」
      // 自分の打牌が完了した時点で解除する。ツモ番だけでなく、鳴いた直後の
      // 打牌でも解除される(鳴きにはツモが無いため、ツモ時のみの解除では
      // 鳴いた後もフリテンが残ってしまっていた)。
      me.tempFuriten = false;
      _currentDrawn = null;
      me.waits = me.calcMyWaits();
      _pushViews();

      // ---- 他家の反応 ----
      final reaction = await _collectReactions(_current, tile);
      if (reaction.rons.isNotEmpty) {
        if (declaringRiichi) {
          // 宣言牌をロンされた = リーチ不成立。供託は出していないので、
          // 和了者が受け取る供託にも含まれない。リーチも付かない。
          me.riichi = false;
          me.doubleRiichi = false;
          me.ippatsu = false;
          me.discards.last = me.discards.last.copyWith(riichi: false);
          if (_paifuReachIdx >= 0 && _paifuReachIdx < _paifuEvents.length) {
            _paifuEvents[_paifuReachIdx]['is_accepted'] = false;
          }
        }
        // 頭ハネ(Mリーグルール: アガリ者は1人)
        return _winByRon([reaction.rons.first], _current, tile);
      }
      // 宣言牌が通ったのでリーチ成立。ここで初めて供託を出す。
      // (チー・ポン・カンされた場合も成立する。Mリーグ:「リーチ宣言牌に対して、
      //  チー・ポン・カンがあった場合は、次巡の打牌を横にする。」)
      if (declaringRiichi) {
        me.score -= 1000;
        _riichiSticks++;
        _statRiichis[_current]++;
      }
      // 見逃しフリテン
      final tileKind = Tile.normalize(tile);
      _markMissedRonFuriten(_current, tileKind);

      if (reaction.caller != null) {
        final caller = reaction.caller!;
        final act = reaction.action!;
        me.discards.last = me.discards.last.copyWith(calledAway: true);
        for (final s in _seats) {
          s.ippatsu = false;
        }
        _anyCall = true;
        final callerState = _seats[caller];

        if (act.type == 'kan') {
          // 大明槓
          final taken = [
            _takeTileOfKind(callerState.hand, tileKind),
            _takeTileOfKind(callerState.hand, tileKind),
            _takeTileOfKind(callerState.hand, tileKind),
            tile,
          ]..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
          callerState.melds.add(
            Meld(
              type: MeldType.minkan,
              tiles: taken,
              fromSeat: _current,
              calledTile: tile,
            ),
          );
          _kanCount++;
          _checkPao(caller, _current, tileKind);
          if (callerState.melds.where((m) => m.isKan).length == 4) {
            callerState.paoSuukantsu = _current;
          }
          if (_recordingPaifu) {
            _paifu({
              'type': 'daiminkan',
              'actor_player_id': caller,
              'target_player_id': _current,
              'tile': Tile.dbNotation(tile),
              'block': callBlock(
                tiles: taken,
                calledTile: tile,
                relative: (_current - caller + 4) % 4,
              ),
            });
            _paifuKanDora();
          }
          _emitEvent('kan', caller);
          if (_liveWall.isNotEmpty) _liveWall.removeAt(0);
          carriedDrawn = _rinshanTiles[_kanCount - 1];
          if (_recordingPaifu) {
            _paifu({
              'type': 'draw',
              'actor_player_id': caller,
              'tile': Tile.dbNotation(carriedDrawn),
              'is_rinshan': true,
            });
          }
          carriedRinshan = true;
          _current = caller;
          afterCall = false;
          forbidden = [];
        } else if (act.type == 'pon') {
          // 晒す2枚: 指定があればそれを、無ければ既定(赤温存)。
          final expose = act.tiles.length == 2
              ? act.tiles
              : defaultPonExpose(callerState.hand, tileKind);
          final taken = [
            _takeExactTile(callerState.hand, expose[0]),
            _takeExactTile(callerState.hand, expose[1]),
            tile,
          ]..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
          callerState.melds.add(
            Meld(
              type: MeldType.pon,
              tiles: taken,
              fromSeat: _current,
              calledTile: tile,
            ),
          );
          _checkPao(caller, _current, tileKind);
          if (_recordingPaifu) {
            _paifu({
              'type': 'pon',
              'actor_player_id': caller,
              'target_player_id': _current,
              'tile': Tile.dbNotation(tile),
              'block': callBlock(
                tiles: taken,
                calledTile: tile,
                relative: (_current - caller + 4) % 4,
              ),
            });
          }
          _emitEvent('pon', caller);
          _current = caller;
          afterCall = true;
          forbidden = ponKuikaeForbidden(tileKind);
        } else {
          // チー: 指定の実牌(赤/通常)を使う
          final a = _takeExactTile(callerState.hand, act.tiles[0]);
          final b = _takeExactTile(callerState.hand, act.tiles[1]);
          final run = [tile, a, b]
            ..sort((x, y) => Tile.sortKey(x) - Tile.sortKey(y));
          callerState.melds.add(
            Meld(
              type: MeldType.chi,
              tiles: run,
              fromSeat: _current,
              calledTile: tile,
            ),
          );
          if (_recordingPaifu) {
            _paifu({
              'type': 'chi',
              'actor_player_id': caller,
              'target_player_id': _current,
              'tile': Tile.dbNotation(tile),
              'block': chiBlock(tiles: run, calledTile: tile),
            });
          }
          _emitEvent('chi', caller);
          _current = caller;
          afterCall = true;
          forbidden = chiKuikaeForbidden(
            run.map(Tile.normalize).toList()..sort(),
            tileKind,
          );
        }
        callerState.sortHand();
        callerState.waits = callerState.calcMyWaits();
        _pushViews();
        continue;
      }

      _current = (_current + 1) % 4;
      afterCall = false;
      forbidden = [];
    }
  }

  /// 手牌から指定牌種を1枚取り出す(通常牌を優先し赤を温存)
  int _takeTileOfKind(List<int> hand, int kind) {
    var idx = hand.indexOf(kind);
    if (idx < 0) {
      idx = hand.indexWhere((t) => Tile.normalize(t) == kind);
    }
    return hand.removeAt(idx);
  }

  /// 手牌から指定の実牌を取り出す(赤/通常の指定を厳密に)。
  /// 指定牌が無ければ同種の任意牌にフォールバック。
  int _takeExactTile(List<int> hand, int tileId) {
    var idx = hand.indexOf(tileId);
    if (idx < 0) {
      idx = hand.indexWhere((t) => Tile.normalize(t) == Tile.normalize(tileId));
    }
    return hand.removeAt(idx);
  }

  /// 責任払いの成立チェック(3つ目の三元牌・4つ目の風牌を鳴かせた場合)
  void _checkPao(int caller, int discarder, int calledKind) {
    final s = _seats[caller];
    final marks = paoMarks(s.melds, calledKind);
    if (marks.daisangen) s.paoDaisangen = discarder;
    if (marks.daisuushi) s.paoDaisuushi = discarder;
  }

  // ---------------- プロンプト構築 ----------------

  TurnPrompt _buildTurnPrompt(
    int seat,
    int? drawn,
    bool isRinshan,
    List<int> forbidden,
  ) {
    final s = _seats[seat];
    var canTsumo = false;
    final ankan = <int>[];
    final kakan = <int>[];
    final riichiTiles = <int>[];

    if (drawn != null) {
      final full = [...s.hand, drawn];
      final counts = toCounts(full);
      if (isWinningHand(counts, meldCount: s.melds.length)) {
        canTsumo =
            _evalWin(seat, drawn, isTsumo: true, isRinshan: isRinshan) != null;
      }

      final canKanNow = kanAllowed(
        kanCount: _kanCount,
        wallRemaining: _liveWall.length,
      );
      if (canKanNow) {
        for (var k = 0; k < Tile.kindCount; k++) {
          if (counts[k] == 4) ankan.add(k);
        }
        if (!s.riichi) {
          for (final m in s.melds) {
            final kind = Tile.normalize(m.tiles[0]);
            if (m.type == MeldType.pon &&
                full.any((t) => Tile.normalize(t) == kind)) {
              kakan.add(kind);
            }
          }
        }
        if (s.riichi) {
          // リーチ中の暗槓は次の3条件をすべて満たす場合のみ。
          // Mリーグ:「リーチ後の不正なカンは…チョンボとなる。」
          // 1. ツモ牌での暗槓であること(送り槓禁止)
          ankan.removeWhere((k) => k != Tile.normalize(drawn));
          // 2. 待ちが変わらないこと
          ankan.removeWhere((k) {
            final reduced = List<int>.from(counts);
            reduced[k] -= 4;
            // 槓した4枚は副露側へ移る。s.waits と同じ基準で比較する。
            final meldsAfter = List<int>.from(s.meldCounts)..[k] += 4;
            final newWaits = calcLiveWaits(
              reduced,
              meldsAfter,
              meldCount: s.melds.length + 1,
            );
            return newWaits.toString() != s.waits.toString();
          });
          // 3. 面子構成が変わらないこと
          //    (4枚目を順子や雀頭にも使える形は、暗槓がその解釈を消すため不可)
          ankan.removeWhere((k) {
            final before = List<int>.from(counts)..[k] -= 1; // ツモ牌を除いた聴牌手
            return !ankanKeepsComposition(before, k, s.waits);
          });
        }
      }

      // リーチ宣言可能な打牌。
      // Mリーグルール:
      // - 持ち点1000点未満でもリーチ可能
      // - 「フリテンリーチやツモ番のないリーチもかける事ができる。
      //    (海底牌を摸した者はリーチを掛ける事はできない。)」
      //   → 山の残り枚数は問わない。海底牌を摸した時(=_liveWall が空)のみ不可。
      if (!s.riichi && s.isMenzen && _liveWall.isNotEmpty) {
        final seen = <int>{};
        final meldCounts = s.meldCounts;
        for (final t in full) {
          if (!seen.add(t)) continue;
          final counts2 = toCounts(full)..[Tile.normalize(t)] -= 1;
          // 打牌後にアガリ得る待ちが残る場合のみリーチ可
          // (自分で4枚使い切った待ちしかない形はノーテン扱い)
          if (calcLiveWaits(
            counts2,
            meldCounts,
            meldCount: s.melds.length,
          ).isNotEmpty) {
            riichiTiles.add(t);
          }
        }
      }
    }

    return TurnPrompt(
      drawnTile: drawn,
      canTsumo: canTsumo,
      riichiTiles: riichiTiles,
      ankanKinds: ankan,
      kakanKinds: kakan,
      forbiddenDiscards: forbidden,
      riichiLocked: s.riichi,
    );
  }

  TurnAction _sanitizeTurnAction(
    TurnAction action,
    TurnPrompt prompt,
    int? drawn,
  ) {
    final s = _seats[_current];
    switch (action.type) {
      case 'tsumo':
        if (prompt.canTsumo) return action;
      case 'ankan':
        if (prompt.ankanKinds.contains(action.tile)) return action;
      case 'kakan':
        if (prompt.kakanKinds.contains(action.tile)) return action;
      case 'discard':
        final tile = action.tile;
        final inHand = s.hand.contains(tile) || tile == drawn;
        if (!inHand) break;
        if (s.riichi && tile != drawn) break; // リーチ中はツモ切りのみ
        final kind = Tile.normalize(tile);
        if (prompt.forbiddenDiscards.contains(kind) &&
            s.hand
                .where(
                  (t) => !prompt.forbiddenDiscards.contains(Tile.normalize(t)),
                )
                .isNotEmpty) {
          break;
        }
        if (action.riichi && !prompt.riichiTiles.contains(tile)) {
          return TurnAction.discard(tile, tsumogiri: action.tsumogiri);
        }
        return action;
    }
    // フォールバック: ツモ切り、または喰い替えにならない適当な牌
    if (drawn != null) return TurnAction.discard(drawn);
    final candidates = s.hand
        .where((t) => !prompt.forbiddenDiscards.contains(Tile.normalize(t)))
        .toList();
    return TurnAction.discard(
      candidates.isEmpty ? s.hand.first : candidates.first,
    );
  }

  void _applyKan(int seat, String type, int kind, int? drawn) {
    final s = _seats[seat];
    if (type == 'ankan') {
      final full = [...s.hand, ?drawn];
      final taken = <int>[];
      final rest = <int>[];
      for (final t in full) {
        if (Tile.normalize(t) == kind && taken.length < 4) {
          taken.add(t);
        } else {
          rest.add(t);
        }
      }
      s.hand = rest;
      // 赤入りの暗槓は赤が表向きに見えるよう2枚目に置く
      taken.sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
      final redIdx = taken.indexWhere(Tile.isRed);
      if (redIdx >= 0) {
        taken.insert(1, taken.removeAt(redIdx));
      }
      s.melds.add(
        Meld(
          type: MeldType.ankan,
          tiles: taken,
          fromSeat: -1,
          calledTile: taken[1],
        ),
      );
    } else {
      // 加槓: ポン面子に4枚目を足す
      final full = [...s.hand, ?drawn];
      int? used;
      final rest = <int>[];
      for (final t in full) {
        if (used == null && Tile.normalize(t) == kind) {
          used = t;
        } else {
          rest.add(t);
        }
      }
      s.hand = rest;
      final idx = s.melds.indexWhere(
        (m) => m.type == MeldType.pon && Tile.normalize(m.tiles[0]) == kind,
      );
      final old = s.melds[idx];
      s.melds[idx] = Meld(
        type: MeldType.kakan,
        tiles: [...old.tiles, used!],
        fromSeat: old.fromSeat,
        calledTile: old.calledTile,
      );
    }
    s.sortHand();
    _kanCount++;
    _currentDrawn = null;
  }

  // ---------------- 反応の収集と解決 ----------------

  ({List<int> rons, int? caller, ReactAction? action}) _emptyReaction() =>
      (rons: <int>[], caller: null, action: null);

  Future<List<int>> _collectRons(
    int fromSeat,
    int tile, {
    bool chankan = false,
  }) async {
    final result = await _collectReactionsInner(
      fromSeat,
      tile,
      ronOnly: true,
      chankan: chankan,
    );
    return result.rons;
  }

  Future<({List<int> rons, int? caller, ReactAction? action})>
  _collectReactions(int fromSeat, int tile) =>
      _collectReactionsInner(fromSeat, tile, ronOnly: false, chankan: false);

  Future<({List<int> rons, int? caller, ReactAction? action})>
  _collectReactionsInner(
    int fromSeat,
    int tile, {
    required bool ronOnly,
    required bool chankan,
  }) async {
    final prompts = <int, ReactPrompt>{};
    final houtei = _liveWall.isEmpty;
    final kind = Tile.normalize(tile);

    for (var i = 0; i < 4; i++) {
      if (i == fromSeat) continue;
      final s = _seats[i];
      var canRon = false;
      if (s.waits.contains(kind) && !s.isFuriten) {
        canRon = _evalWin(i, tile, isTsumo: false, isChankan: chankan) != null;
      }
      var canPon = false;
      var canKan = false;
      final chiOptions = <List<int>>[];
      final ponOptions = <List<int>>[];
      if (!ronOnly && !houtei && !s.riichi) {
        final owned = s.hand.where((t) => Tile.normalize(t) == kind).toList()
          ..sort(); // 通常牌(小ID)→赤牌(大ID)の順
        canPon = owned.length >= 2;
        canKan =
            owned.length >= 3 &&
            kanAllowed(kanCount: _kanCount, wallRemaining: _liveWall.length);
        if (canPon) ponOptions.addAll(ponExposeOptions(s.hand, kind));
        if (i == (fromSeat + 1) % 4) {
          chiOptions.addAll(chiTileOptions(s.hand, kind));
        }
      }
      if (canRon || canPon || canKan || chiOptions.isNotEmpty) {
        prompts[i] = ReactPrompt(
          fromSeat: fromSeat,
          tile: tile,
          canRon: canRon,
          canPon: canPon,
          canKan: canKan,
          chiOptions: chiOptions,
          ponOptions: ponOptions,
          isChankan: chankan,
        );
      }
    }
    if (prompts.isEmpty) return _emptyReaction();

    final seatsAsked = prompts.keys.toList();
    final answers = await Future.wait(
      seatsAsked.map((seat) => _askReact(seat, prompts[seat]!)),
    );

    // 優先順位: ロン(複数可)> ポン・カン > チー
    final rons = <int>[];
    // 放銃者から反時計回りに近い順
    for (var d = 1; d < 4; d++) {
      final seat = (fromSeat + d) % 4;
      final idx = seatsAsked.indexOf(seat);
      if (idx < 0) continue;
      final a = answers[idx];
      if (a.type == 'ron' && prompts[seat]!.canRon) rons.add(seat);
    }
    if (rons.isNotEmpty) return (rons: rons, caller: null, action: null);

    for (var i = 0; i < seatsAsked.length; i++) {
      final seat = seatsAsked[i];
      final a = answers[i];
      if (a.type == 'pon' && prompts[seat]!.canPon) {
        return (rons: <int>[], caller: seat, action: a);
      }
      if (a.type == 'kan' && prompts[seat]!.canKan) {
        return (rons: <int>[], caller: seat, action: a);
      }
    }
    for (var i = 0; i < seatsAsked.length; i++) {
      final seat = seatsAsked[i];
      final a = answers[i];
      if (a.type == 'chi') {
        final valid =
            a.tiles.length == 2 &&
            prompts[seat]!.chiOptions.any(
              (o) => o[0] == a.tiles[0] && o[1] == a.tiles[1],
            );
        if (valid) return (rons: <int>[], caller: seat, action: a);
      }
    }
    return _emptyReaction();
  }

  // ---------------- 和了・流局 ----------------

  WinScore? _evalWin(
    int seat,
    int winTile, {
    required bool isTsumo,
    bool isRinshan = false,
    bool isChankan = false,
  }) {
    final s = _seats[seat];
    // 海底・河底・天和・地和・自風の判定は buildWinContext に一元化
    // (記録エンジンと共有。isHoutei は「山0のロン(搶槓を除く)」として
    // 内部で導出され、全呼び出し箇所で従来の引数と等価)
    return evaluateWin(
      buildWinContext(
        concealed: [...s.hand, winTile],
        melds: s.melds,
        winTile: winTile,
        isTsumo: isTsumo,
        isRiichi: s.riichi,
        isDoubleRiichi: s.doubleRiichi,
        isIppatsu: s.ippatsu,
        wallEmpty: _liveWall.isEmpty,
        isRinshan: isRinshan,
        isChankan: isChankan,
        firstTurn: s.discards.isEmpty && !_anyCall,
        seat: seat,
        dealer: _dealer,
        roundWind: _roundWind,
        doraIndicators: _doraIndicators.take(1 + _kanCount).toList(),
        uraIndicators: s.riichi
            ? _uraIndicators.take(1 + _kanCount).toList()
            : const [],
      ),
    );
  }

  /// 責任払いの対象(該当役満を包んだ席と役満数)
  (int, int) _paoFor(int seat, WinScore score) {
    final s = _seats[seat];
    return paoFor(
      score,
      paoDaisangen: s.paoDaisangen,
      paoDaisuushi: s.paoDaisuushi,
      paoSuukantsu: s.paoSuukantsu,
    );
  }

  HandResult _winByTsumo(int seat, int winTile, bool isRinshan) {
    final s = _seats[seat];
    final score = _evalWin(seat, winTile, isTsumo: true, isRinshan: isRinshan)!;
    final (paoSeat, paoCount) = _paoFor(seat, score);
    // 供託・本場・責任払い込みの点数移動(payout.dart、記録エンジンと共有)
    final payout = winPayout(
      score: score,
      seat: seat,
      dealer: _dealer,
      honba: _honba,
      riichiSticks: _riichiSticks,
      paoSeat: paoSeat,
      paoCount: paoCount,
    );
    final changes = payout.changes;
    final declared = payout.declared; // 供託を除く申告点(表示用)
    _applyChanges(changes);
    _riichiSticks = 0;
    _statWins[seat]++;
    _emitEvent('tsumo', seat);
    if (_recordingPaifu) {
      if (s.riichi) {
        _paifuUraDora(_uraIndicators.take(1 + _kanCount).toList());
      }
      _paifu(
        _paifuAgari(
          type: 'tsumo',
          seat: seat,
          fromSeat: null,
          winTile: winTile,
          score: score,
          label: _basePaymentLabel(score),
          declared: declared,
          total: changes[seat],
        ),
      );
    }

    final win = WinInfo(
      seat: seat,
      fromSeat: -1,
      winTile: winTile,
      score: score,
      points: declared, // 上段表示は供託を含まない申告点
      label: _basePaymentLabel(score),
      hand: _sortedHand([...s.hand, winTile]),
      melds: List<Meld>.from(s.melds),
    );
    return HandResult(
      type: 'win',
      wins: [win],
      scoreChanges: changes,
      scores: scores,
      uraIndicators: s.riichi
          ? _uraIndicators.take(1 + _kanCount).toList()
          : const [],
      revealedHands: {seat: win.hand},
      dealerContinues: seat == _dealer,
    );
  }

  HandResult _winByRon(
    List<int> winners,
    int fromSeat,
    int tile, {
    bool chankan = false,
  }) {
    final changes = List<int>.filled(4, 0);
    final wins = <WinInfo>[];
    final revealed = <int, List<int>>{};
    var anyRiichiWinner = false;
    var first = true;
    for (final seat in winners) {
      final s = _seats[seat];
      final score = _evalWin(seat, tile, isTsumo: false, isChankan: chankan)!;
      // 供託・本場は1人目だけ。責任払いの折半込み(payout.dart、記録側と共有)
      final (paoSeat, paoCount) = _paoFor(seat, score);
      final payout = winPayout(
        score: score,
        seat: seat,
        dealer: _dealer,
        fromSeat: fromSeat,
        honba: first ? _honba : 0,
        riichiSticks: first ? _riichiSticks : 0,
        paoSeat: paoSeat,
        paoCount: paoCount,
      );
      for (var i = 0; i < 4; i++) {
        changes[i] += payout.changes[i];
      }
      final hand = _sortedHand([...s.hand, tile]);
      wins.add(
        WinInfo(
          seat: seat,
          fromSeat: fromSeat,
          winTile: tile,
          score: score,
          points: payout.declared, // 上段表示は供託を含まない申告点
          label: payout.label,
          hand: hand,
          melds: List<Meld>.from(s.melds),
        ),
      );
      revealed[seat] = hand;
      if (s.riichi) anyRiichiWinner = true;
      first = false;
    }
    _applyChanges(changes);
    _riichiSticks = 0;
    for (final seat in winners) {
      _statWins[seat]++;
    }
    _statDealIns[fromSeat]++;
    _emitEvent('ron', winners.first);
    if (_recordingPaifu) {
      if (anyRiichiWinner) {
        _paifuUraDora(_uraIndicators.take(1 + _kanCount).toList());
      }
      for (final w in wins) {
        _paifu(
          _paifuAgari(
            type: 'ron',
            seat: w.seat,
            fromSeat: fromSeat,
            winTile: tile,
            score: w.score,
            label: w.label,
            declared: w.points,
            total: changes[w.seat],
          ),
        );
      }
    }
    return HandResult(
      type: 'win',
      wins: wins,
      scoreChanges: changes,
      scores: scores,
      uraIndicators: anyRiichiWinner
          ? _uraIndicators.take(1 + _kanCount).toList()
          : const [],
      revealedHands: revealed,
      dealerContinues: winners.contains(_dealer),
    );
  }

  HandResult _ryuukyoku() {
    final tenpai = <int>[];
    final revealed = <int, List<int>>{};
    for (var i = 0; i < 4; i++) {
      final s = _seats[i];
      // Mリーグルール: アガリ牌を自分で4枚使い切っている形はテンパイと
      // 認められない(calcMyWaits がその待ちを除く)。
      s.waits = s.calcMyWaits();
      if (s.waits.isNotEmpty) {
        tenpai.add(i);
        revealed[i] = List<int>.from(s.hand);
      }
    }
    final changes = ryukyokuChanges(tenpai); // ノーテン罰符(記録側と共有)
    _applyChanges(changes);
    _emitEvent('draw', -1);
    if (_recordingPaifu) {
      _paifu({
        'type': 'ryukyoku',
        'players': [
          for (var i = 0; i < 4; i++)
            {
              'player_id': i,
              'is_tenpai': tenpai.contains(i),
              'points': changes[i],
            },
        ],
      });
    }
    return HandResult(
      type: 'draw',
      tenpaiSeats: tenpai,
      scoreChanges: changes,
      scores: scores,
      revealedHands: revealed,
      dealerContinues: tenpai.contains(_dealer),
    );
  }

  void _applyChanges(List<int> changes) {
    for (var i = 0; i < 4; i++) {
      _seats[i].score += changes[i];
    }
  }

  List<int> _sortedHand(List<int> tiles) =>
      tiles..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));

  String _basePaymentLabel(WinScore score) => calcPayment(
    score: score,
    isDealer: false,
    isTsumo: false,
    honba: 0,
    riichiSticks: 0,
  ).label;
}
