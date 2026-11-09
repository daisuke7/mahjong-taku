import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/display_text.dart';
import '../engine/tile.dart';
import '../paifu/favorite_store.dart';
import '../paifu/my_paifu_source.dart';
import '../paifu/my_paifu_store.dart';
import '../paifu/paifu_db.dart';
import '../paifu/paifu_store.dart';
import '../paifu/replay_session.dart';
import '../record/rec_paifu_store.dart';
import 'game_screen.dart';
import 'record_screen.dart';

/// 牌譜ビューアの選択フロー:
/// シーズン → ステージ → 試合日 → 試合 → 視点の選手 → 再生。
/// お気に入り局(★)を含む項目にはタイトル横に★を出す。
class PaifuBrowserScreen extends StatefulWidget {
  const PaifuBrowserScreen({super.key});

  @override
  State<PaifuBrowserScreen> createState() => _PaifuBrowserScreenState();
}

class _PaifuBrowserScreenState extends State<PaifuBrowserScreen> {
  PaifuDb? _db;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      await FavoriteStore.ensureLoaded();
      final f = await PaifuStore.dbFile();
      final db = PaifuDb.open(f.path);
      if (!mounted) {
        db.close();
        return;
      }
      setState(() => _db = db);
    } catch (e) {
      if (mounted) setState(() => _error = '牌譜DBを開けません: $e');
    }
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final db = _db;
    if (db == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('牌譜ビューア')),
        body: Center(
          child: Text(
            _error ?? '読み込み中…',
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    // 入口はグループ分けしたメニュー(項目が増えてシーズン一覧が埋もれないように)
    return _PickScaffold(
      title: '牌譜ビューア',
      children: [
        _PickTile(
          label: '🏆 Mリーグの試合',
          subtitle: 'シーズン → ステージ → 試合日 → 試合 → 視点を選んで再生',
          starred: FavoriteStore.gameIds.isNotEmpty,
          onTap: () => _push(context, _SeasonPickScreen(db: db)),
        ),
        _PickTile(
          label: '🀄 自分の対局・記録した牌譜',
          subtitle: 'この端末で打った対局と、手動で記録した牌譜',
          onTap: () => _push(context, const _OwnPickScreen()),
        ),
        _PickTile(
          label: '🔎 局を探す',
          subtitle: 'お気に入り局・役満や一発などのアガリ・通らなかったリーチ',
          onTap: () => _push(context, _FindPickScreen(db: db)),
        ),
      ],
    );
  }

  Future<void> _push(BuildContext context, Widget screen) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) setState(() {}); // 戻ってきたら★を更新
  }
}

// ---------------- Mリーグの試合(シーズン一覧) ----------------

class _SeasonPickScreen extends StatefulWidget {
  final PaifuDb db;

  const _SeasonPickScreen({required this.db});

  @override
  State<_SeasonPickScreen> createState() => _SeasonPickScreenState();
}

class _SeasonPickScreenState extends State<_SeasonPickScreen> {
  bool _favOnly = false; // ★: お気に入り局のある試合だけをフラットに列挙

  @override
  Widget build(BuildContext context) {
    final db = widget.db;
    final favLocs = db.locateGames(FavoriteStore.gameIds);
    // ☆/★トグル: ★ではお気に入り局のある試合だけのフラット一覧に切り替える
    final toggle = IconButton(
      icon: Icon(
        _favOnly ? Icons.star : Icons.star_border,
        color: const Color(0xFFFFD54F),
      ),
      tooltip: _favOnly ? 'すべての試合から選ぶ' : 'お気に入り局のある試合だけ',
      onPressed: () => setState(() => _favOnly = !_favOnly),
    );
    if (_favOnly) {
      return _PickScaffold(
        title: 'お気に入り局のある試合',
        actions: [toggle],
        emptyText: 'お気に入り局はまだありません。\n再生中に☆を押すとここに並びます。',
        children: favoriteGameTiles(context, db, favLocs, _pushAndRefresh),
      );
    }
    return _PickScaffold(
      title: 'シーズンを選ぶ',
      actions: [toggle],
      children: [
        for (final s in db.seasons())
          _PickTile(
            label: s.label,
            starred: favLocs.any((l) => l.seasonId == s.id),
            onTap: () =>
                _pushAndRefresh(context, _StagePickScreen(db: db, season: s)),
          ),
      ],
    );
  }

