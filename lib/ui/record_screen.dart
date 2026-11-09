/// 手動牌譜記録(docs/manual-paifu-design.md)。
///
/// [RecordSetupScreen](名前・開始局)→ [RecordScreen](記録本体)。
/// 左=4人の河(常時表示・照合の生命線)、右=牌パレット37種+?と宣言ボタン。
/// 記録の意味論はすべて [RecordEngine] が持ち、この画面は操作を流し込むだけ。
library;

import 'package:flutter/material.dart';

import '../engine/models.dart';
import '../engine/yaku.dart';
import '../engine/display_text.dart';
import '../engine/call_options.dart';
import '../engine/tile.dart';
import '../record/rec_paifu_store.dart';
import '../record/record_engine.dart';
import 'widgets/table_widgets.dart' show riverDisplayPlan;
import 'widgets/tile_widget.dart';

// ---------------- セットアップ ----------------

class RecordSetupScreen extends StatefulWidget {
  const RecordSetupScreen({super.key});

  @override
  State<RecordSetupScreen> createState() => _RecordSetupScreenState();
}

class _RecordSetupScreenState extends State<RecordSetupScreen> {
  final _names = List.generate(
    4,
    (_) => TextEditingController(),
    growable: false,
  );
  int _roundWind = 0;
  int _kyoku = 1;
  int _honba = 0;
  int _sticks = 0;
  final _scores = List.generate(
    4,
    (_) => TextEditingController(text: '25000'),
    growable: false,
  );

  bool get _isFresh =>
      _roundWind == 0 && _kyoku == 1 && _honba == 0 && _sticks == 0;

  @override
  void dispose() {
    for (final c in [..._names, ..._scores]) {
      c.dispose();
    }
    super.dispose();
  }

