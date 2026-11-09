import 'package:flutter/material.dart';

import '../../engine/display_text.dart';
import '../../engine/paifu_record.dart';
import '../../engine/meld.dart';
import '../../engine/models.dart';
import '../../engine/tile.dart';
import 'tile_widget.dart';

/// 河に見える牌と、その牌を横向きに描くかを組にしたもの。
typedef RiverTile = ({DiscardInfo discard, bool sideways});

/// 河の表示計画(対戦・ビューア・記録画面で共有する純粋関数)。
///
/// 鳴かれた牌は河から取られるので表示しない。ただしリーチ宣言牌が鳴かれると
/// 横向きの情報ごと消えてしまうため、Mリーグの規定に従って次の打牌へ移す:
///
/// 規定の要旨: リーチ宣言牌が鳴かれたときは、次巡の打牌を横向きにする。
///
/// 打牌列のデータ型は画面ごとに違う(対戦=DiscardInfo / 記録=RecRiverTile)ので
/// 述語で受け、「表示する打牌の添字と横向きフラグ」を返す。
List<({int index, bool sideways})> riverDisplayPlan({
  required int length,
  required bool Function(int index) calledAway,
  required bool Function(int index) riichi,
}) {
  final out = <({int index, bool sideways})>[];
  var carry = false; // 宣言牌が鳴かれた → 次に河に残る打牌を横にする
  for (var i = 0; i < length; i++) {
    if (calledAway(i)) {
      if (riichi(i)) carry = true;
      continue;
    }
    out.add((index: i, sideways: riichi(i) || carry));
    carry = false;
  }
  return out;
}

/// [riverDisplayPlan] を対戦・ビューアの打牌列に適用したもの。
///
/// **モデルの `DiscardInfo.riichi` は動かさない。** あれはリーチ宣言の巡目を表す
/// データで、`safety.dart` が現物の判定に使っている(宣言巡がずれると
/// 「リーチ後に通った牌」の範囲が変わってしまう)。横向きは表示だけの話なので、
/// ここで組み立てる。
List<RiverTile> riverTiles(List<DiscardInfo> discards) => [
  for (final p in riverDisplayPlan(
    length: discards.length,
    calledAway: (i) => discards[i].calledAway,
    riichi: (i) => discards[i].riichi,
  ))
    (discard: discards[p.index], sideways: p.sideways),
];

/// 捨て牌の河(6枚ずつ折り返し)。鳴かれた牌は表示しない。
class DiscardRiver extends StatelessWidget {
  final List<DiscardInfo> discards;
  final double tileWidth;
  final int? highlightTile; // 直近の捨て牌強調
  final Set<int> doraKinds;

  /// 一番新しい牌を「少し遅れて置かれる」演出でフェードインさせる(他家用)。
  final bool animateNewest;

  const DiscardRiver({
    super.key,
    required this.discards,
    required this.tileWidth,
    this.highlightTile,
    this.doraKinds = const {},
    this.animateNewest = false,
  });

