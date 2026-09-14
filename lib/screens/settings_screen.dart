import 'package:flutter/material.dart';

import '../api_client.dart';
import '../settings_store.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onLoggedIn;

  const SettingsScreen({super.key, required this.onLoggedIn});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _store = SettingsStore();
  final _serverUrlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _userIdCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _loading = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _serverUrlCtrl.text = await _store.getServerUrl() ?? '';
    _apiKeyCtrl.text = await _store.getApiKey() ?? '';
    setState(() {});
  }

  Future<void> _login() async {
    if (_serverUrlCtrl.text.trim().isEmpty ||
        _apiKeyCtrl.text.trim().isEmpty ||
        _userIdCtrl.text.trim().isEmpty ||
        _passwordCtrl.text.isEmpty) {
      setState(() => _message = '四個欄位都要填喔');
      return;
    }
    setState(() {
      _loading = true;
      _message = null;
    });
    await _store.saveConnection(
      serverUrl: _serverUrlCtrl.text,
      apiKey: _apiKeyCtrl.text,
    );
    try {
      await ApiClient().login(_userIdCtrl.text.trim(), _passwordCtrl.text);
      widget.onLoggedIn();
    } catch (e) {
      setState(() => _message = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _serverUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _userIdCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登入')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '密碼要先在 Discord 私訊「股市小幫手」設定：\n'
              '@股市小幫手 設定密碼 你的密碼\n'
              '（一定要用私訊，不要在公開頻道打，不然密碼會被大家看到）',
              style: TextStyle(color: Colors.orange),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _serverUrlCtrl,
              decoration: const InputDecoration(
                labelText: '伺服器網址',
                hintText: 'https://xxxx.trycloudflare.com',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiKeyCtrl,
              decoration: const InputDecoration(
                labelText: 'API Key',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const Divider(height: 32),
            TextField(
              controller: _userIdCtrl,
              decoration: const InputDecoration(
                labelText: '你的 Discord User ID',
                hintText: '例如 123456789012345678',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordCtrl,
              decoration: const InputDecoration(
                labelText: '密碼',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              onSubmitted: (_) => _login(),
            ),
            const SizedBox(height: 20),
            if (_message != null) ...[
              Text(_message!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: _loading ? null : _login,
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('登入'),
            ),
          ],
        ),
      ),
    );
  }
}
