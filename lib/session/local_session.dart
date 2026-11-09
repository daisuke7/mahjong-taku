/// ソロプレイ(自分+CPU3人)のセッション
library;

import 'dart:async';

import '../engine/ai.dart';
import '../engine/game_engine.dart';
import '../engine/display_text.dart';
import '../engine/models.dart';
import '../net/protocol.dart';
import '../paifu/my_paifu_store.dart';
import 'game_session.dart';
import 'suspend.dart';

class LocalSession implements GameSession {
  final UiAgent _ui = UiAgent();
  final NextGameGate _nextGameGate = NextGameGate();
  late final GameEngine _engine;
  final _connection = StreamController<bool>.broadcast();
  final String _playerName;

  LocalSession({
    required String playerName,
    required GameConfig config,
    int cpuThinkMillis = 550,
    int autoPlayDelayMs = 500,
    int advanceDelayMs = 3000,
    int? seed,
  }) : _playerName = playerName {
    _engine = GameEngine(
      config: config,
      names: [playerName, ...cpuPlayerNames.take(3)],
      isCpu: const [false, true, true, true],
      waitNextGame: _nextGameGate.wait,
      autoPlayDelayMs: autoPlayDelayMs,
      advanceDelayMs: advanceDelayMs,
      seed: seed,
    );
    MyPaifuStore.instance.reopen(null); // 新しい試合ファイルで開始
    _engine.paifuRecorder = MyPaifuStore.instance;
    _engine.setAgent(0, _ui);
    for (var i = 1; i < 4; i++) {
      final cpu = CpuAgent(
        thinkMillis: cpuThinkMillis,
        seed: seed == null ? null : seed + i,
      );
      // 席は場決めで動くので固定インデックスではなくエージェント同一性で引く
      cpu.castEmote = (emoji) => _engine.castEmoteFrom(cpu, emoji);
      _engine.setAgent(i, cpu);
    }
    unawaited(_engine.run());
  }

  /// 中断したソロ対局の復帰(ホスト用の復帰情報から再構築する)
  LocalSession.resume(
    SuspendedHostGame saved, {
    int cpuThinkMillis = 550,
    int autoPlayDelayMs = 500,
    int advanceDelayMs = 3000,
    int? seed,
  }) : _playerName = saved.hostName {
    final data = saved.resumeData;
    _engine = GameEngine.fromResume(
      data,
      waitNextGame: _nextGameGate.wait,
      autoPlayDelayMs: autoPlayDelayMs,
      advanceDelayMs: advanceDelayMs,
      seed: seed,
    );
    MyPaifuStore.instance.reopen(saved.paifuGameId);
    _engine.paifuRecorder = MyPaifuStore.instance;
    for (var seat = 0; seat < 4; seat++) {
      if (data.names[seat] == saved.hostName) {
        _engine.setAgent(seat, _ui, connected: true);
      } else {
        final cpu = CpuAgent(
          thinkMillis: cpuThinkMillis,
          seed: seed == null ? null : seed + seat,
        );
        cpu.castEmote = (emoji) => _engine.castEmoteFrom(cpu, emoji);
        _engine.setAgent(seat, cpu);
      }
    }
    unawaited(_engine.run());
  }

  @override
  int get youSeat => _ui.latestView?.youSeat ?? 0;

  @override
  bool get isHost => true;

  @override
  bool get isSpectator => false;

  @override
  Stream<SpectateRequest> get spectateRequests => const Stream.empty();

  @override
  GameView? get latestView => _ui.latestView;

  @override
  TurnPrompt? get activeTurnPrompt => _ui.activeTurnPrompt;

  @override
  ReactPrompt? get activeReactPrompt => _ui.activeReactPrompt;

  @override
  Stream<GameView> get views => _ui.views;

  @override
  Stream<TurnPrompt> get turnPrompts => _ui.turnPrompts;

  @override
  Stream<ReactPrompt> get reactPrompts => _ui.reactPrompts;

  @override
  Stream<EmoteCast> get emotes => _ui.emotes;

  @override
  Stream<bool> get connectionState => _connection.stream;

  @override
  bool get isConnected => true;

  @override
  void sendTurn(TurnAction action) => _ui.submitTurn(action);

  @override
  void sendReact(ReactAction action) => _ui.submitReact(action);

  @override
  void sendEmote(int emoji) => _engine.castEmote(youSeat, emoji);

  @override
  void advance() => _engine.ackAdvance(_ui.latestView?.youSeat ?? 0);

  @override
  void nextGame() => _nextGameGate.decide(true);

  @override
  Future<SuspendedHostGame?> suspend() async {
    final data = _engine.suspendAndCapture();
    return SuspendedHostGame.capture(
      roomName: '$_playerNameの卓',
      hostName: _playerName,
      data: data,
      savedAt: DateTime.now(),
      paifuGameId: MyPaifuStore.instance.currentGameId,
    );
  }

  @override
  Stream<SuspendNotice> get suspendNotices => const Stream.empty();

  @override
  Future<void> dispose() async {
    _nextGameGate.decide(false);
    _ui.close();
    await _connection.close();
  }
}
