import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'settings_store.dart';

void main() {
  runApp(const FeixuApp());
}

class FeixuApp extends StatelessWidget {
  const FeixuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '費許交易',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF2ECC71),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0F141C),
        cardTheme: const CardThemeData(color: Color(0xFF1A2230)),
      ),
      home: const _StartupGate(),
    );
  }
}

// 開機先檢查有沒有設定過伺服器/帳號，沒設定過就先導去設定頁，
// 不要讓使用者一開 App 就看到一堆連線失敗的錯誤訊息。
class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  bool? _configured;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final configured = await SettingsStore().isConfigured();
    if (!mounted) return;
    setState(() => _configured = configured);
  }

  @override
  Widget build(BuildContext context) {
    if (_configured == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_configured == false) {
      return SettingsScreen(
        onSaved: () => setState(() => _configured = true),
      );
    }
    return const HomeScreen();
  }
}
