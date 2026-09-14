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

// 開機先檢查有沒有登入過，沒登入就先導去登入頁，這裡是唯一決定
// 「現在該顯示登入頁還是首頁」的地方，登入/登出都只是改這裡的一個布林值。
class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  bool? _loggedIn;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final loggedIn = await SettingsStore().isLoggedIn();
    if (!mounted) return;
    setState(() => _loggedIn = loggedIn);
  }

  @override
  Widget build(BuildContext context) {
    if (_loggedIn == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_loggedIn == false) {
      return SettingsScreen(
        onLoggedIn: () => setState(() => _loggedIn = true),
      );
    }
    return HomeScreen(
      onLoggedOut: () => setState(() => _loggedIn = false),
    );
  }
}
