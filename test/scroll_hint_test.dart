import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mahjong_taku/ui/widgets/scroll_hint.dart';

void main() {
  testWidgets('スクロール余地がある時だけヒントを表示し、タップで下へ', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 200,
            child: ScrollHint(
              builder: (context, controller) => SingleChildScrollView(
                controller: controller,
                child: Column(
                  children: [
                    for (var i = 0; i < 30; i++)
                      SizedBox(height: 40, child: Text('行$i')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // post frame で判定

    // 内容が画面より長いのでヒント(下矢印)が表示される
    final hint = find.byIcon(Icons.keyboard_arrow_down);
    expect(hint, findsOneWidget);
    // 表示されている(透明でない)
    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: hint, matching: find.byType(AnimatedOpacity)),
    );
    expect(opacity.opacity, 1.0);

    // タップで下にスクロールする
    await tester.tap(hint);
    await tester.pumpAndSettle();
    final controller = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('内容が短ければヒントは非表示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: ScrollHint(
              builder: (context, controller) => SingleChildScrollView(
                controller: controller,
                child: const SizedBox(height: 50, child: Text('短い')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byIcon(Icons.keyboard_arrow_down),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(opacity.opacity, 0.0);
  });
}
