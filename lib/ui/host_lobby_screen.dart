import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../net/discovery.dart';
import '../net/host.dart';
import '../net/protocol.dart';
import '../session/suspend.dart';
import '../session/suspend_store.dart';
import 'game_screen.dart';

class HostLobbyScreen extends StatefulWidget {
  final String hostName;
  final GameConfig config;

  /// 中断した対局の復帰モード(中断メンバーの合流待ちロビーになる)
  final SuspendedHostGame? resume;

  const HostLobbyScreen({
    super.key,
    required this.hostName,
    required this.config,
    this.resume,
  });

  @override
  State<HostLobbyScreen> createState() => _HostLobbyScreenState();
}

class _HostLobbyScreenState extends State<HostLobbyScreen> {
  HostServer? _server;
  LobbyState? _lobby;
  List<String> _addresses = [];
  StreamSubscription<LobbyState>? _sub;
  String? _error;
  bool _starting = false;
  bool _gameStarted = false;

  /// 通常ロビー表示中に見つかった、復帰可能な中断対局
  SuspendedHostGame? _saved;

  /// ホストは席に着かず観戦する(ギャラリー)
  bool _asGallery = false;

  /// ギャラリー時に観戦する席(0..3)
  int _watchSeat = 0;

  bool get _isResume => widget.resume != null;

  @override
  void initState() {
    super.initState();
    _boot();
    if (!_isResume) {
      // 中断した対局があれば復帰ボタンを出す
      SuspendStore.loadHost().then((saved) {
        if (mounted && saved != null) setState(() => _saved = saved);
      });
    }
  }

