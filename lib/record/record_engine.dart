/// 手動牌譜記録の状態機械(docs/manual-paifu-design.md)。
///
/// 対戦用GameEngineとは独立(あちらは配牌先決前提で遅延配牌と相性が悪い)。
/// 記録はイベントソーシング: 操作を [RecEvent] として積み、状態は畳み込みで
/// 導出する。取消は末尾を捨てて畳み直し、「?」の後埋めはイベントを書き換えて
/// 畳み直すだけで済む。
///
/// 配牌は全員「未知13枚」から始め、手出し・鳴き・開示で判明した牌を
/// 「その人の手にあった牌」の集合(resolved)として貯める。保存時に配牌
/// イベントへ割り付ける(あふれた分は不明ツモの中身へ順に割り当てる)。
/// 点数・役・親移動・積み棒はすべてMリーグルール実装(engine部品)が自動処理。
library;

import '../engine/meld.dart';
import '../engine/display_text.dart';
import '../engine/paifu_record.dart';
import '../engine/payout.dart';
import '../engine/score.dart';
import '../engine/tile.dart';
import '../engine/yaku.dart';

/// ドラ牌そのもの → ドラ表示牌([Tile.doraFromIndicator] の逆変換)。
/// 放送グラフィックはドラ牌そのものを表示するため、入力はドラで受けて
/// DB保存用の表示牌へ内部で戻す。
int indicatorFromDora(int dora) {
  final d = Tile.normalize(dora);
  if (d < 27) {
    final base = (d ~/ 9) * 9;
    return base + (d - base + 8) % 9;
  }
  if (d >= Tile.east && d <= Tile.north) {
    return Tile.east + (d - Tile.east + 3) % 4;
  }
  return Tile.haku + (d - Tile.haku + 2) % 3;
}

/// 記録イベント。typeごとに使うフィールドが違う(JSONライクな可変体)。
/// - dora: tile=ドラ牌そのもの
/// - draw: seat, tile(null=不明), rinshan
/// - discard: seat, tile(null=不明), riichi, tsumogiri
/// - pon / daiminkan: seat(鳴いた人), red(ポンで赤を晒すか)
/// - chi: seat, tiles=手から出す2枚
/// - ankan / kakan: seat, tile=牌種
/// - hand: seat, tiles=いま手にあると確認できた牌(配牌編集)
/// - tsumoWin / ronWin: seat, tiles=手の内13枚(null=欠損→手動点数),
///     ronWinのtargetは放銃者。uraTiles=裏ドラ表示牌。manual*=手動点数
/// - ryukyoku: tenpaiSeats, revealedHands(開示された手牌)
class RecEvent {
  final String type;
  int seat;
  int? tile;
  List<int>? tiles;
  int target;
  bool riichi;
  bool tsumogiri;
  bool rinshan;
  bool red;
  List<int>? uraTiles;
  List<int>? tenpaiSeats;
  Map<int, List<int>>? revealedHands;
  int? manualRon; // ロン申告点(手牌欠損時)
  int? manualTsumoChild; // ツモ子払い
  int? manualTsumoDealer; // ツモ親払い

  RecEvent(
    this.type, {
    this.seat = -1,
    this.tile,
    this.tiles,
    this.target = -1,
    this.riichi = false,
    this.tsumogiri = false,
    this.rinshan = false,
    this.red = false,
    this.uraTiles,
    this.tenpaiSeats,
    this.revealedHands,
    this.manualRon,
    this.manualTsumoChild,
    this.manualTsumoDealer,
  });

  /// 保存用JSON(既定値は省く)。後日の編集・再開(構想③)の布石。
  Map<String, dynamic> toJson() => {
    't': type,
    if (seat != -1) 's': seat,
    if (tile != null) 'k': tile,
    if (tiles != null) 'ks': tiles,
    if (target != -1) 'tg': target,
    if (riichi) 'ri': true,
    if (tsumogiri) 'tsu': true,
    if (rinshan) 'rin': true,
    if (red) 'red': true,
    if (uraTiles != null && uraTiles!.isNotEmpty) 'ura': uraTiles,
    if (tenpaiSeats != null) 'ten': tenpaiSeats,
    if (revealedHands != null && revealedHands!.isNotEmpty)
      'rev': {for (final e in revealedHands!.entries) '${e.key}': e.value},
    if (manualRon != null) 'mr': manualRon,
    if (manualTsumoChild != null) 'mc': manualTsumoChild,
    if (manualTsumoDealer != null) 'md': manualTsumoDealer,
  };

  factory RecEvent.fromJson(Map<String, dynamic> j) => RecEvent(
    j['t'] as String,
    seat: j['s'] as int? ?? -1,
    tile: j['k'] as int?,
    tiles: (j['ks'] as List?)?.cast<int>(),
    target: j['tg'] as int? ?? -1,
    riichi: j['ri'] == true,
    tsumogiri: j['tsu'] == true,
    rinshan: j['rin'] == true,
    red: j['red'] == true,
    uraTiles: (j['ura'] as List?)?.cast<int>(),
    tenpaiSeats: (j['ten'] as List?)?.cast<int>(),
    revealedHands: j['rev'] == null
        ? null
        : {
            for (final e in (j['rev'] as Map).entries)
              int.parse(e.key as String): (e.value as List).cast<int>(),
          },
    manualRon: j['mr'] as int?,
    manualTsumoChild: j['mc'] as int?,
    manualTsumoDealer: j['md'] as int?,
  );
}

/// 確定済みの1局(遡り編集用のアーカイブ)。
/// [events] は保存時のイベント列で、後埋め編集で書き換わる。
class RecKyokuArchive {
  final int roundWind;
  final int kyokuNum;
  final int honba;
  final int carriedSticks;
  final List<int> startScores;
  List<RecEvent> events;

  RecKyokuArchive({
    required this.roundWind,
    required this.kyokuNum,
    required this.honba,
    required this.carriedSticks,
    required this.startScores,
    required this.events,
  });

  String get label => kyokuLabel(
    roundWind,
    kyokuNum,
    honba: honba,
    alwaysHonba: true,
    honbaSep: ' ',
  );

  Map<String, dynamic> toJson() => {
    'round_wind': roundWind,
    'kyoku': kyokuNum,
    'honba': honba,
    'sticks': carriedSticks,
    'start_scores': startScores,
    'events': [for (final e in events) e.toJson()],
  };

  factory RecKyokuArchive.fromJson(Map<String, dynamic> j) => RecKyokuArchive(
    roundWind: j['round_wind'] as int,
    kyokuNum: j['kyoku'] as int,
    honba: j['honba'] as int,
    carriedSticks: j['sticks'] as int,
    startScores: (j['start_scores'] as List).cast<int>(),
    events: [
      for (final e in j['events'] as List)
        RecEvent.fromJson((e as Map).cast<String, dynamic>()),
    ],
  );
}

