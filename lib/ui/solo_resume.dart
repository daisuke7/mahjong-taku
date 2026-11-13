import 'package:flutter/material.dart';

import '../session/local_session.dart';
import '../session/suspend.dart';
import '../session/suspend_store.dart';
import 'game_screen.dart';

/// 中断したソロ対局を、復帰ロビー(HostServer)を経由せずに再開する。
/// 通信対戦の無いビルド(Web)ではサーバーを立てられないのでこちらを使う。
/// ロビー経由の復帰と同じく、開始時点で復帰情報は消す(次の中断で保存し直す)。
Future<void> resumeSoloGame(
  BuildContext context,
  SuspendedHostGame saved, {
  bool replace = false,
}) async {
  await SuspendStore.clearHost();
  if (!context.mounted) return;
  final route = MaterialPageRoute<void>(
    builder: (_) => GameScreen(session: LocalSession.resume(saved)),
  );
  if (replace) {
    Navigator.pushReplacement(context, route);
  } else {
    Navigator.push(context, route);
  }
}