  Future<void> _pushAndRefresh(BuildContext context, Widget screen) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) setState(() {}); // 戻ってきたら★を更新
  }
}

/// お気に入り局のある試合のフラット一覧(新しい試合日順)
List<Widget> favoriteGameTiles(
  BuildContext context,
  PaifuDb db,
  List<({String mid, int seasonId, int stageId, String date})> favLocs,
  Future<void> Function(BuildContext, Widget) push,
) {
  // シーズン/ステージのラベルを引けるようにしておく
  final seasonLabel = <int, String>{};
  final stageOfSeason = <int, (int, String)>{}; // stageId → (seasonId, label)
  for (final s in db.seasons()) {
    seasonLabel[s.id] = s.label;
    for (final st in db.stages(s.id)) {
      stageOfSeason[st.id] = (s.id, st.label);
    }
  }
  final locs = [...favLocs]..sort((a, b) => b.date.compareTo(a.date));
  final tiles = <Widget>[];
  for (final loc in locs) {
    final games = db.games(loc.stageId, loc.date);
    final game = games.where((g) => g.mLeagueGameId == loc.mid).firstOrNull;
    if (game == null) continue; // DB更新で消えた試合のお気に入りは出さない
    final matchLabel = game.label(showTable: db.hasMultipleTables(loc.date));
    final (_, stageLabel) = stageOfSeason[loc.stageId] ?? (0, '');
    tiles.add(
      _PickTile(
        label:
            '${seasonLabel[loc.seasonId] ?? ''} $stageLabel '
            '${loc.date} $matchLabel',
        subtitle: [for (final p in db.gamePlayers(game.id)) p.name].join(' / '),
        starred: true,
        onTap: () => push(
          context,
          _PlayerPickScreen(db: db, game: game, matchLabel: matchLabel),
        ),
      ),
    );
  }
  return tiles;
}

// ---------------- 自分の対局・記録した牌譜 ----------------

class _OwnPickScreen extends StatelessWidget {
  const _OwnPickScreen();

  @override
  Widget build(BuildContext context) {
    return _PickScaffold(
      title: '自分の対局・記録した牌譜',
      children: [
        _PickTile(
          label: '🀄 自分の対局',
          subtitle: 'この端末で打った対局の牌譜(ホスト側で自動保存)',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const _MyGamePickScreen()),
          ),
        ),
        _PickTile(
          label: '✍️ 記録した牌譜',
          subtitle: '放送対局などを見ながら手動で記録した牌譜',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const _RecGamePickScreen()),
          ),
        ),
      ],
    );
  }
}

// ---------------- 局を探す ----------------

class _FindPickScreen extends StatefulWidget {
  final PaifuDb db;

  const _FindPickScreen({required this.db});

  @override
  State<_FindPickScreen> createState() => _FindPickScreenState();
}