  @override
  Widget build(BuildContext context) {
    final visible = riverTiles(discards);
    final rows = <Widget>[];
    for (var i = 0; i < visible.length; i += 6) {
      final chunk = visible.sublist(
        i,
        i + 6 > visible.length ? visible.length : i + 6,
      );
      rows.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < chunk.length; j++)
              () {
                final isNewest = i + j == visible.length - 1;
                Widget tile = TileWidget(
                  tile: chunk[j].discard.tile,
                  width: tileWidth,
                  sideways: chunk[j].sideways,
                  dora: doraKinds.contains(
                    Tile.normalize(chunk[j].discard.tile),
                  ),
                  // ツモ切りはごく薄く灰色にして手出しと見分けられるようにする
                  muted: chunk[j].discard.tsumogiri,
                  highlighted:
                      highlightTile != null &&
                      isNewest &&
                      chunk[j].discard.tile == highlightTile,
                );
                // 最新牌は「消えてから置かれる」ように少し遅れて現れ、
                // 視認性のためしばらく拡大表示してから通常サイズに収まる。
                // order をキーにするので、新しい牌が来たときだけ再生される。
                if (animateNewest && isNewest) {
                  // 拡大の膨らむ向き: 1・2段目は下(次の段側)へ、3段目以降は
                  // 下に伏せ牌が来るので上(前の段に重なる向き)へ。
                  // Transform は描画のみでレイアウトを動かさないため、
                  // 一時的な重なりとして許容する(段が後に描かれるので前段に
                  // 重なっても最新牌が上に見える)。
                  final anchor = (i ~/ 6) >= 2
                      ? Alignment.bottomCenter
                      : Alignment.topCenter;
                  tile = TweenAnimationBuilder<double>(
                    key: ValueKey('drop-${chunk[j].discard.order}'),
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 850),
                    builder: (context, t, child) {
                      // 〜0.15: 透明(河に置かれるまでの「消えている」間)
                      // 〜0.30: 拡大サイズのままフェードイン
                      // 〜0.60: 拡大キープ(どの牌が切られたかを見せる時間)
                      // 〜1.00: 通常サイズへ縮む
                      final opacity = ((t - 0.15) / 0.15).clamp(0.0, 1.0);
                      final shrink = Curves.easeOut.transform(
                        ((t - 0.6) / 0.4).clamp(0.0, 1.0),
                      );
                      return Opacity(
                        opacity: opacity,
                        child: Transform.scale(
                          scale: 1.45 - 0.45 * shrink,
                          alignment: anchor,
                          child: child,
                        ),
                      );
                    },
                    child: tile,
                  );
                }
                return Padding(
                  padding: EdgeInsets.all(tileWidth * 0.03),
                  child: tile,
                );
              }(),
          ],
        ),
      );
    }
    // 4段目以降も伸びられるよう最小高のみ確保する(固定高だとあふれる)
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: tileWidth * 6.6 + tileWidth * TileWidget.aspect,
        maxWidth: tileWidth * 6.6 + tileWidth * TileWidget.aspect,
        minHeight: tileWidth * TileWidget.aspect * 2.25,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }
}

/// 副露の列。鳴いた牌は鳴いた方向(上家=左端・対面=中央・下家=右端)に
/// 横向きで置く。
class MeldRow extends StatelessWidget {
  final List<Meld> melds;
  final double tileWidth;

  /// 副露の持ち主の席(鳴いた方向の計算に使う)
  final int ownerSeat;
  final Set<int> doraKinds;

  const MeldRow({
    super.key,
    required this.melds,
    required this.tileWidth,
    required this.ownerSeat,
    this.doraKinds = const {},
  });

  bool _isDora(int t) => doraKinds.contains(Tile.normalize(t));

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final m in melds)
          Padding(
            padding: EdgeInsets.only(left: tileWidth * 0.25),
            child: _meld(m),
          ),
      ],
    );
  }

  Widget _meld(Meld m) {
    if (m.type == MeldType.ankan) {
      // 両端は伏せ、中2枚を表向き。赤牌があれば表向き側に見せる。
      final face = ankanFaceUp(m.tiles);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TileWidget(tile: null, width: tileWidth),
          TileWidget(tile: face[0], width: tileWidth, dora: _isDora(face[0])),
          TileWidget(tile: face[1], width: tileWidth, dora: _isDora(face[1])),
          TileWidget(tile: null, width: tileWidth),
        ],
      );
    }

    // 鳴いた牌以外を昇順に並べる
    final others = List<int>.from(m.tiles);
    others.remove(m.calledTile);
    others.sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));

    // 加槓は横向き2枚(ポンの牌+足した牌)を縦に重ねる
    Widget called = TileWidget(
      tile: m.calledTile,
      width: tileWidth,
      sideways: true,
      dora: _isDora(m.calledTile),
    );
    if (m.type == MeldType.kakan) {
      final stackIdx = others.indexWhere(
        (t) => Tile.normalize(t) == Tile.normalize(m.calledTile),
      );
      final stacked = others.removeAt(stackIdx);
      called = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TileWidget(
            tile: stacked,
            width: tileWidth,
            sideways: true,
            dora: _isDora(stacked),
          ),
          TileWidget(
            tile: m.calledTile,
            width: tileWidth,
            sideways: true,
            dora: _isDora(m.calledTile),
          ),
        ],
      );
    }

    // 鳴いた方向: 上家=左端 / 対面=中央 / 下家=右端
    final rel = (m.fromSeat - ownerSeat + 4) % 4;
    final pos = calledTilePosition(rel, others.length);

    final children = <Widget>[
      for (final t in others)
        TileWidget(tile: t, width: tileWidth, dora: _isDora(t)),
    ];
    children.insert(pos.clamp(0, children.length), called);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: children,
    );
  }
}

