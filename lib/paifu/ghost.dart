/// ゴーストモード: 牌譜再生の任意の時点から自分が選手になりきって打つ。
///
/// 実エンジン([GameEngine])を「その局だけ」の山と局情報で起動し、4席を
/// 牌譜スクリプト追従エージェントで駆動する。ポーズ位置(突入点)までは
/// 全席が記録どおりに高速再現され、突入点以降は乗り移った席の操作だけが
/// 人間([UiAgent])に渡る。他家は記録どおりに打てる限り記録に従い、
/// ゴーストの介入で記録どおりの操作ができなくなった席はCPUが代行する
/// (名前に👻が付く)。
///
/// 山は記録が残っている牌をエンジンの取り出し位置に正確に置き、記録に
/// 無い位置は「まだ山にあり得る牌」をシャッフルして充填する。誰かが
/// アガるか流局した時点でゴーストは終了し、結果は捨てられて牌譜再生に戻る
/// (終了処理は [ReplaySession] 側)。
library;

import 'dart:async';
import 'dart:math';

import '../engine/ai.dart';
import '../engine/game_engine.dart';
import '../engine/models.dart';
import '../engine/resume.dart';
import '../engine/tile.dart';
import '../session/game_session.dart';
import 'paifu_db.dart';

/// 牌譜の記録からエンジンの山(136枚)を再構成する。
///
/// エンジンの取り出し順(`GameEngine._playHand`)に合わせる:
/// - 王牌14枚 = wall[0..13](嶺上 0..3 / 表ドラ表示 4..8 / 裏ドラ 9..13)
/// - 配牌は山の**末尾**から親→南→西→北の順に1枚ずつ52枚(wall[84..135])
/// - 以後の通常ツモは wall[83] から降順(カンでの先頭除去は末尾順に影響しない)
/// - n回目のカンの嶺上牌は wall[n-1]
///
/// 記録に無い位置は「まだ山にあり得る牌」をシャッフルして充填する。
/// 牌譜が欠損していて再構成できない場合は [StateError] を投げる。
List<int> buildGhostWall({
  required List<PaifuEvent> events,
  required Map<int, int> seatOf,
  required int dealer,
  Random? rng,
}) {
  final haipai = List.generate(4, (_) => <int>[]);
  final normalDraws = <int>[];
  final rinshanDraws = <int>[];
  final omote = <int>[];
  final ura = <int>[];
  for (final ev in events) {
    switch (ev.type) {
      case 'haipai':
        haipai[seatOf[ev.actorPlayerId]!] = Tile.parse(ev.hand!);
      case 'draw':
        (ev.rinshan ? rinshanDraws : normalDraws).add(
          Tile.parse(ev.tile!).single,
        );
      case 'dora_indicator':
        (ev.doraType == 'ura' ? ura : omote).add(
          Tile.parse(ev.doraIndicator!).single,
        );
    }
  }
  if (haipai.any((h) => h.length != 13)) {
    throw StateError('配牌が欠損している');
  }
  if (normalDraws.length > 70 || rinshanDraws.length > 4) {
    throw StateError('ツモの記録が多すぎる');
  }

  final wall = List<int>.filled(136, -1);
  for (var r = 0; r < 13; r++) {
    for (var s = 0; s < 4; s++) {
      wall[135 - (r * 4 + s)] = haipai[(dealer + s) % 4][r];
    }
  }
  for (var k = 0; k < normalDraws.length; k++) {
    wall[83 - k] = normalDraws[k];
  }
  for (var i = 0; i < rinshanDraws.length; i++) {
    wall[i] = rinshanDraws[i];
  }
  for (var i = 0; i < omote.length && 4 + i <= 8; i++) {
    wall[4 + i] = omote[i];
  }
  for (var i = 0; i < ura.length && 9 + i <= 13; i++) {
    wall[9 + i] = ura[i];
  }

  // 未知の位置: まだ山にあり得る牌をシャッフルして充填する
  final pool = Tile.fullWall();
  bool takeFromPool(int t) {
    if (pool.remove(t)) return true;
    // 実DBには赤5を通常の5と表記する揺れがある局が少数あるため、
    // 同種の赤/通常牌で代用する(全体の枚数は保たれる)
    final n = Tile.normalize(t);
    return switch (n) {
      4 => pool.remove(Tile.isRed(t) ? n : Tile.red5m),
      13 => pool.remove(Tile.isRed(t) ? n : Tile.red5p),
      22 => pool.remove(Tile.isRed(t) ? n : Tile.red5s),
      _ => false,
    };
  }

  for (final t in wall) {
    if (t >= 0 && !takeFromPool(t)) {
      throw StateError('牌譜の牌が矛盾している: $t');
    }
  }
  pool.shuffle(rng ?? Random());
  for (var i = 0; i < wall.length; i++) {
    if (wall[i] < 0) wall[i] = pool.removeLast();
  }
  return wall;
}

