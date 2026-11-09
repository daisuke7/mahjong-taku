import 'package:flutter/material.dart';

/// 縦スクロール可能な領域であることを示すヒント。
/// builder に渡す ScrollController を SingleChildScrollView に接続すると、
/// 右下に枠付きの↓アイコンを重ねる。
/// - まだ下にスクロールできる時だけ表示
/// - タップすると少し下にスクロールする
class ScrollHint extends StatefulWidget {
  /// controller を受け取り、スクロールする子を返す
  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  const ScrollHint({super.key, required this.builder});

  @override
  State<ScrollHint> createState() => _ScrollHintState();
}

class _ScrollHintState extends State<ScrollHint> {
  final ScrollController _controller = ScrollController();
  bool _canScrollDown = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_update);
    // 初期レイアウト後に判定
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _controller.removeListener(_update);
    _controller.dispose();
    super.dispose();
  }

  /// 残りがこれ以下ならヒントを出さない(数pxのわずかな余りは無視)
  static const double _threshold = 24.0;

  void _update() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    // 下方向にまだ十分な余地があるか
    final canDown = pos.maxScrollExtent - pos.pixels > _threshold;
    if (canDown != _canScrollDown) {
      setState(() => _canScrollDown = canDown);
    }
  }

  void _scrollABit() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final target = (pos.pixels + pos.viewportDimension * 0.6).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            // 内容サイズが変わった時にも再判定
            WidgetsBinding.instance.addPostFrameCallback((_) => _update());
            return false;
          },
          child: widget.builder(context, _controller),
        ),
        // スクロールヒント(下に余地がある時だけ)
        Positioned(
          right: 8,
          bottom: 8,
          child: AnimatedOpacity(
            opacity: _canScrollDown ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_canScrollDown,
              child: GestureDetector(
                onTap: _scrollABit,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xCC0B2C17),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFFD54F)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.keyboard_arrow_down,
                    color: Color(0xFFFFD54F),
                    size: 24,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
