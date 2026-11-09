// 牌画像(麻雀豆腐)を配布元から取得して assets/tiles/ に配置する。
//
// 配布元の利用規約では素材の頒布・転載に事前許諾が要るため、PNG はリポジトリに
// 同梱しない(2026-11-09 決定、docs/THIRD_PARTY_LICENSES.md)。ビルドする人が
// このスクリプトで取得する。
//
//   fvm dart run tool/fetch_tiles.dart                 # ダウンロードして配置
//   fvm dart run tool/fetch_tiles.dart path/to/x.zip   # 手元の zip から配置
//   fvm dart run tool/fetch_tiles.dart --list [zip]    # zip の中身を表示するだけ
//
// 配置先のファイル名規約は assets/tiles/README.md(man1..9 / pin1..9 / sou1..9 /
// ji1..7=東南西北發白中 / aka1..3=赤5筒・赤5索・赤5萬、66x90 の L 版プレーン)。
import 'dart:io';

import 'package:archive/archive_io.dart';

const zipUrl = 'https://majandofu.com/docs/mahjong-images/pai-images.zip';
const destDir = 'assets/tiles';

/// 採用しているデザイン: 配布元の `<名前>-66-90-l.png`(L 版・プレーン・縦向き)。
/// 2026-11-09 にリポジトリの 37 ファイルと配布元 zip をハッシュで突き合わせて確認した。
/// 他の候補(-l-emb=立体、-s/-s-emb=S 版、-yoko=横向き)は使わない。
const String variantSuffix = '-66-90-l';

/// アプリ側のファイル名(拡張子なし)。配布元の名前は同じ語で、suffix が付くだけ。
const List<String> tileNames = [
  'man1', 'man2', 'man3', 'man4', 'man5', 'man6', 'man7', 'man8', 'man9', //
  'pin1', 'pin2', 'pin3', 'pin4', 'pin5', 'pin6', 'pin7', 'pin8', 'pin9', //
  'sou1', 'sou2', 'sou3', 'sou4', 'sou5', 'sou6', 'sou7', 'sou8', 'sou9', //
  'ji1', 'ji2', 'ji3', 'ji4', 'ji5', 'ji6', 'ji7', // 東南西北發白中
  'aka1', 'aka2', 'aka3', // 赤5筒・赤5索・赤5萬
];

/// 配布元 zip 内のパス → アプリのファイル名
final Map<String, String> fileMap = {
  for (final n in tileNames) 'pai-images/$n$variantSuffix.png': '$n.png',
};

Future<void> main(List<String> args) async {
  final listOnly = args.contains('--list');
  final positional = args.where((a) => !a.startsWith('--')).toList();

  final zipFile = positional.isNotEmpty
      ? File(positional.first)
      : await _download();
  if (!zipFile.existsSync()) {
    stderr.writeln('zip が見つかりません: ${zipFile.path}');
    exit(1);
  }
  final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());

  if (listOnly) {
    for (final f in archive.files) {
      if (f.isFile) {
        stdout.writeln('${f.size.toString().padLeft(8)}  ${f.name}');
      }
    }
    return;
  }

  final byName = {for (final f in archive.files) f.name: f};
  final missing = <String>[];
  var written = 0;
  Directory(destDir).createSync(recursive: true);
  for (final entry in fileMap.entries) {
    final src = byName[entry.key];
    if (src == null || !src.isFile) {
      missing.add(entry.key);
      continue;
    }
    File('$destDir/${entry.value}').writeAsBytesSync(src.content as List<int>);
    written++;
  }
  stdout.writeln('$destDir に $written ファイルを配置しました');
  if (missing.isNotEmpty) {
    stderr.writeln('zip 内に見つからなかったもの(配布元の構成が変わった可能性):');
    for (final m in missing) {
      stderr.writeln('  $m');
    }
    stderr.writeln('`--list` で中身を確認して tool/fetch_tiles.dart の対応表を直してください');
    exit(2);
  }
}

Future<File> _download() async {
  final tmp = File('${Directory.systemTemp.path}/pai-images.zip');
  stdout.writeln('ダウンロード中: $zipUrl');
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(zipUrl));
    final res = await req.close();
    if (res.statusCode != 200) {
      stderr.writeln('ダウンロードに失敗しました(HTTP ${res.statusCode})');
      exit(1);
    }
    final sink = tmp.openWrite();
    await res.pipe(sink);
  } finally {
    client.close();
  }
  return tmp;
}
