// This is a basic Flutter widget test.
import 'package:flutter_test/flutter_test.dart';

import 'package:everlink/main.dart';

void main() {
  testWidgets('应用启动并显示协议列表', (WidgetTester tester) async {
    await tester.pumpWidget(const EverlinkApp());
    // 首页应展示已注册协议的名称。
    expect(find.text('Modbus TCP'), findsOneWidget);
    expect(find.text('MQTT'), findsOneWidget);
  });
}