class _FindPickScreenState extends State<_FindPickScreen> {
  @override
  Widget build(BuildContext context) {
    final db = widget.db;
    final favLocs = db.locateGames(FavoriteStore.gameIds);
    return _PickScaffold(
      title: '局を探す',
      children: [
        _PickTile(
          label: '★ お気に入り局のある試合',
          subtitle: favLocs.isEmpty
              ? 'まだありません。再生中に☆を押すとここに並びます'
              : '${favLocs.length}試合',
          starred: favLocs.isNotEmpty,
          onTap: () => _pushAndRefresh(
            context,
            Builder(
              builder: (ctx) => _PickScaffold(
                title: 'お気に入り局のある試合',
                emptyText: 'お気に入り局はまだありません。\n再生中に☆を押すとここに並びます。',
                children: favoriteGameTiles(
                  ctx,
                  db,
                  db.locateGames(FavoriteStore.gameIds),
                  (c, w) => Navigator.push(
                    c,
                    MaterialPageRoute<void>(builder: (_) => w),
                  ),
                ),
              ),
            ),
          ),
        ),
        for (final kind in AgariSearchKind.values)
          _PickTile(
            label: '${_agariIcon(kind)} ${kind.label}',
            subtitle: '${kind.description}(アガリ者の視点で局を再生)',
            onTap: () =>
                _pushAndRefresh(context, _AgariListScreen(db: db, kind: kind)),
          ),
        _PickTile(
          label: '⚡ 通らなかったリーチ',
          subtitle: '宣言牌をロンされたリーチの一覧(リーチ者の視点で局を再生)',
          onTap: () => _pushAndRefresh(context, _FailedRiichiScreen(db: db)),
        ),
        _PickTile(
          label: '🌅 天和・地和チャンス',
          subtitle: '配牌でテンパイしていた局の一覧(その人の視点で局を再生)',
          onTap: () => _pushAndRefresh(context, _HaipaiTenpaiScreen(db: db)),
        ),
        _PickTile(
          label: '😱 見逃しからのロン和了',
          subtitle: 'ロンできる牌を見逃した後、同じ局でロン和了した一覧(和了者の視点で再生)',
          onTap: () => _pushAndRefresh(context, _MissedRonScreen(db: db)),
        ),
        _PickTile(
          label: '🏁 全員集合からの決着',
          subtitle: 'オーラス開始時に全員2万点台で、その局で試合が決まった一覧(和了者の視点で再生)',
          onTap: () => _pushAndRefresh(context, _ZeninShugoScreen(db: db)),
        ),
      ],
    );
  }

  static String _agariIcon(AgariSearchKind kind) => switch (kind) {
    AgariSearchKind.yakuman => '👑',
    AgariSearchKind.sanbaiman => '💥',
    AgariSearchKind.baiman => '🔥',
    AgariSearchKind.ippatsu => '🎯',
    AgariSearchKind.dora7 => '🎲',
    AgariSearchKind.ura3 => '🔮',
    AgariSearchKind.hadakaTanki => '🃏',
    AgariSearchKind.hellTanki => '😈',
  };

  Future<void> _pushAndRefresh(BuildContext context, Widget screen) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) setState(() {}); // 戻ってきたら★を更新
  }
}

class _StagePickScreen extends StatefulWidget {
  final PaifuDb db;
  final PaifuSeason season;

  const _StagePickScreen({required this.db, required this.season});

  @override
  State<_StagePickScreen> createState() => _StagePickScreenState();
}

class _StagePickScreenState extends State<_StagePickScreen> {
  @override
  Widget build(BuildContext context) {
    final favLocs = widget.db.locateGames(FavoriteStore.gameIds);
    return _PickScaffold(
      title: '${widget.season.label} ステージを選ぶ',
      children: [
        for (final st in widget.db.stages(widget.season.id))
          _PickTile(
            label: st.label,
            starred: favLocs.any((l) => l.stageId == st.id),
            onTap: () => _push(
              _DatePickScreen(db: widget.db, season: widget.season, stage: st),
            ),
          ),
      ],
    );
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) setState(() {});
  }
}

class _DatePickScreen extends StatefulWidget {
  final PaifuDb db;
  final PaifuSeason season;
  final PaifuStage stage;

  const _DatePickScreen({
    required this.db,
    required this.season,
    required this.stage,
  });

  @override
  State<_DatePickScreen> createState() => _DatePickScreenState();
}

