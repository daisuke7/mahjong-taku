import 'package:flutter/material.dart';

import '../session/suspend.dart';
import 'host_lobby_screen.dart';

/// 対局中断後の画面。
/// 全員に「中断した」ことを示し、ホストにだけ復帰ボタンを出す。
/// ゲストはホーム画面の「部屋に入る」から復帰できる。
class SuspendScreen extends StatelessWidget {
  /// ホストの場合は保存済みの復帰情報(ゲストは null)
  final SuspendedHostGame? hostGame;

  /// 観戦者(ギャラリー)だったか。復帰情報は無いので案内文を変える
  final bool spectator;

  const SuspendScreen({super.key, this.hostGame, this.spectator = false});

  bool get _isHost => hostGame != null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.pause_circle_outline,
                size: 56,
                color: Color(0xFFFFE082),
              ),
              const SizedBox(height: 14),
              Text(
                _isHost ? '対局を中断しました' : 'ホストが対局を中断しました',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _isHost
                    ? '状況は保存済みです。復帰するとメンバーの合流待ちになります。\n'
                          '(アプリを終了しても、あとで「部屋を作る」から復帰できます)'
                    : spectator
                    ? '観戦していた対局は中断されました。\n'
                          'ホストが再開したら、また「部屋に入る」から観戦を希望できます。'
                    : '状況はホストに保存されています。\n'
                          'ホストが復帰したら、「部屋に入る」の復帰ボタンから合流してください。',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 24),
              if (_isHost)
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('復帰する'),
                  onPressed: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => HostLobbyScreen(
                          hostName: hostGame!.hostName,
                          config: hostGame!.config,
                          resume: hostGame,
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).popUntil((r) => r.isFirst),
                child: const Text('ホームへ戻る'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