/// 河の1牌(tile=null は不明打牌)
class RecRiverTile {
  final int? tile;
  final bool riichi;
  final bool tsumogiri;
  final int eventIndex; // 後埋め用: この牌を作った discard イベントの位置
  bool called = false;

  RecRiverTile(this.tile, this.riichi, this.tsumogiri, this.eventIndex);
}

/// 1人分の畳み込み状態
class RecSeat {
  final List<int> known = []; // いま手にあると分かっている牌
  int unknown = 13; // 未知スロット数
  final List<int> resolved = []; // 配牌割り付け用: 未知から確定した牌(確定順)
  final List<Meld> melds = [];
  final List<int> meldEventIdx = []; // meldsと同順: 作成イベントの位置
  final Map<int, int> kakanAt = {}; // 加槓イベント位置 → meldsインデックス
  final List<RecRiverTile> river = [];
  bool riichi = false;
  bool doubleRiichi = false;
  int riichiEventIndex = -1;

  // 責任払い(包): 該当役満を確定させた放銃者の席(-1=なし)
  int paoDaisangen = -1;
  int paoDaisuushi = -1;
  int paoSuukantsu = -1;

  int get handSize => known.length + unknown;
}

/// 局結果(結果画面表示用)
class RecKyokuResult {
  final String type; // 'win' | 'ryukyoku'
  final List<RecWinInfo> wins;
  final List<int> tenpaiSeats;
  final List<int> scoreChanges;
  final List<int> endScores;
  final bool dealerContinues;

  const RecKyokuResult({
    required this.type,
    this.wins = const [],
    this.tenpaiSeats = const [],
    required this.scoreChanges,
    required this.endScores,
    required this.dealerContinues,
  });
}

class RecWinInfo {
  final int seat;
  final int fromSeat; // ツモは -1
  final WinScore? score; // null = 手動点数入力
  final String label; // '満貫' など(手動時は '手動入力')
  final int declared; // 供託・本場を除く申告点
  const RecWinInfo(
    this.seat,
    this.fromSeat,
    this.score,
    this.label,
    this.declared,
  );
}

class RecordEngine {
  final List<String> names; // 席順(席0=起家)

  // 局をまたぐ状態
  int roundWind; // 0=東 1=南 2=西 3=北
  int kyokuNum; // 1..4
  int honba;
  int carriedSticks; // 局開始時の供託
  List<int> scores; // 局開始時の点数(席順)
  final List<Map<String, dynamic>> exportedKyokus = [];

  /// 確定済み局のイベント列(遡っての穴埋め編集に使う)。
  /// exportedKyokus と同順・同数。
  final List<RecKyokuArchive> archives = [];

  // 現在局のイベント列と畳み込み状態
  final List<RecEvent> events = [];
  late List<RecSeat> seats;
  final List<int> doraIndicators = [];
  final List<int> doraTiles = []; // 表示用(ドラ牌そのもの)
  int wallRemaining = 70;
  int currentSeat = 0;
  String phase = 'dora'; // 'dora' | 'draw' | 'discard' | 'exhausted' | 'ended'
  int? drawnTile;
  bool hasDrawn = false;
  bool drawnUnknown = false;
  bool rinshanPending = false; // 直前がカン(次のツモは嶺上)
  int acceptedRiichis = 0; // この局で成立したリーチ本数
  bool anyCall = false;
  RecKyokuResult? result;

  RecordEngine({
    required this.names,
    this.roundWind = 0,
    this.kyokuNum = 1,
    this.honba = 0,
    this.carriedSticks = 0,
    List<int>? startScores,
  }) : scores = startScores ?? List.filled(4, 25000) {
    _reset();
  }

  /// 確定済み局のアーカイブから、遡り編集用のエンジンを作る。
  /// 「?」の後埋め(resolveUnknown)と手牌の写し(editHand)だけを行う前提。
  /// 編集後は [exportKyokuJson] で再エクスポートし、archives へ書き戻す。
  factory RecordEngine.replay(RecKyokuArchive a, List<String> names) {
    final eng = RecordEngine(
      names: names,
      roundWind: a.roundWind,
      kyokuNum: a.kyokuNum,
      honba: a.honba,
      carriedSticks: a.carriedSticks,
      startScores: List.of(a.startScores),
    );
    for (final e in a.events) {
      eng._push(e);
    }
    return eng;
  }

  /// 現在の畳み込み状態を1局分のDB互換JSONへ(遡り編集の再エクスポート用)。
  Map<String, dynamic> exportKyokuJson() {
    if (result == null) throw StateError('局が終わっていない');
    return _exportKyoku();
  }

  /// 未確定(「?」と伏せ牌)の数。一覧表示・「完全牌譜」判定に使う。
  ({int marks, int hidden}) get unknownCounts {
    var marks = 0;
    for (final e in events) {
      if ((e.type == 'draw' || e.type == 'discard') && e.tile == null) marks++;
    }
    var hidden = 0;
    for (final s in seats) {
      hidden += s.unknown;
    }
    return (marks: marks, hidden: hidden);
  }

  int get dealer => (kyokuNum - 1) % 4;
  String get roundLabel => kyokuLabel(roundWind, kyokuNum);
  bool get canUndo => events.isNotEmpty;
  int get sticksOnTable => carriedSticks + acceptedRiichis;

  /// 席の現在表示点(成立リーチ分を引く)
  int displayScore(int seat) => scores[seat] - (seats[seat].riichi ? 1000 : 0);

  /// 見えている枚数(パレットのグレーアウト用)。赤は normalize して数える。
  int visibleCount(int kind) {
    var n = 0;
    void count(int? t) {
      if (t != null && Tile.normalize(t) == kind) n++;
    }

    for (final s in seats) {
      for (final r in s.river) {
        if (!r.called) count(r.tile);
      }
      for (final m in s.melds) {
        m.tiles.forEach(count);
      }
      s.known.forEach(count);
    }
    doraIndicators.forEach(count);
    if (hasDrawn) count(drawnTile);
    return n;
  }

  /// 赤5が場に出たか(0m/0p/0s ボタンのグレーアウト用)
  bool redSeen(int red) {
    bool eq(int? t) => t == red;
    for (final s in seats) {
      if (s.river.any((r) => eq(r.tile))) return true;
      if (s.melds.any((m) => m.tiles.any(eq))) return true;
      if (s.known.any(eq)) return true;
    }
    return hasDrawn && drawnTile == red;
  }

  /// 直前の打牌に鳴き・ロンが可能か(UIのボタン活性用)
  bool get canReactToLastDiscard => _lastDiscard() != null;

  /// 直前の打牌(席と牌)。鳴き・ロンの対象をUIが表示・列挙するために使う。
  /// 河のリストを席順に走査すると時系列にならないので、必ずこれを使うこと。
  ({int seat, int? tile})? get lastDiscardInfo {
    final last = _lastDiscard();
    return last == null ? null : (seat: last.$1, tile: last.$2.tile);
  }