/// 相手の手牌(裏向きの列)。
///
/// 打牌が発生すると「切る牌が一瞬消えてから河に置かれる」ように、消える牌の
/// ゴーストをフェードアウトさせる。ツモ切りは右端(ツモ牌の位置)、手出しは
/// 中央あたりに出す。**実際の牌の並びは見せない**(理牌読み防止)ので、
/// ゴーストは確定レイアウトの上に重ねるだけで、並びには影響しない。
class HiddenHand extends StatefulWidget {
  final int count;
  final int meldCount;
  final double tileWidth;

  /// この席の最新打牌の通し番号(order)。変わったら消える演出を再生する。
  final int? animOrder;

  /// 直近の打牌がツモ切りか(消える牌の位置: 右=ツモ切り / 中央=手出し)
  final bool tsumogiri;

  const HiddenHand({
    super.key,
    required this.count,
    required this.meldCount,
    required this.tileWidth,
    this.animOrder,
    this.tsumogiri = false,
  });

  @override
  State<HiddenHand> createState() => _HiddenHandState();
}

class _HiddenHandState extends State<HiddenHand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..value = 1; // 初期表示ではゴーストを出さない

  @override
  void didUpdateWidget(HiddenHand old) {
    super.didUpdateWidget(old);
    // 新しい打牌が来たら消える演出を再生
    if (widget.animOrder != null && widget.animOrder != old.animOrder) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.tileWidth;
    final normal = 13 - widget.meldCount * 3;
    final hasDrawn = widget.count > normal;
    final backs = hasDrawn ? widget.count - 1 : widget.count;

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < backs; i++)
          Padding(
            padding: EdgeInsets.only(right: w * 0.04),
            child: TileWidget(tile: null, width: w),
          ),
        if (hasDrawn)
          Padding(
            padding: EdgeInsets.only(left: w * 0.35),
            child: TileWidget(tile: null, width: w),
          ),
      ],
    );

    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        row,
        // 消える牌のゴースト(確定レイアウトの上に重ねる)
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              // 前半で 1→0 にフェード(消えてから河に置かれる、の「消える」)
              final o = (1 - _c.value / 0.55).clamp(0.0, 1.0);
              if (o <= 0) return const SizedBox.shrink();
              return Align(
                // ツモ切り=右端 / 手出し=中央
                alignment: widget.tsumogiri
                    ? Alignment.centerRight
                    : Alignment.center,
                child: Opacity(
                  opacity: o,
                  child: TileWidget(tile: null, width: w),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 1席分の卓上表示(河+副露+相手なら裏手牌)。
/// 「自分が下辺」の向きで組み、呼び出し側が RotatedBox で回す。
class SeatArea extends StatelessWidget {
  final PlayerView player;
  final int seat;
  final double riverTileWidth;
  final bool showHiddenHand;
  final int? highlightTile;
  final Set<int> doraKinds;

  /// 読みクイズの答え合わせなどで、裏向きの列の代わりに実際の手牌を開いて
  /// 見せる。[showHiddenHand] が true の席でのみ使われる。
  final List<int>? revealHand;

  const SeatArea({
    super.key,
    required this.player,
    required this.seat,
    required this.riverTileWidth,
    required this.showHiddenHand,
    this.highlightTile,
    this.doraKinds = const {},
    this.revealHand,
  });

  @override
  Widget build(BuildContext context) {
    final river = DiscardRiver(
      discards: player.discards,
      tileWidth: riverTileWidth,
      highlightTile: highlightTile,
      doraKinds: doraKinds,
      animateNewest: showHiddenHand, // 他家のみ「置かれる」演出
    );
    // 最新打牌(消える演出の起点)
    final lastDiscard = player.discards.isNotEmpty
        ? player.discards.last
        : null;
    final meldRow = player.melds.isEmpty
        ? null
        : MeldRow(
            melds: player.melds,
            tileWidth: riverTileWidth * 0.9,
            ownerSeat: seat,
            doraKinds: doraKinds,
          );

    // 自分(伏せ牌なし): 副露は河の「右」に横並びで置く。河の下に置くと
    // 3段目のときに手牌と重なってしまうため。左側に副露と同じ幅の不可視
    // バランサーを入れ、副露があっても河の中央位置がずれないようにする。
    // 4副露のときはブロック幅が下家(右)の河ゾーンに達しうるので副露を縮小。
    if (!showHiddenHand) {
      if (player.melds.isEmpty) return river;
      final selfMelds = MeldRow(
        melds: player.melds,
        tileWidth: riverTileWidth * (player.melds.length >= 4 ? 0.7 : 0.9),
        ownerSeat: seat,
        doraKinds: doraKinds,
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Opacity(opacity: 0, child: IgnorePointer(child: selfMelds)),
          SizedBox(width: riverTileWidth * 0.5),
          river,
          SizedBox(width: riverTileWidth * 0.5),
          selfMelds,
        ],
      );
    }

    // 相手: 従来通り、河の下に「伏せ牌 + 副露」を横並びで置く。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        river,
        SizedBox(height: riverTileWidth * 0.2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (revealHand != null)
              TileRow(
                tiles: revealHand!,
                tileWidth: riverTileWidth * 0.9,
                doraKinds: doraKinds,
              )
            else
              HiddenHand(
                count: player.handCount,
                meldCount: player.melds.length,
                tileWidth: riverTileWidth * 0.9,
                animOrder: lastDiscard?.order,
                tsumogiri: lastDiscard?.tsumogiri ?? false,
              ),
            if (meldRow != null) ...[
              SizedBox(width: riverTileWidth * 0.5),
              meldRow,
            ],
          ],
        ),
      ],
    );
  }
}

