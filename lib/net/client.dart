/// クライアント(ホストに接続する側)のセッション。
/// 通信路はWebSocket(LAN/テザリング)でも近距離P2Pでも同じように動く。
library;

import 'dart:async';

import '../engine/models.dart';
import '../session/game_session.dart';
import '../session/suspend.dart';
import 'protocol.dart';
import 'transport.dart';

class ClientSession implements GameSession {
  /// 利用者が入力した名前。実際に席に着いた名前は [name](改名され得る)
  final String playerName;

  /// ホストが確定した名前。同名衝突で「名前2」等に改名されることがあり、
  /// 再接続の名乗りにはこちらを使う(welcome で更新)
  String get name => _name;
  late String _name = playerName;

  /// 再接続手段(通信路の種類ごとに異なる)。null なら再接続不可
  final Future<MessageChannel> Function()? _reconnector;

  MessageChannel? _channel;
  StreamSubscription<String>? _messagesSub;

  final _views = StreamController<GameView>.broadcast();
  final _turnPrompts = StreamController<TurnPrompt>.broadcast();
  final _reactPrompts = StreamController<ReactPrompt>.broadcast();
  final _emotes = StreamController<EmoteCast>.broadcast();
  final _lobby = StreamController<LobbyState>.broadcast();
  final _connection = StreamController<bool>.broadcast();
  final _suspend = StreamController<SuspendNotice>.broadcast();
  final _started = Completer<void>();
  final _kicked = Completer<String>();

  // ---- ギャラリー(観戦) ----
  /// 観戦許可待ちに入った(部屋が対局中だった)
  final _spectatePending = Completer<void>();

  /// 観戦が許可され、席の選択肢(プレイヤー一覧)が届いた
  final _spectateOffer = Completer<List<LobbyPlayer>>();

  /// 観戦者として参加している(観戦席を選んで送信した後 true)
  bool _spectating = false;

  GameView? _latestView;
  TurnPrompt? _activeTurnPrompt;
  ReactPrompt? _activeReactPrompt;
  LobbyState? latestLobby;
  bool _connected = false;
  bool _disposed = false;

  ClientSession._({
    required this.playerName,
    Future<MessageChannel> Function()? reconnector,
  }) : _reconnector = reconnector; // ignore: prefer_initializing_formals

  /// LAN(WebSocket)経由で接続する
  static Future<ClientSession> connect({
    required String host,
    required int port,
    required String playerName,
  }) async {
    final session = ClientSession._(
      playerName: playerName,
      reconnector: () => WsLink.connect(host, port),
    );
    await session._attach(await WsLink.connect(host, port));
    return session;
  }

  /// 既成の通信路(近距離P2P等)で接続する
  static Future<ClientSession> overChannel({
    required MessageChannel channel,
    required String playerName,
    Future<MessageChannel> Function()? reconnector,
  }) async {
    final session = ClientSession._(
      playerName: playerName,
      reconnector: reconnector,
    );
    await session._attach(channel);
    return session;
  }

  Future<void> _attach(MessageChannel channel) async {
    _channel = channel;
    _connected = true;
    if (!_connection.isClosed) _connection.add(true);
    _messagesSub = channel.messages.listen(_onData);
    channel.done.then((_) {
      if (identical(_channel, channel)) _onDisconnect();
    });
    channel.send(encodeMsg('hello', {'name': _name, 'pv': protocolVersion}));
  }

  /// 切断後の再接続(同名で席に復帰)
  Future<void> reconnect() async {
    final reconnector = _reconnector;
    if (reconnector == null) {
      throw Exception('この接続方法では自動再接続できません');
    }
    await _messagesSub?.cancel();
    await _attach(await reconnector());
  }

