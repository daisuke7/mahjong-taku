import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../engine/tile.dart';

/// 暗槓で**表向きに見せる中2枚**を返す(両端は伏せ牌)。
/// 赤牌が端に来ると隠れてしまうので、赤があれば必ず表向き側に含める。
List<int> ankanFaceUp(List<int> tiles) {
  final r = [...tiles]
    ..sort((a, b) => (Tile.isRed(b) ? 1 : 0) - (Tile.isRed(a) ? 1 : 0));
  return [r[0], r[1]]; // 赤を先頭へ寄せたうちの2枚
}

/// ドラ・赤牌の脈動アニメーションの共有位相(0..1を往復)。
/// 全ての牌が同じ位相で光るよう、アプリ全体で1本のTickerを回す。
class _DoraPulse {
  static final _DoraPulse instance = _DoraPulse._();

  final ValueNotifier<double> value = ValueNotifier(0);

  /// 回転位相(0..1で一周、2.4秒周期)。攻守一致ボーダーの回転に使う。
  /// [value] と同じTickerで更新するので、value を購読していれば新鮮。
  final ValueNotifier<double> spin = ValueNotifier(0);
  Ticker? _ticker;
  int _listeners = 0;

  _DoraPulse._();

  void _ensureRunning() {
    _ticker ??= Ticker((elapsed) {
      // 約1.6秒周期で 0→1→0
      final t = (elapsed.inMilliseconds % 1600) / 1600.0;
      value.value = t < 0.5 ? t * 2 : (1 - t) * 2;
      spin.value = (elapsed.inMilliseconds % 2400) / 2400.0;
    })..start();
  }

  void acquire() {
    _listeners++;
    _ensureRunning();
  }

  void release() {
    _listeners--;
    if (_listeners <= 0) {
      _ticker?.dispose();
      _ticker = null;
      _listeners = 0;
    }
  }
}

/// 牌1枚の描画。tile が null なら裏向き(コード描画)。
/// 牌画像: 麻雀豆腐(https://majandofu.com/mahjong-images)の素材を使用。
class TileWidget extends StatefulWidget {
  final int? tile;
  final double width;
  final bool dimmed;
  final bool highlighted;
  final bool sideways; // リーチ宣言牌など
  final bool glowSafe; // 現物(全脅威に100%安全)を青く点滅させる

  /// リーチ者には現物だが、鳴きなど他の脅威には言い切れない牌。
  /// [glowSafe] より薄い青枠で控えめに示す(発光もかすかに)。
  final bool glowSafeFaint;

  /// 最も攻撃的な打牌(最良シャンテン維持+ウケ最大)を赤く点滅させる。
  /// [glowSafe](濃い青)と同時に立つと「攻守一致の理想打牌」として
  /// 青赤交互の回転ボーダーで際立たせる。[glowSafeFaint](薄い青)との
  /// 同時は赤を優先する。
  final bool glowAttack;
  final bool drawn; // ツモってきた牌(明るい緑の点滅)
  final bool forbidden; // 喰い替え等で切れない牌(薄い灰色・静止)
  final bool muted; // ツモ切り牌など、ごく薄く灰色にして判別させる

  /// ドラ(表ドラ/カンドラ)である。赤牌は自動でドラ扱いになる。
  final bool dora;

  const TileWidget({
    super.key,
    required this.tile,
    required this.width,
    this.dimmed = false,
    this.highlighted = false,
    this.sideways = false,
    this.glowSafe = false,
    this.glowSafeFaint = false,
    this.glowAttack = false,
    this.drawn = false,
    this.forbidden = false,
    this.muted = false,
    this.dora = false,
  });

  /// 素材画像の縦横比(66x90px)
  static const double aspect = 90 / 66;

  /// 字牌の画像番号(ji1..ji7 = 東南西北發白中)
  static const List<int> _honorIndex = [1, 2, 3, 4, 6, 5, 7];

  /// ドラ表示牌のリストから、ドラの牌種集合(正規化済)を作る(本体は Tile.doraKinds)
  static Set<int> doraKindsFrom(List<int> indicators) =>
      Tile.doraKinds(indicators);

