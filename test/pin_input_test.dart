import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:everlink/ui/widgets/pin_input.dart';

/// 窄屏（模拟 360dp 手机上 AlertDialog 的内容区宽度）下，外部程序化改写
/// PIN（对应频道弹窗里的「随机生成」按钮）不应触发
/// InheritedElement.notifyClients 的 "really is our descendant" 断言，
/// 也不应出现横向溢出。
void main() {
  testWidgets('窄屏下程序化设置 PIN 不报错且不溢出', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final ctl = TextEditingController();
    addTearDown(ctl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            // 360dp 屏 + AlertDialog 内边距后大致的内容区宽度
            child: SizedBox(
              width: 280,
              child: PinInputWidget(controller: ctl),
            ),
          ),
        ),
      ),
    );

    // 模拟「随机生成」：在 StatefulBuilder 的 setLocal 之外改写 controller。
    ctl.text = '135790';
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // 六个格子全部渲染，且整行宽度未超出可用宽度 280。
    // 用 children.length == 6 精确定位 PIN 那一行，避免命中 TextField 内部的 Row。
    final pinRow = find.byWidgetPredicate(
      (w) => w is Row && w.children.length == 6,
      description: 'PIN 格子所在的行',
    );
    expect(pinRow, findsOneWidget);
    final rowBox = tester.renderObject<RenderBox>(pinRow);
    expect(rowBox.size.width, lessThanOrEqualTo(280));
  });

  testWidgets('只读展示（enabled=false）同样不溢出', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final ctl = TextEditingController(text: '246802');
    addTearDown(ctl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: PinInputWidget(controller: ctl, enabled: false),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final pinRow = find.byWidgetPredicate(
      (w) => w is Row && w.children.length == 6,
      description: 'PIN 格子所在的行',
    );
    final rowBox = tester.renderObject<RenderBox>(pinRow);
    expect(rowBox.size.width, lessThanOrEqualTo(280));
  });
}
