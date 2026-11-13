/// 実行環境で使える機能の判定(1 箇所に集約)。
///
/// Web ビルド(feature/web-solo)はひとりで打つ専用。ファイル保存と通信対戦は
/// 使えないので、ストアの入口は何もせず、ホーム画面は入口を出さない。
/// 判定は今はビルド時定数だが、将来プローブ(実際に開けるか試す)に変えても
/// 呼び出し側は変わらない。
library;

import 'package:flutter/foundation.dart' show kIsWeb;

class Features {
  /// 端末ローカルのファイル保存(牌譜DB・自分の牌譜・手動記録)。
  /// path_provider と dart:io を使うので Web では不可。
  /// shared_preferences(中断・復帰、お気に入り)は Web でも使えるので対象外。
  static const bool localFiles = !kIsWeb;

  /// 通信対戦(部屋を作る/部屋に入る)。Web はホスト不可(HttpServer が無い)、
  /// 参加は Web 用 WebSocket トランスポート未実装のため不可。
  static const bool netPlay = !kIsWeb;
}