/// 実DBの欠損対応: 親の第1ツモが未記録の局は、最初の打牌の牌をそのまま
/// ツモったとみなしてツモイベントを補う。挿入位置よりあとのカットオフは
/// 1つずらして返す。
(List<PaifuEvent>, int) _patchMissingFirstDraw(
  List<PaifuEvent> events,
  int cutoff,
) {
  for (var i = 0; i < events.length; i++) {
    final ev = events[i];
    if (ev.type == 'draw') return (events, cutoff);
    if (ev.type == 'discard') {
      final patched = [
        ...events.sublist(0, i),
        PaifuEvent(
          type: 'draw',
          order: ev.order,
          actorPlayerId: ev.actorPlayerId,
          tile: ev.tile,
        ),
        ...events.sublist(i),
      ];
      return (patched, cutoff > i ? cutoff + 1 : cutoff);
    }
  }
  return (events, cutoff);
}

/// 牌譜スクリプトの1手(誰かの意思決定に対応するイベント)。
/// ツモ・打牌の順序ずれ検出のため、手番エントリはそのときのツモ牌を持つ。
class _ScriptEntry {
  final int idx; // 局イベント列でのインデックス
  final int seat;
  final TurnAction? turn;
  final int? expectedDrawn; // turn: このときのツモ牌(鳴き直後の打牌は null)
  final ReactAction? react;
  final int reactFrom; // react: 対象の打牌者の席
  final int reactKind; // react: 対象牌の牌種(正規化)

  const _ScriptEntry.turn(this.idx, this.seat, this.turn, this.expectedDrawn)
    : react = null,
      reactFrom = -1,
      reactKind = -1;

  const _ScriptEntry.react(
    this.idx,
    this.seat,
    this.react, {
    required this.reactFrom,
    required this.reactKind,
  }) : turn = null,
       expectedDrawn = null;

  bool get isTurn => turn != null;
}

List<_ScriptEntry> _buildScript(List<PaifuEvent> events, Map<int, int> seatOf) {
  final entries = <_ScriptEntry>[];
  final pendingDrawn = List<int?>.filled(4, null);
  for (var i = 0; i < events.length; i++) {
    final ev = events[i];
    switch (ev.type) {
      case 'draw':
        pendingDrawn[seatOf[ev.actorPlayerId]!] = Tile.parse(ev.tile!).single;
      case 'discard':
        final s = seatOf[ev.actorPlayerId]!;
        final t = Tile.parse(ev.tile!).single;
        entries.add(
          _ScriptEntry.turn(
            i,
            s,
            TurnAction.discard(
              t,
              riichi: ev.reachDeclaration,
              tsumogiri: ev.tsumogiri,
            ),
            pendingDrawn[s],
          ),
        );
        pendingDrawn[s] = null;
      case 'pon' || 'chi' || 'daiminkan':
        final s = seatOf[ev.actorPlayerId]!;
        final target = seatOf[ev.targetPlayerId]!;
        final called = Tile.parse(ev.tile!).single;
        // 鳴いた牌以外 = 手から晒す牌(赤の区別込み)
        final fromHand = parseBlockTiles(ev.block!);
        if (!fromHand.remove(called)) {
          final j = fromHand.indexWhere(
            (t) => Tile.normalize(t) == Tile.normalize(called),
          );
          if (j >= 0) fromHand.removeAt(j);
        }
        final act = switch (ev.type) {
          'pon' => ReactAction.pon(fromHand.length == 2 ? fromHand : const []),
          'chi' => ReactAction.chi(fromHand),
          _ => const ReactAction.kan(),
        };
        entries.add(
          _ScriptEntry.react(
            i,
            s,
            act,
            reactFrom: target,
            reactKind: Tile.normalize(called),
          ),
        );
      case 'shominkan':
        final s = seatOf[ev.actorPlayerId]!;
        final kind = Tile.normalize(Tile.parse(ev.tile!).single);
        entries.add(
          _ScriptEntry.turn(i, s, TurnAction.kakan(kind), pendingDrawn[s]),
        );
        pendingDrawn[s] = null;
      case 'ankan':
        final s = seatOf[ev.actorPlayerId]!;
        final kind = Tile.normalize(parseBlockTiles(ev.block!).first);
        entries.add(
          _ScriptEntry.turn(i, s, TurnAction.ankan(kind), pendingDrawn[s]),
        );
        pendingDrawn[s] = null;
      case 'tsumo':
        final s = seatOf[ev.actorPlayerId]!;
        entries.add(
          _ScriptEntry.turn(i, s, const TurnAction.tsumo(), pendingDrawn[s]),
        );
      case 'ron':
        final s = seatOf[ev.actorPlayerId]!;
        final target = seatOf[ev.targetPlayerId] ?? -1;
        final winTile = Tile.parse(
          ev.winningTile!.replaceFirst(RegExp('^t'), ''),
        ).single;
        entries.add(
          _ScriptEntry.react(
            i,
            s,
            const ReactAction.ron(),
            reactFrom: target,
            reactKind: Tile.normalize(winTile),
          ),
        );
      default:
        break; // haipai / reach / dora_indicator / ryukyoku は意思決定ではない
    }
  }
  return entries;
}

