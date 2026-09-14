// 先留一個最基本的煙霧測試：只確認 App 能正常啟動、不會一開就崩潰。
// 因為 HomeScreen/SettingsScreen 都需要真的連到後端 API 才有完整畫面，
// 這裡只驗證「啟動流程」本身（開機檢查設定 → 導去設定頁或首頁）不會噴例外。

import 'package:flutter_test/flutter_test.dart';

import 'package:feixu_trading/main.dart';

void main() {
  testWidgets('App 啟動不會崩潰，會導向登入頁（因為還沒登入過）', (WidgetTester tester) async {
    await tester.pumpWidget(const FeixuApp());
    await tester.pumpAndSettle();

    // 還沒登入過，開機應該會停在登入頁，看得到「登入」標題。
    expect(find.text('登入'), findsOneWidget);
  });
}