  void _onData(String data) {
    final msg = decodeMsg(data);
    if (msg == null) return;
    switch (msg['t']) {
      case 'welcome':
        _name = msg['name'] as String? ?? _name;
      case 'lobby':
        latestLobby = LobbyState.fromJson(
          (msg['state'] as Map).cast<String, dynamic>(),
        );
        if (!_lobby.isClosed) _lobby.add(latestLobby!);
      case 'start':
        if (!_started.isCompleted) _started.complete();
      case 'view':
        _latestView = GameView.fromJson(
          (msg['v'] as Map).cast<String, dynamic>(),
        );
        if (!_views.isClosed) _views.add(_latestView!);
      case 'turnPrompt':
        _activeTurnPrompt = TurnPrompt.fromJson(
          (msg['p'] as Map).cast<String, dynamic>(),
        );
        if (!_turnPrompts.isClosed) _turnPrompts.add(_activeTurnPrompt!);
      case 'reactPrompt':
        _activeReactPrompt = ReactPrompt.fromJson(
          (msg['p'] as Map).cast<String, dynamic>(),
        );
        if (!_reactPrompts.isClosed) _reactPrompts.add(_activeReactPrompt!);
      case 'emote':
        if (!_emotes.isClosed) {
          _emotes.add(EmoteCast(msg['seat'] as int, msg['emoji'] as int));
        }
      case 'spectatePending':
        // 部屋は対局中: ホストの観戦許可待ち
        if (!_spectatePending.isCompleted) _spectatePending.complete();
      case 'spectateOffer':
        // 観戦が許可された。席(プレイヤー)の選択肢が届く
        if (!_spectateOffer.isCompleted) {
          _spectateOffer.complete([
            for (final p in (msg['players'] as List? ?? []))
              LobbyPlayer(
                name: (p as Map)['name'] as String,
                isCpu: p['cpu'] as bool? ?? false,
              ),
          ]);
        }
      case 'suspended':
        // ホストが対局を中断した(切断とは別扱い。復帰情報の保存に使う)
        if (!_suspend.isClosed) {
          _suspend.add(
            SuspendNotice(
              roomName: msg['room'] as String? ?? '',
              playerName: msg['name'] as String? ?? _name,
              spectator: msg['spec'] as bool? ?? false,
            ),
          );
        }
      case 'kick':
        if (!_kicked.isCompleted) {
          _kicked.complete(msg['reason'] as String? ?? '接続を拒否されました');
        }
    }
  }

  void _onDisconnect() {
    _connected = false;
    if (!_disposed && !_connection.isClosed) _connection.add(false);
  }

  /// 対局開始まで待つ(ロビー画面用)
  Future<void> get started => _started.future;

  /// 入室拒否(満席など)
  Future<String> get kicked => _kicked.future;

  /// 部屋が対局中で、ホストの観戦許可待ちに入った
  Future<void> get spectatePending => _spectatePending.future;

  /// 観戦が許可され、席(プレイヤー)の選択肢が届いた
  Future<List<LobbyPlayer>> get spectateOffered => _spectateOffer.future;

  /// 観戦する席(プレイヤー)を選んで観戦を開始する。
  /// この後ホストから 'start' が届き、以後は選んだ席のビューが流れてくる。
  void chooseSpectate(String watchName) {
    _spectating = true;
    _send(encodeMsg('spectate', {'watch': watchName}));
  }

  Stream<LobbyState> get lobbyStream => _lobby.stream;

  @override
  int get youSeat => _latestView?.youSeat ?? 0;

  @override
  bool get isHost => false;

  @override
  bool get isSpectator => _spectating;

  @override
  Stream<SpectateRequest> get spectateRequests => const Stream.empty();

  @override
  GameView? get latestView => _latestView;

  @override
  TurnPrompt? get activeTurnPrompt => _activeTurnPrompt;

  @override
  ReactPrompt? get activeReactPrompt => _activeReactPrompt;

  @override
  Stream<GameView> get views => _views.stream;

  @override
  Stream<TurnPrompt> get turnPrompts => _turnPrompts.stream;

  @override
  Stream<ReactPrompt> get reactPrompts => _reactPrompts.stream;

  @override
  Stream<EmoteCast> get emotes => _emotes.stream;

  @override
  Stream<bool> get connectionState => _connection.stream;

  @override
  bool get isConnected => _connected;

  void _send(String msg) => _channel?.send(msg);

  @override
  void sendTurn(TurnAction action) {
    _activeTurnPrompt = null;
    _send(encodeMsg('turn', {'a': action.toJson()}));
  }

  @override
  void sendReact(ReactAction action) {
    _activeReactPrompt = null;
    _send(encodeMsg('react', {'a': action.toJson()}));
  }

  @override
  void sendEmote(int emoji) => _send(encodeMsg('emote', {'emoji': emoji}));

  @override
  void advance() {
    // 局終了確認: 自分の確認をホストに伝える
    _send(encodeMsg('advance'));
  }

  @override
  void nextGame() {
    // クライアントは進行権を持たない
  }

  @override
  Future<SuspendedHostGame?> suspend() async => null; // ホストのみ中断できる

  @override
  Stream<SuspendNotice> get suspendNotices => _suspend.stream;

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _messagesSub?.cancel();
    await _channel?.close();
    await _views.close();
    await _turnPrompts.close();
    await _reactPrompts.close();
    await _emotes.close();
    await _lobby.close();
    await _suspend.close();
    await _connection.close();
  }
}

/// "192.168.1.10" または "192.168.1.10:47654" をパースする
({String host, int port})? parseHostPort(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;
  final parts = text.split(':');
  if (parts.length == 1) return (host: parts[0], port: defaultPort);
  final port = int.tryParse(parts[1]);
  if (port == null) return null;
  return (host: parts[0], port: port);
}