class _GhostScript {
  final List<List<_ScriptEntry>> _bySeat;
  final List<int> _pos = List.filled(4, 0);

  /// このイベントインデックス以降が「ゴースト操作」(ポーズ位置)
  final int cutoff;

  /// ポーズ位置の状態(ライブ地点の判定基準)
  final int baseWallRemaining;
  final int baseDiscards;
  bool _live = false;

  _GhostScript(
    List<_ScriptEntry> entries,
    this.cutoff, {
    required this.baseWallRemaining,
    required this.baseDiscards,
  }) : _bySeat = List.generate(4, (_) => []) {
    for (final e in entries) {
      _bySeat[e.seat].add(e);
    }
  }

  /// 早送り再現がポーズ位置(ライブ地点)まで追いついたか。
  /// 一度 true になったら以後ずっと true。
  bool isLive(GameView? v) {
    if (_live) return true;
    if (v == null) return false;
    final d = v.players.fold(0, (n, p) => n + p.discards.length);
    if (v.wallRemaining < baseWallRemaining ||
        (v.wallRemaining == baseWallRemaining && d >= baseDiscards)) {
      _live = true;
    }
    return _live;
  }

  _ScriptEntry? peek(int seat) {
    final list = _bySeat[seat];
    final p = _pos[seat];
    return p < list.length ? list[p] : null;
  }

  void consume(int seat) {
    if (peek(seat) == null) return;
    _pos[seat]++;
  }
}

/// 牌譜スクリプト追従エージェント。
/// 記録どおりの操作が可能な限り記録を再現し、不可能になったらCPUに委ねる。
/// [ui] が与えられた席(乗り移り席)は、突入点以降の意思決定を人間に渡す。
/// 記録どおりの手番操作を返す直前に呼ばれる観測フック(ベンチマーク用)。
/// [view] はその席の最新ビュー、[scripted] は記録の操作、[cpu] は同じビューを
/// 見ている CPU エージェント(同じプロンプトに対する CPU の判断を取れる)。
typedef ScriptedTurnHook =
    Future<void> Function(
      int seat,
      TurnPrompt prompt,
      GameView? view,
      TurnAction scripted,
      CpuAgent cpu,
    );

/// 記録どおりの反応(見送り含む)を返す直前に呼ばれる観測フック(ベンチマーク用)
typedef ScriptedReactHook =
    Future<void> Function(
      int seat,
      ReactPrompt prompt,
      GameView? view,
      ReactAction scripted,
      CpuAgent cpu,
    );

class _ScriptedAgent implements PlayerAgent {
  final int seat;
  final _GhostScript script;
  final CpuAgent cpu;
  final UiAgent? ui;
  final void Function(int seat) onFellOffScript;
  final void Function(int seat, GameView view) onSeatView;
  final ScriptedTurnHook? onScriptedTurn;
  final ScriptedReactHook? onScriptedReact;

  /// 突入点以降のスクリプト実行に入れるウェイト(自動再生と同程度の体感)。
  /// 突入点までの早送り再現には掛けない。
  final int actionDelayMs;

  bool _onScript = true;
  bool _humanMode = false;
  GameView? _view;

