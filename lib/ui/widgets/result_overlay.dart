import 'package:flutter/material.dart';

import '../../engine/meld.dart';
import '../../engine/display_text.dart';
import '../../engine/yaku.dart';
import '../../engine/models.dart';
import '../../engine/tile.dart';
import 'guidebook.dart';
import 'scroll_hint.dart';
import 'tile_widget.dart';

/// 局結果(和了・流局)の表示
class HandResultOverlay extends StatelessWidget {
  final GameView view;

  /// 自分が「次へ」を押し済みか
  final bool acked;
  final VoidCallback onAdvance;

  const HandResultOverlay({
    super.key,
    required this.view,
    required this.acked,
    required this.onAdvance,
  });

  @override
  Widget build(BuildContext context) {
    final result = view.handResult!;
    // 流局は各行の右に聴牌者の牌姿(副露込み)を並べるので、横に広げる。
    final isDraw = result.type == 'draw';
    return _OverlayShell(
      maxWidth: isDraw ? 1040 : 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: ScrollHint(
              builder: (context, controller) => SingleChildScrollView(
                controller: controller,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isDraw) ...[
                      _drawHeader(result),
                      const SizedBox(height: 10),
                      _drawScoreTable(context, result),
                    ] else ...[
                      for (final w in result.wins) _winBody(context, w, result),
                      const SizedBox(height: 10),
                      _scoreTable(context, result),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 人間プレイヤーは各自「次へ」を押す。全員押すと次の局へ。
          if (acked)
            const Text(
              '他のプレイヤーの確認を待っています…',
              style: TextStyle(color: Colors.white60),
            )
          else
            FilledButton(onPressed: onAdvance, child: const Text('次へ')),
        ],
      ),
    );
  }

