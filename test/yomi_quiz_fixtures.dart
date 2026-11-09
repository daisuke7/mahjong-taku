/// 読みクイズテスト用の共有フィクスチャ(合成した流局局のイベント列)。
library;

import 'package:mahjong_taku/paifu/paifu_db.dart';
import 'package:mahjong_taku/paifu/yomi_quiz.dart';

/// 席順: pid 100→席0 / 101→席1 / 102→席2 / 103→席3
const quizSeatOf = {100: 0, 101: 1, 102: 2, 103: 3};
const quizNames = ['A', 'B', 'C', 'D'];

/// 親=席2(pid102)・南3局2本場・供託1本
const quizKyoku = PaifuKyoku(
  id: 1,
  round: '2z3',
  honba: 2,
  reachSticks: 1,
  parentPlayerId: 102,
);

/// event_order を自動採番するイベントビルダー
class Ev {
  int order = 0;
  PaifuEvent haipai(int pid, String hand) => PaifuEvent(
    type: 'haipai',
    order: order++,
    actorPlayerId: pid,
    hand: hand,
  );
  PaifuEvent draw(int pid, String tile) =>
      PaifuEvent(type: 'draw', order: order++, actorPlayerId: pid, tile: tile);
  PaifuEvent discard(
    int pid,
    String tile, {
    bool tsumogiri = true,
    bool reach = false,
  }) => PaifuEvent(
    type: 'discard',
    order: order++,
    actorPlayerId: pid,
    tile: tile,
    tsumogiri: tsumogiri,
    reachDeclaration: reach,
  );
  PaifuEvent reach(int pid) => PaifuEvent(
    type: 'reach',
    order: order++,
    actorPlayerId: pid,
    reachAccepted: true,
  );
  PaifuEvent pon(int pid, int target, String tile, String block) => PaifuEvent(
    type: 'pon',
    order: order++,
    actorPlayerId: pid,
    targetPlayerId: target,
    tile: tile,
    block: block,
  );
  PaifuEvent dora(String tile) => PaifuEvent(
    type: 'dora_indicator',
    order: order++,
    doraType: 'omote',
    doraIndicator: tile,
  );
  PaifuEvent ryukyoku(List<(int, bool, int)> players) =>
      PaifuEvent(type: 'ryukyoku', order: order++, ryukyokuPlayers: players);
  PaifuEvent tsumo(int pid) => PaifuEvent(
    type: 'tsumo',
    order: order++,
    actorPlayerId: pid,
    winningTile: 't1m',
    points: 1000,
    fu: 30,
    han: 1,
  );
}

/// 標準の流局局:
/// - 席0: 123m456p789s1155z のシャンポン聴牌(東/白)。リーチ。
/// - 席1: 123m456p789s+45s+1z2z のイーシャンテン
/// - 席2: バラバラのノーテン
/// - 席3: 發をポンして 234m567p23s44z の 1s/4s 聴牌
List<PaifuEvent> standardRyukyokuEvents({
  List<(int, bool, int)>? ryukyokuPlayers,
}) {
  final e = Ev();
  return [
    e.haipai(100, '123m456p789s1155z'),
    e.haipai(101, '123m456p45789s12z'),
    e.haipai(102, '147m258p369s1234z'),
    e.haipai(103, '234m567p23s4466z7z'),
    e.dora('1m'),
    e.draw(100, '9p'),
    e.discard(100, '9p'),
    e.draw(101, '6z'),
    e.discard(101, '6z'),
    e.pon(103, 101, '6z', '6z6z-6z'),
    e.discard(103, '7z', tsumogiri: false),
    e.draw(100, '9m'),
    e.discard(100, '9m', reach: true),
    e.reach(100),
    e.draw(102, '5m'),
    e.discard(102, '5m'),
    e.ryukyoku(
      ryukyokuPlayers ??
          [
            (100, true, 1500),
            (101, false, -1500),
            (102, false, -1500),
            (103, true, 1500),
          ],
    ),
  ];
}

/// [standardRyukyokuEvents] からリーチだけを除いた流局局
/// (席0の9m切りが通常のツモ切りになる)。巻き戻し出題のテスト用。
List<PaifuEvent> noRiichiRyukyokuEvents() {
  final e = Ev();
  return [
    e.haipai(100, '123m456p789s1155z'),
    e.haipai(101, '123m456p45789s12z'),
    e.haipai(102, '147m258p369s1234z'),
    e.haipai(103, '234m567p23s4466z7z'),
    e.dora('1m'),
    e.draw(100, '9p'),
    e.discard(100, '9p'),
    e.draw(101, '6z'),
    e.discard(101, '6z'),
    e.pon(103, 101, '6z', '6z6z-6z'),
    e.discard(103, '7z', tsumogiri: false),
    e.draw(100, '9m'),
    e.discard(100, '9m'),
    e.draw(102, '5m'),
    e.discard(102, '5m'),
    e.ryukyoku([
      (100, true, 1500),
      (101, false, -1500),
      (102, false, -1500),
      (103, true, 1500),
    ]),
  ];
}

YomiQuizProblem? buildQuizProblem(
  List<PaifuEvent> events, {
  int cutoffDiscards = 0,
}) => buildYomiQuizProblem(
  events: events,
  seatOf: quizSeatOf,
  names: quizNames,
  kyoku: quizKyoku,
  startScores: const [25000, 25000, 25000, 25000],
  sourceLabel: 'テスト',
  cutoffDiscards: cutoffDiscards,
);