  /// 搶槓ロンが可能か(直前が加槓)
  bool get canChankan => _lastKakanIndex() != null;

  // ---------------- 操作(検証して積む) ----------------

  void tapDora(int doraTile) {
    if (phase == 'ended') throw StateError('局が終わっている');
    // 表ドラは局頭の1枚+カンごとに1枚(最大5枚)。
    // 「槓ドラは槓子の開示が確認された時点で発生」— カンより先には増えない。
    final kans = seats.expand((s) => s.melds).where((m) => m.isKan).length;
    if (doraTiles.length >= 1 + kans) {
      throw StateError('表ドラはカンごとに1枚(先にカンを記録して)');
    }
    _push(RecEvent('dora', tile: doraTile));
  }

  void draw(int? tile) {
    if (phase != 'draw') throw StateError('ツモ待ちではない');
    _push(
      RecEvent('draw', seat: currentSeat, tile: tile, rinshan: rinshanPending),
    );
  }

  void discard(int? tile, {bool riichi = false, bool tsumogiri = false}) {
    if (phase != 'discard') throw StateError('打牌待ちではない');
    // Mリーグ「海底牌を摸した者はリーチを掛ける事はできない」
    // (対戦エンジンのリーチ候補条件と同じ: 山0=海底牌を摸した状態)
    if (riichi && wallRemaining == 0) {
      throw StateError('海底牌ではリーチできない');
    }
    // リーチ中はツモ切りのみ(手出しはあり得ない)
    if (seats[currentSeat].riichi && !tsumogiri) {
      throw StateError('リーチ中はツモ切りのみ');
    }
    // ツモ切り指定はツモ牌と同種のときだけ有効(不明ツモのツモ切りも可)
    final effTsumogiri =
        tsumogiri &&
        hasDrawn &&
        (drawnUnknown ||
            (tile != null &&
                drawnTile != null &&
                Tile.normalize(tile) == Tile.normalize(drawnTile!)));
    if (effTsumogiri && drawnUnknown && tile != null) {
      // 不明ツモの既知牌ツモ切り: ツモ牌=打牌なので、ツモイベントも同時確定
      for (var i = events.length - 1; i >= 0; i--) {
        if (events[i].type == 'draw') {
          events[i].tile = tile;
          _refold();
          break;
        }
      }
    }
    _push(
      RecEvent(
        'discard',
        seat: currentSeat,
        tile: effTsumogiri && !drawnUnknown ? drawnTile : tile,
        riichi: riichi,
        tsumogiri: effTsumogiri,
      ),
    );
  }

  /// 直前の打牌に対するポン。[seat] は鳴いた人。
  void pon(int seat, {bool red = false}) {
    _requireCallable(seat);
    _push(RecEvent('pon', seat: seat, red: red));
  }

  /// 直前の打牌に対するチー(下家固定)。[handTiles] は手から出す2枚。
  void chi(List<int> handTiles) {
    final last = _lastDiscard();
    if (last == null) throw StateError('鳴ける打牌がない');
    final caller = (last.$1 + 1) % 4;
    _requireCallable(caller);
    _push(RecEvent('chi', seat: caller, tiles: List.of(handTiles)));
  }

  void daiminkan(int seat) {
    _requireCallable(seat);
    _push(RecEvent('daiminkan', seat: seat));
  }

  void ankan(int kind) {
    if (phase != 'discard') throw StateError('打牌待ちではない');
    _push(RecEvent('ankan', seat: currentSeat, tile: kind));
  }

  void kakan(int kind) {
    if (phase != 'discard') throw StateError('打牌待ちではない');
    if (!seats[currentSeat].melds.any(
      (m) =>
          m.type == MeldType.pon &&
          Tile.normalize(m.calledTile) == Tile.normalize(kind),
    )) {
      throw StateError('その牌のポンがない');
    }
    _push(RecEvent('kakan', seat: currentSeat, tile: kind));
  }

  /// 配牌編集: [tiles] がいま手にあると確認できた(部分でも良い)。
  void editHand(int seat, List<int> tiles) {
    _push(RecEvent('hand', seat: seat, tiles: List.of(tiles)));
  }

  /// ツモ和了。ツモ牌(和了牌)は確定済みであること(不明なら先に後埋め)。
  /// [hand13] は手の内(和了牌を除く)。null なら手牌欠損 → 手動点数
  /// ([childPay]/[dealerPay]。親の和了は childPay を全員払いとする)。
  void tsumoWin({
    List<int>? hand13,
    List<int> uraIndicators = const [],
    int? childPay,
    int? dealerPay,
  }) {
    if (phase != 'discard') throw StateError('打牌待ちではない');
    if (!hasDrawn || drawnUnknown) {
      throw StateError('ツモ牌(和了牌)を先に確定して');
    }
    if (hand13 == null && _paoMarked(currentSeat)) {
      throw StateError('責任払い(包)が確定している和了は手牌を写して自動計算で記録して');
    }
    _push(
      RecEvent(
        'tsumoWin',
        seat: currentSeat,
        tiles: hand13 == null ? null : List.of(hand13),
        uraTiles: List.of(uraIndicators),
        manualTsumoChild: childPay,
        manualTsumoDealer: dealerPay,
      ),
    );
  }

  /// ロン和了。和了牌は直前の打牌(搶槓は加槓牌)。
  /// Mリーグは「アガリ者は一局に1人」(頭ハネ)なのでダブロンは存在しない。
  /// [hand13] は手の内13枚(null=手牌欠損→ [manualPoints] で手動点数)。
  void ronWin({
    required int winner,
    List<int>? hand13,
    List<int> ura = const [],
    int? manualPoints,
  }) {
    if (_ronTile() == null) throw StateError('ロン牌が確定していない');
    if (hand13 == null && _paoMarked(winner)) {
      throw StateError('責任払い(包)が確定している和了は手牌を写して自動計算で記録して');
    }
    _push(
      RecEvent(
        'ronWin',
        seat: winner,
        target: _ronTarget(),
        tiles: hand13 == null ? null : List.of(hand13),
        uraTiles: List.of(ura),
        manualRon: manualPoints,
      ),
    );
  }

  /// 流局。[revealedHands] はテンパイ開示された手牌(逆算に使う)。
  void ryukyoku(
    List<int> tenpaiSeats, {
    Map<int, List<int>> revealedHands = const {},
  }) {
    if (phase == 'ended') throw StateError('局が終わっている');
    _push(
      RecEvent(
        'ryukyoku',
        tenpaiSeats: List.of(tenpaiSeats),
        revealedHands: {
          for (final e in revealedHands.entries) e.key: List.of(e.value),
        },
      ),
    );
  }

  void undo() {
    if (events.isEmpty) return;
    events.removeLast();
    _refold();
  }

