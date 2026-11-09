/// 試合中断・復帰のための復帰情報。
///
/// 方式: 局の途中状態を直接シリアライズするのではなく、
/// 「局開始時点の試合状態 + その局の山 + その局で行われた全アクション(牌譜)」
/// を保存する。復帰時は同じ山で局を作り直し、記録済みアクションを
/// そのまま流し込む(リプレイ)ことで中断時点まで進める。
/// エンジンは決定的(乱数は山のシャッフルと場決めのみ)なので、
/// 同じ山+同じアクション列は必ず同じ状態に到達する。
library;

import 'models.dart';

/// 記録された1アクション(どの席が、手番/反応のどちらで、何をしたか)
class RecordedAction {
  final int seat;
  final String kind; // 't'=手番(TurnAction) | 'r'=反応(ReactAction)
  final Map<String, dynamic> action;

  const RecordedAction(this.seat, this.kind, this.action);

  Map<String, dynamic> toJson() => {'s': seat, 'k': kind, 'a': action};

  factory RecordedAction.fromJson(Map<String, dynamic> json) => RecordedAction(
    json['s'] as int,
    json['k'] as String,
    (json['a'] as Map).cast<String, dynamic>(),
  );
}

/// エンジンを中断時点まで復元するための全情報
class ResumeData {
  final GameConfig config;

  /// 席順(0..3)の名前・人間/CPU区分(切断中でも人間メンバーは isCpu=false)
  final List<String> names;
  final List<bool> isCpu;

  /// 席 → メンバーID(場決めの追跡。スタッツはメンバー順で記録される)
  final List<int> seatMember;

  // ---- 局開始時点の試合状態 ----
  final int dealer;
  final int roundWind;
  final int kyoku;
  final int honba;
  final int handsPlayed;
  final List<int> scores; // 局開始時の持ち点(席順)
  final int riichiSticks; // 局開始時の供託本数
  final List<int> statWins; // 席順(局開始時点)
  final List<int> statRiichis;
  final List<int> statDealIns;
  final List<GameStats> history; // 終了済み試合のスタッツ(メンバー順)

  // ---- 進行中の局の牌譜 ----
  final List<int> wall; // 局開始時にシャッフル済みの山(136枚全量)
  final List<RecordedAction> actions;

  const ResumeData({
    required this.config,
    required this.names,
    required this.isCpu,
    required this.seatMember,
    required this.dealer,
    required this.roundWind,
    required this.kyoku,
    required this.honba,
    required this.handsPlayed,
    required this.scores,
    required this.riichiSticks,
    required this.statWins,
    required this.statRiichis,
    required this.statDealIns,
    required this.history,
    required this.wall,
    required this.actions,
  });

  Map<String, dynamic> toJson() => {
    'config': config.toJson(),
    'names': names,
    'isCpu': isCpu,
    'seatMember': seatMember,
    'dealer': dealer,
    'roundWind': roundWind,
    'kyoku': kyoku,
    'honba': honba,
    'handsPlayed': handsPlayed,
    'scores': scores,
    'riichiSticks': riichiSticks,
    'statWins': statWins,
    'statRiichis': statRiichis,
    'statDealIns': statDealIns,
    'history': history.map((h) => h.toJson()).toList(),
    'wall': wall,
    'actions': actions.map((a) => a.toJson()).toList(),
  };

  factory ResumeData.fromJson(Map<String, dynamic> json) => ResumeData(
    config: GameConfig.fromJson(
      (json['config'] as Map).cast<String, dynamic>(),
    ),
    names: (json['names'] as List).cast<String>(),
    isCpu: (json['isCpu'] as List).cast<bool>(),
    seatMember: (json['seatMember'] as List).cast<int>(),
    dealer: json['dealer'] as int,
    roundWind: json['roundWind'] as int,
    kyoku: json['kyoku'] as int,
    honba: json['honba'] as int,
    handsPlayed: json['handsPlayed'] as int,
    scores: (json['scores'] as List).cast<int>(),
    riichiSticks: json['riichiSticks'] as int,
    statWins: (json['statWins'] as List).cast<int>(),
    statRiichis: (json['statRiichis'] as List).cast<int>(),
    statDealIns: (json['statDealIns'] as List).cast<int>(),
    history: (json['history'] as List)
        .map((h) => GameStats.fromJson((h as Map).cast<String, dynamic>()))
        .toList(),
    wall: (json['wall'] as List).cast<int>(),
    actions: (json['actions'] as List)
        .map((a) => RecordedAction.fromJson((a as Map).cast<String, dynamic>()))
        .toList(),
  );

  /// ホスト以外の人間メンバーの名前(復帰ロビーで合流を待つ相手)
  List<String> guestNames(String hostName) => [
    for (var i = 0; i < 4; i++)
      if (!isCpu[i] && names[i] != hostName) names[i],
  ];
}
