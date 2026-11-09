/// マスター(ホスト)端末のサーバー実装。
/// ロビー管理・クライアント代理エージェント・切断時のCPU代打を担う。
/// 通信路はWebSocket(LAN/テザリング)と近距離P2Pの両方を同時に待ち受ける。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../engine/ai.dart';
import '../engine/game_engine.dart';
import '../engine/display_text.dart';
import '../engine/models.dart';
import '../paifu/my_paifu_store.dart';
import '../session/game_session.dart';
import '../session/suspend.dart';
import 'ble_transport.dart';
import 'discovery.dart';
import 'nearby_transport.dart';
import 'protocol.dart';
import 'transport.dart';

/// ホスト側から見たクライアント接続(対局中の席の代理)
class NetworkAgent implements PlayerAgent {
  final MessageChannel _channel;
  Completer<TurnAction>? _turn;
  Completer<ReactAction>? _react;

  /// このクライアントが顔文字を送ってきたときに呼ぶ(ホストが配線する)
  void Function(int emoji)? onEmoteFromClient;

  NetworkAgent(this._channel);

  void _send(String msg) => _channel.send(msg);

  @override
  void onView(GameView view) => _send(encodeMsg('view', {'v': view.toJson()}));

  @override
  void onEmote(int seat, int emoji) =>
      _send(encodeMsg('emote', {'seat': seat, 'emoji': emoji}));

  @override
  Future<TurnAction> onTurn(TurnPrompt prompt) {
    _turn = Completer<TurnAction>();
    _send(encodeMsg('turnPrompt', {'p': prompt.toJson()}));
    return _turn!.future;
  }

  @override
  Future<ReactAction> onReact(ReactPrompt prompt) {
    _react = Completer<ReactAction>();
    _send(encodeMsg('reactPrompt', {'p': prompt.toJson()}));
    return _react!.future;
  }

  void handleMessage(Map<String, dynamic> msg) {
    switch (msg['t']) {
      case 'turn':
        final c = _turn;
        _turn = null;
        if (c != null && !c.isCompleted) {
          c.complete(
            TurnAction.fromJson((msg['a'] as Map).cast<String, dynamic>()),
          );
        }
      case 'react':
        final c = _react;
        _react = null;
        if (c != null && !c.isCompleted) {
          c.complete(
            ReactAction.fromJson((msg['a'] as Map).cast<String, dynamic>()),
          );
        }
      case 'emote':
        onEmoteFromClient?.call(msg['emoji'] as int);
    }
  }
}

class _Client {
  MessageChannel channel;
  String name;
  int seat;
  bool connected = true;
  NetworkAgent? agent;

  _Client(this.channel, this.name, this.seat);
}

/// 部屋のホスト。ロビー→対局まで一貫して保持する。
class HostServer {
  final String roomName;
  final String hostName;
  final GameConfig config;

  /// 中断した対局の復帰モード。設定されている場合、ロビーは中断メンバー
  /// (ゲスト名が一致する者)だけを受け入れ、開始時にエンジンを復元する。
  final SuspendedHostGame? resume;

  HttpServer? _http;
  final RoomBroadcaster _broadcaster = RoomBroadcaster();
  NearbyHost? _nearbyHost;
  BleHost? _bleHost;

  /// 近距離待ち受けの状態(null=待受中、それ以外=理由)
  String? nearbyStatus = '初期化中…';

  /// BLE 待ち受けの状態(null=待受中、それ以外=理由)
  String? bleStatus = '初期化中…';

  int port = defaultPort;

  /// ゲスト枠(通常3、ホストがギャラリーなら4)。index=スロット
  final List<_Client?> _clients = [null, null, null, null];
  final _lobbyController = StreamController<LobbyState>.broadcast();

  bool _started = false;
  GameEngine? _engine;
  HostGameSession? session;

  // ---- ギャラリー(観戦) ----
  /// ホストが席に着かず観戦する予定(ロビーで切り替え)。
  /// ON の間はゲスト枠が4になり、4人全員が人間ゲストになれる。
  bool galleryMode = false;

  /// 観戦希望(ホストのUIが許可/拒否を決める)
  final _spectateRequests = StreamController<SpectateRequest>.broadcast();