  _ScriptedAgent({
    required this.seat,
    required this.script,
    required this.cpu,
    required this.ui,
    required this.onFellOffScript,
    required this.onSeatView,
    this.actionDelayMs = 0,
    this.onScriptedTurn,
    this.onScriptedReact,
  });

  /// 突入点以降の記録どおりの操作は、間を置いてから返す
  Future<T> _paced<T>(T action, int idx) async {
    if (idx >= script.cutoff && actionDelayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: actionDelayMs));
    }
    return action;
  }

  @override
  void onView(GameView view) {
    _view = view;
    cpu.onView(view);
    onSeatView(seat, view);
  }

  @override
  void onEmote(int seat, int emoji) => ui?.onEmote(seat, emoji);

  void _fallOff() {
    if (!_onScript) return;
    _onScript = false;
    onFellOffScript(seat);
  }

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) {
    if (_humanMode) return ui!.onTurn(prompt);
    if (_onScript) {
      // 乗り移り席: ポーズ位置(ライブ地点)に到達したら以後は人間が決める
      if (ui != null && script.isLive(_view)) {
        _humanMode = true;
        return ui!.onTurn(prompt);
      }
      // リーチ中の自動ツモ切り(プロンプトが来ない)ぶんの記録を読み飛ばす
      if (prompt.riichiLocked) {
        while (true) {
          final e = script.peek(seat);
          final a = e?.turn;
          if (e == null ||
              a == null ||
              a.type != 'discard' ||
              a.riichi ||
              e.expectedDrawn != a.tile ||
              e.expectedDrawn == prompt.drawnTile) {
            break;
          }
          script.consume(seat);
        }
      }
      final e = script.peek(seat);
      if (e != null &&
          e.isTurn &&
          e.expectedDrawn == prompt.drawnTile &&
          _turnFeasible(e.turn!, prompt)) {
        script.consume(seat);
        final hook = onScriptedTurn;
        if (hook != null) {
          return hook(seat, prompt, _view, e.turn!, cpu).then((_) => e.turn!);
        }
        return _paced(e.turn!, e.idx);
      }
      if (ui != null) {
        _humanMode = true; // 乗り移り席は逸脱してもCPUではなく人間へ
        return ui!.onTurn(prompt);
      }
      _fallOff();
    }
    return cpu.onTurn(prompt);
  }

  bool _turnFeasible(TurnAction a, TurnPrompt p) {
    switch (a.type) {
      case 'tsumo':
        return p.canTsumo;
      case 'ankan':
        return p.ankanKinds.contains(a.tile);
      case 'kakan':
        return p.kakanKinds.contains(a.tile);
      case 'discard':
        final hand = _view?.hand ?? const [];
        if (!hand.contains(a.tile) && a.tile != p.drawnTile) return false;
        if (p.riichiLocked && a.tile != p.drawnTile) return false;
        if (a.riichi && !p.riichiTiles.contains(a.tile)) return false;
        if (p.forbiddenDiscards.contains(Tile.normalize(a.tile))) return false;
        return true;
    }
    return false;
  }

  @override
  Future<ReactAction> onReact(ReactPrompt prompt) {
    if (_humanMode) return ui!.onReact(prompt);
    if (_onScript) {
      // 乗り移り席: ポーズ位置(ライブ地点)以降の反応は人間が決める
      if (ui != null && script.isLive(_view)) {
        _humanMode = true;
        return ui!.onReact(prompt);
      }
      final e = script.peek(seat);
      final kind = Tile.normalize(prompt.tile);
      final matches =
          e != null &&
          !e.isTurn &&
          e.reactFrom == prompt.fromSeat &&
          e.reactKind == kind;
      if (matches) {
        final act = _reactIfFeasible(e.react!, prompt);
        if (act != null) {
          script.consume(seat);
          final hook = onScriptedReact;
          if (hook != null) {
            return hook(seat, prompt, _view, act, cpu).then((_) => act);
          }
          return _paced(act, e.idx);
        }
        if (ui != null) {
          _humanMode = true;
          return ui!.onReact(prompt);
        }
        _fallOff();
        return cpu.onReact(prompt);
      }
      // 記録に該当の鳴き・ロンが無い = 記録どおり見送り
      final hook = onScriptedReact;
      if (hook != null) {
        const pass = ReactAction.pass();
        return hook(seat, prompt, _view, pass, cpu).then((_) => pass);
      }
      return Future.value(const ReactAction.pass());
    }
    return cpu.onReact(prompt);
  }

  ReactAction? _reactIfFeasible(ReactAction a, ReactPrompt p) {
    switch (a.type) {
      case 'ron':
        return p.canRon ? a : null;
      case 'pon':
        return p.canPon ? a : null;
      case 'kan':
        return p.canKan ? a : null;
      case 'chi':
        // エンジンは chiOptions の並びで厳密に照合するので、
        // 記録の2枚と同じ組を選択肢から探して使う
        final want = [...a.tiles]..sort();
        for (final o in p.chiOptions) {
          final opt = [...o]..sort();
          if (opt.length == want.length &&
              opt[0] == want[0] &&
              opt[1] == want[1]) {
            return ReactAction.chi(o);
          }
        }
        return null;
    }
    return null;
  }
}