  /// 「?」の後埋め: [eventIndex] の draw/discard の牌を確定する。
  /// ツモ切りはツモと打牌が同じ牌なので、対になるイベントも一緒に埋める。
  void resolveUnknown(int eventIndex, int tile) {
    final e = events[eventIndex];
    if (e.type != 'draw' && e.type != 'discard') {
      throw StateError('埋められるのはツモ・打牌のみ');
    }
    RecEvent? pair;
    if (e.type == 'discard' && e.tsumogiri) {
      for (var i = eventIndex - 1; i >= 0; i--) {
        if (events[i].type == 'draw') {
          if (events[i].seat == e.seat && events[i].tile == null) {
            pair = events[i];
          }
          break;
        }
      }
    } else if (e.type == 'draw' &&
        eventIndex + 1 < events.length &&
        events[eventIndex + 1].type == 'discard' &&
        events[eventIndex + 1].tsumogiri &&
        events[eventIndex + 1].tile == null) {
      pair = events[eventIndex + 1];
    }
    final old = e.tile;
    final oldPair = pair?.tile;
    e.tile = tile;
    pair?.tile = tile;
    try {
      _refold();
    } catch (_) {
      e.tile = old;
      pair?.tile = oldPair;
      _refold();
      rethrow;
    }
  }

  // ---------------- 局送り・保存 ----------------

  /// 局結果を確定して次局の状態へ進める(exportedKyokus に1局分を追加)
  void nextKyoku() {
    final r = result;
    if (r == null) throw StateError('局が終わっていない');
    if (isAllLastEnd && !r.dealerContinues) {
      throw StateError('南4局で親が流れたら半荘終了(西入は無い)');
    }
    archives.add(
      RecKyokuArchive(
        roundWind: roundWind,
        kyokuNum: kyokuNum,
        honba: honba,
        carriedSticks: carriedSticks,
        startScores: List.of(scores),
        events: List.of(events),
      ),
    );
    exportedKyokus.add(_exportKyoku());
    scores = r.endScores;
    carriedSticks = r.type == 'win' ? 0 : sticksOnTable;
    if (r.dealerContinues) {
      honba++;
    } else {
      honba = r.type == 'win' ? 0 : honba + 1;
      kyokuNum++;
      if (kyokuNum > 4) {
        kyokuNum = 1;
        roundWind = (roundWind + 1) % 4;
      }
    }
    _reset();
  }

  /// いま終わった局で半荘が終わりうるか(南4局以降)
  bool get isAllLastEnd =>
      result != null && (roundWind > 1 || (roundWind == 1 && kyokuNum == 4));

  /// 保存用JSON(MyPaifuStore と同じ形)。[settle] で順位・ポイント確定。
  /// 進行中の局が終わっていれば含める(nextKyoku 前でも保存できる)。
  Map<String, dynamic> buildGameJson({required bool settle}) {
    final kyokus = List<Map<String, dynamic>>.of(exportedKyokus);
    var lastScores = scores;
    if (result != null) {
      kyokus.add(_exportKyoku());
      lastScores = result!.endScores;
    }
    final game = <String, dynamic>{
      'names': names,
      'kyokus': kyokus,
      'finished': settle,
      // 生イベント列(遡り編集の元データ)。保存後の編集・記録再開(将来)の布石。
      // ビューア(MyPaifuSource)は未知キーとして無視する。
      'rec_kyokus': [
        for (final a in archives) a.toJson(),
        if (result != null)
          RecKyokuArchive(
            roundWind: roundWind,
            kyokuNum: kyokuNum,
            honba: honba,
            carriedSticks: carriedSticks,
            startScores: List.of(scores),
            events: events,
          ).toJson(),
      ],
    };
    if (settle) {
      // 局の途中で終える場合、その局は保存されないので、成立リーチ棒
      // (acceptedRiichis)は無かったことにする(carriedSticksだけが場の供託)。
      final pot = result != null
          ? (result!.type == 'win' ? 0 : sticksOnTable)
          : carriedSticks;
      final settled = settleGame(scores: lastScores, pot: pot);
      game['results'] = [
        for (var i = 0; i < 4; i++)
          {
            'player_id': i,
            'score': settled.finalScores[i],
            'points': settled.points[i],
            'rank': settled.ranking.indexOf(i) + 1,
          },
      ];
    }
    return game;
  }

  // ---------------- 内部: 畳み込み ----------------

  void _push(RecEvent e) {
    events.add(e);
    try {
      _apply(e, events.length - 1);
    } catch (_) {
      events.removeLast();
      _refold();
      rethrow;
    }
  }

  void _reset() {
    events.clear();
    seats = List.generate(4, (_) => RecSeat());
    doraIndicators.clear();
    doraTiles.clear();
    wallRemaining = 70;
    currentSeat = dealer;
    phase = 'dora';
    hasDrawn = false;
    drawnTile = null;
    drawnUnknown = false;
    rinshanPending = false;
    acceptedRiichis = 0;
    anyCall = false;
    result = null;
  }

  void _refold() {
    final saved = List.of(events);
    _reset();
    for (var i = 0; i < saved.length; i++) {
      events.add(saved[i]);
      _apply(saved[i], i);
    }
  }

  void _apply(RecEvent e, int index) {
    switch (e.type) {
      case 'dora':
        doraTiles.add(e.tile!);
        doraIndicators.add(indicatorFromDora(e.tile!));
        if (phase == 'dora') phase = 'draw';
      case 'draw':
        if (phase != 'draw') throw StateError('ツモ待ちではない');
        if (wallRemaining <= 0 && !e.rinshan) throw StateError('山が無い');
        hasDrawn = true;
        drawnTile = e.tile;
        drawnUnknown = e.tile == null;
        if (!e.rinshan) wallRemaining--;
        currentSeat = e.seat;
        phase = 'discard';
      case 'discard':
        _applyDiscard(e, index);
      case 'pon' || 'daiminkan':
        _applyPonKan(e, index);
      case 'chi':
        _applyChi(e, index);
      case 'ankan':
        _applyAnkan(e, index);
      case 'kakan':
        _applyKakan(e, index);
      case 'hand':
        _resolveInto(seats[e.seat], e.tiles!);
      case 'tsumoWin':
        _applyTsumoWin(e);
      case 'ronWin':
        _applyRonWin(e);
      case 'ryukyoku':
        _applyRyukyoku(e);
    }
  }

  void _applyDiscard(RecEvent e, int index) {
    final s = seats[e.seat];
    if (e.tsumogiri) {
      // ツモ牌がそのまま出る(手は不変)
    } else {
      _removeFromHand(s, e.tile);
      _mergeDrawn(s);
    }
    hasDrawn = false;
    drawnTile = null;
    drawnUnknown = false;
    rinshanPending = false;
    if (e.riichi) {
      s.riichi = true;
      s.doubleRiichi = s.river.isEmpty && !anyCall;
      s.riichiEventIndex = index;
      acceptedRiichis++; // 宣言牌ロンなら _applyRonWin で倒す
    }
    s.river.add(RecRiverTile(e.tile, e.riichi, e.tsumogiri, index));
    currentSeat = (e.seat + 1) % 4;
    phase = wallRemaining > 0 ? 'draw' : 'exhausted';
  }

