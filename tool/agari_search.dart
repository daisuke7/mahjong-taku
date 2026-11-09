// ignore_for_file: avoid_print
// 「局を探す」のアガリ検索を本番と同じ問い合わせで実DBに掛けて一覧する(動作確認用)。
// 使い方: fvm dart run tool/agari_search.dart <database.sqlite3> <kind>
//   kind: yakuman | sanbaiman | baiman | ippatsu | dora7 | ura3 | hadakaTanki
//         | missedRon | failedRiichi | haipaiTenpai | zeninShugo
import 'package:mahjong_taku/paifu/paifu_db.dart';

void main(List<String> args) {
  final db = PaifuDb.open(args[0]);
  try {
    final sw = Stopwatch()..start();
    // アガリ検索以外の一覧(通らなかったリーチ・配牌テンパイ・見逃し)もここから確認できる
    switch (args[1]) {
      case 'missedRon':
        for (final m in db.missedRonAgaris()) {
          print(
            '${m.date} 第${m.matchNumber}試合 ${m.kyokuLabel} ${m.winnerName}: '
            '${m.missedTile}(${m.missedFromName})見逃し → ${m.loserName}から${m.ronTile} ${m.points}点'
            '${m.sameOpponent ? ' ★同じ相手' : ''}',
          );
        }
        print('見逃しからのロン和了: ${sw.elapsedMilliseconds}ms');
        return;
      case 'failedRiichi':
        print(
          '通らなかったリーチ: ${db.failedRiichis().length} 件 ${sw.elapsedMilliseconds}ms',
        );
        return;
      case 'zeninShugo':
        for (final z in db.zeninShugoFinals()) {
          print(
            '${z.date} 第${z.matchNumber}試合 ${z.kyokuLabel} ${z.startScoresLabel} '
            '→ ${z.resultLabel} / 1位 ${z.winnerName}'
            '${z.agariButNotTop ? ' ★和了してもトップになれず' : ''}',
          );
        }
        print('全員集合からの決着: ${sw.elapsedMilliseconds}ms');
        return;
      case 'haipaiTenpai':
        print(
          '天和・地和チャンス: ${db.haipaiTenpais().length} 件 ${sw.elapsedMilliseconds}ms',
        );
        return;
    }
    final kind = AgariSearchKind.values.byName(args[1]);
    final list = db.searchAgari(kind);
    print('${kind.label}: ${list.length} 件(countAgari=${db.countAgari(kind)})');
    for (final a in list) {
      print(
        '${a.date} 第${a.matchNumber}試合 ${a.kyokuLabel} ${a.winnerName} '
        '${a.isTsumo ? 'ツモ' : '${a.loserName}からロン'} ${a.points}点 ${a.yaku}',
      );
    }
  } finally {
    db.close();
  }
}