  /// 接続中の観戦者(中断通知・シャットダウンで使う)
  final List<({MessageChannel channel, NetworkAgent agent, String name})>
  _spectators = [];

  /// ホスト自身がギャラリーの場合の観戦対象プレイヤー名(中断保存に使う)
  String? _hostWatchName;

  Stream<SpectateRequest> get spectateRequests => _spectateRequests.stream;

  HostServer({
    required this.roomName,
    required this.hostName,
    required this.config,
    this.resume,
  });

  Stream<LobbyState> get lobbyStream => _lobbyController.stream;

  /// 現在のゲスト枠数(通常3。ホストがギャラリーなら4。
  /// 復帰時は中断メンバー数に合わせる)
  int get slotCount {
    if (resume != null) return resume!.guestNames.length > 3 ? 4 : 3;
    return galleryMode ? 4 : 3;
  }

  /// ギャラリーモードの切り替え(ロビー中のみ)。
  /// 4人目のゲストがいる間は解除できない(false を返す)。
  bool setGalleryMode(bool on) {
    if (!on && _clients[3] != null) return false;
    galleryMode = on;
    _broadcastLobby();
    return true;
  }

  LobbyState get lobbyState => LobbyState(
    roomName: roomName,
    players: [
      LobbyPlayer(
        name: hostName,
        isHost: true,
        gallery: galleryMode || (resume?.hostIsGallery ?? false),
      ),
      for (var i = 0; i < slotCount; i++) _lobbySlot(i),
    ],
    config: config,
  );

  /// ロビーの席1..3(スロット0..2)の表示。
  /// 復帰モードでは中断メンバーの名前を出して合流待ちにする。
  LobbyPlayer _lobbySlot(int slot) {
    final c = _clients[slot];
    if (c != null) return LobbyPlayer(name: c.name);
    final guests = resume?.guestNames;
    if (guests != null && slot < guests.length) {
      return LobbyPlayer(name: guests[slot], waiting: true);
    }
    return const LobbyPlayer(name: '(CPU)', isCpu: true);
  }

  Future<void> start() async {
    HttpServer? http;
    var p = defaultPort;
    for (var i = 0; i < 10; i++) {
      try {
        http = await HttpServer.bind(InternetAddress.anyIPv4, p);
        break;
      } on SocketException {
        p++;
      }
    }
    http ??= await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _http = http;
    port = http.port;
    http.listen(_onRequest);
    try {
      await _broadcaster.start(roomName: roomName, port: port);
    } catch (_) {
      // mDNSが使えない環境でも手動IP接続で遊べるようにする
    }
    // 近距離P2P(共通Wi-Fi不要)の待ち受けも開始する
    if (nearbySupported) {
      _nearbyHost = NearbyHost(onChannel: attachChannel);
      try {
        nearbyStatus = await _nearbyHost!.start(roomName: roomName);
      } catch (e) {
        nearbyStatus = '近距離接続を開始できませんでした';
      }
    } else {
      nearbyStatus = 'この端末では利用できません';
    }
    // BLE(Wi-Fi不要・iOS/Android混合可)の待ち受けも開始する
    if (bleSupported) {
      _bleHost = BleHost(onChannel: attachChannel);
      try {
        bleStatus = await _bleHost!.start(roomName: roomName);
      } catch (e) {
        // 原因が画面で分かるよう例外文を添える(2026-11-09 の iOS 不具合は
        // この文言だけでは原因が追えなかった)
        bleStatus = 'BLE を開始できませんでした: $e';
      }
    } else {
      bleStatus = 'この端末では利用できません';
    }
    _lobbyController.add(lobbyState);
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    attachChannel(FramedChannel(WsLink(ws)));
  }

