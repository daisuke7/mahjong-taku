import 'package:flutter/material.dart';

import '../../engine/advisor.dart';
import '../../engine/models.dart';
import '../../engine/tile.dart';
import 'guidebook.dart';
import 'scroll_hint.dart';
import 'tile_widget.dart';

/// ツモ時のアドバイス表示
void showAdviceDialog(BuildContext context, GameView view) {
  final report = buildAdvice(view);
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF10331C),
      title: Row(
        children: [
          const Icon(Icons.lightbulb, color: Color(0xFFFFD54F), size: 20),
          const SizedBox(width: 8),
          const Text(
            'アドバイス',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          const Spacer(),
          // 早見表(点数表・役一覧)
          IconButton(
            icon: const Icon(Icons.menu_book, color: Color(0xFFFFD54F)),
            tooltip: '早見表',
            visualDensity: VisualDensity.compact,
            onPressed: () => showGuidebook(ctx),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        height: 380,
        child: ScrollHint(
          builder: (context, controller) => SingleChildScrollView(
            controller: controller,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _sectionTitle(
                  '攻撃',
                  Icons.local_fire_department,
                  const Color(0xFFFF8A65),
                ),
                Text(
                  report.shanten <= 0 ? 'テンパイ!' : '${report.shanten}シャンテン',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (report.waits.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  // 切る牌ごとに待ちが変わるので、打牌ごとに1行(受けの広い順)。
                  for (final o in report.waits)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (o.discard != null) ...[
                            const Text(
                              '切→',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(width: 2),
                            TileWidget(tile: o.discard, width: 20),
                            const SizedBox(width: 8),
                          ],
                          const Text(
                            '待ち',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Wrap(
                              spacing: 3,
                              runSpacing: 3,
                              children: [
                                for (final w in o.tiles)
                                  TileWidget(tile: w, width: 20),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '残り${o.total}枚',
                            style: const TextStyle(
                              color: Color(0xFFFFCC80),
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                if (report.ukeire.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  // 非テンパイ: 最良シャンテンを保つ打牌ごとのウケ(受け広い順)。
                  // 候補が多い序盤は上位だけに絞って読める量にする。
                  for (final o in report.ukeire.take(6))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            '切→',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(width: 2),
                          TileWidget(tile: o.discard, width: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'ウケ',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Wrap(
                              spacing: 3,
                              runSpacing: 3,
                              children: [
                                for (final w in o.tiles)
                                  TileWidget(tile: w, width: 20),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${o.tiles.length}種${o.total}枚',
                            style: const TextStyle(
                              color: Color(0xFFFFCC80),
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (report.ukeire.length > 6)
                    Text(
                      'ほか${report.ukeire.length - 6}候補(同シャンテン)',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10.5,
                      ),
                    ),
                ],
                const SizedBox(height: 6),
                if (report.offense.isEmpty)
                  const Text(
                    '今の形からはっきり狙える役は見えません。',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  )
                else
                  for (final c in report.offense)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              // 役満は翻数を数えないので「(0翻)」を出さない
                              '・${c.parts.join(' + ')}${c.han > 0 ? '(${c.han}翻)' : ''}'
                              ' → ${c.points}点'
                              '${c.label.isNotEmpty ? '(${c.label})' : ''}'
                              // 手なりより遠い役は、どれだけ遠回りかを添える
                              '${c.shanten != null && c.shanten! > report.shanten ? '  ※${c.shanten}シャンテン' : ''}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                          if (c.discard != null) ...[
                            const SizedBox(width: 6),
                            const Text(
                              '切→',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(width: 2),
                            TileWidget(tile: c.discard, width: 22),
                          ],
                        ],
                      ),
                    ),
                const Divider(color: Colors.white24, height: 20),
                _sectionTitle('守備', Icons.shield, const Color(0xFF64B5F6)),
                if (report.threats.isEmpty)
                  const Text(
                    '今のところ警戒すべき相手は見当たりません。',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  )
                else ...[
                  for (final t in report.threats)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '・${view.players[t.seat].name}: ${t.description}',
                        style: TextStyle(
                          color: t.level >= 2
                              ? const Color(0xFFEF9A9A)
                              : const Color(0xFFFFE082),
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  if (report.dangerTiles.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text(
                      '今切ると危なそうな牌:',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    TileRow(tiles: report.dangerTiles, tileWidth: 24),
                  ],
                  if (report.safeTiles.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text(
                          '通りやすい牌',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        if (report.genbutsuKinds.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(0xFF4FC3F7),
                              ),
                            ),
                            child: const Text(
                              '青=現物(100%通る)',
                              style: TextStyle(
                                color: Color(0xFF4FC3F7),
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final t in report.safeTiles)
                          TileWidget(
                            tile: t,
                            width: 24,
                            glowSafe: report.genbutsuKinds.contains(
                              Tile.normalize(t),
                            ),
                          ),
                      ],
                    ),
                  ],
                  for (final s in report.sujiTables) ...[
                    const SizedBox(height: 10),
                    Text(
                      '通ったスジ(${view.players[s.seat].name}のリーチ) '
                      '${s.passedCount}/18',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    const Text(
                      '明るいスジは両面待ちなら通ると読める(暗いスジは未確認)',
                      style: TextStyle(color: Colors.white38, fontSize: 10.5),
                    ),
                    const SizedBox(height: 5),
                    _SujiTableView(table: s),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
}

/// 通ったスジの6本×3色表。1マス=スジ1本(例: 2-5)を牌2枚で示し、
/// 通っていれば明るく、通っていなければ暗く描く。
class _SujiTableView extends StatelessWidget {
  final SujiTable table;

  const _SujiTableView({required this.table});

  @override
  Widget build(BuildContext context) {
    const tileW = 15.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var suit = 0; suit < 3; suit++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                for (var i = 0; i < 6; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 9),
                    child: Row(
                      children: [
                        TileWidget(
                          tile: suit * 9 + i,
                          width: tileW,
                          dimmed: !table.passed[suit][i],
                        ),
                        const SizedBox(width: 1),
                        TileWidget(
                          tile: suit * 9 + i + 3,
                          width: tileW,
                          dimmed: !table.passed[suit][i],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

Widget _sectionTitle(String title, IconData icon, Color color) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );
}
