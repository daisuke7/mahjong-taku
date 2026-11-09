import 'dart:async';
import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../session/local_session.dart';
import 'game_screen.dart';
import 'host_lobby_screen.dart';
import 'join_screen.dart';
import '../paifu/paifu_update_check.dart';
import 'paifu_home_screen.dart';
import 'widgets/guidebook.dart';
import 'yomi_quiz_screen.dart';

/// アプリ内で使い回すプレイヤー設定(セッション中のみ保持)
class PlayerPrefs {
  static String name = '';
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _nameController;

  /// 動作確認用: --dart-define=AUTOSTART_SOLO=true でソロ対局を自動開始
  static const bool _autostartSolo = bool.fromEnvironment('AUTOSTART_SOLO');

  /// 動作確認用: --dart-define=OPEN_GUIDE=true で早見表を自動で開く
  static const bool _openGuide = bool.fromEnvironment('OPEN_GUIDE');
  static const int _guidePage = int.fromEnvironment('GUIDE_PAGE');

  /// 動作確認用: --dart-define=OPEN_YOMI_QUIZ=true で読みクイズを自動で開く
  /// (牌譜DBダウンロード済みの端末でのみ動く)
  static const bool _openYomiQuiz = bool.fromEnvironment('OPEN_YOMI_QUIZ');

  /// 動作確認用: --dart-define=AUTO_HOST=true で部屋を作る画面を自動で開く、
  /// --dart-define=AUTO_JOIN=true で部屋に入る画面を自動で開く(実機通信確認用)
  static const bool _autoHost = bool.fromEnvironment('AUTO_HOST');
  static const bool _autoJoin = bool.fromEnvironment('AUTO_JOIN');

  /// 動作確認用: --dart-define=OPEN_PAIFU_HOME=true で牌譜閲覧モードを自動で開く
  static const bool _openPaifuHome = bool.fromEnvironment('OPEN_PAIFU_HOME');

  /// 動作確認用: `--dart-define=AUTO_JOIN_IP=<host>` で指定先へ自動接続する
  static const String _autoJoinIp = String.fromEnvironment('AUTO_JOIN_IP');

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: PlayerPrefs.name);
    // 牌譜DBの更新有無を起動後1回だけ確認(DBなし・オフラインなら何もしない)
    unawaited(PaifuUpdateCheck.runOnce());
    if (_autostartSolo) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startSolo());
    }
    if (_openGuide) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => showGuidebook(context, initialPage: _guidePage),
      );
    }
    if (_openPaifuHome) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const PaifuHomeScreen()),
        ),
      );
    }
    if (_openYomiQuiz) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const YomiQuizScreen()),
        ),
      );
    }
    if (_autoHost) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                HostLobbyScreen(hostName: _playerName, config: _config),
          ),
        ),
      );
    }
    if (_autoJoin || _autoJoinIp.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => JoinScreen(
              playerName: _playerName,
              autoConnectHost: _autoJoinIp.isEmpty ? null : _autoJoinIp,
            ),
          ),
        ),
      );
    }
  }

  void _startSolo() {
    final session = LocalSession(playerName: _playerName, config: _config);
    if (_autostartSolo) _attachAutopilot(session);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(session: session)),
    );
  }

  /// 動作確認用: 自席もツモ切り・スルーで自動進行させる
  static void _attachAutopilot(LocalSession session) {
    void answerTurn(TurnPrompt p) {
      Future.delayed(const Duration(milliseconds: 600), () {
        final view = session.latestView;
        if (view == null) return;
        session.sendTurn(TurnAction.discard(p.drawnTile ?? view.hand.first));
      });
    }

    session.turnPrompts.listen(answerTurn);
    session.reactPrompts.listen(
      (_) => session.sendReact(const ReactAction.pass()),
    );
    // 購読前に発行済みのプロンプトも処理する
    final pending = session.activeTurnPrompt;
    if (pending != null) answerTurn(pending);
    var advancedSerial = -1;
    var lastPhase = '';
    session.views.listen((v) {
      if (v.phase == 'handEnd' && v.lastEvent?.serial != advancedSerial) {
        advancedSerial = v.lastEvent?.serial ?? -1;
        Future.delayed(const Duration(seconds: 2), session.advance);
      }
      // 試合が終わったら自動で次の試合へ(連戦の動作確認用)
      if (v.phase == 'gameEnd' && lastPhase != 'gameEnd') {
        Future.delayed(const Duration(seconds: 3), session.nextGame);
      }
      lastPhase = v.phase;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String get _playerName {
    final name = _nameController.text.trim();
    PlayerPrefs.name = name;
    return name.isEmpty ? 'プレイヤー' : name;
  }

  // Mリーグルール専用なので半荘戦固定(GameConfig の既定)。東風戦の選択は置かない
  // (2026-11-09 までは切り替えが有り、ルールレビューで「意図的な機能追加」と誤分類していた)
  GameConfig get _config => const GameConfig();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '麻雀卓',
                      style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFFFE082),
                        letterSpacing: 8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Wi-Fi・近距離・Bluetooth でつながる四人打ちリーチ麻雀(Mリーグルール)',
                      style: TextStyle(color: Colors.white54),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '牌画像: 麻雀豆腐(majandofu.com)',
                      style: TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: 300,
                      child: TextField(
                        controller: _nameController,
                        maxLength: 8,
                        decoration: const InputDecoration(
                          labelText: 'なまえ',
                          counterText: '',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 14,
                      runSpacing: 10,
                      alignment: WrapAlignment.center,
                      children: [
                        _menuButton(
                          icon: Icons.smart_toy,
                          label: 'ひとりで打つ',
                          subtitle: 'CPU3人と対局',
                          onTap: _startSolo,
                        ),
                        _menuButton(
                          icon: Icons.wifi_tethering,
                          label: '部屋を作る',
                          subtitle: 'この端末がホストになる',
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => HostLobbyScreen(
                                  hostName: _playerName,
                                  config: _config,
                                ),
                              ),
                            );
                          },
                        ),
                        _menuButton(
                          icon: Icons.search,
                          label: '部屋に入る',
                          subtitle: '近くの部屋を探す',
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    JoinScreen(playerName: _playerName),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // 右上に牌譜閲覧モード切替+早見表(ガイド)ボタン。
            // スクロール領域にタップを奪われないよう最前面(Stackの最後)に置く
            Align(
              alignment: Alignment.topRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.history_edu,
                      color: Color(0xFFFFD54F),
                    ),
                    tooltip: '牌譜閲覧モードへ',
                    onPressed: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const PaifuHomeScreen(),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.menu_book, color: Color(0xFFFFD54F)),
                    tooltip: '早見表',
                    onPressed: () => showGuidebook(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuButton({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: 180,
      height: 92,
      child: FilledButton.tonal(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1B4D2B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF2E7D32)),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 26, color: const Color(0xFFFFE082)),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 10.5, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
