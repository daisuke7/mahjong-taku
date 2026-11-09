import 'package:flutter/material.dart';
import '../../engine/display_text.dart';

import '../../engine/comeback.dart';
import '../../engine/models.dart';

/// 中央パネルのタップで開く「順位表 / 逆転の目安」ダイアログ。
Future<void> showRankTable(BuildContext context, GameView view) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => RankTableDialog(view: view),
  );
}

class RankTableDialog extends StatelessWidget {
  final GameView view;
  const RankTableDialog({super.key, required this.view});

  @override
  Widget build(BuildContext context) {
    final rows = buildRanking(view);
    return Dialog(
      backgroundColor: const Color(0xFF0B2B14),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFF2E7D32)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.leaderboard,
                      color: Color(0xFFFFD54F),
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '順位表 / 逆転の目安',
                      style: TextStyle(
                        color: Color(0xFFFFE082),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close, color: Colors.white54),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _RankGrid(rows: rows),
                const SizedBox(height: 8),
                const Text(
                  '「逆転ツモ/ロン」= その相手を上回るのに最低限必要な手(符も考慮)と、その手で得られる点(供託・本場込み)。'
                  'ツモは相手も支払う分軽い。ロンは直撃を考慮しない。',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RankGrid extends StatelessWidget {
  final List<RankEntry> rows;
  const _RankGrid({required this.rows});

  static const _headStyle = TextStyle(
    color: Color(0xFFFFE082),
    fontSize: 12,
    fontWeight: FontWeight.bold,
  );

  @override
  Widget build(BuildContext context) {
    return Table(
      border: TableBorder.all(color: const Color(0xFF2E7D32), width: 0.8),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: const {
        0: FixedColumnWidth(36), // 順位
        1: FlexColumnWidth(2.2), // 名前
        2: FlexColumnWidth(2), // 現在点
        3: FlexColumnWidth(2), // 差
        4: FlexColumnWidth(2.6), // 逆転ツモ
        5: FlexColumnWidth(2.6), // 逆転ロン
      },
      children: [
        TableRow(
          decoration: const BoxDecoration(color: Color(0xFF14401F)),
          children: const [
            _Cell('#', style: _headStyle),
            _Cell('名前', style: _headStyle),
            _Cell('現在点', style: _headStyle),
            _Cell('自分との差', style: _headStyle),
            _Cell('逆転ツモ', style: _headStyle),
            _Cell('逆転ロン', style: _headStyle),
          ],
        ),
        for (var i = 0; i < rows.length; i++) _row(i + 1, rows[i]),
      ],
    );
  }

  TableRow _row(int rank, RankEntry e) {
    final nameStyle = TextStyle(
      color: e.isSelf ? const Color(0xFFFFE082) : Colors.white,
      fontSize: 13,
      fontWeight: e.isSelf ? FontWeight.bold : FontWeight.normal,
    );
    return TableRow(
      decoration: BoxDecoration(
        color: e.isSelf ? const Color(0x3341C46A) : Colors.transparent,
      ),
      children: [
        _Cell(
          '$rank',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        _Cell(e.isSelf ? '${e.name}(自分)' : e.name, style: nameStyle),
        _Cell(
          '${e.score}',
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        _Cell(
          _diffText(e),
          style: TextStyle(
            color: e.isSelf
                ? Colors.white38
                : (e.diff > 0
                      ? const Color(0xFFEF9A9A)
                      : const Color(0xFFA5D6A7)),
            fontSize: 13,
          ),
        ),
        _needCell(e.tsumo),
        _needCell(e.ron),
      ],
    );
  }

  String _diffText(RankEntry e) {
    if (e.isSelf) return '—';
    return formatSignedPoints(e.diff);
  }

  Widget _needCell(NeededHand? n) {
    if (n == null) {
      return const _Cell(
        '—',
        style: TextStyle(color: Colors.white30, fontSize: 13),
      );
    }
    if (!n.reachable) {
      return const _Cell(
        '届かず',
        style: TextStyle(color: Colors.white38, fontSize: 12),
      );
    }
    return _Cell.rich(
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            n.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '${n.gain}',
            style: const TextStyle(color: Color(0xFFFFCC80), fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  final String? text;
  final TextStyle? style;
  final Widget? child;
  const _Cell(this.text, {this.style}) : child = null;
  const _Cell.rich(this.child) : text = null, style = null;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      child: Center(
        child:
            child ??
            Text(text ?? '', textAlign: TextAlign.center, style: style),
      ),
    );
  }
}
