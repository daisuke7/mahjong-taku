import 'dart:async';

import 'package:flutter/material.dart';

import '../net/client.dart';
import '../net/discovery.dart';
import '../net/ble_transport.dart';
import '../net/nearby_transport.dart';
import '../net/protocol.dart';
import '../net/transport.dart';
import '../session/suspend.dart';
import '../session/suspend_store.dart';
import 'game_screen.dart';

class JoinScreen extends StatefulWidget {
  final String playerName;

  /// 動作確認用: 指定があれば画面表示直後にこのアドレスへ自動接続する
  final String? autoConnectHost;

  const JoinScreen({super.key, required this.playerName, this.autoConnectHost});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final RoomScanner _scanner = RoomScanner();
  final NearbyBrowser _nearby = NearbyBrowser();
  final TextEditingController _ipController = TextEditingController();
  List<RoomInfo> _lanRooms = [];
  List<NearbyRoom> _nearbyRooms = [];
  String? _nearbyError;
  final BleBrowser _ble = BleBrowser();
  List<BleRoom> _bleRooms = [];
  String? _bleError;
  StreamSubscription<List<BleRoom>>? _bleSub;
  StreamSubscription<List<RoomInfo>>? _roomSub;
  StreamSubscription<List<NearbyRoom>>? _nearbySub;

  ClientSession? _session; // 接続済み(ロビー待機中)
  LobbyState? _lobby;
  StreamSubscription<LobbyState>? _lobbySub;
  bool _connecting = false;
  bool _navigated = false;

  /// 観戦(ギャラリー)フローの状態表示(null=通常のロビー待機)
  String? _spectateState;

  /// 中断された対局のゲスト復帰情報(あれば復帰ボタンを出す)
  SuspendedGuestGame? _guestSaved;

  /// 復帰ボタンが押され、中断された部屋を探して自動合流する状態
  bool _resumeArmed = false;

