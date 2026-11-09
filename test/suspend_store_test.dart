import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/engine/models.dart';
import 'package:mahjong_taku/engine/resume.dart';
import 'package:mahjong_taku/engine/tile.dart';
import 'package:mahjong_taku/session/suspend.dart';
import 'package:mahjong_taku/session/suspend_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 復帰情報の永続化(shared_preferences)の往復
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ResumeData sampleData() => ResumeData(
    config: const GameConfig(rounds: 2),
    names: const ['ホスト', 'ゲストA', 'CPU 南美', 'CPU 西夫'],
    isCpu: const [false, false, true, true],
    seatMember: const [2, 0, 3, 1],
    dealer: 1,
    roundWind: 1,
    kyoku: 3,
    honba: 2,
    handsPlayed: 6,
    scores: const [31000, 24000, 20000, 24000],
    riichiSticks: 1,
    statWins: const [2, 1, 0, 1],
    statRiichis: const [1, 2, 0, 0],
    statDealIns: const [0, 1, 1, 0],
    history: [
      const GameStats(
        points: [50.0, 10.0, -20.0, -40.0],
        wins: [3, 1, 1, 0],
        riichis: [2, 1, 1, 0],
        dealIns: [0, 1, 0, 2],
      ),
    ],
    wall: List.generate(136, (i) => i % 34),
    actions: const [
      RecordedAction(0, 't', {'type': 'discard', 'tile': 5, 'riichi': false}),
      RecordedAction(2, 'r', {'type': 'pass', 'tiles': <int>[]}),
    ],
  );

  test('ホストの復帰情報: 保存→読込→破棄', () async {
    SharedPreferences.setMockInitialValues({});
    final game = SuspendedHostGame.capture(
      roomName: 'ホストの卓',
      hostName: 'ホスト',
      data: sampleData(),
      savedAt: DateTime(2026, 7, 17, 21, 30),
    );
    expect(game.guestNames, ['ゲストA']);

    await SuspendStore.saveHost(game);

    // 保存形式は配列で、各要素にリビジョンと中断日時が入る
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString('suspendedHostGames')!) as List;
    expect(stored, hasLength(1));
    expect((stored[0] as Map)['rev'], suspendDataRevision);
    expect((stored[0] as Map)['savedAt'], isNotNull);

    final loaded = await SuspendStore.loadHost();
    expect(loaded, isNotNull);
    expect(loaded!.roomName, 'ホストの卓');
    expect(loaded.hostName, 'ホスト');
    expect(loaded.guestNames, ['ゲストA']);
    expect(loaded.savedAt, DateTime(2026, 7, 17, 21, 30));
    expect(loaded.revision, suspendDataRevision);

    final data = loaded.resumeData;
    expect(data.kyoku, 3);
    expect(data.honba, 2);
    expect(data.riichiSticks, 1);
    expect(data.scores, [31000, 24000, 20000, 24000]);
    expect(data.seatMember, [2, 0, 3, 1]);
    expect(data.wall.length, 136);
    expect(data.actions.length, 2);
    expect(data.actions[0].kind, 't');
    expect(data.actions[1].seat, 2);
    expect(data.history.single.points, [50.0, 10.0, -20.0, -40.0]);

    await SuspendStore.clearHost();
    expect(await SuspendStore.loadHost(), isNull);
  });

  test('保存時のみ牌をMリーグ牌譜DB表記へ変換する(内部表現はintのまま)', () async {
    // 1牌の変換(赤5は '0m/0p/0s'、字牌は '1z'〜'7z')
    expect(Tile.dbNotation(0), '1m');
    expect(Tile.dbNotation(4), '5m');
    expect(Tile.dbNotation(Tile.red5m), '0m');
    expect(Tile.dbNotation(Tile.red5p), '0p');
    expect(Tile.dbNotation(Tile.red5s), '0s');
    expect(Tile.dbNotation(17), '9p');
    expect(Tile.dbNotation(Tile.east), '1z');
    expect(Tile.dbNotation(Tile.chun), '7z');
    for (var t = 0; t <= Tile.red5s; t++) {
      expect(Tile.fromDbNotation(Tile.dbNotation(t)), t, reason: '往復 t=$t');
    }

    SharedPreferences.setMockInitialValues({});
    final data = ResumeData(
      config: const GameConfig(rounds: 2),
      names: const ['ホスト', 'ゲストA', 'CPU 南美', 'CPU 西夫'],
      isCpu: const [false, false, true, true],
      seatMember: const [0, 1, 2, 3],
      dealer: 0,
      roundWind: 0,
      kyoku: 1,
      honba: 0,
      handsPlayed: 0,
      scores: const [25000, 25000, 25000, 25000],
      riichiSticks: 0,
      statWins: const [0, 0, 0, 0],
      statRiichis: const [0, 0, 0, 0],
      statDealIns: const [0, 0, 0, 0],
      history: const [],
      wall: [0, Tile.red5m, Tile.east, 33, 17],
      actions: [
        RecordedAction(0, 't', {
          'type': 'discard',
          'tile': Tile.red5p,
          'riichi': true,
        }),
        const RecordedAction(1, 't', {'type': 'tsumo', 'tile': -1}),
        const RecordedAction(2, 'r', {
          'type': 'chi',
          'tiles': [3, 4],
        }),
      ],
    );
    await SuspendStore.saveHost(
      SuspendedHostGame.capture(
        roomName: '表記変換の卓',
        hostName: 'ホスト',
        data: data,
        savedAt: DateTime(2026, 7, 21, 12, 0),
      ),
    );

    // ストレージ上はDB表記の文字列になっている
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString('suspendedHostGames')!) as List;
    final engine = ((stored[0] as Map)['engine'] as Map);
    expect(engine['wall'], ['1m', '0m', '1z', '7z', '9p']);
    final acts = engine['actions'] as List;
    expect(((acts[0] as Map)['a'] as Map)['tile'], '0p');
    expect(((acts[0] as Map)['a'] as Map)['riichi'], true, reason: '牌以外は不変');
    expect(((acts[1] as Map)['a'] as Map)['tile'], '', reason: 'ツモ(-1)は空文字');
    expect(((acts[2] as Map)['a'] as Map)['tiles'], ['4m', '5m']);

    // 読み込むと内部表現(int)へ戻る
    final loaded = (await SuspendStore.loadHost())!.resumeData;
    expect(loaded.wall, [0, Tile.red5m, Tile.east, 33, 17]);
    expect(loaded.actions[0].action['tile'], Tile.red5p);
    expect(loaded.actions[1].action['tile'], -1);
    expect(loaded.actions[2].action['tiles'], [3, 4]);
    await SuspendStore.clearHost();
  });

  test('ゲストの復帰情報: 保存→読込→破棄', () async {
    SharedPreferences.setMockInitialValues({});
    await SuspendStore.saveGuest(
      SuspendedGuestGame(
        roomName: 'ホストの卓',
        playerName: 'ゲストA2',
        savedAt: DateTime(2026, 7, 17, 22, 0),
      ),
    );
    final loaded = await SuspendStore.loadGuest();
    expect(loaded, isNotNull);
    expect(loaded!.roomName, 'ホストの卓');
    expect(loaded.playerName, 'ゲストA2');

    await SuspendStore.clearGuest();
    expect(await SuspendStore.loadGuest(), isNull);
  });

  test('壊れた保存データは null 扱い(クラッシュしない)', () async {
    SharedPreferences.setMockInitialValues({
      'suspendedHostGames': '{{{not json',
      'suspendedGuestGames': '42',
    });
    expect(await SuspendStore.loadHost(), isNull);
    expect(await SuspendStore.loadGuest(), isNull);
  });

  test('旧形式(単一オブジェクト・rev無し)も読める(rev=1扱い)', () async {
    final game = SuspendedHostGame.capture(
      roomName: '旧形式の卓',
      hostName: 'ホスト',
      data: sampleData(),
      savedAt: DateTime(2026, 7, 16, 12, 0),
    );
    final legacy = game.toJson()..remove('rev'); // rev導入前の保存を再現
    SharedPreferences.setMockInitialValues({
      'suspendedHostGame': jsonEncode(legacy), // 旧キー・非配列
      'suspendedGuestGame': jsonEncode(
        SuspendedGuestGame(
          roomName: '旧形式の卓',
          playerName: 'ゲストA',
          savedAt: DateTime(2026, 7, 16, 12, 0),
        ).toJson()..remove('rev'),
      ),
    });
    final host = await SuspendStore.loadHost();
    expect(host, isNotNull);
    expect(host!.roomName, '旧形式の卓');
    expect(host.revision, 1);
    final guest = await SuspendStore.loadGuest();
    expect(guest, isNotNull);
    expect(guest!.playerName, 'ゲストA');
    expect(guest.revision, 1);

    // clear は旧キーも消す
    await SuspendStore.clearHost();
    await SuspendStore.clearGuest();
    expect(await SuspendStore.loadHost(), isNull);
    expect(await SuspendStore.loadGuest(), isNull);
  });

  test('未知の新しいリビジョンは読まずに無視する(将来データ)', () async {
    final game = SuspendedHostGame.capture(
      roomName: '未来の卓',
      hostName: 'ホスト',
      data: sampleData(),
      savedAt: DateTime(2026, 7, 17, 23, 0),
    );
    final future = game.toJson()..['rev'] = suspendDataRevision + 1;
    SharedPreferences.setMockInitialValues({
      'suspendedHostGames': jsonEncode([future]),
    });
    expect(
      await SuspendStore.loadHost(),
      isNull,
      reason: '読めないリビジョンでクラッシュも誤読もしない',
    );
  });

  test('複数エントリの配列は新しい順で返る(将来の複数セット保存)', () async {
    final older = SuspendedHostGame.capture(
      roomName: '古い卓',
      hostName: 'ホスト',
      data: sampleData(),
      savedAt: DateTime(2026, 7, 15, 10, 0),
    );
    final newer = SuspendedHostGame.capture(
      roomName: '新しい卓',
      hostName: 'ホスト',
      data: sampleData(),
      savedAt: DateTime(2026, 7, 17, 10, 0),
    );
    SharedPreferences.setMockInitialValues({
      'suspendedHostGames': jsonEncode([older.toJson(), newer.toJson()]),
    });
    final all = await SuspendStore.loadHostAll();
    expect(all.map((g) => g.roomName), ['新しい卓', '古い卓']);
    expect((await SuspendStore.loadHost())!.roomName, '新しい卓');
  });
}