  void _applyPonKan(RecEvent e, int index) {
    final last = _takeLastDiscard(index);
    if (last.tile == null) throw StateError('不明打牌は鳴けない(先に後埋めして)');
    final called = last.tile!;
    final kind = Tile.normalize(called);
    final s = seats[e.seat];
    final List<int> expose;
    if (e.type == 'pon') {
      final exposeRed = e.red && !Tile.isRed(called) && _isFive(kind);
      expose = [exposeRed ? _redOf(kind) : kind, kind];
    } else {
      // 大明槓: 残り3枚すべて(5なら赤も必ず含む)
      _requireKanAllowed();
      expose = [kind, kind, kind];
      if (_isFive(kind) && !Tile.isRed(called)) expose[0] = _redOf(kind);
    }
    for (final t in expose) {
      _removeFromHand(s, t);
    }
    final taken = [...expose, called]
      ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
    s.melds.add(
      Meld(
        type: e.type == 'pon' ? MeldType.pon : MeldType.minkan,
        tiles: taken,
        fromSeat: last.from,
        calledTile: called,
      ),
    );
    s.meldEventIdx.add(index);
    _checkPao(s, last.from, kind);
    if (e.type == 'daiminkan' && s.melds.where((m) => m.isKan).length == 4) {
      s.paoSuukantsu = last.from; // 4つ目のカンが大明槓なら包
    }
    anyCall = true;
    currentSeat = e.seat;
    if (e.type == 'pon') {
      phase = 'discard'; // 鳴き後はツモなしで打牌
      hasDrawn = false;
    } else {
      wallRemaining--; // 王牌補充
      phase = 'draw';
      rinshanPending = true;
    }
  }

  void _applyChi(RecEvent e, int index) {
    final last = _takeLastDiscard(index);
    if (last.tile == null) throw StateError('不明打牌は鳴けない(先に後埋めして)');
    final s = seats[e.seat];
    final run = [last.tile!, ...e.tiles!]
      ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
    // 順子の検証(同色の連続3枚でなければ不正)
    final norm = run.map(Tile.normalize).toList();
    if (run.length != 3 ||
        Tile.isHonor(norm[0]) ||
        Tile.suit(norm[0]) != Tile.suit(norm[2]) ||
        norm[1] != norm[0] + 1 ||
        norm[2] != norm[0] + 2) {
      throw StateError('チーの形になっていない');
    }
    for (final t in e.tiles!) {
      _removeFromHand(s, t);
    }
    s.melds.add(
      Meld(
        type: MeldType.chi,
        tiles: run,
        fromSeat: last.from,
        calledTile: last.tile!,
      ),
    );
    s.meldEventIdx.add(index);
    anyCall = true;
    currentSeat = e.seat;
    phase = 'discard';
    hasDrawn = false;
  }

  void _applyAnkan(RecEvent e, int index) {
    _requireKanAllowed();
    if (!hasDrawn) throw StateError('カンは自分のツモ番のみ(鳴き直後は不可)');
    final s = seats[e.seat];
    final kind = Tile.normalize(e.tile!);
    var need = 4;
    final tiles = <int>[];
    // ツモ牌が同種ならそれを1枚に充てる(不明ツモも1枚に充てる)。
    // 別種のツモ牌は手に戻してから4枚取る(戻さないと1枚消えてしまう)。
    if (!drawnUnknown && Tile.normalize(drawnTile!) == kind) {
      tiles.add(drawnTile!);
      need--;
    } else if (drawnUnknown) {
      tiles.add(kind);
      need--;
    } else {
      _mergeDrawn(s);
    }
    hasDrawn = false;
    drawnTile = null;
    drawnUnknown = false;
    final withRed = _isFive(kind) && !tiles.any(Tile.isRed);
    for (var i = 0; i < need; i++) {
      final t = withRed && i == 0 ? _redOf(kind) : kind;
      _removeFromHand(s, t);
      tiles.add(t);
    }
    tiles.sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
    s.melds.add(
      Meld(
        type: MeldType.ankan,
        tiles: tiles,
        fromSeat: -1,
        calledTile: tiles[0],
      ),
    );
    s.meldEventIdx.add(index);
    anyCall = true;
    wallRemaining--;
    phase = 'draw';
    rinshanPending = true;
  }

  void _applyKakan(RecEvent e, int index) {
    _requireKanAllowed();
    if (!hasDrawn) throw StateError('カンは自分のツモ番のみ(鳴き直後は不可)');
    final s = seats[e.seat];
    final kind = Tile.normalize(e.tile!);
    final i = s.melds.indexWhere(
      (m) => m.type == MeldType.pon && Tile.normalize(m.calledTile) == kind,
    );
    if (i < 0) throw StateError('その牌のポンがない');
    final pon = s.melds[i];
    // 加える1枚: 赤は各色1枚なので、5はポンに赤が無ければ残りは必ず赤
    // (入力牌の赤/通常には従わない — 従うと「赤なし5が4枚」があり得てしまう)
    final added = _isFive(kind) && !pon.tiles.any(Tile.isRed)
        ? _redOf(kind)
        : kind;
    if (!drawnUnknown && Tile.normalize(drawnTile!) == kind) {
      // ツモ牌を充てる(手は減らない)
    } else if (drawnUnknown) {
      // 不明ツモを加槓牌に充てる(未知スロットは消費しない)
    } else {
      _removeFromHand(s, added);
      _mergeDrawn(s);
    }
    hasDrawn = false;
    drawnTile = null;
    drawnUnknown = false;
    s.melds[i] = Meld(
      type: MeldType.kakan,
      tiles: [...pon.tiles, added],
      fromSeat: pon.fromSeat,
      calledTile: pon.calledTile,
    );
    s.kakanAt[index] = i;
    anyCall = true;
    wallRemaining--;
    phase = 'draw';
    rinshanPending = true;
  }