  @override
  void initState() {
    super.initState();
    _scanner.start().catchError((_) {
      // mDNSが使えなくても手動入力で参加できる
    });
    _roomSub = _scanner.rooms.listen((rooms) {
      if (mounted) {
        setState(() => _lanRooms = rooms);
        _tryResumeConnect();
      }
    });
    _startNearby();
    _startBle();
    SuspendStore.loadGuest().then((saved) {
      if (mounted && saved != null) setState(() => _guestSaved = saved);
    });
    final auto = widget.autoConnectHost;
    if (auto != null && auto.isNotEmpty) {
      _ipController.text = auto;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connectManual();
      });
    }
  }

  Future<void> _startNearby() async {
    if (!nearbySupported) {
      setState(() => _nearbyError = 'この端末では利用できません');
      return;
    }
    final error = await _nearby.start();
    if (!mounted) return;
    setState(() => _nearbyError = error);
    if (error == null) {
      _nearbySub = _nearby.rooms.listen((rooms) {
        if (mounted) {
          setState(() => _nearbyRooms = rooms);
          _tryResumeConnect();
        }
      });
    }
  }

  Future<void> _startBle() async {
    if (!bleSupported) {
      setState(() => _bleError = 'この端末では利用できません');
      return;
    }
    String? error;
    try {
      error = await _ble.start();
    } catch (e) {
      error = 'BLE を開始できませんでした';
    }
    if (!mounted) return;
    setState(() => _bleError = error);
    if (error == null) {
      _bleSub = _ble.rooms.listen((rooms) {
        if (mounted) {
          setState(() => _bleRooms = rooms);
          _tryResumeConnect();
        }
      });
    }
  }

  /// 復帰モード中: 中断された部屋(名前一致)が見つかったら自動で合流する
  void _tryResumeConnect() {
    final saved = _guestSaved;
    if (!_resumeArmed || saved == null || _connecting || _session != null) {
      return;
    }
    for (final room in _lanRooms) {
      if (room.name == saved.roomName) {
        _connectLan(room.host, room.port, name: saved.playerName);
        return;
      }
    }
    for (final room in _nearbyRooms) {
      if (room.name == saved.roomName) {
        _connectNearby(room, name: saved.playerName);
        return;
      }
    }
    for (final room in _bleRooms) {
      if (room.name == saved.roomName) {
        _connectBle(room, name: saved.playerName);
        return;
      }
    }
  }

  @override
  void dispose() {
    _roomSub?.cancel();
    _scanner.stop();
    _nearbySub?.cancel();
    _nearby.stop();
    _bleSub?.cancel();
    _ble.stop();
    _lobbySub?.cancel();
    if (!_navigated) _session?.dispose();
    _ipController.dispose();
    super.dispose();
  }

  Future<void> _connectWith(Future<ClientSession> Function() connector) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      final session = await connector();
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _lobby = session.latestLobby;
        _spectateState = null;
      });
      _lobbySub = session.lobbyStream.listen((state) {
        if (mounted) setState(() => _lobby = state);
      });
      // 開始通知で対局画面へ
      unawaited(
        session.started.then((_) {
          if (!mounted || _navigated) return;
          _navigated = true;
          // 復帰合流が成立したら保存情報は消費済み(中断すればまた保存される)
          if (_resumeArmed) SuspendStore.clearGuest();
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => GameScreen(session: session)),
          );
        }),
      );
      // 部屋が対局中: 観戦(ギャラリー)フローに入る
      unawaited(
        session.spectatePending.then((_) {
          if (!mounted || _navigated || !identical(session, _session)) return;
          setState(() => _spectateState = 'ホストの観戦許可を待っています…');
        }),
      );
      unawaited(
        session.spectateOffered.then((players) async {
          if (!mounted || _navigated || !identical(session, _session)) return;
          setState(() => _spectateState = '観戦する席を選んでください');
          final watch = await _pickSpectateTarget(players);
          if (!mounted || !identical(session, _session)) return;
          if (watch == null) {
            // 選ばずに閉じた → 観戦をやめる
            await session.dispose();
            setState(() {
              _session = null;
              _spectateState = null;
            });
            return;
          }
          session.chooseSpectate(watch);
          setState(() => _spectateState = '観戦を開始しています…');
        }),
      );
      unawaited(
        session.kicked.then((reason) {
          if (!mounted || _navigated) return;
          setState(() {
            _session = null;
            _lobby = null;
            _spectateState = null;
          });
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(reason)));
        }),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('接続できませんでした')));
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _connectLan(String host, int port, {String? name}) {
    _connectWith(
      () => ClientSession.connect(
        host: host,
        port: port,
        playerName: name ?? widget.playerName,
      ),
    );
  }

  void _connectNearby(NearbyRoom room, {String? name}) {
    _connectWith(() async {
      final channel = await _nearby.join(room.id);
      return ClientSession.overChannel(
        channel: channel,
        playerName: name ?? widget.playerName,
        reconnector: () => _rejoinNearby(room.id),
      );
    });
  }

  void _connectBle(BleRoom room, {String? name}) {
    _connectWith(() async {
      final channel = await _ble.join(room.id);
      return ClientSession.overChannel(
        channel: channel,
        playerName: name ?? widget.playerName,
        reconnector: () => _rejoinBle(room.id),
      );
    });
  }

  /// 切断後の BLE 再接続(再探索してつなぎ直す)
  static Future<MessageChannel> _rejoinBle(String id) async {
    final browser = BleBrowser();
    final error = await browser.start();
    if (error != null) throw Exception(error);
    try {
      await browser.rooms
          .firstWhere((rooms) => rooms.any((r) => r.id == id))
          .timeout(const Duration(seconds: 15));
      return await browser.join(id);
    } finally {
      unawaited(browser.stop());
    }
  }

  /// 切断後の近距離再接続(再探索してつなぎ直す)
  static Future<MessageChannel> _rejoinNearby(String deviceId) async {
    final browser = NearbyBrowser();
    final error = await browser.start();
    if (error != null) throw Exception(error);
    try {
      await browser.rooms
          .firstWhere((rooms) => rooms.any((r) => r.id == deviceId))
          .timeout(const Duration(seconds: 15));
      return await browser.join(deviceId);
    } finally {
      unawaited(browser.stop());
    }
  }

  void _connectManual() {
    final parsed = parseHostPort(_ipController.text);
    if (parsed == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('IPアドレスの形式が正しくありません')));
      return;
    }
    // 復帰待ち中のIP直接入力は、中断時の名前で合流する
    _connectLan(
      parsed.host,
      parsed.port,
      name: _resumeArmed ? _guestSaved?.playerName : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_session == null ? '部屋に入る' : '開始を待っています…'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(child: _session != null ? _waitingBody() : _searchBody()),
    );
  }

  /// 観戦する席(プレイヤー)を選ぶダイアログ
  Future<String?> _pickSpectateTarget(List<LobbyPlayer> players) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('どの席を観戦しますか?'),
        children: [
          for (final p in players)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p.name),
              child: Row(
                children: [
                  Icon(
                    p.isCpu ? Icons.smart_toy : Icons.person,
                    size: 18,
                    color: p.isCpu ? Colors.white38 : const Color(0xFFFFE082),
                  ),
                  const SizedBox(width: 8),
                  Text(p.name),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _waitingBody() {
    final lobby = _lobby;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(
            _spectateState ??
                (lobby == null
                    ? '入室しました'
                    : '${lobby.roomName} — ホストの開始を待っています'),
            style: const TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 10),
          if (lobby != null)
            Wrap(
              spacing: 10,
              children: [
                for (final p in lobby.players)
                  Chip(
                    avatar: Icon(
                      p.isCpu
                          ? Icons.smart_toy
                          : p.gallery
                          ? Icons.visibility
                          : Icons.person,
                      size: 16,
                    ),
                    label: Text(
                      p.isCpu
                          ? 'CPU'
                          : p.gallery
                          ? '${p.name}(観戦)'
                          : p.name,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 中断された対局への復帰カード。
  /// タップで復帰モードになり、部屋が見つかり次第、中断時の名前で自動合流する。
  Widget _resumeCard() {
    final saved = _guestSaved!;
    return Card(
      color: const Color(0xFF4E3D13),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        dense: true,
        leading: _resumeArmed
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.pause_circle_outline, color: Color(0xFFFFE082)),
        title: Text(
          _resumeArmed
              ? '「${saved.roomName}」を探しています…'
              : '中断した対局: ${saved.roomName}',
        ),
        subtitle: Text(
          _resumeArmed
              ? 'ホストが復帰待機を始めると自動で合流します'
              : '「${saved.playerName}」として復帰できます',
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
        trailing: Wrap(
          spacing: 4,
          children: [
            if (!_resumeArmed)
              FilledButton(
                onPressed: _connecting
                    ? null
                    : () {
                        setState(() => _resumeArmed = true);
                        _tryResumeConnect();
                      },
                child: const Text('復帰する'),
              ),
            IconButton(
              tooltip: '復帰情報を破棄',
              icon: const Icon(Icons.delete_outline, color: Colors.white38),
              onPressed: () async {
                await SuspendStore.clearGuest();
                if (mounted) {
                  setState(() {
                    _guestSaved = null;
                    _resumeArmed = false;
                  });
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBody() {
    final hasAny =
        _lanRooms.isNotEmpty || _nearbyRooms.isNotEmpty || _bleRooms.isNotEmpty;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_guestSaved != null) _resumeCard(),
                const Row(
                  children: [
                    Text(
                      '見つかった部屋',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(width: 10),
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: !hasAny
                      ? Center(
                          child: Text(
                            '同じWi-Fi内と近く(${nearbySupported ? '同じOS同士' : '非対応'})の部屋を探しています…\n'
                            '見つからないときは右のIP入力かテザリングを使ってください',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView(
                          children: [
                            for (final room in _lanRooms)
                              Card(
                                color: const Color(0xFF1B4D2B),
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.wifi,
                                    color: Color(0xFFFFE082),
                                  ),
                                  title: Text(room.name),
                                  subtitle: Text(
                                    'Wi-Fi経由 ${room.host}:${room.port}',
                                    style: const TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                  ),
                                  trailing: const Icon(Icons.login),
                                  onTap: _connecting
                                      ? null
                                      : () => _connectLan(room.host, room.port),
                                ),
                              ),
                            for (final room in _nearbyRooms)
                              Card(
                                color: const Color(0xFF13424E),
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.bluetooth_searching,
                                    color: Color(0xFF80DEEA),
                                  ),
                                  title: Text(room.name),
                                  subtitle: const Text(
                                    '近距離接続(Wi-Fi不要・同じOS同士)',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                  ),
                                  trailing: const Icon(Icons.login),
                                  onTap: _connecting
                                      ? null
                                      : () => _connectNearby(room),
                                ),
                              ),
                            for (final room in _bleRooms)
                              Card(
                                color: const Color(0xFF1E3A5F),
                                child: ListTile(
                                  leading: const Icon(
                                    Icons.bluetooth,
                                    color: Color(0xFF82B1FF),
                                  ),
                                  title: Text(room.name),
                                  subtitle: const Text(
                                    'BLE接続(Wi-Fi不要・iPhone/Android混合可)',
                                    style: TextStyle(
                                      color: Colors.white38,
                                      fontSize: 11,
                                    ),
                                  ),
                                  trailing: const Icon(Icons.login),
                                  onTap: _connecting
                                      ? null
                                      : () => _connectBle(room),
                                ),
                              ),
                          ],
                        ),
                ),
                if (_nearbyError != null)
                  Text(
                    '近距離接続: $_nearbyError',
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 11,
                    ),
                  ),
                if (_bleError != null)
                  Text(
                    'BLE接続: $_bleError',
                    style: const TextStyle(
                      color: Colors.orangeAccent,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Container(width: 1, color: Colors.white12),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'IPアドレスで接続',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'ホスト画面に表示されているアドレスを入力',
                    style: TextStyle(color: Colors.white70, fontSize: 12.5),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _ipController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      hintText: '例: 192.168.1.23',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _connectManual(),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: _connecting ? null : _connectManual,
                    child: Text(_connecting ? '接続中…' : '接続'),
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: Colors.white12),
                  const Text(
                    'つながらないときは',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '・共通のWi-Fiがない場合は、誰か1人のスマホで「テザリング(インターネット共有)」をONにして、全員そのWi-Fiに接続してください(通信はその場で完結し、データはほぼ消費しません)\n'
                    '・iPhone同士/Android同士なら「近距離接続」でWi-Fiなしでも接続できます(iPhoneとAndroidの近距離直結はOSの制約で不可)',
                    style: TextStyle(color: Colors.white54, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
