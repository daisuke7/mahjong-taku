/// 牌譜イベント列を局中の卓状態(手牌・河・副露・ドラ・山)へ適用する共有部品。
///
/// [ReplaySession] の自動再生と、読みクイズの静的な局面切り出しが同じ適用
/// ロジックを使うためにここへ置く(適用規則を2箇所に書かない)。
/// 局をまたぐ状態(点数・供託・スタッツ)と演出(GameEvent・遅延)は
/// 呼び出し側の責務。
library;

import '../engine/meld.dart';
import '../engine/models.dart';
import '../engine/tile.dart';
import 'paifu_db.dart';

class KyokuTileState {
  /// playerId → 席(0..3)
  final Map<int, int> seatOf;

  final List<List<int>> hands = List.generate(4, (_) => []);
  final List<int?> drawn = List.filled(4, null);
  final List<List<DiscardInfo>> rivers = List.generate(4, (_) => []);
  final List<List<Meld>> melds = List.generate(4, (_) => []);
  final List<bool> riichi = List.filled(4, false);
  final List<int> doraInds = [];
  final List<int> uraInds = [];
  int wall = 70;
  int currentSeat = -1;
  int discardOrder = 0;

  /// その局のツモ回数(「一局戻す」の分岐などに使う)
  int drawCount = 0;

  KyokuTileState(this.seatOf);

  /// 牌の動きに関わるイベントを適用する。
  /// ron/tsumo/ryukyoku は局の結果なのでここでは何もしない。
  /// reach は宣言フラグのみ立て、点数・供託の移動は呼び出し側が行う。
  void apply(PaifuEvent ev) {
    switch (ev.type) {
      case 'haipai':
        final seat = seatOf[ev.actorPlayerId]!;
        hands[seat] = Tile.parse(ev.hand!)
          ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
      case 'draw':
        final seat = seatOf[ev.actorPlayerId]!;
        drawn[seat] = Tile.parse(ev.tile!).single;
        currentSeat = seat;
        wall--;
        drawCount++;
      case 'discard':
        _applyDiscard(seatOf[ev.actorPlayerId]!, ev);
      case 'reach':
        if (ev.reachAccepted) riichi[seatOf[ev.actorPlayerId]!] = true;
      case 'pon' || 'chi' || 'daiminkan':
        _applyCall(ev);
      case 'shominkan':
        _applyShominkan(ev);
      case 'ankan':
        _applyAnkan(ev);
      case 'dora_indicator':
        final ind = Tile.parse(ev.doraIndicator!).single;
        if (ev.doraType == 'ura') {
          uraInds.add(ind);
        } else {
          doraInds.add(ind);
        }
    }
  }

  /// 手牌+ツモ牌(あれば)をソートして返す
  List<int> handWithDrawn(int seat) {
    final d = drawn[seat];
    return [...hands[seat], ?d]
      ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
  }

  void _applyDiscard(int seat, PaifuEvent ev) {
    final t = Tile.parse(ev.tile!).single;
    if (ev.tsumogiri && drawn[seat] != null) {
      drawn[seat] = null;
    } else {
      _removeTile(hands[seat], t);
      _mergeDrawn(seat);
    }
    rivers[seat].add(
      DiscardInfo(
        t,
        riichi: ev.reachDeclaration,
        tsumogiri: ev.tsumogiri,
        order: discardOrder++,
      ),
    );
  }

  void _applyCall(PaifuEvent ev) {
    final seat = seatOf[ev.actorPlayerId]!;
    final target = seatOf[ev.targetPlayerId]!;
    final called = Tile.parse(ev.tile!).single;
    final tiles = parseBlockTiles(ev.block!)
      ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
    // 鳴いた牌以外は自分の手から出す
    final fromHand = [...tiles];
    _removeTileExactFirst(fromHand, called);
    for (final t in fromHand) {
      _removeTile(hands[seat], t);
    }
    // 鳴かれた牌を相手の河から取り除いた表示にする
    if (rivers[target].isNotEmpty) {
      rivers[target].last = rivers[target].last.copyWith(calledAway: true);
    }
    final type = switch (ev.type) {
      'pon' => MeldType.pon,
      'chi' => MeldType.chi,
      _ => MeldType.minkan,
    };
    melds[seat].add(
      Meld(type: type, tiles: tiles, fromSeat: target, calledTile: called),
    );
    currentSeat = seat;
  }

  void _applyShominkan(PaifuEvent ev) {
    final seat = seatOf[ev.actorPlayerId]!;
    final kind = Tile.normalize(Tile.parse(ev.tile!).single);
    _mergeDrawn(seat);
    final i = melds[seat].indexWhere(
      (m) => m.type == MeldType.pon && Tile.normalize(m.tiles[0]) == kind,
    );
    final tiles = parseBlockTiles(ev.block!)
      ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
    // 加えた1枚(ポンに無かった牌)を手牌から出す
    final added = [...tiles];
    if (i >= 0) {
      for (final t in melds[seat][i].tiles) {
        _removeTileExactFirst(added, t);
      }
    }
    _removeTile(hands[seat], added.isNotEmpty ? added.first : kind);
    melds[seat] = [...melds[seat]];
    if (i >= 0) {
      final old = melds[seat][i];
      melds[seat][i] = Meld(
        type: MeldType.kakan,
        tiles: tiles,
        fromSeat: old.fromSeat,
        calledTile: old.calledTile,
      );
    }
  }

  void _applyAnkan(PaifuEvent ev) {
    final seat = seatOf[ev.actorPlayerId]!;
    _mergeDrawn(seat);
    final visible = parseBlockTiles(ev.block!); // 伏せ2枚は省かれている
    final kind = Tile.normalize(visible.first);
    // 手牌から同種4枚(赤込みの実物)を抜いて槓子にする
    final tiles = [
      for (final t in hands[seat])
        if (Tile.normalize(t) == kind) t,
    ]..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
    hands[seat].removeWhere((t) => Tile.normalize(t) == kind);
    melds[seat].add(
      Meld(
        type: MeldType.ankan,
        tiles: tiles.length == 4 ? tiles : List.filled(4, kind),
        fromSeat: -1,
        calledTile: kind,
      ),
    );
  }

  void _mergeDrawn(int seat) {
    final d = drawn[seat];
    if (d == null) return;
    drawn[seat] = null;
    hands[seat]
      ..add(d)
      ..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
  }

  /// 実物一致 → 同種(赤違い)の順で1枚取り除く
  void _removeTile(List<int> hand, int t) {
    if (hand.remove(t)) return;
    final i = hand.indexWhere((h) => Tile.normalize(h) == Tile.normalize(t));
    if (i >= 0) hand.removeAt(i);
  }

  void _removeTileExactFirst(List<int> tiles, int t) {
    if (tiles.remove(t)) return;
    final i = tiles.indexWhere((h) => Tile.normalize(h) == Tile.normalize(t));
    if (i >= 0) tiles.removeAt(i);
  }
}
