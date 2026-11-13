import 'package:flutter/material.dart';

import '../../session/suspend.dart';

/// 「中断した対局がある」の帯(復帰/破棄ボタン付き)。
/// 部屋を作るロビー(ネット対戦・ソロ共用)と、通信対戦の無いビルドのホーム画面の両方で使う。
class ResumeBanner extends StatelessWidget {
  final SuspendedHostGame saved;
  final VoidCallback onResume;
  final VoidCallback onDiscard;

  const ResumeBanner({
    super.key,
    required this.saved,
    required this.onResume,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
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
            FilledButton(onPressed: onResume, child: const Text('復帰する')),
            IconButton(
              tooltip: '復帰情報を破棄',
              icon: const Icon(Icons.delete_outline, color: Colors.white38),
              onPressed: onDiscard,
            ),
          ],
        ),
      ),
    );
  }
}