  static String assetFor(int tile) {
    if (Tile.isRed(tile)) {
      // aka1=赤5筒 aka2=赤5索 aka3=赤5萬
      final aka = switch (tile) {
        Tile.red5p => 1,
        Tile.red5s => 2,
        _ => 3,
      };
      return 'assets/tiles/aka$aka.png';
    }
    final kind = Tile.normalize(tile);
    final String name;
    if (kind < 9) {
      name = 'man${kind + 1}';
    } else if (kind < 18) {
      name = 'pin${kind - 8}';
    } else if (kind < 27) {
      name = 'sou${kind - 17}';
    } else {
      name = 'ji${_honorIndex[kind - 27]}';
    }
    return 'assets/tiles/$name.png';
  }

  @override
  State<TileWidget> createState() => _TileWidgetState();
}

class _TileWidgetState extends State<TileWidget> {
  bool _pulsing = false;

  bool get _isDoraTile =>
      widget.tile != null && (widget.dora || Tile.isRed(widget.tile!));

  /// 脈動アニメが要る状態(ツモ=緑 / ドラ=橙 / 現物=青)
  bool get _wantPulse =>
      _isDoraTile ||
      widget.drawn ||
      widget.glowSafe ||
      widget.glowSafeFaint ||
      widget.glowAttack;

  @override
  void initState() {
    super.initState();
    _updatePulse();
  }

  @override
  void didUpdateWidget(TileWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updatePulse();
  }

  void _updatePulse() {
    final want = _wantPulse;
    if (want && !_pulsing) {
      _DoraPulse.instance.acquire();
      _pulsing = true;
    } else if (!want && _pulsing) {
      _DoraPulse.instance.release();
      _pulsing = false;
    }
  }

  @override
  void dispose() {
    if (_pulsing) _DoraPulse.instance.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = width * TileWidget.aspect;
    final radius = BorderRadius.circular(width * 0.09);

    // 裏牌はコード描画(素材に裏面がないため)
    final Widget back = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFE8A33D), Color(0xFFC77F1E)],
        ),
        borderRadius: radius,
        border: Border.all(color: const Color(0xFF8A5A10), width: 1),
      ),
      padding: EdgeInsets.all(width * 0.12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(width * 0.06),
          border: Border.all(color: const Color(0x66FFE0B2), width: 1),
        ),
      ),
    );

    // 攻守一致(全脅威に通る現物 かつ 最攻撃打牌)= 理想の打牌
    final ideal = widget.glowSafe && widget.glowAttack;

    Widget buildBody(double t, double spin) {
      // 白地だけに色を乗せるため、図柄を潰さない multiply で牌画像を着色する。
      // (乗算: 白→その色 / 黒い線は黒のまま残るので図柄が読める)
      // 優先: 喰い替え禁止(濃い灰) > ツモ切り(薄い灰) > ツモ牌(緑) > ドラ(橙)。
      final Color? tint = widget.forbidden
          ? const Color(0xFF8C8C8C).withValues(alpha: 0.78)
          : widget.muted
          ? const Color(0xFF7C7C7C).withValues(alpha: 0.62)
          : widget.drawn
          ? const Color(0xFF7CC47F).withValues(alpha: 0.5 + t * 0.45) // ツモ: 緑
          : _isDoraTile
          ? const Color(0xFFFFB74D).withValues(alpha: 0.5 + t * 0.45) // ドラ: 橙
          : null;

      final Widget faceLayer = widget.tile == null
          ? back
          : Image.asset(
              TileWidget.assetFor(widget.tile!),
              width: width,
              height: height,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
              color: tint,
              colorBlendMode: tint != null ? BlendMode.multiply : null,
            );

      Widget body = Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: ideal
              ? [
                  // 攻守一致: 発光色が青⇔赤を行き来する
                  BoxShadow(
                    color: Color.lerp(
                      const Color(0xFF29B6F6),
                      const Color(0xFFEF5350),
                      t,
                    )!.withValues(alpha: 0.55 + t * 0.25),
                    blurRadius: width * 0.5,
                    spreadRadius: width * 0.12,
                  ),
                ]
              : widget.glowSafe
              ? [
                  // 現物: 青い発光を脈動させる
                  BoxShadow(
                    color: const Color(
                      0xFF29B6F6,
                    ).withValues(alpha: 0.45 + t * 0.5),
                    blurRadius: width * 0.5,
                    spreadRadius: width * 0.12,
                  ),
                ]
              : widget.glowAttack
              ? [
                  // 最攻撃打牌: 赤い発光を脈動させる
                  BoxShadow(
                    color: const Color(
                      0xFFEF5350,
                    ).withValues(alpha: 0.45 + t * 0.5),
                    blurRadius: width * 0.5,
                    spreadRadius: width * 0.12,
                  ),
                ]
              : widget.glowSafeFaint
              ? [
                  // リーチにだけは通る牌: 発光はかすかに
                  BoxShadow(
                    color: const Color(
                      0xFF29B6F6,
                    ).withValues(alpha: 0.15 + t * 0.2),
                    blurRadius: width * 0.35,
                    spreadRadius: width * 0.05,
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    offset: const Offset(0, 1),
                    blurRadius: 1.5,
                  ),
                ],
        ),
        foregroundDecoration: widget.highlighted
            ? BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: const Color(0xFFFFC400), width: 2),
              )
            : ideal
            ? null // 回転ボーダー(CustomPaint)が枠を描く
            : widget.glowSafe
            ? BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: const Color(0xFF4FC3F7), width: 2),
              )
            : widget.glowAttack
            ? BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: const Color(0xFFEF5350), width: 2),
              )
            : widget.glowSafeFaint
            ? BoxDecoration(
                borderRadius: radius,
                border: Border.all(
                  color: const Color(0xFF4FC3F7).withValues(alpha: 0.45),
                  width: 1.5,
                ),
              )
            : null,
        child: ideal && !widget.highlighted
            ? CustomPaint(
                foregroundPainter: _IdealBorderPainter(
                  spin: spin,
                  cornerRadius: width * 0.09,
                  strokeWidth: 3,
                ),
                child: ClipRRect(borderRadius: radius, child: faceLayer),
              )
            : ClipRRect(borderRadius: radius, child: faceLayer),
      );

      if (widget.dimmed) {
        body = Opacity(opacity: 0.4, child: body);
      }
      if (widget.sideways) {
        body = RotatedBox(quarterTurns: 1, child: body);
      }
      return body;
    }

    if (_wantPulse) {
      return ValueListenableBuilder<double>(
        valueListenable: _DoraPulse.instance.value,
        builder: (context, t, _) =>
            buildBody(t, _DoraPulse.instance.spin.value),
      );
    }
    return buildBody(0, 0);
  }
}

