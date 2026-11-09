import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';

/// Mリーグルール専用であることの見張り(CLAUDE.md §1)。
/// 2026-11-09: 東風戦の切り替えが初期実装から残ったまま GitHub へ初回 push してしまった
/// (ルールレビューで「意図的な機能追加」と誤分類)。同じ種類の逸脱が UI に戻らないよう固定する。
void main() {
  test('対局設定の既定は半荘戦(東南二風)', () {
    expect(const GameConfig().rounds, 2);
    expect(GameConfig.fromJson(const {}).rounds, 2);
  });

  test('UI に東風戦の選択肢・表記が無い(Mリーグに東風戦は存在しない)', () {
    final hits = <String>[];
    for (final f in Directory('lib/ui').listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.dart')) {
        // コメント行は除いて、画面に出る文字列だけを見る
        final code = f
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        if (code.contains('東風戦')) hits.add(f.path);
      }
    }
    expect(hits, isEmpty, reason: '東風戦に触れる UI がある: $hits');
  });
}