/// ゴーストモードの1局ぶんの実行体。
/// [ReplaySession] が生成し、ここが公開するビュー・プロンプトの単一ストリームを
/// セッションが対局画面へ配管する。
///
/// [everyone] が true(全員ゴースト)の場合は4席全部を人間が操作する。
/// 手番・反応が来た席へ視点(youSeat)を切り替えるホットシート方式で、
/// 「もしここでこれを切ったらどうなるか」を全席分検証できる。
class GhostRun {
  /// 乗り移り席。負なら乗り移りなし(全席が記録追従、逸脱席はCPU代行)で、
  /// ベンチマーク等の観測実行に使う。
  final int youSeat;

  /// 全員ゴースト(全席を自分で操作)か
  final bool everyone;

  final List<String> _baseNames;
  late final GameEngine _engine;

  final List<UiAgent?> _uis = List.filled(4, null); // 乗り移り席のみ非null
  final List<GameView?> _seatViews = List.filled(4, null);
  final List<StreamSubscription<dynamic>> _subs = [];

  final _views = StreamController<GameView>.broadcast();
  final _turnPrompts = StreamController<TurnPrompt>.broadcast();
  final _reactPrompts = StreamController<ReactPrompt>.broadcast();

  int _focusSeat; // いま表示している席(プロンプト待ちの席)
  int? _turnSeat; // 手番応答待ちの席
  int? _reactSeat; // 反応応答待ちの席
  final _reactQueue = <(int, ReactPrompt)>[]; // 同時に来た反応の順番待ち

  Stream<GameView> get views => _views.stream;
  Stream<TurnPrompt> get turnPrompts => _turnPrompts.stream;
  Stream<ReactPrompt> get reactPrompts => _reactPrompts.stream;
  TurnPrompt? get activeTurnPrompt =>
      _turnSeat == null ? null : _uis[_turnSeat!]?.activeTurnPrompt;
  ReactPrompt? get activeReactPrompt =>
      _reactSeat == null ? null : _uis[_reactSeat!]?.activeReactPrompt;