  /// 通信路(WebSocket/近距離)をロビー・対局に接続する
  @visibleForTesting
  void attachChannel(MessageChannel channel) {
    _Client? client;
    // 観戦(ギャラリー)の接続状態(このチャネル限り)
    var spectateApproved = false;
    var spectatorName = '';
    NetworkAgent? spectatorAgent;

    channel.messages.listen((data) {
      final msg = decodeMsg(data);
      if (msg == null) return;
      if (msg['t'] == 'hello') {
        final name0 = (msg['name'] as String?)?.trim() ?? '';
        final name = name0.isEmpty ? 'ゲスト' : name0;
        if (msg['pv'] != protocolVersion) {
          channel.send(
            encodeMsg('kick', {'reason': 'アプリのバージョンが違います(全員が同じ版に更新してください)'}),
          );
          channel.close();
          return;
        }
        if (_started) {
          // 再接続・遅れた合流ならプレイヤーとして席へ戻す
          client = _tryRejoin(channel, name);
          if (client != null) return;
          // それ以外は観戦希望としてホストに確認を出す
          spectatorName = name;
          channel.send(encodeMsg('spectatePending'));
          _spectateRequests.add(
            SpectateRequest(
              name: name,
              approve: () {
                if (spectateApproved) return;
                spectateApproved = true;
                channel.send(
                  encodeMsg('spectateOffer', {'players': _playerList()}),
                );
              },
              deny: () {
                channel.send(encodeMsg('kick', {'reason': '観戦は許可されませんでした'}));
                channel.close();
              },
            ),
          );
          return;
        }
        client = _onHello(channel, name);
        return;
      }
      // 観戦席の決定(許可済みのチャネルのみ)
      if (msg['t'] == 'spectate') {
        if (!spectateApproved || spectatorAgent != null) return;
        final players = _playerList();
        var watch = msg['watch'] as String? ?? '';
        if (!players.any((p) => p['name'] == watch)) {
          watch = players.first['name'] as String;
        }
        final agent = NetworkAgent(channel);
        spectatorAgent = agent;
        _spectators.add((channel: channel, agent: agent, name: spectatorName));
        _engine?.addSpectator(agent, watch);
        channel.send(encodeMsg('start'));
        return;
      }
      // 局終了確認: クライアントの人間が「次へ」を押した
      if (msg['t'] == 'advance') {
        final c = client;
        if (c != null) {
          final seat = _engine?.seatOfName(c.name) ?? c.seat;
          _engine?.ackAdvance(seat);
        }
        return;
      }
      client?.agent?.handleMessage(msg);
    });
    channel.done.then((_) {
      if (client != null) _onDisconnect(client!);
      final agent = spectatorAgent;
      if (agent != null) {
        _engine?.removeSpectator(agent);
        _spectators.removeWhere((s) => identical(s.agent, agent));
      }
    });
  }

  /// 対局中の席一覧(観戦席の選択肢)
  List<Map<String, dynamic>> _playerList() {
    final view = session?.latestView;
    final engine = _engine;
    if (engine == null) return const [];
    return [
      for (var i = 0; i < 4; i++)
        {
          'name': engine.nameOfSeat(i),
          'cpu': view == null ? false : view.players[i].isCpu,
        },
    ];
  }

  /// 開始済みの対局への再入室(再接続・中断メンバーの遅れた合流)。
  /// 該当しなければ null(観戦候補)。
  _Client? _tryRejoin(MessageChannel channel, String name) {
    // 再接続: 同名の切断席に復帰させる(席は場決めで動くので名前で引く)
    final rejoin = _disconnectedClientNamed(name);
    if (rejoin != null) {
      rejoin.channel = channel;
      rejoin.connected = true;
      _attachNetworkAgent(rejoin);
      return rejoin;
    }
    // 復帰対局への遅れた合流: ロビーに間に合わなかった中断メンバーは
    // CPUが代打している。開始後でも本人なら席に戻す。
    final slot = resume?.guestNames.indexOf(name) ?? -1;
    if (slot >= 0 && slot < 4 && _clients[slot] == null) {
      final client = _Client(channel, name, slot + 1);
      _clients[slot] = client;
      _attachNetworkAgent(client);
      return client;
    }
    return null;
  }

  /// 切断中の席のうち [name] の人のもの。完全一致を優先し、無ければ
  /// 入室時の改名(同名衝突で「名前2」等になった)を元の名前で名乗っている場合も
  /// 本人とみなす(候補が1人に絞れるときだけ)。
  /// 2026-11-09 実機: ホストと参加者が共に初期値「プレイヤー」で、参加者が
  /// 「プレイヤー2」に改名された後、アプリを入れ直して「プレイヤー」で再入室
  /// したら席に戻れず観戦候補になった。
  _Client? _disconnectedClientNamed(String name) {
    final gone = _clients.whereType<_Client>().where((c) => !c.connected);
    for (final c in gone) {
      if (c.name == name) return c;
    }
    final renamed = RegExp('^${RegExp.escape(name)}[0-9]+\$');
    final candidates = gone.where((c) => renamed.hasMatch(c.name)).toList();
    return candidates.length == 1 ? candidates.single : null;
  }