  Widget _drawHeader(HandResult result) {
    return Column(
      children: [
        const Text(
          '流局',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          tenpaiSummary([
            for (final s in result.tenpaiSeats) view.players[s].name,
          ]),
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ],
    );
  }

  /// 流局時の点数表。各行の右に、聴牌者は牌姿(手牌+副露)を並べる。
  Widget _drawScoreTable(BuildContext context, HandResult result) {
    final doraKinds = TileWidget.doraKindsFrom(view.doraIndicators);
    return Column(
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 34,
                  child: Text(
                    windNames[view.seatWind(i)],
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
                SizedBox(
                  width: 100,
                  child: Text(
                    view.players[i].name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                SizedBox(
                  width: 60,
                  child: Text(
                    formatSignedPoints(result.scoreChanges[i], zero: '±0'),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: result.scoreChanges[i] > 0
                          ? const Color(0xFF81C784)
                          : result.scoreChanges[i] < 0
                          ? const Color(0xFFE57373)
                          : Colors.white38,
                    ),
                  ),
                ),
                SizedBox(
                  width: 74,
                  child: Text(
                    '${result.scores[i]}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: result.tenpaiSeats.contains(i)
                      ? _handShape(i, result, doraKinds)
                      : const Text(
                          'ノーテン',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 聴牌者の牌姿(手牌+副露)。長い場合は横スクロールで収める。
  Widget _handShape(int seat, HandResult result, Set<int> doraKinds) {
    final concealed = result.revealedHands[seat] ?? const <int>[];
    final melds = view.players[seat].melds;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          TileRow(tiles: concealed, tileWidth: 20, doraKinds: doraKinds),
          for (final m in melds) ...[
            const SizedBox(width: 6),
            _meldTiles(m, doraKinds),
          ],
        ],
      ),
    );
  }

  /// 副露の牌並び。暗槓だけは両端を伏せて暗槓の見た目にする。
  /// (ポン・チー・明槓・加槓は結果表示ではまとめて表向きで簡略表示)
  Widget _meldTiles(Meld m, Set<int> doraKinds) {
    const w = 19.0;
    if (m.type != MeldType.ankan) {
      return TileRow(tiles: m.tiles, tileWidth: w, doraKinds: doraKinds);
    }
    // 暗槓: 両端を伏せ、中2枚を表向き(対局画面の副露表示と同じ見た目)。
    // 赤牌があれば表向き側に見せる。
    final face = ankanFaceUp(m.tiles);
    Widget tile(int? t) => Padding(
      padding: const EdgeInsets.only(right: w * 0.06),
      child: TileWidget(
        tile: t,
        width: w,
        dora: t != null && doraKinds.contains(Tile.normalize(t)),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [tile(null), tile(face[0]), tile(face[1]), tile(null)],
    );
  }

  Widget _winBody(BuildContext context, WinInfo w, HandResult result) {
    final winner = view.players[w.seat];
    final method = w.isTsumo ? 'ツモ' : 'ロン';
    final score = w.score;
    final hanText = score.isYakuman
        ? w.label
        : '${hanFuLabel(score.han, score.fu)}${w.label.isNotEmpty ? ' ${w.label}' : ''}';
    // 和了牌は牌姿に組み込まず右端に離して表示する
    final concealed = List<int>.from(w.hand)..remove(w.winTile);
    // 表ドラ・カンドラ・裏ドラの全表示牌からドラ牌種を作る
    final doraKinds = TileWidget.doraKindsFrom([
      ...view.doraIndicators,
      ...result.uraIndicators,
    ]);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Text(
            // 和了要約の書式は winSummary と同じ(名前 ツモ/ロン … 点)。間に翻符を挟む
            '${winner.name} $method  $hanText  ${w.points}点',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TileRow(tiles: concealed, tileWidth: 26, doraKinds: doraKinds),
              for (final m in w.melds) ...[
                const SizedBox(width: 8),
                TileRow(tiles: m.tiles, tileWidth: 24, doraKinds: doraKinds),
              ],
              const SizedBox(width: 16),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    method,
                    style: const TextStyle(fontSize: 10, color: Colors.white54),
                  ),
                  const SizedBox(height: 2),
                  TileWidget(
                    tile: w.winTile,
                    width: 26,
                    highlighted: true,
                    dora: doraKinds.contains(Tile.normalize(w.winTile)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              for (final y in orderYakuForDisplay(score.yaku))
                Chip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(
                    yakuItemLabel(
                      y,
                      isYakuman: score.isYakuman,
                      withHanSuffix: true,
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          if (result.uraIndicators.isNotEmpty &&
              w.seat == _riichiWinnerSeat(result))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '裏ドラ表示 ',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  TileRow(tiles: result.uraIndicators, tileWidth: 20),
                ],
              ),
            ),
        ],
      ),
    );
  }

  int _riichiWinnerSeat(HandResult result) {
    for (final w in result.wins) {
      if (view.players[w.seat].riichi) return w.seat;
    }
    return -1;
  }

  Widget _scoreTable(BuildContext context, HandResult result) {
    return Column(
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    windNames[view.seatWind(i)],
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
                SizedBox(
                  width: 130,
                  child: Text(
                    view.players[i].name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: Text(
                    formatSignedPoints(result.scoreChanges[i], zero: ''),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: result.scoreChanges[i] >= 0
                          ? const Color(0xFF81C784)
                          : const Color(0xFFE57373),
                    ),
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: Text(
                    '${result.scores[i]}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Mリーグ式ポイント表記(+50.3 / ▲12.0)
String formatPt(double p) {
  final abs = p.abs().toStringAsFixed(1);
  return p >= 0 ? '+$abs' : '▲$abs';
}

Color ptColor(double p) =>
    p >= 0 ? const Color(0xFF81C784) : const Color(0xFFE57373);

/// 1試合分のゲームスタッツ表(行=メンツ、列=pt/アガリ/リーチ/放銃)
class StatsTable extends StatelessWidget {
  final List<String> names;
  final GameStats stats;

  /// 素点も表示する場合に指定(試合終了直後の表示用)
  final List<int>? scores;

  const StatsTable({
    super.key,
    required this.names,
    required this.stats,
    this.scores,
  });

  @override
  Widget build(BuildContext context) {
    // ポイント順に並べる(同点は1試合目の起家に近い順=メンバー順)
    final order = List.generate(4, (i) => i)
      ..sort((a, b) {
        final c = stats.points[b].compareTo(stats.points[a]);
        return c != 0 ? c : a - b;
      });

    const headStyle = TextStyle(color: Colors.white54, fontSize: 12);
    const cellStyle = TextStyle(color: Colors.white, fontSize: 15);

    Widget cell(
      String text,
      double width, {
      TextStyle style = cellStyle,
      TextAlign align = TextAlign.right,
    }) {
      return SizedBox(
        width: width,
        child: Text(
          text,
          textAlign: align,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            cell('', 116, align: TextAlign.left, style: headStyle),
            if (scores != null) cell('素点', 64, style: headStyle),
            cell('ポイント', 72, style: headStyle),
            cell('アガリ', 56, style: headStyle),
            cell('リーチ', 56, style: headStyle),
            cell('放銃', 56, style: headStyle),
          ],
        ),
        const SizedBox(height: 4),
        for (var rank = 0; rank < 4; rank++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                cell(
                  '${rank + 1}位 ${names[order[rank]]}',
                  116,
                  align: TextAlign.left,
                  style: TextStyle(
                    fontSize: 15,
                    color: rank == 0 ? const Color(0xFFFFD54F) : Colors.white,
                  ),
                ),
                if (scores != null) cell('${scores![order[rank]]}', 64),
                cell(
                  formatPt(stats.points[order[rank]]),
                  72,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: ptColor(stats.points[order[rank]]),
                  ),
                ),
                cell('${stats.wins[order[rank]]}', 56),
                cell('${stats.riichis[order[rank]]}', 56),
                cell('${stats.dealIns[order[rank]]}', 56),
              ],
            ),
          ),
      ],
    );
  }
}

/// 試合終了時のゲームスタッツ表示
class GameResultOverlay extends StatelessWidget {
  final GameView view;
  final bool isHost;
  final VoidCallback onNextGame;
  final VoidCallback onExit;

  /// タイトルの試合名。省略時は連戦の通し番号(第N試合)。
  /// 牌譜再生では実際の試合名(例: '第2試合(B卓)')を渡す。
  final String? matchLabel;

  const GameResultOverlay({
    super.key,
    required this.view,
    required this.isHost,
    required this.onNextGame,
    required this.onExit,
    this.matchLabel,
  });

  @override
  Widget build(BuildContext context) {
    final stats = view.history.isNotEmpty
        ? view.history.last
        : GameStats.zero();
    return _OverlayShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${matchLabel ?? '第${view.history.length}試合'} 結果',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 14),
          StatsTable(
            names: view.memberNameList,
            stats: stats,
            // 素点(席順)をメンバー順に並べ替え
            scores: [
              for (final s in view.memberSeats)
                (view.gameResult?.scores ?? view.scores)[s],
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isHost) ...[
                FilledButton.icon(
                  onPressed: onNextGame,
                  icon: const Icon(Icons.refresh),
                  label: const Text('次の試合へ'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(onPressed: onExit, child: const Text('終了')),
              ] else if (matchLabel != null) ...[
                // 牌譜再生: 連戦はないので退出のみ
                FilledButton(onPressed: onExit, child: const Text('退出')),
              ] else ...[
                FilledButton(onPressed: onExit, child: const Text('退出')),
                const SizedBox(width: 12),
                const Text(
                  'ホストが次の試合を開始できます',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 総合成績表(対局中いつでも開ける)
class ScoreboardOverlay extends StatelessWidget {
  final GameView view;
  final VoidCallback onClose;

  const ScoreboardOverlay({
    super.key,
    required this.view,
    required this.onClose,
  });

  void _showStats(BuildContext context, String title, GameStats stats) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10331C),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: StatsTable(names: view.memberNameList, stats: stats),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playing = view.phase != 'gameEnd';
    final rows = <(String, List<double>, GameStats, bool)>[
      for (var i = 0; i < view.history.length; i++)
        ('第${i + 1}試合', view.history[i].points, view.history[i], false),
      if (playing)
        (
          '第${view.gameIndex}試合',
          view.currentStats.points,
          view.currentStats,
          true,
        ),
    ];
    final totals = List<double>.filled(4, 0);
    for (final r in rows) {
      for (var i = 0; i < 4; i++) {
        totals[i] += r.$2[i];
      }
    }

    const headStyle = TextStyle(color: Colors.white54, fontSize: 12);

    Widget cell(
      String text,
      double width, {
      TextStyle? style,
      TextAlign align = TextAlign.right,
    }) {
      return SizedBox(
        width: width,
        child: Text(
          text,
          textAlign: align,
          overflow: TextOverflow.ellipsis,
          style: style ?? const TextStyle(color: Colors.white, fontSize: 14),
        ),
      );
    }

    return _OverlayShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '総合成績表',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.menu_book, color: Color(0xFFFFD54F)),
                tooltip: '早見表',
                onPressed: () => showGuidebook(context),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54),
                onPressed: onClose,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 列 = 1試合目の東南西北順で固定したメンバー
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              cell('', 110, align: TextAlign.left, style: headStyle),
              for (var s = 0; s < 4; s++)
                cell(view.memberNameList[s], 86, style: headStyle),
            ],
          ),
          const Divider(color: Colors.white24, height: 10),
          Flexible(
            child: ScrollHint(
              builder: (context, controller) => SingleChildScrollView(
                controller: controller,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final r in rows)
                      InkWell(
                        onTap: () =>
                            _showStats(context, '${r.$1}のゲームスタッツ', r.$3),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              cell(
                                r.$4 ? '${r.$1}(対局中)' : r.$1,
                                110,
                                align: TextAlign.left,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: r.$4
                                      ? const Color(0xFFFFD54F)
                                      : Colors.white70,
                                ),
                              ),
                              for (var s = 0; s < 4; s++)
                                cell(
                                  formatPt(r.$2[s]),
                                  86,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontStyle: r.$4
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                    color: r.$4
                                        ? const Color(0xFFFFE082)
                                        : ptColor(r.$2[s]),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (rows.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'まだ試合結果がありません',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(color: Colors.white24, height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              cell(
                '合計',
                110,
                align: TextAlign.left,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              for (var s = 0; s < 4; s++)
                cell(
                  formatPt(totals[s]),
                  86,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: ptColor(totals[s]),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '行をタップするとその試合のスタッツを表示',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _OverlayShell extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const _OverlayShell({required this.child, this.maxWidth = 560});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.65),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF10331C),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF2E7D32)),
          ),
          child: child,
        ),
      ),
    );
  }
}
