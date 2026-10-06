import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:feixu_trading/screens/slot_screen.dart';

void main() {
  testWidgets('slot LED shows server cash', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'server_url': 'http://x', 'api_key': 'k', 'auth_token': 't'});
    final strips = List.generate(5, (c) => List.generate(60, (i) => i % 7));
    final info = {
      'cash': 1234567.0,
      'symbols': ['🍒', '🍋', '🍊', '🔔', '⭐', '7️⃣', '💎', '🃏'],
      'strips': strips,
      'cols': 5,
      'rows': 4,
      'pay': {'0': {'3': 0.01, '4': 0.03, '5': 0.1}},
      'diamond_pay': {'1': 1.2},
      'min_bet': 1000,
      'max_bet': 1000000,
      'history': [],
      'jackpot': {'pool': 3000000.0, 'min_bet': 5000, 'recent': []},
    };
    final client = MockClient((req) async {
      if (req.url.path == '/api/slot/info') return http.Response(jsonEncode(info), 200, headers: {'content-type': 'application/json'});
      if (req.url.path == '/api/slot/jackpot') return http.Response(jsonEncode(info['jackpot']), 200);
      if (req.url.path == '/api/slot/spin') {
        return http.Response(
            jsonEncode({
              'ok': true,
              'stops': [1, 2, 3, 4, 5],
              'grid': List.generate(4, (_) => List.filled(5, 0)),
              'wins': [],
              'diamond': {'count': 0, 'amount': 0, 'cells': []},
              'bet': 10000,
              'payout': 0,
              'cash': 1224567.0,
              'big': false,
              'jackpot_win': 0,
              'jackpot_pool': 3000150.0,
            }),
            200);
      }
      return http.Response('{}', 404);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: SlotScreen()));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('1,234,567'), findsOneWidget);
      await tester.tap(find.text('SPIN'));
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('1,224,567'), findsOneWidget);
    }, () => client);
  });
}
