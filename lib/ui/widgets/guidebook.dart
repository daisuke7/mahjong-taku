import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../engine/score.dart';
import '../../engine/tile.dart';
import 'scroll_hint.dart';
import 'tile_widget.dart';

/// 早見表(ガイドブック)。全画面モーダルで、1ページ1コンテンツ。
/// 各ページは「タイトル + 縦スクロール内容」。左右のボタンでページめくり。
class GuidebookPage {
  final String title;
  final WidgetBuilder builder;

  const GuidebookPage({required this.title, required this.builder});
}

void showGuidebook(BuildContext context, {int initialPage = 0}) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (_, a, b) => _GuidebookModal(initialPage: initialPage),
      transitionsBuilder: (_, anim, b, child) =>
          FadeTransition(opacity: anim, child: child),
    ),
  );
}

class _GuidebookModal extends StatefulWidget {
  final int initialPage;

  const _GuidebookModal({this.initialPage = 0});

  @override
  State<_GuidebookModal> createState() => _GuidebookModalState();
}

class _GuidebookModalState extends State<_GuidebookModal> {
  late final PageController _controller = PageController(
    initialPage: widget.initialPage,
  );
  late int _page = widget.initialPage;

  late final List<GuidebookPage> _pages = [
    GuidebookPage(title: '役一覧', builder: (_) => const YakuListPage()),
    GuidebookPage(title: '点数表', builder: (_) => const ScoreTablePage()),
    GuidebookPage(title: '符計算', builder: (_) => const FuTablePage()),
    GuidebookPage(title: '牌一覧', builder: (_) => const TileListPage()),
    GuidebookPage(title: '基本用語集', builder: (_) => const GlossaryPage()),
    GuidebookPage(title: 'このアプリについて', builder: (_) => const AboutPage()),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = _page + delta;
    if (next < 0 || next >= _pages.length) return;
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF12331E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2E7D32)),
            ),
            child: Column(
              children: [
                // ヘッダー(タイトル+閉じる)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.menu_book,
                        color: Color(0xFFFFD54F),
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _pages[_page].title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      Text(
                        '${_page + 1} / ${_pages.length}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white24, height: 1),
                // 本文(横スワイプ + 各ページ縦スクロール)
                Expanded(
                  child: Row(
                    children: [
                      _pageArrow(Icons.chevron_left, _page > 0, () => _go(-1)),
                      Expanded(
                        child: PageView.builder(
                          controller: _controller,
                          itemCount: _pages.length,
                          onPageChanged: (i) => setState(() => _page = i),
                          itemBuilder: (context, i) => Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 12,
                            ),
                            child: ScrollHint(
                              builder: (context, controller) =>
                                  SingleChildScrollView(
                                    controller: controller,
                                    // Align で内容をページ幅いっぱいに広げる。
                                    // 内容が狭い(Wrapが左に寄る)ページでも、右側の
                                    // 余白がスクロール領域に含まれるようにする
                                    // (SingleChildScrollView は子の幅に縮むため、
                                    //  そのままだと余白部分がドラッグに反応しない)。
                                    child: Align(
                                      alignment: Alignment.topLeft,
                                      child: _pages[i].builder(context),
                                    ),
                                  ),
                            ),
                          ),
                        ),
                      ),
                      _pageArrow(
                        Icons.chevron_right,
                        _page < _pages.length - 1,
                        () => _go(1),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pageArrow(IconData icon, bool enabled, VoidCallback onTap) {
    return SizedBox(
      width: 44,
      child: IconButton(
        icon: Icon(
          icon,
          size: 34,
          color: enabled ? Colors.white : Colors.white.withValues(alpha: 0.15),
        ),
        onPressed: enabled ? onTap : null,
      ),
    );
  }
}

// ---------------- 点数表 ----------------

class ScoreTablePage extends StatelessWidget {
  const ScoreTablePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _note(
          'ロン(放銃者が全額払う) / 数字は和了者の得点。'
          '本場+300(ロン)・+100オール(ツモ)、供託は別途。',
        ),
        const SizedBox(height: 10),
        _tableTitle('子の点数(ロン)'),
        _scoreTable(isDealer: false, isTsumo: false),
        const SizedBox(height: 14),
        _tableTitle('子のツモ(子払い / 親払い)'),
        _scoreTable(isDealer: false, isTsumo: true),
        const SizedBox(height: 14),
        _tableTitle('親の点数(ロン)'),
        _scoreTable(isDealer: true, isTsumo: false),
        const SizedBox(height: 14),
        _tableTitle('親のツモ(全員払い)'),
        _scoreTable(isDealer: true, isTsumo: true),
        const SizedBox(height: 14),
        _tableTitle('満貫以上'),
        _limitTable(),
        const SizedBox(height: 10),
        _note('Mリーグルール: 30符4翻・60符3翻は切り上げ満貫。'),
      ],
    );
  }

  Widget _tableTitle(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      t,
      style: const TextStyle(
        color: Color(0xFFFFE082),
        fontSize: 15,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _note(String t) => Text(
    t,
    style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
  );

  static const _fuList = [20, 25, 30, 40, 50, 60, 70];
  static const _hanList = [1, 2, 3, 4];

  Widget _scoreTable({required bool isDealer, required bool isTsumo}) {
    // 基本点・丸めは点数計算(engine/score.dart)と同じ関数を使う
    String cell(int fu, int han) {
      if (scoreImpossible(fu: fu, han: han, isTsumo: isTsumo)) return '—';
      final base = basePointsOf(han, fu);
      if (isTsumo) {
        if (isDealer) {
          final each = ceil100(base * 2);
          return '$each オール';
        }
        final ko = ceil100(base);
        final oya = ceil100(base * 2);
        return '$ko/$oya';
      }
      final ron = ceil100(base * (isDealer ? 6 : 4));
      return '$ron';
    }

    return _grid(
      header: ['符\\翻', for (final h in _hanList) '$h翻'],
      rows: [
        for (final fu in _fuList)
          ['$fu', for (final h in _hanList) cell(fu, h)],
      ],
    );
  }

  Widget _limitTable() {
    final rows = [
      ('満貫', '8000', '2000オール', '12000', '4000オール'),
      ('跳満', '12000', '3000オール', '18000', '6000オール'),
      ('倍満', '16000', '4000オール', '24000', '8000オール'),
      ('三倍満', '24000', '6000オール', '36000', '12000オール'),
      ('役満', '32000', '8000オール', '48000', '16000オール'),
    ];
    return _grid(
      header: ['', '子ロン', '子ツモ', '親ロン', '親ツモ'],
      rows: [
        for (final r in rows) [r.$1, r.$2, r.$3, r.$4, r.$5],
      ],
    );
  }
}

/// 点数表で「存在しない (符,翻,ツモ/ロン) の組合せ」なら true
/// (判定本体は engine/score.dart の isValidHanFu。逆転計算と共有)。
bool scoreImpossible({
  required int fu,
  required int han,
  required bool isTsumo,
}) => !isValidHanFu(han: han, fu: fu, isTsumo: isTsumo);

/// 汎用の表(1行目ヘッダー)
Widget _grid({
  required List<String> header,
  required List<List<String>> rows,
  double firstColWidth = 56,
}) {
  TableRow buildRow(List<String> cells, {required bool head}) {
    return TableRow(
      decoration: head ? const BoxDecoration(color: Color(0xFF1B4D2B)) : null,
      children: [
        for (var i = 0; i < cells.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: Text(
              cells[i],
              textAlign: i == 0 ? TextAlign.left : TextAlign.right,
              style: TextStyle(
                color: head
                    ? const Color(0xFFFFE082)
                    : (i == 0 ? Colors.white70 : Colors.white),
                fontSize: 12.5,
                fontWeight: head ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
      ],
    );
  }

  return Table(
    border: TableBorder.all(color: Colors.white12, width: 0.5),
    defaultColumnWidth: const IntrinsicColumnWidth(),
    columnWidths: {0: FixedColumnWidth(firstColWidth)},
    children: [
      buildRow(header, head: true),
      for (final r in rows) buildRow(r, head: false),
    ],
  );
}

/// 符計算表のセル(テキスト+任意の例示牌)
class _Cell {
  final String text;
  final String? ex; // 牌記法。例示牌を表示する場合

  /// 横に倒す牌のインデックス(明刻・明槓)。-1=なし
  final int sidewaysIndex;

  /// 裏向きにする牌のインデックス集合(暗槓の両端)
  final Set<int> hiddenIndexes;

  const _Cell(
    this.text, {
    this.ex,
    this.sidewaysIndex = -1,
    this.hiddenIndexes = const {},
  });
}

/// 例示牌を混在できる表(符計算用)
Widget _fuGrid({
  required double firstColWidth,
  required List<_Cell> header,
  required List<List<_Cell>> rows,
}) {
  Widget miniTiles(
    String notation, {
    int sidewaysIndex = -1,
    Set<int> hiddenIndexes = const {},
  }) {
    final parsed = Tile.parse(notation);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < parsed.length; i++)
          Padding(
            padding: const EdgeInsets.only(left: 1),
            child: TileWidget(
              tile: hiddenIndexes.contains(i) ? null : parsed[i],
              width: 14,
              sideways: i == sidewaysIndex,
            ),
          ),
      ],
    );
  }

  Widget cellWidget(_Cell c, {required bool head, required int col}) {
    final style = TextStyle(
      color: head
          ? const Color(0xFFFFE082)
          : (col == 0 ? Colors.white70 : Colors.white),
      fontSize: 12.5,
      fontWeight: head ? FontWeight.bold : FontWeight.normal,
    );
    final text = Text(c.text, style: style);
    final tiles = c.ex == null
        ? null
        : miniTiles(
            c.ex!,
            sidewaysIndex: c.sidewaysIndex,
            hiddenIndexes: c.hiddenIndexes,
          );

    if (tiles == null) {
      return Text(
        c.text,
        textAlign: col == 0 ? TextAlign.left : TextAlign.right,
        style: style,
      );
    }
    if (col == 0) {
      // 1列目: テキスト左、例示牌を右端に
      return Row(
        children: [
          Flexible(child: text),
          const SizedBox(width: 4),
          tiles,
        ],
      );
    }
    // ヘッダーの符種など: テキストの横に小さく例示
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [text, const SizedBox(width: 3), tiles],
    );
  }

  TableRow buildRow(List<_Cell> cells, {required bool head}) {
    return TableRow(
      decoration: head ? const BoxDecoration(color: Color(0xFF1B4D2B)) : null,
      children: [
        for (var i = 0; i < cells.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: cellWidget(cells[i], head: head, col: i),
          ),
      ],
    );
  }

  return Table(
    border: TableBorder.all(color: Colors.white12, width: 0.5),
    defaultColumnWidth: const IntrinsicColumnWidth(),
    columnWidths: {0: FixedColumnWidth(firstColWidth)},
    children: [
      buildRow(header, head: true),
      for (final r in rows) buildRow(r, head: false),
    ],
  );
}

// ---------------- 牌一覧 ----------------

class TileListPage extends StatelessWidget {
  const TileListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // カテゴリ別に図柄を並べる
        _catRow('萬子(マンズ)', '1〜9萬', Tile.parse('123456789m')),
        _catRow('筒子(ピンズ)', '1〜9筒', Tile.parse('123456789p')),
        _catRow('索子(ソーズ)', '1〜9索', Tile.parse('123456789s')),
        _catRow('風牌(フォンパイ)', '東南西北', Tile.parse('1234z')),
        _catRow('三元牌(サンゲンパイ)', '白發中', Tile.parse('567z')),
        const Divider(color: Colors.white24, height: 22),
        // 数牌のグループ(重複を避けて代表牌で示す)
        _catRow('老頭牌(ロートー牌)', '各色の1・9', Tile.parse('19m19p19s')),
        _catRow('中張牌(チュンチャン牌)', '各色の2〜8', Tile.parse('2345678m')),
        _catRow('幺九牌(ヤオチュー牌)', '老頭牌+字牌', Tile.parse('19m1234567z')),
        const Divider(color: Colors.white24, height: 22),
        // 読み方(発音)
        _note('読み方(発音):'),
        const SizedBox(height: 6),
        _readingRow('数牌(1〜9)', [
          ('萬子', 'イー/リャン/サン/スー/ウー/ロー/チー/パー/キュー + マン'),
          ('筒子', '数字 + ピン(例: 3筒=サンピン)'),
          ('索子', '数字 + ソー(例: 3索=サンソー)'),
        ]),
        const SizedBox(height: 6),
        _readingRow('風牌', [
          ('東', 'トン'),
          ('南', 'ナン'),
          ('西', 'シャー'),
          ('北', 'ペー'),
        ]),
        const SizedBox(height: 6),
        _readingRow('三元牌', [('白', 'ハク'), ('發', 'ハツ'), ('中', 'チュン')]),
        const Divider(color: Colors.white24, height: 22),
        // 呼び名の組み合わせ例(牌 + その読み)
        _note('呼び名の組み合わせ例:'),
        const SizedBox(height: 6),
        _exampleRow('中張牌の萬子', '4m', 'スーマン'),
        _exampleRow('老頭牌の索子', '9s', 'キューソー'),
        _exampleRow('字牌の風牌(西)', '3z', 'シャー'),
        _exampleRow('字牌の三元牌(發)', '6z', 'ハツ'),
        _exampleRow('幺九牌(端の数牌)', '1p', 'イーピン'),
        _exampleRow('幺九牌(字牌)', '7z', 'チュン'),
        const SizedBox(height: 8),
        _note(
          '数牌=マンズ・ピンズ・ソーズ / 字牌=風牌+三元牌。'
          '中張牌はタンヤオ、幺九牌はチャンタ系で使う分類。',
        ),
      ],
    );
  }

  /// 読み方一覧の行: 見出し + (牌名, 読み) の並び
  Widget _readingRow(String head, List<(String, String)> items) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              head,
              style: const TextStyle(
                color: Color(0xFFFFE082),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '${it.$1} … ${it.$2}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
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

  /// カテゴリ行: 名前+説明(左)+ 図柄(横スクロール)
  Widget _catRow(String name, String desc, List<int> tiles) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 168,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  desc,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final t in tiles)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: TileWidget(tile: t, width: 20),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 読み例: 説明(左)+ 代表牌 + その発音(右)
  Widget _exampleRow(String label, String notation, String pron) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 200,
            child: Text(
              '・$label',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          for (final t in Tile.parse(notation))
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: TileWidget(tile: t, width: 20),
            ),
          const SizedBox(width: 6),
          Text(
            pron,
            style: const TextStyle(
              color: Color(0xFF80CBC4),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(String t) => Text(
    t,
    style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
  );
}

// ---------------- 役一覧 ----------------

class YakuListPage extends StatelessWidget {
  const YakuListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section('1翻'),
        _yaku('立直(リーチ)', '門前でテンパイ宣言。1000点供託', '門前のみ'),
        _yaku('一発', 'リーチ後1巡以内に和了', '門前のみ'),
        _yaku('門前清自摸和(ツモ)', '門前でツモ和了', '門前のみ'),
        _yaku(
          '平和(ピンフ)',
          '4面子が順子+役牌でない雀頭+両面待ち',
          '門前のみ',
          example: '234m567m22p345s678s',
        ),
        _yaku(
          '断么九(タンヤオ)',
          '2〜8の数牌のみ',
          '喰い下がりなし',
          example: '234m567m345s88p',
          meld: '222p',
        ),
        _yaku('一盃口', '同じ順子2組', '門前のみ', example: '223344m567p88s678s'),
        _yaku(
          '役牌',
          '三元牌・自風・場風の刻子',
          '',
          example: '234m567m789m55p',
          meld: '555z',
        ),
        _yaku('海底/河底', '最後のツモ/最後の打牌でロン', ''),
        _yaku('嶺上開花', 'カンの補充牌でツモ和了', ''),
        _yaku('搶槓', '他家の加槓牌でロン', ''),
        _section('2翻'),
        _yaku('ダブル立直', '第一打でリーチ', '門前のみ'),
        _yaku(
          '三色同順',
          '3種の同じ順子',
          '喰い下がり1翻',
          example: '234m234s678p55z',
          meld: '234p',
        ),
        _yaku(
          '一気通貫',
          '同種の123456789',
          '喰い下がり1翻',
          example: '123456m678s22p',
          meld: '789m',
        ),
        _yaku(
          '全帯么九(チャンタ)',
          '全面子に幺九牌',
          '喰い下がり1翻',
          example: '123m789m111z99s',
          meld: '123p',
        ),
        _yaku('七対子', '対子7組', '門前のみ・25符', example: '1122m4455p3377s66z'),
        _yaku(
          '対々和(トイトイ)',
          '4面子すべて刻子',
          '',
          example: '333m888s333z22p',
          meld: '555m',
        ),
        _yaku(
          '三暗刻',
          '暗刻3つ(残り1面子は鳴いてもよい)',
          '',
          example: '111m333m555p22z',
          meld: '678s',
        ),
        _yaku('三色同刻', '3種の同じ刻子', '', example: '333m333p678s55z', meld: '333s'),
        _yaku('三槓子', '槓3つ', ''),
        _yaku(
          '小三元',
          '三元牌の2刻子+1雀頭',
          '',
          example: '234m555z66z678s',
          meld: '777z',
        ),
        _yaku('混老頭', '幺九牌のみ', '', example: '111m999m111z99s', meld: '999p'),
        _section('3翻'),
        _yaku('二盃口', '一盃口2組', '門前のみ', example: '223344m556677p88s'),
        _yaku(
          '純全帯么九(純チャン)',
          '全面子に老頭牌',
          '喰い下がり2翻',
          example: '123m789m789s99s',
          meld: '123p',
        ),
        _yaku(
          '混一色(ホンイツ)',
          '1種の数牌+字牌',
          '喰い下がり2翻',
          example: '123456s555z11z',
          meld: '789s',
        ),
        _section('6翻'),
        _yaku(
          '清一色(チンイツ)',
          '1種の数牌のみ',
          '喰い下がり5翻',
          example: '234567888s99s',
          meld: '123s',
        ),
        _section('役満'),
        _yaku('国士無双', '幺九牌13種+いずれか1枚', '門前のみ', example: '19m19p19s1234567z1z'),
        _yaku('四暗刻', '暗刻4つ(門前限定)', '門前のみ', example: '111m333m555p888s22z'),
        _yaku('大三元', '三元牌3刻子', '', example: '234m555z666z11p', meld: '777z'),
        _yaku(
          '小四喜/大四喜',
          '風牌の4面子系',
          '',
          example: '111z222z333z11p',
          meld: '444z',
        ),
        _yaku('字一色', '字牌のみ', '', example: '111z222z333z55z', meld: '666z'),
        _yaku('清老頭', '老頭牌のみ', '', example: '111m999m111p99s', meld: '999p'),
        _yaku(
          '緑一色',
          '索子23468と發のみ',
          '',
          example: '222s333s444s66s',
          meld: '666z',
        ),
        _yaku(
          '九蓮宝燈',
          '同種で1112345678999+1枚',
          '門前のみ',
          example: '1112345678999s5s',
        ),
        _yaku('四槓子', '槓4つ', ''),
        _yaku('天和/地和', '配牌時/第一ツモで和了', ''),
        const SizedBox(height: 8),
        const Text(
          'ドラ: 表示牌の次の牌・赤5(各1翻)。役ではないので単独では和了不可。',
          style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
        ),
      ],
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      t,
      style: const TextStyle(
        color: Color(0xFFFFD54F),
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  /// example=手の内の牌姿。meld=1副露(3枚)を指定すると鳴き例になる。
  Widget _yaku(
    String name,
    String desc,
    String note, {
    String? example,
    String? meld,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 150,
                child: Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      desc,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                    if (note.isNotEmpty)
                      Text(
                        note,
                        style: const TextStyle(
                          color: Color(0xFF80CBC4),
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (example != null)
            Padding(
              padding: const EdgeInsets.only(left: 150, top: 3),
              child: _handExample(example, meld),
            ),
        ],
      ),
    );
  }

  /// 牌姿例(横スクロール)。meld があれば右に少し離して副露を表示。
  Widget _handExample(String concealed, String? meld) {
    Widget tile(int t) => Padding(
      padding: const EdgeInsets.only(right: 1.5),
      child: TileWidget(tile: t, width: 18),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final t in Tile.parse(concealed)) tile(t),
          if (meld != null) ...[
            const SizedBox(width: 10),
            // 副露(鳴き)は先頭を横向きにして区別
            for (var i = 0; i < Tile.parse(meld).length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 1.5),
                child: TileWidget(
                  tile: Tile.parse(meld)[i],
                  width: 18,
                  sideways: i == 0,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------- 符計算 ----------------

class FuTablePage extends StatelessWidget {
  const FuTablePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _note('符 = 副底20符 + 各要素の合計を、10符単位で切り上げ。'),
        const SizedBox(height: 10),
        _title('基本'),
        _grid(
          firstColWidth: 150,
          header: const ['要素', '符'],
          rows: const [
            ['副底(和了の基本)', '20'],
            ['門前ロン(加符)', '+10'],
            ['ツモ(平和以外)', '+2'],
          ],
        ),
        const SizedBox(height: 14),
        _title('面子(明刻/暗刻・槓)'),
        _fuGrid(
          firstColWidth: 150,
          // ヘッダーの符種は例示牌(1m)付き。明は1枚倒し、暗槓は両端裏向き
          header: const [
            _Cell('牌の種類'),
            _Cell('明刻', ex: '111m', sidewaysIndex: 0),
            _Cell('暗刻', ex: '111m'),
            _Cell('明槓', ex: '1111m', sidewaysIndex: 0),
            _Cell('暗槓', ex: '1111m', hiddenIndexes: {0, 3}),
          ],
          rows: const [
            [
              _Cell('中張牌(2〜8)', ex: '222m'),
              _Cell('2'),
              _Cell('4'),
              _Cell('8'),
              _Cell('16'),
            ],
            [
              _Cell('幺九牌(1・9・字)', ex: '111z'),
              _Cell('4'),
              _Cell('8'),
              _Cell('16'),
              _Cell('32'),
            ],
          ],
        ),
        const SizedBox(height: 6),
        _note('順子は0符。'),
        const SizedBox(height: 14),
        _title('雀頭'),
        _fuGrid(
          firstColWidth: 210,
          header: const [_Cell('雀頭'), _Cell('符')],
          rows: const [
            [_Cell('役牌(三元牌・自風・場風)', ex: '77z'), _Cell('+2')],
            [_Cell('連風牌(自風=場風)', ex: '11z'), _Cell('+2(合計4)')],
            [_Cell('その他', ex: '44p'), _Cell('0')],
          ],
        ),
        const SizedBox(height: 14),
        _title('待ちの形'),
        _fuGrid(
          firstColWidth: 200,
          header: const [_Cell('待ち'), _Cell('符')],
          rows: const [
            [_Cell('嵌張(かんちゃん)', ex: '35p'), _Cell('+2')],
            [_Cell('辺張(ぺんちゃん)', ex: '89m'), _Cell('+2')],
            [_Cell('単騎(たんき)', ex: '3z'), _Cell('+2')],
            [_Cell('両面(りゃんめん)・双碰', ex: '67s'), _Cell('0')],
          ],
        ),
        const SizedBox(height: 14),
        _title('特例'),
        _grid(
          firstColWidth: 200,
          header: const ['形', '符'],
          rows: const [
            ['平和ツモ', '20符固定'],
            ['平和ロン', '30符固定'],
            ['七対子', '25符固定'],
            ['喰い平和形(鳴きで20符)', '30符に繰上げ'],
          ],
        ),
        const SizedBox(height: 10),
        _note(
          '例: 門前ロン40符 = 20(副底)+10(門前ロン)+'
          '8(幺九暗刻)+2(嵌張)= 40符。',
        ),
      ],
    );
  }

  Widget _title(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      t,
      style: const TextStyle(
        color: Color(0xFFFFE082),
        fontSize: 15,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _note(String t) => Text(
    t,
    style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.4),
  );
}

// ---------------- 基本用語集 ----------------

/// 麻雀の基本用語集。「カタカナ(漢字)」+ 簡潔な説明の並び。
/// 役・点数・符・牌の分類など、他のページに詳細があるものは載せない。
class GlossaryPage extends StatelessWidget {
  const GlossaryPage({super.key});

  /// 用語カードの間隔と、2列にする最小カード幅
  static const double _gap = 20;
  static const double _minCardWidth = 320;

  @override
  Widget build(BuildContext context) {
    // ページ幅に応じて列数を決め、カードは常に幅いっぱいに割り付ける。
    // 幅が狭い(SE横など)ときは1列=全幅で、テキストが途中で折り返さない。
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final cols = ((w + _gap) / (_minCardWidth + _gap)).floor().clamp(1, 3);
        final cardWidth = (w - _gap * (cols - 1)) / cols;
        return _content(cardWidth);
      },
    );
  }

  Widget _content(double cardWidth) {
    Widget terms(List<(String, String)> items) => _terms(items, cardWidth);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section('進行'),
        terms(const [
          ('ハンチャン(半荘)', '東場と南場を通して打つ1試合の単位。東風戦は東場のみで終わる。'),
          ('ハイパイ(配牌)', '局の初めに配られる13枚の手牌。'),
          ('ツモ(自摸)', '山から牌を引くこと。引いた牌での和了(ツモ和了)も指す。'),
          ('ロン(栄和)', '他家の捨て牌で和了すること。'),
          ('アガリ(和了)', '手を完成させること。ツモとロンの2通り。'),
          (
            'テンパイ(聴牌)',
            'あと1枚で和了できる状態。ただしそのアガリ牌を自分の手牌・副露で'
                '全部使い切っている形は聴牌と認められない。',
          ),
          ('マチ(待ち)', 'テンパイしたときのアガリ牌(の種類)。'),
          (
            'ノーテン(不聴)',
            'テンパイしていない状態。流局時にテンパイ者へ聴牌料'
                '(場に3000点)を払う。',
          ),
          ('シャンテン(向聴)', 'テンパイまでの遠さを表す数。1シャンテン=あと1枚手が進めばテンパイ。'),
          (
            'フリテン(振聴)',
            '自分の待ち牌を自分で捨てている(または見逃した)状態。'
                'ロンできず、ツモ和了のみになる。',
          ),
          (
            'リュウキョク(流局)',
            'アガリ者が出ないまま山が尽きた局。聴牌料の授受をして'
                '次へ進む(途中流局はない)。',
          ),
          ('レンチャン(連荘)', '親が和了(または流局時テンパイ)して、次局も親を続けること。'),
          (
            'ホンバ(本場)',
            '連荘や流局で積まれるカウント('
                'ルールでは「積み場」)。'
                '1本場ごとに和了点へ300点加算。',
          ),
          (
            'キョウタク(供託)',
            'リーチ棒として場に出された1000点棒。以降のアガリ者が取得する'
                '(流局で半荘が終わったときはトップ者)。',
          ),
          ('オヤ(親)', '自風が東の人。得点が1.5倍だが、ツモられたときの支払いも大きい。'),
          ('コ(子)', '親以外の3人。'),
          ('ターチャ(他家)', '自分以外の3人。'),
          (
            'ジカゼ(自風)・バカゼ(場風)',
            '自分の席の風と、その場(東場・南場)の風。'
                '刻子にすると役牌になる。',
          ),
          ('カミチャ(上家)・トイメン(対面)・シモチャ(下家)', '左隣・正面・右隣の相手。チーは上家からしかできない。'),
        ]),
        _section('手牌の形'),
        terms(const [
          ('テハイ(手牌)', '自分の持ち牌13枚(ツモ直後は14枚)。'),
          (
            'メンツ(面子)',
            '3枚1組の完成形。順子か刻子(槓子も1面子と数える)。基本の和了形は'
                '4面子+雀頭(七対子・国士無双は例外)。',
          ),
          ('シュンツ(順子)', '同じ種類で連続する3枚(例: 4-5-6)。'),
          ('コーツ(刻子)', '同じ牌3枚。'),
          ('カンツ(槓子)', '同じ牌4枚。カンを宣言して初めて面子になる。'),
          ('トイツ(対子)', '同じ牌2枚。'),
          ('ターツ(搭子)', '順子まであと1枚の2枚(例: 4-5、4-6)。'),
          ('ジャントウ(雀頭)', '和了形に1組だけ必要な対子。アタマとも言う。'),
          ('メンゼン(門前清)', '一度も鳴いていない状態。略して門前。リーチや門前限定役の条件。'),
        ]),
        _section('鳴き'),
        terms(const [
          ('ナキ(鳴き)・フーロ(副露)', '他家の捨て牌をもらって面子を晒すこと。'),
          ('ポン(碰)', '捨て牌をもらって刻子を晒す。誰の捨て牌でもよい。'),
          ('チー(吃)', '捨て牌をもらって順子を晒す。上家からのみ。'),
          (
            'カン(槓)',
            '槓子を作ること。手の中の4枚=暗槓、ポンに足す=加槓、'
                '捨て牌から=大明槓。カンするとドラ表示牌が1枚増える(槓ドラ)。',
          ),
          (
            'クイカエ(食い換え)',
            '鳴いた直後に、その鳴きと合わせて面子を作れた牌(同じ牌や筋の牌)を'
                '切ること。反則で、アガリ放棄になる(このアプリでは切れない)。',
          ),
          (
            'アトヅケ(後付け)',
            '役を後から確定させる進め方(役牌を最後に鳴くなど)。'
                '認められている。',
          ),
        ]),
        _section('攻めと守り'),
        terms(const [
          ('ウケイレ(受け入れ)', 'ツモってくると手が進む牌(の種類と枚数)。多いほど手が早い。'),
          ('ダマテン(黙聴)', 'リーチせずにテンパイを隠しておくこと。'),
          ('オリ(降り)', '和了をあきらめ、安全な牌だけを切って放銃を避けること。'),
          (
            'ホウジュウ(放銃)',
            '自分の捨て牌でロンされること(加槓に搶槓された場合も放銃)。'
                '振り込みとも言う。',
          ),
          ('アンパイ(安全牌)', 'ロンされる可能性が低い牌。'),
          ('ゲンブツ(現物)', '相手が自分で捨てた牌。その相手には絶対にロンされない。'),
          (
            'スジ(筋)',
            '1-4-7・2-5-8・3-6-9の並び。捨て牌から両面待ちを消して'
                '通りやすさを読む手がかり。',
          ),
        ]),
        _section('場'),
        terms(const [
          ('ヤマ(山)', '伏せて積まれた牌。ここからツモる(Mリーグルールでは「壁牌」)。'),
          (
            'ワンパイ(王牌)',
            '山の末尾14枚。ツモには使わず、ドラ表示牌と'
                'カン用の嶺上牌を置く。',
          ),
          ('カワ(河)', '捨て牌を並べる場所。'),
          (
            'ジュンイテン(順位点)',
            '半荘の順位に従って加減算されるポイント(1位+50/2位+10/'
                '3位▲10/4位▲30)。俗に言うウマ。持ち点を30000点基準で'
                '換算するのが俗に言うオカ。',
          ),
        ]),
      ],
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 6),
    child: Text(
      t,
      style: const TextStyle(
        color: Color(0xFFFFD54F),
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  /// 用語カードの並び。幅に応じた列数で、カードは常に割付幅いっぱいに使う。
  Widget _terms(List<(String, String)> items, double cardWidth) {
    return Wrap(
      spacing: _gap,
      runSpacing: 10,
      children: [
        for (final it in items)
          SizedBox(
            width: cardWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  it.$1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  it.$2,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------- このアプリについて ----------------

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      // ページは左上寄せで置かれるので、全幅に広げて中央寄せを保つ
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text(
              '麻雀卓',
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                color: Color(0xFFFFE082),
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Wi-Fiでつながる四人打ちリーチ麻雀(Mリーグルール)',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 28),
            // copyright
            const Text(
              '© Daisuke Sawada',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            // 素材クレジット
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  '麻雀牌は麻雀豆腐さんの素材を使用しております。',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                _link('素材ページ', 'https://majandofu.com/mahjong-images'),
              ],
            ),
            const SizedBox(height: 16),
            // Mリーグ牌譜DB(牌譜閲覧モードのデータ)クレジット
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  '牌譜閲覧モードのデータは ',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                _link(
                  'Mリーグ試合情報データベース',
                  'https://github.com/konoui/m-league-game-db',
                ),
                const Text(
                  ' を使用しております。',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Copyright (c) 2025 konoui (MIT License)',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 16),
            // Mリーグ ファンアートガイドライン
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  '「Mリーグ」 ',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                _link(
                  'ファンアートの取り扱いに関するガイドライン',
                  'https://m-league.jp/news202406261200/',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _link(String text, String url) {
    return GestureDetector(
      onTap: () => _open(url),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF80CBC4),
          fontSize: 13,
          decoration: TextDecoration.underline,
          decorationColor: Color(0xFF80CBC4),
        ),
      ),
    );
  }
}