  Future<void> _boot() async {
    try {
      final server = HostServer(
        roomName: widget.resume?.roomName ?? '${widget.hostName}の卓',
        hostName: widget.resume?.hostName ?? widget.hostName,
        config: widget.resume?.config ?? widget.config,
        resume: widget.resume,
      );
      await server.start();
      final addresses = await localIpAddresses();
      if (!mounted) {
        await server.shutdown();
        return;
      }
      setState(() {
        _server = server;
        _lobby = server.lobbyState;
        _addresses = addresses;
      });
      _sub = server.lobbyStream.listen((state) {
        if (mounted) setState(() => _lobby = state);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '部屋を作れませんでした: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    // 対局開始後はセッション(GameScreen)側がサーバーを管理する
    if (!_gameStarted) _server?.shutdown();
    super.dispose();
  }

  void _startGame() {
    final server = _server;
    if (server == null || _starting) return;
    setState(() => _starting = true);
    final session = server.startGame(
      asGallery: _asGallery,
      watchSeat: _watchSeat,
    );
    _gameStarted = true;
    // 復帰情報は消費した(次に中断すればまた保存される)
    if (_isResume) SuspendStore.clearHost();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(session: session)),
    );
  }

  /// ギャラリー時の観戦席の選択肢(席0..3のラベル)。
  /// ホストが席に着かないため、席はゲスト4枠(空きはCPU)になる。
  List<String> _gallerySeatLabels(LobbyState lobby) {
    final slots = lobby.players.skip(1).take(4).toList();
    return [
      for (var i = 0; i < 4; i++)
        i < slots.length && !slots[i].isCpu ? slots[i].name : 'CPU(${i + 1}人目)',
    ];
  }

  /// 通常ロビーから中断対局の復帰ロビーへ切り替える
  void _switchToResume() {
    final saved = _saved;
    if (saved == null || _starting) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => HostLobbyScreen(
          hostName: saved.hostName,
          config: saved.config,
          resume: saved,
        ),
      ),
    );
  }

  /// ロビーの1人分の行(復帰ロビーでは合流待ちを表示する)
  Widget _playerTile(LobbyPlayer p) {
    final IconData icon;
    final Color color;
    final String label;
    if (p.waiting) {
      icon = Icons.hourglass_top;
      color = Colors.orangeAccent;
      label = '${p.name}(合流待ち…)';
    } else if (p.isCpu) {
      icon = Icons.smart_toy;
      color = Colors.white38;
      label = 'CPUが代打します';
    } else {
      icon = p.gallery ? Icons.visibility : Icons.person;
      color = const Color(0xFFFFE082);
      label = p.name + (p.isHost ? (p.gallery ? '(ホスト・観戦)' : '(ホスト)') : '');
    }
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(label),
    );
  }

  /// 通常ロビーに出す「中断した対局があります」バナー
  Widget _resumeBanner() {
    final saved = _saved!;
    return Card(
      color: const Color(0xFF4E3D13),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        dense: true,
        leading: const Icon(
          Icons.pause_circle_outline,
          color: Color(0xFFFFE082),
        ),
        title: Text('中断した対局: ${saved.roomName}'),
        subtitle: Text(
          '${saved.savedAt.month}/${saved.savedAt.day} '
          '${saved.savedAt.hour}:${saved.savedAt.minute.toString().padLeft(2, '0')} 中断'
          '${saved.guestNames.isEmpty ? '' : ' / 合流待ち: ${saved.guestNames.join('、')}'}',
          style: const TextStyle(fontSize: 11, color: Colors.white54),
        ),
        trailing: Wrap(
          spacing: 4,
          children: [
            FilledButton(onPressed: _switchToResume, child: const Text('復帰する')),
            IconButton(
              tooltip: '復帰情報を破棄',
              icon: const Icon(Icons.delete_outline, color: Colors.white38),
              onPressed: () async {
                await SuspendStore.clearHost();
                if (mounted) setState(() => _saved = null);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lobby = _lobby;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _server == null
              ? '部屋を作成中…'
              : _isResume
              ? '復帰待機: ${_server!.roomName}'
              : '部屋: ${_server!.roomName}',
        ),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: _error != null
            ? Center(
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              )
            : lobby == null
            ? const Center(child: CircularProgressIndicator())
            : Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 中断した対局があれば復帰への切り替えを出す
                          if (!_isResume && _saved != null) _resumeBanner(),
                          Text(
                            _isResume
                                ? 'メンバーの合流を待っています'
                                // 観戦するホストは対局メンバーに数えない
                                : 'メンバー(${lobby.players.where((p) => !p.isCpu && !p.gallery).length}/4)',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: ListView(
                              children: [
                                for (final p in lobby.players) _playerTile(p),
                              ],
                            ),
                          ),
                          // ギャラリー(観戦)として開始するオプション。
                          // 復帰時は中断時の形(参加/観戦)を引き継ぐので出さない
                          if (!_isResume) ...[
                            CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: _asGallery,
                              onChanged: (v) {
                                final on = v ?? false;
                                // ゲスト枠も3⇔4で切り替える(4人目がいる間は解除不可)
                                final ok = _server?.setGalleryMode(on) ?? false;
                                if (!ok) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('4人目のゲストがいる間は解除できません'),
                                    ),
                                  );
                                  return;
                                }
                                setState(() => _asGallery = on);
                              },
                              title: const Text(
                                '自分は参加せず観戦する(ギャラリー)',
                                style: TextStyle(fontSize: 13.5),
                              ),
                              subtitle: const Text(
                                'ゲスト枠が4になり、足りない席はCPUが打ちます',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                            if (_asGallery)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: [
                                    const Text(
                                      '観戦する席: ',
                                      style: TextStyle(fontSize: 13),
                                    ),
                                    DropdownButton<int>(
                                      value: _watchSeat,
                                      isDense: true,
                                      items: [
                                        for (var i = 0; i < 4; i++)
                                          DropdownMenuItem(
                                            value: i,
                                            child: Text(
                                              _gallerySeatLabels(lobby)[i],
                                              style: const TextStyle(
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                      ],
                                      onChanged: (v) =>
                                          setState(() => _watchSeat = v ?? 0),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          FilledButton.icon(
                            onPressed: _starting ? null : _startGame,
                            icon: const Icon(Icons.play_arrow),
                            label: Text(
                              _isResume
                                  ? (lobby.players.any((p) => p.waiting)
                                        ? '再開する(未合流はCPUが代行)'
                                        : '再開する')
                                  : _asGallery
                                  ? '観戦で開始する'
                                  : lobby.players.any((p) => p.isCpu)
                                  ? '開始する(足りない席はCPU)'
                                  : '開始する',
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 状態文が長くなっても(小画面でも)あふれないよう上部はスクロール
                          Expanded(
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _isResume ? '合流方法' : '参加方法',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _isResume
                                        ? '中断したメンバーは「部屋に入る」の復帰ボタンで'
                                              '自動的に合流します。\n'
                                              '全員そろわなくても再開でき、'
                                              '未合流の席はCPUが代打します(あとから合流も可)。'
                                        : '相手は「部屋に入る」から選ぶだけ。\n'
                                              '① 同じWi-Fi(またはテザリング)経由\n'
                                              '② 近距離接続(Wi-Fi不要・iPhone同士/Android同士)\n'
                                              '③ BLE接続(Wi-Fi不要・iPhone/Android混合可)',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _server!.nearbyStatus == null
                                        ? '近距離接続: 待受中'
                                        : '近距離接続: ${_server!.nearbyStatus}',
                                    style: TextStyle(
                                      color: _server!.nearbyStatus == null
                                          ? const Color(0xFF80DEEA)
                                          : Colors.orangeAccent,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    _server!.bleStatus == null
                                        ? 'BLE接続: 待受中(iPhone/Android混合可)'
                                        : 'BLE接続: ${_server!.bleStatus}',
                                    style: TextStyle(
                                      color: _server!.bleStatus == null
                                          ? const Color(0xFF80DEEA)
                                          : Colors.orangeAccent,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    '見つからないときは下のIPアドレスを直接入力:',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  for (final addr in _addresses)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 2,
                                      ),
                                      child: SelectableText(
                                        _server!.port == defaultPort
                                            ? addr
                                            : '$addr:${_server!.port}',
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFFFFE082),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const Text(
                            '共通Wi-Fiがない時は誰かのテザリングに全員接続でもOK',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'ルール: 半荘戦 / Mリーグ準拠(赤あり・頭ハネ・トビなし)',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
