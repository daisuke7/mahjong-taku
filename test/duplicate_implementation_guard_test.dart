import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 二重実装の機械検査(CLAUDE.md §2 の「同じ計算を 2 箇所に書かない」の見張り)。
///
/// 同じ値を出している間は誰も気づかないので、人の監査(pre-publish-review §3.5)を
/// 待たずに、重複しやすい「式・リテラル」が決まったファイル以外に現れた瞬間に
/// 赤くする。2026-11-09 の監査で 11 件が溜まっていた反省から導入
/// (docs/failure-log.md 2026-11-09)。
///
/// 新しい共有関数を作ったら、その本体にしか現れない式・リテラルをここに足す。
/// 許可ファイルを増やすのは「その式を使わざるを得ない理由」がある時だけで、
/// 普通は共有関数を呼ぶ側に直す。
void main() {
  // (正規表現, 許可するファイル, 何の重複か)
  final rules = <(RegExp, Set<String>, String)>[
    (
      RegExp(r'\(1 << \(2 \+'),
      {'lib/engine/score.dart'},
      '基本点の式 fu × 2^(2+han) は basePointsOf だけが持つ',
    ),
    (
      RegExp(r'\+ 99\) ~/ 100'),
      {'lib/engine/score.dart'},
      '100点単位の切り上げは ceil100 だけが持つ',
    ),
    (
      RegExp(r'50000, 10000, -10000, -30000'),
      {'lib/engine/score.dart'},
      'Mリーグ順位点の表は mleagueRankBonus だけ',
    ),
    (
      RegExp(r'Tile\.normalize\(t\) == d\)\.length'),
      {'lib/engine/yaku.dart'},
      'ドラ枚数を数えるループは countDora だけ',
    ),
    (
      RegExp(
        r'\{\s*for \(final ind in [^)]*\)\s*(Tile\.)?doraFromIndicator\(ind\),?\s*\}',
      ),
      {'lib/engine/tile.dart'},
      'ドラ種集合の内包表記は Tile.doraKinds だけ',
    ),
    (
      RegExp(r'Tile\.isDragon\(\w+\) \? 1 : 0'),
      {'lib/engine/yaku.dart'},
      '役牌の翻数の足し算は yakuhaiHan だけ',
    ),
    (
      RegExp(r'- dealer \+ 4\) % 4'),
      {'lib/engine/models.dart'},
      '自風の式は seatWindOf だけ',
    ),
    (
      RegExp(r"'東', '南', '西', '北'"),
      {'lib/engine/tile.dart'},
      '風の名前の表は windNames / Tile.displayName だけ',
    ),
    (
      RegExp(r"'白', '發', '中'"),
      {'lib/engine/tile.dart'},
      '三元牌の名前の表は Tile.displayName だけ',
    ),
    (
      RegExp(r"'CPU 東子'"),
      {'lib/engine/display_text.dart'},
      'CPU 名の表は cpuPlayerNames だけ',
    ),
    (
      RegExp(r'3 => 0,'),
      {'lib/engine/paifu_record.dart'},
      '鳴いた牌の位置(上家=先頭/対面=2番目/下家=末尾)は calledTilePosition だけ',
    ),
  ];

  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  test('lib/ の Dart ファイルを読めている', () {
    expect(files, isNotEmpty, reason: 'lib/ をプロジェクトルートから読めていない');
  });

  for (final (pattern, allowed, what) in rules) {
    test(what, () {
      final hits = <String>[];
      for (final f in files) {
        if (pattern.hasMatch(f.readAsStringSync())) hits.add(f.path);
      }
      // 本体が消えていたら、式が別の場所へ移った(=この規則を直す)
      expect(
        hits.where(allowed.contains),
        isNotEmpty,
        reason: '$what のはずが、許可ファイル $allowed に式が無い。本体を移したなら規則を更新する',
      );
      final violations = hits.where((p) => !allowed.contains(p)).toList();
      expect(
        violations,
        isEmpty,
        reason:
            '二重実装の疑い: $what。\n'
            '  $violations\n'
            '  CLAUDE.md §2 の置き場所の関数を呼ぶ形に直す',
      );
    });
  }
}