/// 中央の情報パネル(局・本場・残り牌・ドラ・各家の点数)
class CenterPanel extends StatelessWidget {
  final GameView view;
  final double scale; // 基準となる幅

  const CenterPanel({super.key, required this.view, required this.scale});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: scale,
      padding: EdgeInsets.all(scale * 0.028),
      decoration: BoxDecoration(
        color: const Color(0xFF07270F).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2E7D32)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 対面
          _chip(view, 2),
          // 左 | 局表示(大きく中央) | 右(卓を模した配置)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 5, child: _chip(view, 3)),
              Expanded(flex: 4, child: Center(child: _kyoku())),
              Expanded(flex: 5, child: _chip(view, 1)),
            ],
          ),
          SizedBox(height: scale * 0.004),
          // 下段: [ドラ(左下・上家との間)] [自分] [残数・供託(右下・下家との間)]
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Center(
                  child: FittedBox(fit: BoxFit.scaleDown, child: _dora()),
                ),
              ),
              _chip(view, 0),
              Expanded(
                child: Center(
                  child: FittedBox(fit: BoxFit.scaleDown, child: _wallSticks()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 局・本場(中央)。局数は大きく、本場は小さく2行表示。
  /// 本場は0本場でも常に表示し、本場の値で局数のサイズが変わらないよう
  /// 各行を独立に配置する。
  Widget _kyoku() {
    final name = kyokuLabel(view.roundWind, view.kyoku);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 局数(大きめ)
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            name,
            style: TextStyle(
              fontSize: scale * 0.092,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        // 本場(小さめ・常に表示)
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${view.honba}本場',
            style: TextStyle(fontSize: scale * 0.05, color: Colors.white70),
          ),
        ),
      ],
    );
  }

  /// 王牌のドラ表示(めくれた表示牌+裏向き)。左下コーナーに配置。
  Widget _dora() {
    final doraW = scale * 0.092;
    final doraKinds = TileWidget.doraKindsFrom(view.doraIndicators);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: const EdgeInsets.only(right: 1.5),
            child: TileWidget(
              tile: i < view.doraIndicators.length
                  ? view.doraIndicators[i]
                  : null,
              width: doraW,
              dora:
                  i < view.doraIndicators.length &&
                  doraKinds.contains(Tile.normalize(view.doraIndicators[i])),
            ),
          ),
      ],
    );
  }

  /// 残り牌数・供託(右下コーナーに大きめで配置)
  Widget _wallSticks() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.view_agenda, size: scale * 0.062, color: Colors.white60),
            SizedBox(width: scale * 0.014),
            Text(
              '残 ${view.wallRemaining}',
              style: TextStyle(
                fontSize: scale * 0.066,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        if (view.riichiSticks > 0)
          Padding(
            padding: EdgeInsets.only(top: scale * 0.014),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // リーチ棒(白い棒+赤点)
                Container(
                  width: scale * 0.11,
                  height: scale * 0.026,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Center(
                    child: Container(
                      width: scale * 0.022,
                      height: scale * 0.022,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: scale * 0.016),
                Text(
                  '${view.riichiSticks}',
                  style: TextStyle(
                    fontSize: scale * 0.062,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFFFF8A65),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// rel: 自分から見た相対位置 0=自分(下) 1=右 2=対面 3=左
  /// 全チップで同じフォントサイズ。名前は独立行にして必要なら省略表示。
  Widget _chip(GameView view, int rel) {
    final seat = (view.youSeat + rel) % 4;
    final p = view.players[seat];
    final isTurn = view.currentSeat == seat;
    final isDealer = view.dealer == seat;
    final wind = windNames[view.seatWind(seat)];
    final cpuLabel = p.isCpu ? '' : (p.connected ? '' : '(代打)');

    // 全チップ共通の固定フォントサイズ
    final fs = scale * 0.048;

    return Container(
      margin: EdgeInsets.symmetric(vertical: scale * 0.008),
      padding: EdgeInsets.symmetric(
        horizontal: scale * 0.02,
        vertical: scale * 0.01,
      ),
      decoration: BoxDecoration(
        color: isTurn ? const Color(0xFF4E4419) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isTurn ? const Color(0xFFFFC400) : Colors.white24,
          width: isTurn ? 1.5 : 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 名前(独立行・長ければ省略)
          Text(
            '${p.name}$cpuLabel',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: fs, color: Colors.white),
          ),
          SizedBox(height: scale * 0.006),
          // 自風 + 点数(+リーチ棒)。狭いセルでも崩れないよう縮小許容
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  wind,
                  style: TextStyle(
                    fontSize: fs,
                    fontWeight: FontWeight.bold,
                    color: isDealer ? const Color(0xFFFF7043) : Colors.white70,
                  ),
                ),
                SizedBox(width: scale * 0.02),
                Text(
                  '${view.scores[seat]}',
                  style: TextStyle(
                    fontSize: fs,
                    fontWeight: FontWeight.w600,
                    color: view.scores[seat] < 0
                        ? const Color(0xFFEF5350)
                        : const Color(0xFFFFE082),
                  ),
                ),
                if (p.riichi)
                  Padding(
                    padding: EdgeInsets.only(left: scale * 0.02),
                    child: Container(
                      width: scale * 0.09,
                      height: scale * 0.02,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Center(
                        child: Container(
                          width: scale * 0.018,
                          height: scale * 0.018,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
