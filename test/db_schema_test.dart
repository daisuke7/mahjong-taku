import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/paifu/db_schema.dart';
import 'package:mahjong_taku/paifu/own_paifu_format.dart';
import 'package:mahjong_taku/paifu/paifu_db.dart';
import 'package:sqlite3/sqlite3.dart';

import 'paifu_fixture.dart';

/// 牌譜DBの取り込み時検査(足りないテーブル・列の検出)と、自分牌譜JSONの版管理。
/// 背景: docs/failure-log.md 2026-10-02(配布元の改名でビューアが丸ごと動かなくなった)。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('db_schema');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('フィクスチャ(現行スキーマ)は検査に通る', () {
    final path = '${tmp.path}/ok.sqlite3';
    buildPaifuFixture(path);
    expect(PaifuDb.schemaProblemsAt(path), isEmpty);
  });

  test('テーブルや列が足りなければ「table」「table.column」の形で列挙する', () {
    final path = '${tmp.path}/old.sqlite3';
    buildPaifuFixture(path);
    final db = sqlite3.open(path);
    // 旧名に戻す(2026-10-01 リリース前の形を再現)
    db.execute('ALTER TABLE agari_yaku RENAME TO agari_yaku_event');
    db.execute(
      'ALTER TABLE kyoku RENAME COLUMN oya_player_id TO parent_player_id',
    );
    db.dispose();
    final problems = PaifuDb.schemaProblemsAt(path);
    expect(problems, contains('agari_yaku'));
    expect(problems, contains('kyoku.oya_player_id'));
    expect(problems, isNot(contains('kyoku.round')));
  });

  test('生成列(GENERATED ALWAYS)も「ある」と判定する(table_xinfo)', () {
    final path = '${tmp.path}/gen.sqlite3';
    buildPaifuFixture(path);
    final db = sqlite3.open(path);
    // 本物の agari_event と同じく revenue_points を生成列にする
    db.execute('ALTER TABLE agari_event RENAME TO agari_event_old');
    db.execute(
      'CREATE TABLE agari_event (event_id INTEGER, actor_player_id INTEGER, '
      'target_player_id INTEGER, agari_points INTEGER, honba_points INTEGER, '
      'kyotaku_points INTEGER, revenue_points INTEGER GENERATED ALWAYS AS '
      '(agari_points + honba_points + kyotaku_points) VIRTUAL, '
      'agari_tile TEXT, agari_waiting_type TEXT, fu INTEGER, han INTEGER, '
      'is_called INTEGER, is_menzen INTEGER, is_yakuman INTEGER, description TEXT)',
    );
    db.dispose();
    expect(
      PaifuDb.schemaProblemsAt(path),
      isNot(contains('agari_event.revenue_points')),
    );
    expect(PaifuDb.schemaProblemsAt(path), isEmpty);
  });

  test('開けないファイルは「全部足りない」扱い(例外にしない)', () {
    expect(PaifuDb.schemaProblemsAt('${tmp.path}/missing.sqlite3'), isNotEmpty);
  });

  test('対応外の版の例外メッセージは版と足りないものを含み、今の牌譜が使えると伝える', () {
    final e = PaifuSchemaUnsupported('20261001-2219-x', [
      'agari_yaku',
      'kyoku.oya_player_id',
      'a',
      'b',
    ]);
    final s = e.toString();
    expect(s, contains('20261001-2219-x'));
    expect(s, contains('まだ対応していません'));
    expect(s, contains('今の牌譜はそのまま使えます'));
    expect(s, contains('agari_yaku'));
    expect(s, contains('他1件'));
  });

  test('DbSchema.required の列名定数は変換表(internalToDbKey)の値を全部含む', () {
    final all = {
      for (final e in DbSchema.required.entries)
        for (final c in e.value) c,
    };
    for (final db in internalToDbKey.values) {
      expect(all, contains(db), reason: '変換表の列 $db が required に無い');
    }
  });

  group('自分牌譜JSONの版', () {
    test('保存時に format を付け、読み込みで版0(キー無し)は版1に繰り上がる', () {
      final stamped = stampOwnPaifuFormat({'id': 'x', 'kyokus': []});
      expect(stamped['format'], ownPaifuFormatVersion);
      final migrated = migrateOwnPaifu({'id': 'x', 'kyokus': []});
      expect(migrated['format'], ownPaifuFormatVersion);
      expect(migrated['id'], 'x');
    });

    test('繰り上げは元の Map を変更しない', () {
      final src = <String, dynamic>{'id': 'x'};
      migrateOwnPaifu(src);
      expect(src.containsKey('format'), isFalse);
    });

    test('未知の未来の版はそのまま(壊さない)', () {
      final g = migrateOwnPaifu({'format': ownPaifuFormatVersion + 1});
      expect(g['format'], ownPaifuFormatVersion + 1);
    });
  });
}
