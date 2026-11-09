import 'package:flutter/material.dart';

import '../paifu/paifu_store.dart';
import '../paifu/paifu_update_check.dart';
import 'home_screen.dart';
import 'paifu_browser_screen.dart';
import 'yomi_quiz_screen.dart';

/// 牌譜閲覧モードのホーム画面。
/// 対戦モード(通常のホーム)とはモード切替ボタンで交互に行き来する。
class PaifuHomeScreen extends StatefulWidget {
  const PaifuHomeScreen({super.key});

  @override
  State<PaifuHomeScreen> createState() => _PaifuHomeScreenState();
}

class _PaifuHomeScreenState extends State<PaifuHomeScreen> {
  String? _version; // 記録されている最終試合日(null=未ダウンロード)
  bool _loadingVersion = true;

  // ダウンロード進捗(null=待機中)
  String? _stage; // 'download' | 'extract'
  int _received = 0;
  int _total = -1;
  String? _error;

  /// 今あるDBがこのアプリの対応外(足りないテーブル・列)。空なら読める
  List<String> _schemaProblems = const [];

  bool get _downloading => _stage != null;
  bool get _dbReadable => _version != null && _schemaProblems.isEmpty;

  /// 画面に出す注意書き(1つだけ)。ダウンロードの失敗があればそれ、無ければ
  /// 今のDBが読めない形式のときの案内。
  /// 手元のDBに足りないものがあるのは「DBがアプリより古い」場合(配布元の改名より前に
  /// 取り込んだ牌譜を、改名に追従したアプリで開いた)なので、やることは再ダウンロードの
  /// 一択。列名の羅列は利用者には役に立たないので出さない(2026-11-06 Pixel 6 で
  /// 「エラーかどうか分かりづらい」とユーザー指摘)。
  String? get _statusMessage {
    if (_error != null) return _error;
    if (_schemaProblems.isEmpty) return null;
    return '⚠ この牌譜は古い形式のため、今のアプリでは開けません。'
        '「最新牌譜ダウンロード」で更新してください';
  }

  @override
  void initState() {
    super.initState();
    _refreshVersion();
  }

  Future<void> _refreshVersion() async {
    final v = await PaifuStore.currentVersion();
    final problems = await PaifuStore.schemaProblems();
    if (!mounted) return;
    setState(() {
      _schemaProblems = problems;
      _version = v;
      _loadingVersion = false;
    });
  }

  Future<void> _download() async {
    setState(() {
      _error = null;
      _stage = 'download';
      _received = 0;
      _total = -1;
    });
    try {
      await PaifuStore.downloadLatest(
        onProgress: (stage, received, total) {
          if (!mounted) return;
          // 進捗の更新は間引く(1MBごと)。段階が変わったとき(再試行で received が
          // 0 に戻るときも含む)は必ず反映する
          if (stage == _stage && received - _received < 1 << 20) return;
          setState(() {
            _stage = stage;
            _received = received;
            _total = total;
          });
        },
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _stage = null);
      await _refreshVersion();
    }
  }

  String get _progressText {
    if (_stage == 'extract') return '展開中…';
    if (_stage == 'verify') return '形式を確認中…';
    if (_stage == 'retry') return '配布元の応答待ち… 再試行($_received/$_total回目)';
    final mb = (_received / (1 << 20)).toStringAsFixed(0);
    if (_total <= 0) return 'ダウンロード中… ${mb}MB';
    final totalMb = (_total / (1 << 20)).toStringAsFixed(0);
    return 'ダウンロード中… $mb / ${totalMb}MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '牌譜閲覧モード',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFFFE082),
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Mリーグ全試合の牌譜を選手視点で再生',
                      style: TextStyle(color: Colors.white54),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '牌譜データ: konoui/m-league-game-db (MIT)',
                      style: TextStyle(color: Colors.white38, fontSize: 10),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF2E7D32)),
                      ),
                      child: Text(
                        _loadingVersion
                            ? '牌譜バージョンを確認中…'
                            : _version == null
                            ? '牌譜データ未ダウンロード'
                            : '牌譜バージョン: $_version (最終試合日)',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    // 最新リリースが対応外と分かっているとき(取り込みを拒否した版)
                    ValueListenableBuilder<String?>(
                      valueListenable: PaifuUpdateCheck.unsupportedTag,
                      builder: (_, tag, _) => tag != null && !_downloading
                          ? const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                '未対応の更新あり(アプリ側の対応待ち)',
                                style: TextStyle(
                                  color: Color(0xFFFFE082),
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    // 起動時の1回だけの確認で新しいリリースがあったとき、控えめに知らせる
                    ValueListenableBuilder<bool>(
                      valueListenable: PaifuUpdateCheck.updateAvailable,
                      builder: (_, available, _) =>
                          available && _version != null && !_downloading
                          ? const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text(
                                '更新あり',
                                style: TextStyle(
                                  color: Color(0xFFFFE082),
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    if (_downloading) ...[
                      const SizedBox(height: 14),
                      SizedBox(
                        width: 280,
                        child: LinearProgressIndicator(
                          value: _stage == 'download' && _total > 0
                              ? _received / _total
                              : null,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _progressText,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    // 注意書きは1つだけ出す(ダウンロードの失敗 > 今のDBが読めない)。
                    // 2つ並べると縦に伸びて崩れる(2026-10-02 ユーザー指摘)
                    if (_statusMessage != null) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        width: 320,
                        child: Text(
                          _statusMessage!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFEF9A9A),
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 14,
                      runSpacing: 10,
                      alignment: WrapAlignment.center,
                      children: [
                        _menuButton(
                          icon: Icons.cloud_download,
                          label: '最新牌譜ダウンロード',
                          subtitle: 'zip約200MBを取得して更新',
                          onTap: _downloading ? null : _download,
                        ),
                        _menuButton(
                          icon: Icons.play_circle_outline,
                          label: '牌譜ビューア',
                          subtitle: 'シーズン→試合→視点を選ぶ',
                          onTap: (_downloading || !_dbReadable)
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const PaifuBrowserScreen(),
                                  ),
                                ),
                        ),
                        _menuButton(
                          icon: Icons.psychology,
                          label: '読みクイズ',
                          subtitle: '流局時のテンパイと待ちを当てる',
                          onTap: (_downloading || !_dbReadable)
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const YomiQuizScreen(),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // 右上: モード切替(対戦モードへ)。
            // スクロール領域にタップを奪われないよう最前面(Stackの最後)に置く
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(
                  Icons.sports_esports,
                  color: Color(0xFFFFD54F),
                ),
                tooltip: '対戦モードへ',
                onPressed: _downloading
                    ? null
                    : () => Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const HomeScreen()),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuButton({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      width: 200,
      height: 92,
      child: FilledButton.tonal(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1B4D2B),
          disabledBackgroundColor: const Color(0xFF163020),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF2E7D32)),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 26,
              color: onTap == null
                  ? const Color(0x66FFE082)
                  : const Color(0xFFFFE082),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: onTap == null ? Colors.white38 : Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }
}