  void _applyTsumoWin(RecEvent e) {
    final s = seats[e.seat];
    final winTile = drawnTile!;
    final isDealerWin = e.seat == dealer;
    if (e.tiles != null) {
      _resolveInto(s, e.tiles!);
      final score = _evaluate(e, e.tiles!, winTile, isTsumo: true);
      // 供託・本場・責任払い込みの点数移動(payout.dart、対戦エンジンと共有)
      final (paoSeat, paoCount) = _paoFor(e.seat, score);
      final payout = winPayout(
        score: score,
        seat: e.seat,
        dealer: dealer,
        honba: honba,
        riichiSticks: sticksOnTable,
        paoSeat: paoSeat,
        paoCount: paoCount,
      );
      final hasPao =
          score.isYakuman && paoSeat >= 0 && paoCount > 0 && paoSeat != e.seat;
      _finishWin([
        RecWinInfo(
          e.seat,
          -1,
          score,
          hasPao ? '役満(責任払い)' : payout.label,
          payout.declared,
        ),
      ], payout.changes);
      return;
    }
    // 手動点数: childPay/dealerPay + 本場100点ずつ + 供託
    final changes = List<int>.filled(4, 0);
    final child = e.manualTsumoChild ?? 0;
    final dealerPay = isDealerWin ? child : (e.manualTsumoDealer ?? child);
    var total = 0;
    for (var i = 0; i < 4; i++) {
      if (i == e.seat) continue;
      final pay =
          ((isDealerWin || i != dealer) ? child : dealerPay) + honba * 100;
      changes[i] -= pay;
      total += pay;
    }
    changes[e.seat] = total + sticksOnTable * 1000;
    _finishWin([
      // 申告点表示は自動計算(calcPayment.declared)に合わせて本場込み
      RecWinInfo(e.seat, -1, null, '手動入力', total),
    ], changes);
  }

  void _applyRonWin(RecEvent e) {
    // Mリーグ「アガリ者は一局に1人」(頭ハネ)— 2人目のロンは受け付けない
    if (phase == 'ended') throw StateError('アガリ者は1人(頭ハネ)');
    final winTile = _foldRonTile();
    if (winTile == null) throw StateError('ロン牌が不明');
    // リーチ宣言牌へのロンならそのリーチは不成立(供託にならない)
    if (!rinshanPending) {
      final t = seats[e.target];
      if (t.riichi &&
          t.river.isNotEmpty &&
          t.river.last.riichi &&
          !t.river.last.called) {
        t.riichi = false;
        acceptedRiichis--;
      }
    }
    final s = seats[e.seat];
    if (e.tiles != null) {
      _resolveInto(s, e.tiles!);
      final score = _evaluate(e, e.tiles!, winTile, isTsumo: false);
      // 供託・本場・責任払いの折半込み(payout.dart、対戦側と共有)
      final (paoSeat, paoCount) = _paoFor(e.seat, score);
      final payout = winPayout(
        score: score,
        seat: e.seat,
        dealer: dealer,
        fromSeat: e.target,
        honba: honba,
        riichiSticks: sticksOnTable,
        paoSeat: paoSeat,
        paoCount: paoCount,
      );
      final hasPao =
          score.isYakuman &&
          paoSeat >= 0 &&
          paoCount > 0 &&
          paoSeat != e.seat &&
          paoSeat != e.target;
      _finishWin([
        RecWinInfo(
          e.seat,
          e.target,
          score,
          hasPao ? '役満(責任払い)' : payout.label,
          payout.declared,
        ),
      ], payout.changes);
      return;
    }
    final declared = e.manualRon ?? 0;
    final changes = List<int>.filled(4, 0);
    changes[e.seat] = declared + honba * 300 + sticksOnTable * 1000;
    changes[e.target] = -(declared + honba * 300);
    _finishWin([
      // 申告点表示は自動計算(calcPayment.declared)に合わせて本場込み
      RecWinInfo(e.seat, e.target, null, '手動入力', declared + honba * 300),
    ], changes);
  }

  void _finishWin(List<RecWinInfo> wins, List<int> changes) {
    final endScores = [
      for (var i = 0; i < 4; i++)
        scores[i] - (seats[i].riichi ? 1000 : 0) + changes[i],
    ];
    result = RecKyokuResult(
      type: 'win',
      wins: wins,
      scoreChanges: changes,
      endScores: endScores,
      dealerContinues: wins.any((w) => w.seat == dealer),
    );
    phase = 'ended';
  }

  void _applyRyukyoku(RecEvent e) {
    for (final entry in (e.revealedHands ?? const <int, List<int>>{}).entries) {
      _resolveInto(seats[entry.key], entry.value);
    }
    final tenpai = e.tenpaiSeats ?? const <int>[];
    final changes = ryukyokuChanges(tenpai); // ノーテン罰符(対戦側と共有)
    final endScores = [
      for (var i = 0; i < 4; i++)
        scores[i] - (seats[i].riichi ? 1000 : 0) + changes[i],
    ];
    result = RecKyokuResult(
      type: 'ryukyoku',
      tenpaiSeats: List.of(tenpai)..sort(),
      scoreChanges: changes,
      endScores: endScores,
      dealerContinues: tenpai.contains(dealer),
    );
    phase = 'ended';
  }

  WinScore _evaluate(
    RecEvent e,
    List<int> hand13,
    int winTile, {
    required bool isTsumo,
  }) {
    final s = seats[e.seat];
    // 海底・河底・嶺上・搶槓・天和・地和・自風の判定は buildWinContext に
    // 一元化(対戦エンジンと共有)
    final score = evaluateWin(
      buildWinContext(
        concealed: [...hand13, winTile],
        melds: s.melds,
        winTile: winTile,
        isTsumo: isTsumo,
        isRiichi: s.riichi,
        isDoubleRiichi: s.riichi && s.doubleRiichi,
        isIppatsu: s.riichi && _isIppatsu(e.seat, s.riichiEventIndex),
        wallEmpty: wallRemaining == 0,
        isRinshan: rinshanPending,
        isChankan: rinshanPending,
        firstTurn: s.river.isEmpty && !anyCall,
        seat: e.seat,
        dealer: dealer,
        roundWind: roundWind,
        doraIndicators: doraIndicators,
        uraIndicators: e.uraTiles ?? const [],
      ),
    );
    if (score == null) {
      throw StateError('和了形になっていない(役なし・牌の入力誤り?)');
    }
    return score;
  }

  /// 包が確定している席か(3副露の三元牌などは和了役が確定するため、
  /// 手動点数では責任払いを表現できない → 手牌入力を必須にする)
  bool _paoMarked(int seat) {
    final s = seats[seat];
    return s.paoDaisangen >= 0 || s.paoDaisuushi >= 0 || s.paoSuukantsu >= 0;
  }

  /// 責任払いのマーク(payout.dart の共有判定を席状態へ反映)
  void _checkPao(RecSeat s, int discarder, int calledKind) {
    final marks = paoMarks(s.melds, calledKind);
    if (marks.daisangen) s.paoDaisangen = discarder;
    if (marks.daisuushi) s.paoDaisuushi = discarder;
  }

  /// 和了者の役に包対象役満があれば (包の席, 役満数)。無ければ (-1, 0)。
  (int, int) _paoFor(int seat, WinScore score) {
    final s = seats[seat];
    return paoFor(
      score,
      paoDaisangen: s.paoDaisangen,
      paoDaisuushi: s.paoDaisuushi,
      paoSuukantsu: s.paoSuukantsu,
    );
  }

