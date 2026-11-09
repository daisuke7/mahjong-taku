// ignore_for_file: avoid_print
// 配牌テンパイの全数をアプリのシャンテン計算で数える(DBの is_tenho/is_chiho_possible との突き合わせ用)
// 使い方: fvm dart run tool/haipai_tenpai.dart <database.sqlite3>
import 'package:mahjong_taku/engine/hand.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/paifu/paifu_db.dart';
import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  final db = sqlite3.open(args.first);
  var total = 0, tenpai = 0, agree = 0, disagree = 0;
  for (final r in db.select(
    'SELECT h.hand, h.is_tenho_possible + h.is_chiho_possible AS flag, '
    'g.date, k.round, p.name FROM haipai_event h '
    'JOIN event e ON e.id = h.event_id JOIN kyoku k ON k.id = e.kyoku_id '
    'JOIN game g ON g.id = k.game_id JOIN player p ON p.id = h.actor_player_id',
  )) {
    final tiles = Tile.parse(r['hand'] as String);
    if (tiles.length != 13) continue;
    total++;
    final s = calcShanten(toCounts(tiles), meldCount: 0);
    final mine = s <= 0;
    if (mine) tenpai++;
    final theirs = (r['flag'] as int) == 1;
    if (mine == theirs) {
      agree++;
    } else {
      disagree++;
      print(
        '不一致: ${r['date']} ${r['round']} ${r['name']} ${r['hand']} '
        'app=$mine db=$theirs',
      );
    }
  }
  print('配牌 $total 件 / アプリ判定テンパイ $tenpai 件 / 一致 $agree / 不一致 $disagree');
  db.dispose();
  // アプリの一覧(「局を探す」→「天和・地和チャンス」と同じ問い合わせ)
  final pdb = PaifuDb.open(args.first);
  for (final h in pdb.haipaiTenpais()) {
    print(
      '${h.date} 第${h.matchNumber}試合 ${h.kyokuLabel} ${h.name}(${h.chanceLabel}) '
      '${h.hand} → ${h.firstTile} ${h.firstActionLabel} → ${h.resultLabel}',
    );
  }
  pdb.close();
}