  /// 入室が確定した名前を本人に知らせる(同名衝突で改名されたとき、
  /// 再接続で同じ名前を名乗って席に戻れるように)
  void _sendWelcome(_Client client) {
    client.channel.send(encodeMsg('welcome', {'name': client.name}));
  }

  _Client? _onHello(MessageChannel channel, String name) {
    if (resume != null) {
      // 復帰ロビー: 中断メンバー(名前が一致するゲスト)だけを受け入れる
      final slot = resume!.guestNames.indexOf(name);
      if (slot < 0 || slot >= 4) {
        channel.send(encodeMsg('kick', {'reason': '中断した対局のメンバーのみ入れます'}));
        channel.close();
        return null;
      }
      if (_clients[slot] != null) {
        channel.send(encodeMsg('kick', {'reason': '同名のプレイヤーが合流済みです'}));
        channel.close();
        return null;
      }
      final client = _Client(channel, name, slot + 1);
      _clients[slot] = client;
      _sendWelcome(client);
      _broadcastLobby();
      return client;
    }

    // 空席を探す(ギャラリーモードなら4枠、通常は3枠)
    for (var i = 0; i < slotCount; i++) {
      if (_clients[i] == null) {
        var uniqueName = name;
        final used = {
          hostName,
          ..._clients.whereType<_Client>().map((c) => c.name),
        };
        var n = 2;
        while (used.contains(uniqueName)) {
          uniqueName = '$name$n';
          n++;
        }
        final client = _Client(channel, uniqueName, i + 1);
        _clients[i] = client;
        _sendWelcome(client);
        _broadcastLobby();
        return client;
      }
    }
    channel.send(encodeMsg('kick', {'reason': '満席です'}));
    channel.close();
    return null;
  }

  /// 開始済みの対局にクライアントをつなぎ込む(再接続・遅れた合流)
  void _attachNetworkAgent(_Client c) {
    final seat = _engine?.seatOfName(c.name) ?? c.seat;
    final agent = NetworkAgent(c.channel);
    agent.onEmoteFromClient = (emoji) => _engine?.castEmoteFrom(agent, emoji);
    c.agent = agent;
    c.channel.send(encodeMsg('start'));
    _engine?.setAgent(seat, agent, connected: true, isCpu: false);
  }

  void _onDisconnect(_Client client) {
    if (!_started) {
      _clients[client.seat - 1] = null;
      _broadcastLobby();
      return;
    }
    client.connected = false;
    client.agent = null;
    // CPUが代打(席は場決めで動くので名前で引く)
    final seat = _engine?.seatOfName(client.name) ?? client.seat;
    final cpu = CpuAgent();
    cpu.castEmote = (emoji) => _engine?.castEmoteFrom(cpu, emoji);
    _engine?.setAgent(seat, cpu, connected: false);
  }

  void _broadcastLobby() {
    final state = lobbyState;
    _lobbyController.add(state);
    final msg = encodeMsg('lobby', {'state': state.toJson()});
    for (final c in _clients) {
      if (c != null && c.connected) {
        c.channel.send(msg);
      }
    }
  }

