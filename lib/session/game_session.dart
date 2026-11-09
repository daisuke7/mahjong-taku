/// UI が対局に参加するための抽象セッション
library;

import 'dart:async';

import '../engine/game_engine.dart';
import '../engine/models.dart';
import '../net/protocol.dart';
import 'suspend.dart';

/// 対局画面が消費するインターフェース。
/// ソロ(=ホスト+CPU)、LANホスト、LANクライアントで実装が分かれる。
abstract class GameSession {
  int get youSeat;
  bool get isHost;

  /// ギャラリー(観戦)モードか。観戦中は打牌などの操作UIを出さない
  /// (プロンプト自体も届かない)。
  bool get isSpectator;

  /// 観戦希望の通知(ホストのみ流れる。許可/拒否を選ぶ)
  Stream<SpectateRequest> get spectateRequests;

  GameView? get latestView;
  TurnPrompt? get activeTurnPrompt;
  ReactPrompt? get activeReactPrompt;

  Stream<GameView> get views;
  Stream<TurnPrompt> get turnPrompts;
  Stream<ReactPrompt> get reactPrompts;

  /// 顔文字キャストの受信(全席分)
  Stream<EmoteCast> get emotes;

  /// 接続状態(クライアントのみ意味を持つ。ホスト・ソロは常に true)
  Stream<bool> get connectionState;
  bool get isConnected;

  void sendTurn(TurnAction action);
  void sendReact(ReactAction action);

  /// 顔文字を全席に送る(いつでも呼べる)
  void sendEmote(int emoji);

  /// 局結果画面から次の局へ(ホストのみ有効)
  void advance();

  /// 試合終了画面から次の試合へ(ホストのみ有効)
  void nextGame();

  /// 対局を中断し、保存すべき復帰情報を返す(ホストのみ。非ホストは null)。
  /// 呼び出し後はエンジンが停止し、クライアントには中断通知が届く。
  Future<SuspendedHostGame?> suspend();

  /// ホストが対局を中断した通知(クライアントのみ流れる)
  Stream<SuspendNotice> get suspendNotices;

  Future<void> dispose();
}

/// 試合間の「次の試合へ / 終了」待ち
class NextGameGate {
  Completer<bool>? _completer;

  Future<bool> wait() {
    _completer ??= Completer<bool>();
    return _completer!.future;
  }

  void decide(bool again) {
    final c = _completer;
    _completer = null;
    if (c != null && !c.isCompleted) c.complete(again);
  }
}

/// 人間プレイヤーのUIをエンジンに接続するエージェント
class UiAgent implements PlayerAgent {
  final _views = StreamController<GameView>.broadcast();
  final _turnPrompts = StreamController<TurnPrompt>.broadcast();
  final _reactPrompts = StreamController<ReactPrompt>.broadcast();
  final _emotes = StreamController<EmoteCast>.broadcast();

  GameView? latestView;
  TurnPrompt? activeTurnPrompt;
  ReactPrompt? activeReactPrompt;

  Completer<TurnAction>? _turnCompleter;
  Completer<ReactAction>? _reactCompleter;

  Stream<GameView> get views => _views.stream;
  Stream<TurnPrompt> get turnPrompts => _turnPrompts.stream;
  Stream<ReactPrompt> get reactPrompts => _reactPrompts.stream;
  Stream<EmoteCast> get emotes => _emotes.stream;

  @override
  void onEmote(int seat, int emoji) {
    if (!_emotes.isClosed) _emotes.add(EmoteCast(seat, emoji));
  }

  @override
  void onView(GameView view) {
    latestView = view;
    if (!_views.isClosed) _views.add(view);
  }

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) {
    activeTurnPrompt = prompt;
    _turnCompleter = Completer<TurnAction>();
    if (!_turnPrompts.isClosed) _turnPrompts.add(prompt);
    return _turnCompleter!.future;
  }

  @override
  Future<ReactAction> onReact(ReactPrompt prompt) {
    activeReactPrompt = prompt;
    _reactCompleter = Completer<ReactAction>();
    if (!_reactPrompts.isClosed) _reactPrompts.add(prompt);
    return _reactCompleter!.future;
  }

  void submitTurn(TurnAction action) {
    activeTurnPrompt = null;
    final c = _turnCompleter;
    _turnCompleter = null;
    if (c != null && !c.isCompleted) c.complete(action);
  }

  void submitReact(ReactAction action) {
    activeReactPrompt = null;
    final c = _reactCompleter;
    _reactCompleter = null;
    if (c != null && !c.isCompleted) c.complete(action);
  }

  void close() {
    _views.close();
    _turnPrompts.close();
    _reactPrompts.close();
    _emotes.close();
  }
}