  GhostRun({
    required List<PaifuEvent> events,
    required int cutoff,
    required Map<int, int> seatOf,
    required List<String> names,
    required this.youSeat,
    required int dealer,
    required int roundWind,
    required int kyoku,
    required int honba,
    required int riichiSticks,
    required List<int> scores,
    required int baseWallRemaining,
    required int baseDiscards,
    this.everyone = false,
    List<int>? statWins,
    List<int>? statRiichis,
    List<int>? statDealIns,
    int? seed,
    int cpuThinkMillis = 550,
    int autoPlayDelayMs = 250,
    int scriptActionDelayMs = 0,
    ScriptedTurnHook? onScriptedTurn,
    ScriptedReactHook? onScriptedReact,
    CpuAgent Function(int seat)? cpuFactory,
  }) : _baseNames = names,
       _focusSeat = youSeat {
    final (evs, cut) = _patchMissingFirstDraw(events, cutoff);
    final wall = buildGhostWall(
      events: evs,
      seatOf: seatOf,
      dealer: dealer,
      rng: Random(seed),
    );
    final script = _GhostScript(
      _buildScript(evs, seatOf),
      cut,
      baseWallRemaining: baseWallRemaining,
      baseDiscards: baseDiscards,
    );
    _engine = GameEngine.fromResume(
      ResumeData(
        config: const GameConfig(rounds: 4), // 局単位の再現なので終局判定は使わない
        names: [
          for (var s = 0; s < 4; s++)
            everyone || s == youSeat ? '👻${names[s]}' : names[s],
        ],
        isCpu: const [false, false, false, false],
        seatMember: const [0, 1, 2, 3],
        dealer: dealer,
        roundWind: roundWind,
        kyoku: kyoku,
        honba: honba,
        handsPlayed: 0,
        scores: scores,
        riichiSticks: riichiSticks,
        statWins: statWins ?? List.filled(4, 0),
        statRiichis: statRiichis ?? List.filled(4, 0),
        statDealIns: statDealIns ?? List.filled(4, 0),
        history: const [],
        wall: wall,
        actions: const [],
      ),
      autoPlayDelayMs: autoPlayDelayMs,
      advanceDelayMs: 0,
      seed: seed,
    );
    for (var s = 0; s < 4; s++) {
      if (everyone || s == youSeat) {
        final ui = _uis[s] = UiAgent();
        _subs.add(ui.turnPrompts.listen((p) => _onUiTurnPrompt(s, p)));
        _subs.add(ui.reactPrompts.listen((p) => _onUiReactPrompt(s, p)));
      }
      final cpu =
          cpuFactory?.call(s) ??
          CpuAgent(
            thinkMillis: cpuThinkMillis,
            seed: seed == null ? null : seed + s,
          );
      // 全席「接続中」にする。切断扱いだと対戦モードの「(代打)」表示が
      // 付いてしまう(牌譜上のプレイヤーは全員その場で打っている)。
      // 局終了の確認は ReplaySession 側で完結するので進行には影響しない。
      _engine.setAgent(
        s,
        _ScriptedAgent(
          seat: s,
          script: script,
          cpu: cpu,
          ui: _uis[s],
          onFellOffScript: _markGhosted,
          onSeatView: _onSeatView,
          actionDelayMs: scriptActionDelayMs,
          onScriptedTurn: onScriptedTurn,
          onScriptedReact: onScriptedReact,
        ),
        connected: true,
      );
    }
  }

  /// 再生を開始する(呼び出し側がビュー・プロンプトの配管を終えてから呼ぶ)
  void start() => unawaited(_engine.run());

  /// 表示中の席のビューだけを流す(全員ゴーストでは応答待ちの席に切り替わる)。
  /// [youSeat] が負(乗り移り席なしの観測実行)なら全席のビューを流す。
  void _onSeatView(int seat, GameView view) {
    _seatViews[seat] = view;
    if ((seat == _focusSeat || _focusSeat < 0) && !_views.isClosed) {
      _views.add(view);
    }
  }

  void _setFocus(int seat) {
    if (_focusSeat == seat) return;
    _focusSeat = seat;
    final v = _seatViews[seat];
    if (v != null && !_views.isClosed) _views.add(v);
  }

  void _onUiTurnPrompt(int seat, TurnPrompt p) {
    _turnSeat = seat;
    _setFocus(seat);
    if (!_turnPrompts.isClosed) _turnPrompts.add(p);
  }

  void _onUiReactPrompt(int seat, ReactPrompt p) {
    // 反応は複数席から同時に来得る(例: ポンとロン)。1席ずつ順に問う
    if (_reactSeat != null) {
      _reactQueue.add((seat, p));
      return;
    }
    _activateReact(seat, p);
  }

  void _activateReact(int seat, ReactPrompt p) {
    _reactSeat = seat;
    _setFocus(seat);
    if (!_reactPrompts.isClosed) _reactPrompts.add(p);
  }

  void submitTurn(TurnAction action) {
    final s = _turnSeat;
    if (s == null) return;
    _turnSeat = null;
    _uis[s]?.submitTurn(action);
  }

  void submitReact(ReactAction action) {
    final s = _reactSeat;
    if (s == null) return;
    _reactSeat = null;
    _uis[s]?.submitReact(action);
    if (_reactQueue.isNotEmpty) {
      final (ns, np) = _reactQueue.removeAt(0);
      _activateReact(ns, np);
    }
  }

  /// 記録どおりに打てなくなった席: CPU代行になり名前に👻が付く
  void _markGhosted(int seat) {
    _engine.setSeatStatus(seat, name: '👻${_baseNames[seat]}', isCpu: true);
  }

  /// エンジンを止めて破棄する(ゴーストの結果は捨てる)
  void dispose() {
    _engine.suspendAndCapture();
    for (final sub in _subs) {
      sub.cancel();
    }
    for (final ui in _uis) {
      ui?.close();
    }
    _views.close();
    _turnPrompts.close();
    _reactPrompts.close();
  }
}