class _DatePickScreenState extends State<_DatePickScreen> {
  @override
  Widget build(BuildContext context) {
    final favLocs = widget.db.locateGames(FavoriteStore.gameIds);
    return _PickScaffold(
      title: '${widget.season.label} ${widget.stage.label} 試合日を選ぶ',
      children: [
        for (final d in widget.db.dates(widget.stage.id))
          _PickTile(
            label: d,
            starred: favLocs.any(
              (l) => l.stageId == widget.stage.id && l.date == d,
            ),
            onTap: () => _push(
              _GamePickScreen(
                db: widget.db,
                season: widget.season,
                stage: widget.stage,
                date: d,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) setState(() {});
  }
}

class _GamePickScreen extends StatefulWidget {
  final PaifuDb db;
  final PaifuSeason season;
  final PaifuStage stage;
  final String date;

  const _GamePickScreen({
    required this.db,
    required this.season,
    required this.stage,
    required this.date,
  });

  @override
  State<_GamePickScreen> createState() => _GamePickScreenState();
}

class _GamePickScreenState extends State<_GamePickScreen> {
  @override
  Widget build(BuildContext context) {
    final games = widget.db.games(widget.stage.id, widget.date);
    // 2卓開催日(A/B卓)のときだけ卓名を表示する(判定は hasMultipleTables に統一)
    final showTable = widget.db.hasMultipleTables(widget.date);
    return _PickScaffold(
      title: '${widget.date} 試合を選ぶ',
      children: [
        for (final g in games)
          _PickTile(
            label: g.label(showTable: showTable),
            subtitle: [
              for (final p in widget.db.gamePlayers(g.id)) p.name,
            ].join(' / '),
            starred: FavoriteStore.gameIds.contains(g.mLeagueGameId),
            onTap: () => _push(
              _PlayerPickScreen(
                db: widget.db,
                game: g,
                matchLabel: g.label(showTable: showTable),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _push(Widget screen) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
    if (mounted) setState(() {});
  }
}

class _PlayerPickScreen extends StatelessWidget {
  final PaifuDb db;
  final PaifuGame game;
  final String matchLabel;

  const _PlayerPickScreen({
    required this.db,
    required this.game,
    required this.matchLabel,
  });

  Future<void> _start(BuildContext context, int seat) async {
    // 再生セッションは自前のDB接続を持つ(閲覧用と寿命を分ける)
    final f = await PaifuStore.dbFile();
    final session = ReplaySession(
      db: PaifuDb.open(f.path),
      gameId: game.id,
      youSeat: seat,
      matchLabel: matchLabel,
      mLeagueGameId: game.mLeagueGameId,
    );
    unawaited(session.run());
    if (!context.mounted) {
      await session.dispose();
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(session: session)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final players = db.gamePlayers(game.id);
    return _PickScaffold(
      title: 'どの選手の視点で見る?',
      children: [
        for (var i = 0; i < players.length; i++)
          _PickTile(
            label: players[i].name,
            subtitle: seatFromChiichaLabel(i),
            onTap: () => _start(context, i),
          ),
      ],
    );
  }
}

// ---------------- 局の再生(検索系の共通) ----------------

/// 指定の局を、指定選手の視点で局の頭から再生する(検索系一覧の共通入口)。
Future<void> openKyokuReplay(
  BuildContext context,
  PaifuDb db, {
  required int gameId,
  required int kyokuId,
  required int playerId,
}) async {
  final game = db.gameById(gameId);
  if (game == null) return;
  final players = db.gamePlayers(gameId);
  var seat = players.indexWhere((p) => p.id == playerId);
  if (seat < 0) seat = 0;
  final kyokuIndex = db.kyokus(gameId).indexWhere((k) => k.id == kyokuId);
  final matchLabel = matchLabelOf(
    matchNumber: game.matchNumber,
    tableLetter: game.tableLetter,
    showTable: db.hasMultipleTables(game.date),
    date: game.date,
  );
  final f = await PaifuStore.dbFile();
  final session = ReplaySession(
    db: PaifuDb.open(f.path),
    gameId: gameId,
    youSeat: seat,
    matchLabel: matchLabel,
    mLeagueGameId: game.mLeagueGameId,
    startKyoku: kyokuIndex < 0 ? 0 : kyokuIndex,
  );
  unawaited(session.run());
  if (!context.mounted) {
    await session.dispose();
    return;
  }
  await Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => GameScreen(session: session)),
  );
}

/// DB表記('2m'/'0p'/'1z')を読みやすく('2萬'/'赤5筒'/'東')。本体は Tile.displayName
String tileLabelOf(String code) {
  try {
    return Tile.displayName(Tile.fromDbNotation(code));
  } catch (_) {
    return code;
  }
}

// ---------------- アガリ検索(役満・三倍満・一発) ----------------

/// 件数がこれを超える種類は、先にシーズンで分ける
const int agariListSeasonSplitThreshold = 100;

/// アガリ検索のシーズン選択。シーズンマスタをまず即表示し、
/// 各シーズンの件数は表示後に順に数えて埋める(0件のシーズンも出す)。
class _AgariSeasonPickScreen extends StatefulWidget {
  final PaifuDb db;
  final AgariSearchKind kind;
  final int total;

  const _AgariSeasonPickScreen({
    required this.db,
    required this.kind,
    required this.total,
  });

  @override
  State<_AgariSeasonPickScreen> createState() => _AgariSeasonPickScreenState();
}

class _AgariSeasonPickScreenState extends State<_AgariSeasonPickScreen> {
  late final List<PaifuSeason> _seasons = widget.db.seasons();
  final Map<int, int> _counts = {};
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    // 最初のフレームを出してから件数を後追いで数える
    WidgetsBinding.instance.addPostFrameCallback((_) => _countAll());
  }

  Future<void> _countAll() async {
    for (final s in _seasons) {
      if (_cancelled || !mounted) return;
      final n = widget.db.countAgari(widget.kind, seasonId: s.id);
      if (!mounted) return;
      setState(() => _counts[s.id] = n);
      await Future<void>.delayed(Duration.zero); // 1件ごとに描画を挟む
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _PickScaffold(
      title: '${widget.kind.label}: シーズンを選ぶ(全${widget.total}件)',
      children: [
        for (final s in _seasons)
          _PickTile(
            label: s.label,
            subtitle: _counts.containsKey(s.id) ? '${_counts[s.id]}件' : '…',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => _AgariListScreen(
                  db: widget.db,
                  kind: widget.kind,
                  season: s,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _AgariListScreen extends StatelessWidget {
  final PaifuDb db;
  final AgariSearchKind kind;
  final PaifuSeason? season; // null=全シーズン

  const _AgariListScreen({required this.db, required this.kind, this.season});

  @override
  Widget build(BuildContext context) {
    if (season == null) {
      // 件数だけ数えて(一覧は組み立てない)、多すぎればシーズン一覧を挟む
      final total = db.countAgari(kind);
      if (total > agariListSeasonSplitThreshold) {
        return _AgariSeasonPickScreen(db: db, kind: kind, total: total);
      }
    }
    final list = db.searchAgari(kind, seasonId: season?.id);
    final multi = db.multiTableDates();
    return _PickScaffold(
      title:
          '${kind.label}${season == null ? '' : ' ${season!.label}'}'
          '(${list.length}件)',
      emptyText: '該当するアガリはありません',
      children: [
        for (final a in list)
          _PickTile(
            label:
                '${matchLabelOf(matchNumber: a.matchNumber, tableLetter: a.tableLetter, showTable: multi.contains(a.date), date: a.date)} '
                '${a.kyokuLabel}',
            subtitle:
                '${winSummary(name: a.winnerName, isTsumo: a.isTsumo, loserName: a.loserName, points: a.points)} '
                '${a.isYakuman ? '役満' : '(${hanFuLabel(a.han, a.fu)})'} ${a.yaku}',
            onTap: () => openKyokuReplay(
              context,
              db,
              gameId: a.gameId,
              kyokuId: a.kyokuId,
              playerId: a.winnerId,
            ),
          ),
      ],
    );
  }
}

// ---------------- 通らなかったリーチ ----------------

/// 宣言牌をロンされて不成立になったリーチの一覧。タップでその局の頭から
/// リーチ者の視点で再生する(局の途中からではなく頭から: 巡目の文脈ごと見るため)。
class _FailedRiichiScreen extends StatelessWidget {
  final PaifuDb db;

  const _FailedRiichiScreen({required this.db});

  @override
  Widget build(BuildContext context) {
    final list = db.failedRiichis();
    final multi = db.multiTableDates();
    return _PickScaffold(
      title: '通らなかったリーチ(${list.length}件)',
      emptyText: '宣言牌をロンされたリーチはありません',
      children: [
        for (final fr in list)
          _PickTile(
            label:
                '${matchLabelOf(matchNumber: fr.matchNumber, tableLetter: fr.tableLetter, showTable: multi.contains(fr.date), date: fr.date)} '
                '${fr.kyokuLabel}',
            subtitle:
                '${fr.riichiName} のリーチ宣言牌 ${tileLabelOf(fr.declTile)} を '
                '${fr.winnerName} がロン(${fr.points}点)',
            onTap: () => openKyokuReplay(
              context,
              db,
              gameId: fr.gameId,
              kyokuId: fr.kyokuId,
              playerId: fr.riichiPlayerId,
            ),
          ),
      ],
    );
  }
}

// ---------------- 天和・地和チャンス ----------------

/// 配牌13枚がテンパイしていた局の一覧。タップでその局の頭からその人の視点で再生する。
class _HaipaiTenpaiScreen extends StatelessWidget {
  final PaifuDb db;

  const _HaipaiTenpaiScreen({required this.db});

  @override
  Widget build(BuildContext context) {
    final list = db.haipaiTenpais();
    final multi = db.multiTableDates();
    return _PickScaffold(
      title: '天和・地和チャンス(${list.length}件)',
      emptyText: '配牌でテンパイしていた局はありません',
      children: [
        for (final h in list)
          _PickTile(
            label:
                '${matchLabelOf(matchNumber: h.matchNumber, tableLetter: h.tableLetter, showTable: multi.contains(h.date), date: h.date)} '
                '${h.kyokuLabel}',
            subtitle:
                '${h.name}(${h.chanceLabel}) ${h.hand} → '
                '${h.firstTile.isEmpty ? '' : '${tileLabelOf(h.firstTile)} '}'
                '${h.firstActionLabel} → ${h.resultLabel}',
            onTap: () => openKyokuReplay(
              context,
              db,
              gameId: h.gameId,
              kyokuId: h.kyokuId,
              playerId: h.playerId,
            ),
          ),
      ],
    );
  }
}

// ---------------- 見逃しからのロン和了 ----------------

/// 役のあるロン牌を見逃し(同巡内フリテン)、同じ局で後にロン和了した局の一覧。
/// 見逃した相手本人から討ち取った局には印を付ける。
class _MissedRonScreen extends StatelessWidget {
  final PaifuDb db;

  const _MissedRonScreen({required this.db});

  @override
  Widget build(BuildContext context) {
    final list = db.missedRonAgaris();
    final multi = db.multiTableDates();
    return _PickScaffold(
      title: '見逃しからのロン和了(${list.length}件)',
      emptyText: '見逃しからのロン和了はありません',
      children: [
        for (final m in list)
          _PickTile(
            label:
                '${matchLabelOf(matchNumber: m.matchNumber, tableLetter: m.tableLetter, showTable: multi.contains(m.date), date: m.date)} '
                '${m.kyokuLabel}',
            subtitle:
                '${m.winnerName}: ${tileLabelOf(m.missedTile)}(${m.missedFromName})を見逃し → '
                '${m.loserName}から${tileLabelOf(m.ronTile)}でロン ${m.points}点'
                '${m.sameOpponent ? ' ★同じ相手' : ''}',
            onTap: () => openKyokuReplay(
              context,
              db,
              gameId: m.gameId,
              kyokuId: m.kyokuId,
              playerId: m.winnerId,
            ),
          ),
      ],
    );
  }
}

// ---------------- 全員集合からの決着 ----------------

/// 南4局開始時に全員が2万点台(全員集合)で、その局で試合が終わった局の一覧。
/// 開始時の点数と局の結果を出し、タップで和了者(流局なら試合1位)の視点で再生する。
class _ZeninShugoScreen extends StatelessWidget {
  final PaifuDb db;

  const _ZeninShugoScreen({required this.db});

  @override
  Widget build(BuildContext context) {
    final list = db.zeninShugoFinals();
    final multi = db.multiTableDates();
    return _PickScaffold(
      title: '全員集合からの決着(${list.length}件)',
      emptyText: '全員集合から決着した局はありません',
      children: [
        for (final z in list)
          _PickTile(
            label:
                '${matchLabelOf(matchNumber: z.matchNumber, tableLetter: z.tableLetter, showTable: multi.contains(z.date), date: z.date)} '
                '${z.kyokuLabel}',
            subtitle:
                '${z.startScoresLabel}\n'
                '${z.resultLabel} → 1位 ${z.winnerName}'
                '${z.agariButNotTop ? ' ★和了してもトップになれず' : ''}',
            onTap: () => openKyokuReplay(
              context,
              db,
              gameId: z.gameId,
              kyokuId: z.kyokuId,
              playerId: z.viewPlayerId,
            ),
          ),
      ],
    );
  }
}

// ---------------- 自分の対局 ----------------

class _MyGamePickScreen extends StatefulWidget {
  const _MyGamePickScreen();

  @override
  State<_MyGamePickScreen> createState() => _MyGamePickScreenState();
}

class _MyGamePickScreenState extends State<_MyGamePickScreen> {
  List<MyPaifuSummary>? _games;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final games = await MyPaifuStore.listGames();
    if (mounted) setState(() => _games = games);
  }

  Future<void> _confirmDelete(MyPaifuSummary g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('牌譜を削除'),
        content: Text('${g.date} の対局(${g.names.join(' / ')})を削除しますか?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await MyPaifuStore.deleteGame(g.id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    return _PickScaffold(
      title: '自分の対局',
      emptyText: games == null
          ? '読み込み中…'
          : 'まだ保存された対局がありません。\nソロや通信対戦をホストとして打つと自動で貯まります。',
      children: [
        for (final g in games ?? const <MyPaifuSummary>[])
          _PickTile(
            label: '${g.date} ${g.kyokuCount}局${g.finished ? '' : ' (途中終了)'}',
            subtitle: [
              for (var i = 0; i < g.names.length; i++)
                '${g.names[i]} ${g.lastScores[i]}',
            ].join(' / '),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => _MyPlayerPickScreen(summary: g),
              ),
            ),
            onLongPress: () => _confirmDelete(g),
          ),
      ],
    );
  }
}

class _MyPlayerPickScreen extends StatelessWidget {
  final MyPaifuSummary summary;

  const _MyPlayerPickScreen({required this.summary});

  Future<void> _start(BuildContext context, int seat) async {
    final game = await MyPaifuStore.loadGame(summary.id);
    if (game == null || !context.mounted) return;
    final session = ReplaySession(
      db: MyPaifuSource(game),
      gameId: MyPaifuSource.soloGameId,
      youSeat: seat,
      matchLabel: '自分の対局 ${summary.date}',
      mLeagueGameId: summary.id, // お気に入り・ゴースト試行のキーに使う
    );
    unawaited(session.run());
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(session: session)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PickScaffold(
      title: 'どの視点で見る?',
      children: [
        for (var i = 0; i < summary.names.length; i++)
          _PickTile(
            label: summary.names[i],
            subtitle: seatFromChiichaLabel(i),
            onTap: () => _start(context, i),
          ),
      ],
    );
  }
}

// ---------------- 記録した牌譜(手動記録) ----------------

class _RecGamePickScreen extends StatefulWidget {
  const _RecGamePickScreen();

  @override
  State<_RecGamePickScreen> createState() => _RecGamePickScreenState();
}

class _RecGamePickScreenState extends State<_RecGamePickScreen> {
  List<RecPaifuSummary>? _games;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final games = await RecPaifuStore.listGames();
    if (mounted) setState(() => _games = games);
  }

  Future<void> _confirmDelete(RecPaifuSummary g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('牌譜を削除'),
        content: Text('${g.date} の記録(${g.names.join(' / ')})を削除しますか?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await RecPaifuStore.deleteGame(g.id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    return _PickScaffold(
      title: '記録した牌譜',
      children: [
        _PickTile(
          label: '✍️ 新しく記録する',
          subtitle: '放送対局などを見ながら牌譜を記録する',
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const RecordSetupScreen(),
              ),
            );
            await _load();
          },
        ),
        if (games != null)
          for (final g in games)
            _PickTile(
              label: '${g.date} ${g.kyokuCount}局${g.finished ? '' : ' (記録のみ)'}',
              subtitle: [
                for (var i = 0; i < g.names.length; i++)
                  '${g.names[i]} ${g.lastScores[i]}',
              ].join(' / '),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => _RecPlayerPickScreen(summary: g),
                ),
              ),
              onLongPress: () => _confirmDelete(g),
            ),
      ],
    );
  }
}

class _RecPlayerPickScreen extends StatelessWidget {
  final RecPaifuSummary summary;

  const _RecPlayerPickScreen({required this.summary});

  Future<void> _start(BuildContext context, int seat) async {
    final game = await RecPaifuStore.loadGame(summary.id);
    if (game == null || !context.mounted) return;
    final session = ReplaySession(
      db: MyPaifuSource(game), // 同じ形のJSONなのでそのまま読める
      gameId: MyPaifuSource.soloGameId,
      youSeat: seat,
      matchLabel: '記録した牌譜 ${summary.date}',
      mLeagueGameId: summary.id, // お気に入り・ゴースト試行のキーに使う
    );
    unawaited(session.run());
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameScreen(session: session)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PickScaffold(
      title: 'どの視点で見る?',
      children: [
        for (var i = 0; i < summary.names.length; i++)
          _PickTile(
            label: summary.names[i],
            subtitle: seatFromChiichaLabel(i),
            onTap: () => _start(context, i),
          ),
      ],
    );
  }
}

// ---------------- 共通部品 ----------------

class _PickScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final String emptyText;

  const _PickScaffold({
    required this.title,
    required this.children,
    this.actions = const [],
    this.emptyText = 'データがありません',
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF10331C),
        actions: actions,
      ),
      // 横画面ではノッチ側のインセットが大きいので、リストは SafeArea 内に置く
      body: SafeArea(
        child: children.isEmpty
            ? Center(
                child: Text(
                  emptyText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54),
                ),
              )
            : ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                children: children,
              ),
      ),
    );
  }
}

class _PickTile extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool starred;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _PickTile({
    required this.label,
    this.subtitle,
    this.starred = false,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1B4D2B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFF2E7D32)),
      ),
      child: ListTile(
        dense: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (starred) ...[
              const SizedBox(width: 6),
              const Icon(Icons.star, color: Color(0xFFFFD54F), size: 16),
            ],
          ],
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
        trailing: const Icon(
          Icons.chevron_right,
          color: Colors.white38,
          size: 18,
        ),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
