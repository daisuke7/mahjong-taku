// ignore_for_file: avoid_print
// 牌譜DBファイルをアプリの取り込み時検査(PaifuDb.schemaProblemsAt)に掛ける(動作確認用)。
// 使い方: fvm dart run tool/db_schema_check.dart <database.sqlite3>
import 'package:mahjong_taku/paifu/paifu_db.dart';

void main(List<String> args) {
  final problems = PaifuDb.schemaProblemsAt(args.first);
  print(problems.isEmpty ? '検査OK(足りないもの無し)' : '足りないもの: ${problems.join(', ')}');
}