  /// 一発: リーチ宣言打牌の後、和了までに鳴きが無く、和了者の打牌も無い
  bool _isIppatsu(int seat, int riichiIdx) {
    if (riichiIdx < 0) return false;
    for (var i = riichiIdx + 1; i < events.length; i++) {
      final e = events[i];
      switch (e.type) {
        case 'pon' || 'chi' || 'daiminkan' || 'ankan' || 'kakan':
          return false;
        case 'discard':
          if (e.seat == seat) return false;
      }
    }
    return true;
  }

  // ---------------- 内部: 手牌モデル ----------------

  /// 手から [tile] を取り除く。既知に無ければ未知スロットを消費して
  /// resolved(配牌割り付け)へ積む。[tile] が null(不明打牌)なら未知を1消費。
  void _removeFromHand(RecSeat s, int? tile) {
    if (tile == null) {
      if (s.unknown <= 0) throw StateError('手牌が全て既知なので不明打牌はできない');
      s.unknown--;
      return;
    }
    if (s.known.remove(tile)) return;
    // 赤/通常の取り違えは同種でゆるく受ける
    final i = s.known.indexWhere(
      (t) => Tile.normalize(t) == Tile.normalize(tile),
    );
    if (i >= 0) {
      s.known.removeAt(i);
      return;
    }
    if (s.unknown <= 0) throw StateError('手に無い牌は切れない');
    s.unknown--;
    s.resolved.add(tile);
  }

  void _mergeDrawn(RecSeat s) {
    if (!hasDrawn) return;
    if (drawnUnknown) {
      s.unknown++;
    } else if (drawnTile != null) {
      s.known.add(drawnTile!);
      s.known.sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
    }
  }

  /// [tiles] がいま手にあると確認できた: 既知に無い分を未知から確定する
  void _resolveInto(RecSeat s, List<int> tiles) {
    final pool = List.of(s.known);
    for (final t in tiles) {
      if (pool.remove(t)) continue;
      final i = pool.indexWhere((k) => Tile.normalize(k) == Tile.normalize(t));
      if (i >= 0) {
        pool.removeAt(i);
        continue;
      }
      if (s.unknown <= 0) continue; // 入力過多はゆるく無視
      s.unknown--;
      s.known.add(t);
      s.resolved.add(t);
    }
    s.known.sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
  }

  bool _isFive(int kind) => !Tile.isHonor(kind) && Tile.number(kind) == 5;

  /// カンの前提(payout.dart の kanAllowed、対戦エンジンと同条件)
  void _requireKanAllowed() {
    final kans = seats.expand((s) => s.melds).where((m) => m.isKan).length;
    if (kans >= 4) throw StateError('カンは4回まで');
    if (!kanAllowed(kanCount: kans, wallRemaining: wallRemaining)) {
      throw StateError('山が無いのでカンできない');
    }
  }

  int _redOf(int kind) => switch (Tile.normalize(kind)) {
    4 => Tile.red5m,
    13 => Tile.red5p,
    22 => Tile.red5s,
    _ => kind,
  };

  // ---------------- 内部: 鳴き・ロンの対象 ----------------

  void _requireCallable(int seat) {
    final last = _lastDiscard();
    if (last == null) throw StateError('鳴ける打牌がない(次のツモ入力済みなら取消して)');
    if (last.$1 == seat) throw StateError('自分の打牌は鳴けない');
  }

  /// 直前の打牌 (seat, riverTile)。次のツモが入力済みなら null。
  (int, RecRiverTile)? _lastDiscard() => _lastDiscardBefore(events.length);