  /// 対局開始。空席はCPUで埋める。
  /// [asGallery] ならホストは席に着かず、席[watchSeat](0..3)の
  /// プレイヤー視点を観戦するギャラリーになる。
  HostGameSession startGame({bool asGallery = false, int watchSeat = 0}) {
    if (resume != null) return _startResumedGame();
    if (asGallery) return _startGalleryGame(watchSeat);
    _started = true;
    // 通常開始はホスト+ゲスト3枠。4人目の枠はギャラリーモード専用なので、
    // 万一残っていたら退室してもらう(setGalleryMode が防いでいるが保険)
    final fourth = _clients[3];
    if (fourth != null) {
      fourth.channel.send(
        encodeMsg('kick', {'reason': 'ホストが参加するため4人目の枠がありません'}),
      );
      fourth.channel.close();
      _clients[3] = null;
    }
    final names = <String>[hostName];
    final isCpu = <bool>[false];
    for (var i = 0; i < 3; i++) {
      final c = _clients[i];
      names.add(c?.name ?? cpuPlayerNames[names.length - 1]);
      isCpu.add(c == null);
    }

    final nextGameGate = NextGameGate();
    final engine = GameEngine(
      config: config,
      names: names,
      isCpu: isCpu,
      waitNextGame: nextGameGate.wait,
    );
    _engine = engine;

    final ui = UiAgent();
    engine.setAgent(0, ui);
    for (var i = 0; i < 3; i++) {
      final seat = i + 1;
      final c = _clients[i];
      if (c == null) {
        final cpu = CpuAgent();
        cpu.castEmote = (emoji) => engine.castEmoteFrom(cpu, emoji);
        engine.setAgent(seat, cpu);
      } else {
        final agent = NetworkAgent(c.channel);
        agent.onEmoteFromClient = (emoji) => engine.castEmoteFrom(agent, emoji);
        c.agent = agent;
        c.channel.send(encodeMsg('start'));
        engine.setAgent(seat, agent, connected: true);
      }
    }
    MyPaifuStore.instance.reopen(null); // 新しい試合ファイルで開始
    engine.paifuRecorder = MyPaifuStore.instance;
    unawaited(engine.run());
    session = HostGameSession(this, ui, nextGameGate);
    return session!;
  }

  /// ホストがギャラリー(観戦)の対局開始。ホストは席に着かず、
  /// 席はゲスト4枠+残りをCPUで埋める(誰もいなければ全員CPU、
  /// 4人全員が人間ゲストでもよい)。
  HostGameSession _startGalleryGame(int watchSeat) {
    _started = true;
    final names = <String>[];
    final isCpu = <bool>[];
    for (var i = 0; i < 4; i++) {
      names.add(_clients[i]?.name ?? cpuPlayerNames[i]);
      isCpu.add(_clients[i] == null);
    }

    final nextGameGate = NextGameGate();
    final engine = GameEngine(
      config: config,
      names: names,
      isCpu: isCpu,
      waitNextGame: nextGameGate.wait,
    );
    _engine = engine;

    for (var i = 0; i < 4; i++) {
      final c = _clients[i];
      if (c == null) {
        final cpu = CpuAgent();
        cpu.castEmote = (emoji) => engine.castEmoteFrom(cpu, emoji);
        engine.setAgent(i, cpu);
      } else {
        final agent = NetworkAgent(c.channel);
        agent.onEmoteFromClient = (emoji) => engine.castEmoteFrom(agent, emoji);
        c.agent = agent;
        c.channel.send(encodeMsg('start'));
        engine.setAgent(i, agent, connected: true);
      }
    }

    final ui = UiAgent();
    final watch = names[watchSeat.clamp(0, 3)];
    _hostWatchName = watch;
    engine.addSpectator(ui, watch);
    MyPaifuStore.instance.reopen(null); // 新しい試合ファイルで開始
    engine.paifuRecorder = MyPaifuStore.instance;
    unawaited(engine.run());
    session = HostGameSession(this, ui, nextGameGate, isSpectator: true);
    return session!;
  }

  /// 中断した対局の再開。エンジンを復元し、合流済みのゲストを元の席へ、
  /// 未合流のメンバーはCPUが代打する(あとから合流したら本人に戻す)。
  /// ホストがギャラリーだった対局は、ホストがギャラリーのまま復帰する。
  HostGameSession _startResumedGame() {
    _started = true;
    final data = resume!.resumeData;
    final nextGameGate = NextGameGate();
    final engine = GameEngine.fromResume(data, waitNextGame: nextGameGate.wait);
    _engine = engine;
    MyPaifuStore.instance.reopen(resume!.paifuGameId);

    final ui = UiAgent();
    final hostSeated = data.names.contains(hostName);
    for (var seat = 0; seat < 4; seat++) {
      final name = data.names[seat];
      if (name == hostName) {
        engine.setAgent(seat, ui, connected: true);
        continue;
      }
      _Client? client;
      for (final c in _clients) {
        if (c != null && c.connected && c.name == name) client = c;
      }
      if (client != null) {
        final agent = NetworkAgent(client.channel);
        agent.onEmoteFromClient = (emoji) => engine.castEmoteFrom(agent, emoji);
        client.agent = agent;
        client.channel.send(encodeMsg('start'));
        engine.setAgent(seat, agent, connected: true);
      } else {
        // CPUメンバー、または未合流の人間メンバー(CPU代打)。
        // isCpu は fromResume が復元済みなので触らない(人間メンバーの
        // 代打でも isCpu=false のまま=再接続で本人に戻せる)。
        final cpu = CpuAgent();
        cpu.castEmote = (emoji) => engine.castEmoteFrom(cpu, emoji);
        engine.setAgent(seat, cpu, connected: false);
      }
    }
    // ホストがギャラリーだった対局は、ギャラリーのまま復帰する
    if (!hostSeated) {
      final watch = data.names.contains(resume!.watchName)
          ? resume!.watchName!
          : data.names.first;
      _hostWatchName = watch;
      engine.addSpectator(ui, watch);
    }
    engine.paifuRecorder = MyPaifuStore.instance;
    unawaited(engine.run());
    session = HostGameSession(this, ui, nextGameGate, isSpectator: !hostSeated);
    return session!;
  }