  void _start() {
    final names = [
      for (var i = 0; i < 4; i++)
        _names[i].text.trim().isEmpty ? seatWindName(i) : _names[i].text.trim(),
    ];
    final scores = _isFresh
        ? List.filled(4, 25000)
        : [for (final c in _scores) int.tryParse(c.text.trim()) ?? 25000];
    final engine = RecordEngine(
      names: names,
      roundWind: _roundWind,
      kyokuNum: _kyoku,
      honba: _honba,
      carriedSticks: _sticks,
      startScores: scores,
    );
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(builder: (_) => RecordScreen(engine: engine)),
    );
  }

  Widget _dropdown(
    String label,
    int value,
    int max,
    void Function(int) onChanged, {
    int min = 0,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(width: 4),
        DropdownButton<int>(
          value: value,
          dropdownColor: const Color(0xFF14401F),
          style: const TextStyle(color: Colors.white, fontSize: 13),
          items: [
            for (var i = min; i <= max; i++)
              DropdownMenuItem(value: i, child: Text('$i')),
          ],
          onChanged: (v) => onChanged(v!),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B2B14),
      appBar: AppBar(
        title: const Text('✍️ 牌譜記録', style: TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF10331C),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          children: [
            const Text(
              'プレイヤー名(起家から席順・空欄は 東家/南家/…)',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _names[i],
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: seatFromChiichaLabel(i),
                        labelStyle: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                        enabledBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF2E7D32)),
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF81C784)),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '開始 ',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    DropdownButton<int>(
                      value: _roundWind,
                      dropdownColor: const Color(0xFF14401F),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('東')),
                        DropdownMenuItem(value: 1, child: Text('南')),
                      ],
                      onChanged: (v) => setState(() => _roundWind = v!),
                    ),
                  ],
                ),
                _dropdown(
                  '',
                  _kyoku,
                  4,
                  (v) => setState(() => _kyoku = v),
                  min: 1,
                ),
                _dropdown('本場', _honba, 9, (v) => setState(() => _honba = v)),
                _dropdown('供託', _sticks, 9, (v) => setState(() => _sticks = v)),
              ],
            ),
            if (!_isFresh) ...[
              const SizedBox(height: 8),
              const Text(
                '持ち点(途中の局から記録する場合)',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  for (var i = 0; i < 4; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _scores[i],
                        keyboardType: TextInputType.number,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Color(0xFF2E7D32)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Color(0xFF81C784)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 16),
            Center(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                ),
                onPressed: _start,
                child: const Text('記録をはじめる'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 記録本体 ----------------

class RecordScreen extends StatefulWidget {
  final RecordEngine engine;

  /// 過去局の穴埋めモード([RecordEngine.replay] で作った局を開く)。
  /// 「?」の後埋めと手牌の写しだけができ、進行操作は出さない。
  final bool backfill;

  const RecordScreen({super.key, required this.engine, this.backfill = false});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  RecordEngine get eng => widget.engine;
  final String _gameId = RecPaifuStore.newId();
  bool _savedAnything = false;

  bool _riichiArmed = false; // 次の打牌がリーチ宣言牌
  bool _kanSelecting = false; // 次のパレットタップ=カンする牌種
  bool _doraAdding = false; // 次のパレットタップ=新ドラ
  int? _editSeat; // 配牌(手牌)編集モードの席
  int? _fillEventIndex; // 「?」後埋め対象のイベント位置
  bool _resultHidden = false; // 結果画面を一時的に閉じて牌を埋めている

  // ---------------- 操作 ----------------

  void _run(void Function() op) {
    try {
      op();
    } on StateError catch (e) {
      _toast(e.message);
    }
    // 局が終わっていない状態では結果画面の一時クローズを解除しておく
    // (次に局が終わったとき結果が必ず表示されるように)
    if (eng.phase != 'ended') _resultHidden = false;
    setState(() {});
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(milliseconds: 1600),
        ),
      );
  }

  void _onPalette(int? tile) {
    if (_fillEventIndex != null) {
      if (tile == null) return;
      final idx = _fillEventIndex!;
      _fillEventIndex = null;
      _run(() => eng.resolveUnknown(idx, tile));
      return;
    }
    if (_editSeat != null) {
      if (tile == null) return;
      _run(() => eng.editHand(_editSeat!, [tile]));
      return;
    }
    if (_doraAdding) {
      if (tile == null) return;
      _doraAdding = false;
      _run(() => eng.tapDora(tile));
      return;
    }
    if (_kanSelecting) {
      if (tile == null) return;
      _kanSelecting = false;
      final kind = Tile.normalize(tile);
      final hasPon = eng.seats[eng.currentSeat].melds.any(
        (m) => !m.isRun && !m.isKan && Tile.normalize(m.calledTile) == kind,
      );
      _run(() => hasPon ? eng.kakan(kind) : eng.ankan(kind));
      return;
    }
    switch (eng.phase) {
      case 'dora':
        if (tile == null) return;
        _run(() => eng.tapDora(tile));
      case 'draw':
        _run(() => eng.draw(tile));
      case 'discard':
        if (eng.seats[eng.currentSeat].riichi) {
          // リーチ中はツモ切りのみ(手出しはありえない)
          if (tile != null &&
              !eng.drawnUnknown &&
              eng.drawnTile != null &&
              Tile.normalize(tile) != Tile.normalize(eng.drawnTile!)) {
            _toast('リーチ中はツモ切りのみ(和了は[ツモ]・暗槓は[カン])');
            return;
          }
          _run(() => eng.discard(tile, tsumogiri: true));
          return;
        }
        final riichi = _riichiArmed;
        _riichiArmed = false;
        // ツモ牌と同じ牌のタップ=ツモ切り(連続2タップのショートカット)
        final tsumogiri =
            tile != null &&
            !eng.drawnUnknown &&
            eng.drawnTile != null &&
            Tile.normalize(tile) == Tile.normalize(eng.drawnTile!);
        _run(() => eng.discard(tile, riichi: riichi, tsumogiri: tsumogiri));
      case 'exhausted':
        _toast('山が無い — ロンか流局を選んで');
      case 'ended':
        break;
    }
  }

  void _onTsumogiriButton() {
    final riichi = _riichiArmed;
    _riichiArmed = false;
    _run(() => eng.discard(eng.drawnTile, riichi: riichi, tsumogiri: true));
  }

  Future<void> _onPon() async {
    final seat = await _pickSeat('ポンした人は?');
    if (seat == null) return;
    final lastTile = eng.lastDiscardInfo?.tile;
    var red = false;
    final kind = lastTile == null ? -1 : Tile.normalize(lastTile);
    if (kind >= 0 && !Tile.isHonor(kind) && Tile.number(kind) == 5) {
      final r = await _ask2('晒した2枚に赤5は入っている?', '赤入り', '赤なし');
      if (r == null) return;
      red = r;
    }
    _run(() => eng.pon(seat, red: red));
  }

  Future<void> _onChi() async {
    final lastTile = eng.lastDiscardInfo?.tile;
    if (lastTile == null) {
      _toast('チーできる打牌がない');
      return;
    }
    final kind = Tile.normalize(lastTile);
    if (Tile.isHonor(kind)) {
      _toast('字牌はチーできない');
      return;
    }
    final options = allChiForms(kind); // 形と赤5変種の列挙(対戦側と同モジュール)
    final picked = await showDialog<List<int>>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: const Color(0xFF14401F),
        title: const Text(
          'チーの形は?',
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
        children: [
          for (final o in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Row(
                children: [
                  for (final t in [
                    lastTile,
                    ...o,
                  ]..sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b)))
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: TileWidget(tile: t, width: 24),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null) return;
    _run(() => eng.chi(picked));
  }

  Future<void> _onKan() async {
    if (eng.phase == 'discard') {
      // 手番中: 暗槓 or 加槓 → 牌種をパレットで選ぶ
      setState(() => _kanSelecting = true);
      return;
    }
    final seat = await _pickSeat('カン(大明槓)した人は?');
    if (seat == null) return;
    _run(() => eng.daiminkan(seat));
  }

  Future<void> _onRon() async {
    // Mリーグはアガリ者が常に1人(頭ハネ)なのでダブロンの入力は無い
    final seat = await _pickSeat('ロンした人は?');
    if (seat == null || !mounted) return;
    final fill = await Navigator.push<_WinFillResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _WinFillScreen(
          engine: eng,
          seat: seat,
          winTile: null,
          isTsumo: false,
        ),
      ),
    );
    if (fill == null) return;
    _run(
      () => eng.ronWin(
        winner: seat,
        hand13: fill.hand13,
        ura: fill.ura,
        manualPoints: fill.manualPoints,
      ),
    );
  }

  Future<void> _onTsumo() async {
    if (eng.drawnUnknown || eng.drawnTile == null) {
      _toast('ツモ牌(和了牌)を先に入力・確定して');
      return;
    }
    final fill = await Navigator.push<_WinFillResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _WinFillScreen(
          engine: eng,
          seat: eng.currentSeat,
          winTile: eng.drawnTile,
          isTsumo: true,
        ),
      ),
    );
    if (fill == null) return;
    _run(
      () => eng.tsumoWin(
        hand13: fill.hand13,
        uraIndicators: fill.ura,
        childPay: fill.manualChild,
        dealerPay: fill.manualDealer,
      ),
    );
  }

  Future<void> _onRyukyoku() async {
    final tenpai = <int>{};
    // リーチ者は必ずテンパイ
    for (var i = 0; i < 4; i++) {
      if (eng.seats[i].riichi) tenpai.add(i);
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          backgroundColor: const Color(0xFF14401F),
          title: const Text(
            '流局 — テンパイしていた人は?',
            style: TextStyle(color: Colors.white, fontSize: 14),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 4; i++)
                CheckboxListTile(
                  dense: true,
                  title: Text(
                    eng.names[i],
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  value: tenpai.contains(i),
                  onChanged: eng.seats[i].riichi
                      ? null // リーチ者はノーテンにできない
                      : (v) => setDialog(
                          () => v == true ? tenpai.add(i) : tenpai.remove(i),
                        ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('確定'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    // テンパイ者の手牌開示を順に写す(スキップ可)
    final revealed = <int, List<int>>{};
    for (final seat in tenpai) {
      if (!mounted) return;
      final fill = await Navigator.push<_WinFillResult>(
        context,
        MaterialPageRoute(
          builder: (_) => _WinFillScreen(
            engine: eng,
            seat: seat,
            winTile: null,
            isTsumo: false,
            tenpaiMode: true,
          ),
        ),
      );
      if (fill?.hand13 != null) revealed[seat] = fill!.hand13!;
    }
    _run(() => eng.ryukyoku(tenpai.toList()..sort(), revealedHands: revealed));
  }

  /// 確定済みの過去局を開いて「?」と手牌の穴を埋める(→再エクスポート・保存)
  Future<void> _onBackfillPast() async {
    // 各局の未確定数を出すため、アーカイブを畳み込み直す
    final subs = [
      for (final a in eng.archives) RecordEngine.replay(a, eng.names),
    ];
    if (!mounted) return;
    final idx = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: const Color(0xFF14401F),
        title: const Text(
          'どの局の穴を埋める?',
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
        children: [
          for (var i = 0; i < subs.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: Builder(
                builder: (context) {
                  final u = subs[i].unknownCounts;
                  final state = u.marks == 0 && u.hidden == 0
                      ? '完全'
                      : '?${u.marks}・伏せ${u.hidden}';
                  return Text(
                    '${eng.archives[i].label}  ($state)',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  );
                },
              ),
            ),
        ],
      ),
    );
    if (idx == null || !mounted) return;
    final sub = subs[idx];
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RecordScreen(engine: sub, backfill: true),
      ),
    );
    // 編集結果をアーカイブへ書き戻し、その局だけ再エクスポートして保存
    eng.archives[idx].events = List.of(sub.events);
    eng.exportedKyokus[idx] = sub.exportKyokuJson();
    await _save(settle: false);
    setState(() {});
  }

  Future<int?> _pickSeat(String title) {
    return showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: const Color(0xFF14401F),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        children: [
          for (var i = 0; i < 4; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: Text(
                '${_windOf(i)} ${eng.names[i]}',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  Future<bool?> _ask2(String title, String yes, String no) {
    return showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: const Color(0xFF14401F),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, true),
            child: Text(yes, style: const TextStyle(color: Colors.white)),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, false),
            child: Text(no, style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _save({required bool settle}) async {
    final ok = await RecPaifuStore.save(
      _gameId,
      eng.buildGameJson(settle: settle),
    );
    if (ok) _savedAnything = true;
  }

  Future<void> _nextKyoku() async {
    _run(() => eng.nextKyoku());
    await _save(settle: false);
  }

  Future<void> _finishGame({required bool settle}) async {
    if (eng.exportedKyokus.isEmpty && eng.result == null) {
      Navigator.pop(context);
      return;
    }
    await _save(settle: settle);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _onMenu() async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: const Color(0xFF14401F),
        title: const Text(
          'メニュー',
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
        children: [
          for (final (key, label) in [
            ('dora', '新ドラを入力(カン後など)'),
            ('ryukyoku', '流局にする'),
            if (eng.archives.isNotEmpty) ('backfill', '前の局の穴を埋める'),
            ('finish', '試合終了として保存(順位精算)'),
            ('stop', '記録を保存して終了'),
            ('discardGame', 'この記録を破棄して終了'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, key),
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'dora':
        setState(() => _doraAdding = true);
      case 'ryukyoku':
        await _onRyukyoku();
      case 'backfill':
        await _onBackfillPast();
      case 'finish':
        await _finishGame(settle: true);
      case 'stop':
        await _finishGame(settle: false);
      case 'discardGame':
        final ok = await _ask2('この記録を破棄して終了する?', '破棄する', 'やめる');
        if (ok == true && mounted) {
          if (_savedAnything) await RecPaifuStore.deleteGame(_gameId);
          if (mounted) Navigator.pop(context);
        }
    }
  }

  // ---------------- 表示 ----------------

  String _windOf(int seat) => windNames[seatWindOf(seat, eng.dealer)];

  String get _guide {
    if (_fillEventIndex != null) return '「?」の牌を確定: パレットからタップ';
    if (_editSeat != null) {
      final s = eng.seats[_editSeat!];
      return '${eng.names[_editSeat!]} の手牌を写す(不明あと${s.unknown}枚)— 完了で戻る';
    }
    if (widget.backfill) {
      final u = eng.unknownCounts;
      return u.marks == 0 && u.hidden == 0
          ? 'この局は完全に埋まっている'
          : '河の「?」タップ / 行タップで手牌を写す(?${u.marks}・伏せ${u.hidden})';
    }
    if (eng.phase == 'ended' && _resultHidden) {
      final u = eng.unknownCounts;
      return '局終了 — 「?」と手牌を埋められる(?${u.marks}・伏せ${u.hidden})';
    }
    if (_doraAdding) return '新しいドラ牌をタップ(放送のドラ表示と同じ牌)';
    if (_kanSelecting) return 'カンする牌をタップ';
    if (_riichiArmed) return 'リーチ宣言牌をタップ';
    switch (eng.phase) {
      case 'dora':
        return 'ドラ牌をタップ(放送のドラ表示と同じ牌)';
      case 'draw':
        return '${eng.names[eng.currentSeat]} のツモ — 牌をタップ(見えなければ ?)';
      case 'discard':
        final name = eng.names[eng.currentSeat];
        if (eng.seats[eng.currentSeat].riichi) {
          return '$name はリーチ中 — もう一度タップでツモ切り([ツモ]和了 / [カン]暗槓)';
        }
        return eng.drawnUnknown
            ? '$name の打牌 — 切った牌をタップ(ツモ切りは[ツモ切り])'
            : '$name の打牌 — 同じ牌でツモ切り / 別の牌で手出し';
      case 'exhausted':
        return '山切れ — ロン(河底)か流局';
      case 'ended':
        return '局終了';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final ended = eng.phase == 'ended';
    return PopScope(
      canPop: widget.backfill,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onMenu();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B2B14),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _topBar(),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _leftPanel()),
                        _rightPanel(),
                      ],
                    ),
                  ),
                ],
              ),
              if (ended && !_resultHidden && !widget.backfill) _resultOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final inEdit =
        _editSeat != null ||
        _fillEventIndex != null ||
        _doraAdding ||
        _kanSelecting ||
        _riichiArmed;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: const Color(0xFF10331C),
      child: Row(
        children: [
          Text(
            '${kyokuLabel(eng.roundWind, eng.kyokuNum, honba: eng.honba, alwaysHonba: true, honbaSep: ' ')} 供託${eng.sticksOnTable}'
            ' 残り${eng.wallRemaining}',
            style: const TextStyle(
              color: Color(0xFF81C784),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 8),
          // ドラ表示(ドラ牌そのもの)
          for (final d in eng.doraTiles)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: TileWidget(tile: d, width: 14),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _guide,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: inEdit ? const Color(0xFFFFD54F) : Colors.white70,
                fontSize: 11,
              ),
            ),
          ),
          if (inEdit)
            _miniButton('完了', () {
              setState(() {
                _editSeat = null;
                _fillEventIndex = null;
                _doraAdding = false;
                _kanSelecting = false;
                _riichiArmed = false;
              });
            })
          else if (widget.backfill)
            _miniButton('✓ 完了(戻る)', () => Navigator.pop(context))
          else ...[
            if (eng.phase == 'ended' && _resultHidden)
              _miniButton('結果へ', () => setState(() => _resultHidden = false)),
            _miniButton('↩︎ 取消', eng.canUndo ? () => _run(eng.undo) : null),
            _miniButton('⋮', _onMenu),
          ],
        ],
      ),
    );
  }

  Widget _miniButton(String label, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: onTap == null
                ? const Color(0xFF163A22)
                : const Color(0xFF1E5A2E),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: onTap == null ? Colors.white24 : Colors.white,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }

  Widget _leftPanel() {
    return Column(
      children: [for (var i = 0; i < 4; i++) Expanded(child: _seatRow(i))],
    );
  }

  Widget _seatRow(int seat) {
    final s = eng.seats[seat];
    final isTurn =
        !['dora', 'ended'].contains(eng.phase) && eng.currentSeat == seat;
    final editing = _editSeat == seat;
    final doraKinds = TileWidget.doraKindsFrom(eng.doraIndicators);
    return InkWell(
      onTap: () => setState(() => _editSeat = editing ? null : seat),
      child: Container(
        margin: const EdgeInsets.fromLTRB(4, 2, 2, 0),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: editing
              ? const Color(0xFF2A5A1E)
              : isTurn
              ? const Color(0xFF1A4A26)
              : const Color(0xFF123420),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isTurn ? const Color(0xFF81C784) : const Color(0xFF1E5A2E),
            width: isTurn ? 1.4 : 0.8,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _windOf(seat),
                  style: const TextStyle(
                    color: Color(0xFFFFB74D),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    eng.names[seat],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${eng.displayScore(seat)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
                if (s.riichi)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Text(
                      'リーチ',
                      style: TextStyle(
                        color: Color(0xFFEF5350),
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                const Spacer(),
                // 副露(コンパクト表示)
                for (final m in s.melds) ...[
                  const SizedBox(width: 3),
                  for (final t in m.tiles.take(m.isKan ? 4 : 3))
                    TileWidget(tile: t, width: 10),
                ],
                if (s.unknown > 0 || editing)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      '伏${s.unknown}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 9,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 1),
            Expanded(
              child: editing
                  // 配牌編集モード: 既知の手牌を大きめに表示
                  ? Wrap(
                      spacing: 1,
                      runSpacing: 1,
                      children: [
                        for (final t in s.known) TileWidget(tile: t, width: 16),
                        for (var i = 0; i < s.unknown; i++)
                          const TileWidget(tile: null, width: 16),
                      ],
                    )
                  : isTurn && (eng.phase == 'draw' || eng.phase == 'discard')
                  // 手番中(ツモ〜打牌・鳴き後の打牌待ち)は手牌+ツモ牌を表示
                  ? _handView(s)
                  // 河の表示規則(鳴かれた牌は非表示・宣言牌が鳴かれたら
                  // 次の打牌を横向き)は対戦・ビューアと共通(riverDisplayPlan)
                  : _riverView(s, doraKinds),
            ),
          ],
        ),
      ),
    );
  }

  /// 河の表示: 実卓の6枚区切りに合わせ、6牌ごとの塊の間に小さな余白を入れる。
  /// 改行も塊単位になるので6の倍数で折り返し、実卓の6×n段の河と対応が取れる。
  Widget _riverView(RecSeat s, Set<int> doraKinds) {
    final plan = riverDisplayPlan(
      length: s.river.length,
      calledAway: (i) => s.river[i].called,
      riichi: (i) => s.river[i].riichi,
    );
    return Wrap(
      spacing: 4,
      runSpacing: 1,
      children: [
        for (var g = 0; g < plan.length; g += 6)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (j, p) in plan.skip(g).take(6).indexed) ...[
                if (j > 0) const SizedBox(width: 1),
                _riverTile(s.river[p.index], p.sideways, doraKinds),
              ],
            ],
          ),
      ],
    );
  }

  /// 手番中の手牌表示: 既知牌+伏せ牌、ツモ牌は間隔を空けて横に(緑グロー)
  Widget _handView(RecSeat s) {
    const w = 16.0;
    return Wrap(
      spacing: 1,
      runSpacing: 1,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final t in s.known) TileWidget(tile: t, width: w),
        for (var i = 0; i < s.unknown; i++)
          const TileWidget(tile: null, width: w),
        const SizedBox(width: 10),
        if (eng.hasDrawn)
          eng.drawnUnknown
              ? Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: const Color(0xFF7CC47F)),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const TileWidget(tile: null, width: w),
                      const Text(
                        '?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                )
              : TileWidget(tile: eng.drawnTile, width: w, drawn: true)
        else
          // ツモ待ち: ツモ牌の置き場を点線枠で示す
          Container(
            width: w,
            height: w * TileWidget.aspect,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: Colors.white24),
            ),
          ),
      ],
    );
  }

  Widget _riverTile(RecRiverTile r, bool sideways, Set<int> doraKinds) {
    const w = 13.0;
    final tile = r.tile;
    if (tile == null) {
      // 「?」(不明打牌)はタップで後埋め
      return InkWell(
        onTap: () => setState(() => _fillEventIndex = r.eventIndex),
        child: Stack(
          alignment: Alignment.center,
          children: [
            TileWidget(tile: null, width: w, sideways: sideways),
            const Text(
              '?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }
    return TileWidget(
      tile: tile,
      width: w,
      sideways: sideways,
      // 対戦時と同様、ツモ切りは薄い灰色にして手出しと見分ける
      muted: r.tsumogiri,
      dora: doraKinds.contains(Tile.normalize(tile)),
    );
  }

  Widget _rightPanel() {
    return LayoutBuilder(
      builder: (context, outer) {
        return Container(
          width: 296,
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
          child: Column(
            children: [
              Expanded(
                child: _TilePalette(
                  onTap: _onPalette,
                  countOf: eng.visibleCount,
                  redSeen: eng.redSeen,
                ),
              ),
              if (!widget.backfill) ...[
                const SizedBox(height: 2),
                _actionButtons(),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _actionButtons() {
    final discard = eng.phase == 'discard';
    final react = eng.canReactToLastDiscard;
    final myRiichi = discard && eng.seats[eng.currentSeat].riichi;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _action(
                'ツモ切り',
                discard ? _onTsumogiriButton : null,
                color: const Color(0xFF1E5A2E),
              ),
            ),
            const SizedBox(width: 3),
            Expanded(
              child: _action(
                _riichiArmed ? 'リーチ中止' : 'リーチ',
                discard && !myRiichi
                    ? () => setState(() => _riichiArmed = !_riichiArmed)
                    : null,
                color: _riichiArmed
                    ? const Color(0xFFB71C1C)
                    : const Color(0xFF1E5A2E),
              ),
            ),
            const SizedBox(width: 3),
            Expanded(
              child: _action(
                '流局',
                eng.phase == 'exhausted' || react ? _onRyukyoku : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Expanded(
              child: _action('ロン', react || eng.canChankan ? _onRon : null),
            ),
            const SizedBox(width: 3),
            Expanded(child: _action('ツモ', discard ? _onTsumo : null)),
            const SizedBox(width: 3),
            Expanded(child: _action('ポン', react ? _onPon : null)),
            const SizedBox(width: 3),
            Expanded(child: _action('チー', react ? _onChi : null)),
            const SizedBox(width: 3),
            Expanded(child: _action('カン', react || discard ? _onKan : null)),
          ],
        ),
      ],
    );
  }

  Widget _action(String label, VoidCallback? onTap, {Color? color}) {
    return SizedBox(
      height: 30,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: color ?? const Color(0xFF1E5A2E),
          disabledBackgroundColor: const Color(0xFF163A22),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onPressed: onTap,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: onTap == null ? Colors.white24 : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _resultOverlay() {
    final r = eng.result!;
    final lines = <String>[];
    if (r.type == 'win') {
      for (final w in r.wins) {
        final summary = winSummary(
          name: eng.names[w.seat],
          isTsumo: w.fromSeat < 0,
          loserName: w.fromSeat < 0 ? '' : eng.names[w.fromSeat],
          points: w.declared,
        );
        if (w.score != null) {
          final yaku = [
            for (final y in orderYakuForDisplay(w.score!.yaku))
              yakuItemLabel(
                y,
                isYakuman: w.score!.isYakuman,
                withHanSuffix: false,
              ),
          ].join('・');
          lines.add('$summary — $yaku');
        } else {
          lines.add('$summary(手動入力)');
        }
      }
    } else {
      lines.add(
        '流局 — ${tenpaiSummary([for (final s in r.tenpaiSeats) eng.names[s]])}',
      );
    }
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF14401F),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2E7D32)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${kyokuLabel(eng.roundWind, eng.kyokuNum, honba: eng.honba, alwaysHonba: true, honbaSep: ' ')} 終了',
              style: const TextStyle(
                color: Color(0xFF81C784),
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            for (final l in lines)
              Text(
                l,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < 4; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      children: [
                        Text(
                          eng.names[i],
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        ),
                        Text(
                          '${r.endScores[i]}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          formatSignedPoints(r.scoreChanges[i], zero: '+0'),
                          style: TextStyle(
                            color: r.scoreChanges[i] >= 0
                                ? const Color(0xFF81C784)
                                : const Color(0xFFEF9A9A),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: () => _run(eng.undo),
                  child: const Text('↩︎ 取消'),
                ),
                TextButton(
                  // 開示で判明した牌で「?」や手牌を埋めてから次局へ進める
                  onPressed: () => setState(() => _resultHidden = true),
                  child: const Text('牌を埋める'),
                ),
                const SizedBox(width: 8),
                // 南4局(以降)で親が流れたら半荘終了(西入は無い)。
                // 親の連荘(和了・テンパイ)は規定により強制
                // (Mリーグにアガリやめ・テンパイやめは無い)。
                if (!(eng.isAllLastEnd && !r.dealerContinues)) ...[
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                    ),
                    onPressed: _nextKyoku,
                    child: const Text('次の局へ'),
                  ),
                  const SizedBox(width: 8),
                ],
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF2E7D32)),
                  ),
                  onPressed: () => _finishGame(settle: true),
                  child: const Text(
                    '試合終了(精算)',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------- 牌パレット ----------------

class _TilePalette extends StatelessWidget {
  final void Function(int? tile) onTap;
  final int Function(int kind) countOf;
  final bool Function(int red) redSeen;

  const _TilePalette({
    required this.onTap,
    required this.countOf,
    required this.redSeen,
  });

  @override
  Widget build(BuildContext context) {
    // 10列×4行: 1-9m 0m / 1-9p 0p / 1-9s 0s / 字牌7 + ? (+空2)
    final rows = <List<int?>>[
      [for (var i = 0; i < 9; i++) i, Tile.red5m],
      [for (var i = 9; i < 18; i++) i, Tile.red5p],
      [for (var i = 18; i < 27; i++) i, Tile.red5s],
      [for (var i = 27; i < 34; i++) i, -1, null, null], // -1 = 「?」
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final w = ((c.maxWidth - 9 * 2) / 10).clamp(16.0, 30.0);
        final h = (c.maxHeight - 3 * 2) / 4;
        final tileW = (h / TileWidget.aspect).clamp(16.0, w);
        return Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final row in rows)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final t in row)
                    t == null
                        ? SizedBox(width: tileW)
                        : t == -1
                        ? _unknownButton(tileW)
                        : _tileButton(t, tileW),
                ],
              ),
          ],
        );
      },
    );
  }

  Widget _tileButton(int tile, double w) {
    final used = Tile.isRed(tile)
        ? (redSeen(tile) ? 1 : 0)
        : countOf(Tile.normalize(tile));
    final exhausted = Tile.isRed(tile) ? used >= 1 : used >= 4;
    return GestureDetector(
      onTap: () => onTap(tile),
      child: Opacity(
        opacity: exhausted ? 0.25 : 1,
        child: TileWidget(tile: tile, width: w),
      ),
    );
  }

  Widget _unknownButton(double w) {
    return GestureDetector(
      onTap: () => onTap(null),
      child: Container(
        width: w,
        height: w * TileWidget.aspect,
        decoration: BoxDecoration(
          color: const Color(0xFF3E3226),
          borderRadius: BorderRadius.circular(w * 0.09),
          border: Border.all(color: const Color(0xFF8A5A10)),
        ),
        alignment: Alignment.center,
        child: const Text(
          '?',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ---------------- 和了手牌・テンパイ手牌の補完 ----------------

class _WinFillResult {
  final List<int>? hand13; // null = 手牌欠損(手動点数)
  final List<int> ura;
  final int? manualPoints; // ロン申告点
  final int? manualChild; // ツモ子払い
  final int? manualDealer; // ツモ親払い

  const _WinFillResult({
    required this.hand13,
    this.ura = const [],
    this.manualPoints,
    this.manualChild,
    this.manualDealer,
  });
}

class _WinFillScreen extends StatefulWidget {
  final RecordEngine engine;
  final int seat;
  final int? winTile; // ツモのときのみ(表示用)
  final bool isTsumo;
  final bool tenpaiMode; // 流局テンパイの開示(和了ではない)

  const _WinFillScreen({
    required this.engine,
    required this.seat,
    required this.winTile,
    required this.isTsumo,
    this.tenpaiMode = false,
  });

  @override
  State<_WinFillScreen> createState() => _WinFillScreenState();
}

class _WinFillScreenState extends State<_WinFillScreen> {
  late final List<int> _tiles; // 手の内(和了牌を除く)
  final List<int> _ura = [];
  bool _uraMode = false;

  RecordEngine get eng => widget.engine;
  int get _capacity => 13 - 3 * eng.seats[widget.seat].melds.length;
  bool get _complete => _tiles.length >= _capacity;
  bool get _winnerRiichi => eng.seats[widget.seat].riichi;

  @override
  void initState() {
    super.initState();
    _tiles = List.of(eng.seats[widget.seat].known);
  }

  void _onPalette(int? tile) {
    if (tile == null) return;
    setState(() {
      if (_uraMode) {
        if (_ura.length < 5) _ura.add(tile);
      } else if (_tiles.length < _capacity) {
        _tiles.add(tile);
        _tiles.sort((a, b) => Tile.sortKey(a) - Tile.sortKey(b));
      }
    });
  }

  int _extraCount(int kind) {
    // パレットのグレーアウト: 場に見えている分 + この画面で足した分。
    // ただし元々knownだった牌は場の集計に含まれているので二重に数えない。
    final known = eng.seats[widget.seat].known;
    var extra = 0;
    void count(List<int> ts) {
      for (final t in ts) {
        if (Tile.normalize(t) == kind) extra++;
      }
    }

    count(_tiles);
    count(_ura);
    var base = eng.visibleCount(kind);
    for (final t in known) {
      if (Tile.normalize(t) == kind) base--;
    }
    return base + extra;
  }

  bool _redSeenHere(int red) {
    if (_tiles.contains(red) || _ura.contains(red)) return true;
    if (eng.seats[widget.seat].known.contains(red)) return false;
    return eng.redSeen(red);
  }

  Future<void> _manual() async {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    final isDealer = widget.seat == eng.dealer;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF14401F),
        title: Text(
          widget.isTsumo ? 'ツモの支払いを手動入力' : 'ロンの申告点を手動入力',
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: c1,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: widget.isTsumo
                    ? (isDealer ? '全員の支払い(例 4000)' : '子の支払い(例 2000)')
                    : '申告点(例 8000)',
                labelStyle: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
              ),
            ),
            if (widget.isTsumo && !isDealer)
              TextField(
                controller: c2,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: '親の支払い(例 3900)',
                  labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final v1 = int.tryParse(c1.text.trim()) ?? 0;
    final v2 = int.tryParse(c2.text.trim());
    Navigator.pop(
      context,
      widget.isTsumo
          ? _WinFillResult(
              hand13: null,
              ura: _ura,
              manualChild: v1,
              manualDealer: v2,
            )
          : _WinFillResult(hand13: null, ura: _ura, manualPoints: v1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.tenpaiMode
        ? '${eng.names[widget.seat]} のテンパイ手牌'
        : '${eng.names[widget.seat]} の和了手牌';
    return Scaffold(
      backgroundColor: const Color(0xFF0B2B14),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: const Color(0xFF10331C),
              child: Row(
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Color(0xFF81C784),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _uraMode
                          ? '裏ドラ表示牌をタップ(${_ura.length}枚)'
                          : 'あと${(_capacity - _tiles.length).clamp(0, 13)}枚 — '
                                'パレットから写す(牌タップで戻せる)',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'キャンセル',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ),
                ],
              ),
            ),
            // 手の内+和了牌の表示
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _tiles.length; i++)
                    GestureDetector(
                      onTap: () => setState(() => _tiles.removeAt(i)),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 2),
                        child: TileWidget(tile: _tiles[i], width: 24),
                      ),
                    ),
                  for (var i = _tiles.length; i < _capacity; i++)
                    const Padding(
                      padding: EdgeInsets.only(right: 2),
                      child: TileWidget(tile: null, width: 24),
                    ),
                  if (widget.winTile != null) ...[
                    const SizedBox(width: 8),
                    TileWidget(tile: widget.winTile, width: 24, drawn: true),
                  ],
                  if (_winnerRiichi && !widget.tenpaiMode) ...[
                    const SizedBox(width: 12),
                    const Text(
                      '裏:',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    for (var i = 0; i < _ura.length; i++)
                      GestureDetector(
                        onTap: () => setState(() => _ura.removeAt(i)),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 2),
                          child: TileWidget(tile: _ura[i], width: 24),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _TilePalette(
                  onTap: _onPalette,
                  countOf: _extraCount,
                  redSeen: _redSeenHere,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_winnerRiichi && !widget.tenpaiMode) ...[
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: _uraMode
                              ? const Color(0xFFFFD54F)
                              : const Color(0xFF2E7D32),
                        ),
                      ),
                      onPressed: () => setState(() => _uraMode = !_uraMode),
                      child: Text(
                        _uraMode ? '手牌に戻る' : '裏ドラを写す',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                    ),
                    onPressed: _complete
                        ? () => Navigator.pop(
                            context,
                            _WinFillResult(hand13: List.of(_tiles), ura: _ura),
                          )
                        : null,
                    child: Text(
                      widget.tenpaiMode ? '開示を確定' : '和了確定(自動計算)',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (!widget.tenpaiMode) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _manual,
                      child: const Text(
                        '手牌が読み取れない(点数を手動入力)',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