/// 攻守一致(現物かつ最攻撃打牌)の回転ボーダー。青と赤の弧が45度ごとに
/// 交互に並び、ゆっくり回って「理想の打牌」を際立たせる。
class _IdealBorderPainter extends CustomPainter {
  final double spin; // 0..1 で一周
  final double cornerRadius;
  final double strokeWidth;

  _IdealBorderPainter({
    required this.spin,
    required this.cornerRadius,
    required this.strokeWidth,
  });

  static const _blue = Color(0xFF4FC3F7);
  static const _red = Color(0xFFEF5350);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 同色を2点ずつ置いて境界をくっきりさせる(グラデーションのにじみ防止)
    final colors = <Color>[];
    final stops = <double>[];
    for (var i = 0; i < 8; i++) {
      final c = i.isEven ? _blue : _red;
      colors
        ..add(c)
        ..add(c);
      stops
        ..add(i / 8)
        ..add((i + 1) / 8);
    }
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = SweepGradient(
        colors: colors,
        stops: stops,
        transform: GradientRotation(spin * 2 * pi),
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(strokeWidth / 2),
        Radius.circular(cornerRadius),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_IdealBorderPainter old) =>
      old.spin != spin ||
      old.cornerRadius != cornerRadius ||
      old.strokeWidth != strokeWidth;
}

/// 牌の横並び(和了表示・ドラ表示などの単純列)
class TileRow extends StatelessWidget {
  final List<int> tiles;
  final double tileWidth;
  final Set<int> highlightIndexes;
  final Set<int> doraKinds;

  const TileRow({
    super.key,
    required this.tiles,
    required this.tileWidth,
    this.highlightIndexes = const {},
    this.doraKinds = const {},
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < tiles.length; i++)
          Padding(
            padding: EdgeInsets.only(right: tileWidth * 0.06),
            child: TileWidget(
              tile: tiles[i],
              width: tileWidth,
              highlighted: highlightIndexes.contains(i),
              dora: doraKinds.contains(Tile.normalize(tiles[i])),
            ),
          ),
      ],
    );
  }
}