  /// [before] より前のイベントだけを見た直前の打牌(畳み込み中は
  /// 適用中のイベント自身が末尾に積まれているため、それを除いて探す)。
  (int, RecRiverTile)? _lastDiscardBefore(int before) {
    if (hasDrawn || phase == 'ended' || phase == 'dora') return null;
    for (var i = before - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type == 'hand' || e.type == 'dora') continue;
      if (e.type == 'discard') {
        final r = seats[e.seat].river.last;
        if (r.called) return null;
        return (e.seat, r);
      }
      return null;
    }
    return null;
  }

  ({int from, int? tile}) _takeLastDiscard(int index) {
    final last = _lastDiscardBefore(index);
    if (last == null) throw StateError('鳴ける打牌がない');
    last.$2.called = true;
    return (from: last.$1, tile: last.$2.tile);
  }

  /// 直前が加槓ならそのイベント位置(搶槓ロン用)。暗槓は対象外。
  int? _lastKakanIndex() {
    if (hasDrawn || phase == 'ended') return null;
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type == 'hand' || e.type == 'dora') continue;
      return e.type == 'kakan' ? i : null;
    }
    return null;
  }

  /// ロン牌(公開API用: 直前の打牌 or 加槓牌)
  int? _ronTile() {
    final kakanIdx = _lastKakanIndex();
    if (kakanIdx != null) {
      final e = events[kakanIdx];
      return seats[e.seat].melds[seats[e.seat].kakanAt[kakanIdx]!].tiles.last;
    }
    return _lastDiscard()?.$2.tile;
  }

  /// 畳み込み中(ronWin適用時)のロン牌: ronWin イベントを読み飛ばして探す
  int? _foldRonTile() {
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type == 'ronWin' || e.type == 'hand' || e.type == 'dora') continue;
      if (e.type == 'discard') return e.tile;
      if (e.type == 'kakan') {
        final s = seats[e.seat];
        final mi = s.kakanAt[i];
        return mi == null ? null : s.melds[mi].tiles.last;
      }
      return null;
    }
    return null;
  }

  int _ronTarget() {
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type == 'ronWin' || e.type == 'hand' || e.type == 'dora') continue;
      if (e.type == 'discard' || e.type == 'kakan') return e.seat;
      break;
    }
    throw StateError('放銃者が特定できない');
  }

  // ---------------- 内部: DB互換エクスポート ----------------

  Map<String, dynamic> _exportKyoku() {
    final r = result!;
    // 配牌割り付け: resolved を先頭から配牌へ(あふれは不明ツモの中身へ)
    final haipai = <int, List<int>>{};
    final drawFill = <int, List<int>>{}; // 席ごとの不明ツモへ割り当てる牌
    for (var i = 0; i < 4; i++) {
      final resolved = seats[i].resolved;
      haipai[i] = resolved.take(13).toList()
        ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
      drawFill[i] = resolved.skip(13).toList();
    }

    var order = 0;
    final out = <Map<String, dynamic>>[];
    void emit(Map<String, dynamic> ev) {
      out.add({...ev, 'event_order': order++});
    }

    // 局頭: 表ドラ → 配牌(親から反時計回り)
    if (doraIndicators.isNotEmpty) {
      emit({
        'type': 'dora_indicator',
        'dora_type': 'omote',
        'dora_indicator': Tile.dbNotation(doraIndicators[0]),
      });
    }
    for (var i = 0; i < 4; i++) {
      final seat = (dealer + i) % 4;
      if (haipai[seat]!.isEmpty) continue; // 全欠損は本家の欠損局と同じ扱い
      emit({
        'type': 'haipai',
        'player_id': seat,
        'hand': tilesToDbString(haipai[seat]!),
      });
    }

    var doraSeen = 0;
    var uraEmitted = false;
    for (var idx = 0; idx < events.length; idx++) {
      final e = events[idx];
      switch (e.type) {
        case 'dora':
          doraSeen++;
          if (doraSeen == 1) break; // 最初の表ドラは局頭で出力済み
          emit({
            'type': 'dora_indicator',
            'dora_type': 'omote',
            'dora_indicator': Tile.dbNotation(doraIndicators[doraSeen - 1]),
          });
        case 'draw':
          var t = e.tile;
          if (t == null && drawFill[e.seat]!.isNotEmpty) {
            t = drawFill[e.seat]!.removeAt(0); // 逆算で埋まった不明ツモ
          }
          if (t == null) break; // 埋まらない不明ツモはイベント欠落として省く
          emit({
            'type': 'draw',
            'actor_player_id': e.seat,
            'tile': Tile.dbNotation(t),
            'is_rinshan': e.rinshan,
          });
        case 'discard':
          if (e.riichi) {
            emit({
              'type': 'reach',
              'actor_player_id': e.seat,
              'is_accepted': seats[e.seat].riichi, // 宣言牌ロンなら false
            });
          }
          if (e.tile == null) break; // 不明打牌はイベント欠落
          emit({
            'type': 'discard',
            'actor_player_id': e.seat,
            'tile': Tile.dbNotation(e.tile!),
            'is_reach_declaration': e.riichi,
            'is_tsumogiri': e.tsumogiri,
          });
        case 'pon' || 'daiminkan':
          final m = _meldOfEvent(e.seat, idx);
          emit({
            'type': e.type,
            'actor_player_id': e.seat,
            'target_player_id': m.fromSeat,
            'tile': Tile.dbNotation(m.calledTile),
            'block': callBlock(
              tiles: e.type == 'pon' && m.type == MeldType.kakan
                  ? m.tiles.sublist(0, 3) // 後に加槓されたポン
                  : m.tiles,
              calledTile: m.calledTile,
              relative: (m.fromSeat - e.seat + 4) % 4,
            ),
          });
        case 'chi':
          final m = _meldOfEvent(e.seat, idx);
          emit({
            'type': 'chi',
            'actor_player_id': e.seat,
            'target_player_id': m.fromSeat,
            'tile': Tile.dbNotation(m.calledTile),
            'block': chiBlock(tiles: m.tiles, calledTile: m.calledTile),
          });
        case 'ankan':
          final m = _meldOfEvent(e.seat, idx);
          emit({
            'type': 'ankan',
            'actor_player_id': e.seat,
            'block': ankanBlock(m.tiles),
          });
        case 'kakan':
          final m = seats[e.seat].melds[seats[e.seat].kakanAt[idx]!];
          emit({
            'type': 'shominkan',
            'actor_player_id': e.seat,
            'tile': Tile.dbNotation(m.tiles.last),
            'block': shominkanBlock(meld: m, actorSeat: e.seat),
          });
        case 'tsumoWin' || 'ronWin':
          if (!uraEmitted) {
            uraEmitted = true;
            // 和了グループの先頭で、リーチ和了者の裏ドラをまとめて出す
            final uras = <int>[];
            for (var j = idx; j < events.length; j++) {
              final w = events[j];
              if (w.type != 'tsumoWin' && w.type != 'ronWin') break;
              if (seats[w.seat].riichi) {
                for (final u in w.uraTiles ?? const <int>[]) {
                  if (!uras.contains(u)) uras.add(u);
                }
              }
            }
            for (final u in uras) {
              emit({
                'type': 'dora_indicator',
                'dora_type': 'ura',
                'dora_indicator': Tile.dbNotation(u),
              });
            }
          }
          final win = r.wins.firstWhere((w) => w.seat == e.seat);
          final score = win.score;
          final isTsumo = e.type == 'tsumoWin';
          final winTile = isTsumo ? _drawnTileBefore(idx) : _exportRonTile(idx);
          emit({
            'type': isTsumo ? 'tsumo' : 'ron',
            'actor_player_id': e.seat,
            'target_player_id': isTsumo ? null : e.target,
            'points': r.scoreChanges[e.seat], // 供託本場込みの総取得点
            'winning_tile': isTsumo
                ? 't${Tile.dbNotation(winTile)}'
                : Tile.dbNotation(winTile),
            'fu': score?.fu ?? 0,
            'han': score == null
                ? 0
                : (score.isYakuman ? 13 * score.yakuman : score.han),
            'is_yakuman': score?.isYakuman ?? false,
            'description': score == null
                ? '手動入力 ${win.declared}'
                : agariDescription(
                    isYakuman: score.isYakuman,
                    fu: score.fu,
                    han: score.han,
                    label: win.label,
                    declared: win.declared,
                  ),
            'yaku': score == null ? const [] : yakuToJson(score.yaku),
          });
        case 'ryukyoku':
          emit({
            'type': 'ryukyoku',
            'players': [
              for (var i = 0; i < 4; i++)
                {
                  'player_id': i,
                  'is_tenpai': r.tenpaiSeats.contains(i),
                  'points': r.scoreChanges[i],
                },
            ],
          });
        case 'hand':
          break;
      }
    }

    return {
      'round': '${roundWind + 1}z$kyokuNum',
      'honba_count': honba,
      'reach_stick_count': carriedSticks,
      'parent_player_id': dealer,
      'start_scores': List.of(scores),
      'end_scores': List.of(r.endScores),
      'events': out,
    };
  }

  /// [idx] のイベントで作られた副露(加槓で上書きされていてもその位置の面子)
  Meld _meldOfEvent(int seat, int idx) =>
      seats[seat].melds[seats[seat].meldEventIdx.indexOf(idx)];

  /// [idx] の tsumoWin の和了牌 = 直前の draw の牌(確定済み前提)
  int _drawnTileBefore(int idx) {
    for (var i = idx - 1; i >= 0; i--) {
      if (events[i].type == 'draw') return events[i].tile!;
    }
    throw StateError('ツモ牌が見つからない');
  }

  /// [idx] の ronWin の和了牌 = 直前の discard か加槓の牌
  int _exportRonTile(int idx) {
    for (var i = idx - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type == 'ronWin' || e.type == 'hand' || e.type == 'dora') continue;
      if (e.type == 'discard') return e.tile!;
      if (e.type == 'kakan') {
        return seats[e.seat].melds[seats[e.seat].kakanAt[i]!].tiles.last;
      }
      break;
    }
    throw StateError('ロン牌が見つからない');
  }
}