  /// 対局を中断する。復帰情報を取り出してエンジンを止め、
  /// 全クライアント・観戦者に中断通知を送る。
  Future<SuspendedHostGame?> suspend() async {
    final engine = _engine;
    if (engine == null) return null;
    final data = engine.suspendAndCapture();
    final saved = SuspendedHostGame.capture(
      roomName: roomName,
      hostName: hostName,
      data: data,
      savedAt: DateTime.now(),
      watchName: _hostWatchName,
      paifuGameId: MyPaifuStore.instance.currentGameId,
    );
    for (final c in _clients) {
      if (c != null && c.connected) {
        c.channel.send(
          encodeMsg('suspended', {'room': roomName, 'name': c.name}),
        );
      }
    }
    for (final s in _spectators) {
      s.channel.send(
        encodeMsg('suspended', {
          'room': roomName,
          'name': s.name,
          'spec': true,
        }),
      );
    }
    // 通知が届く前にサーバーが落とされないよう、送信を少し待つ
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return saved;
  }

  /// 局終了確認: 指定席の人間が確認した(ホスト自身・クライアント共通)
  void ackAdvance(int seat) => _engine?.ackAdvance(seat);

  /// 顔文字キャストを全席に配信する
  void castEmote(int seat, int emoji) => _engine?.castEmote(seat, emoji);

  Future<void> shutdown() async {
    await _broadcaster.stop();
    await _nearbyHost?.stop();
    await _bleHost?.stop();
    for (final c in _clients) {
      await c?.channel.close();
    }
    for (final s in _spectators) {
      await s.channel.close();
    }
    await _http?.close(force: true);
    await _lobbyController.close();
    await _spectateRequests.close();
  }
}

class HostGameSession implements GameSession {
  final HostServer server;
  final UiAgent _ui;
  final NextGameGate _nextGameGate;
  final _connection = StreamController<bool>.broadcast();

  /// ホストがギャラリー(観戦)として参加している
  @override
  final bool isSpectator;

  HostGameSession(
    this.server,
    this._ui,
    this._nextGameGate, {
    this.isSpectator = false,
  });

  @override
  int get youSeat => _ui.latestView?.youSeat ?? 0;

  @override
  bool get isHost => true;

  @override
  Stream<SpectateRequest> get spectateRequests => server.spectateRequests;

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
  void sendEmote(int emoji) {
    // 観戦中の youSeat は見ているプレイヤーの席。なりすましになるので送らない
    if (isSpectator) return;
    server.castEmote(_ui.latestView?.youSeat ?? 0, emoji);
  }

  @override
  void advance() {
    // 観戦中の確認は席のプレイヤーの確認として扱われてしまうので送らない
    if (isSpectator) return;
    server.ackAdvance(_ui.latestView?.youSeat ?? 0);
  }

  @override
  void nextGame() => _nextGameGate.decide(true);

  @override
  Future<SuspendedHostGame?> suspend() => server.suspend();

  @override
  Stream<SuspendNotice> get suspendNotices => const Stream.empty();

  @override
  Future<void> dispose() async {
    _nextGameGate.decide(false);
    _ui.close();
    await _connection.close();
    await server.shutdown();
  }
}
