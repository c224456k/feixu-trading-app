import 'package:flutter/material.dart';

import '../api_client.dart';
import '../settings_store.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onSaved;

  const SettingsScreen({super.key, required this.onSaved});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _store = SettingsStore();
  final _serverUrlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _userIdCtrl = TextEditingController();

  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _serverUrlCtrl.text = await _store.getServerUrl() ?? '';
    _apiKeyCtrl.text = await _store.getApiKey() ?? '';
    _userIdCtrl.text = await _store.getUserId() ?? '';
    setState(() {});
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    await _store.save(
      serverUrl: _serverUrlCtrl.text,
      apiKey: _apiKeyCtrl.text,
      userId: _userIdCtrl.text,
    );
    final ok = await ApiClient().healthCheck();
    setState(() {
      _testing = false;
      _testResult = ok ? '✅ 連線成功！' : '❌ 連不到，檢查一下網址對不對、伺服器是不是還開著';
    });
  }

  Future<void> _saveAndContinue() async {
    if (_serverUrlCtrl.text.trim().isEmpty ||
        _apiKeyCtrl.text.trim().isEmpty ||
        _userIdCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('三個欄位都要填喔')),
      );
      return;
    }
    await _store.save(
      serverUrl: _serverUrlCtrl.text,
      apiKey: _apiKeyCtrl.text,
      userId: _userIdCtrl.text,
    );
    widget.onSaved();
  }

  @override
  void dispose() {
    _serverUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _userIdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('連線設定')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '這幾個資訊會存在這台裝置本機，不會傳給第三方。\n'
              '目前還沒有真正的登入驗證，Discord user id 就是你的帳號，'
              '知道 id 的人也能動這個帳號的資產，先求堪用，之後會補上真正的登入系統。',
              style: TextStyle(color: Colors.grey),
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
            const SizedBox(height: 16),
            TextField(
              controller: _userIdCtrl,
              decoration: const InputDecoration(
                labelText: '你的 Discord User ID',
                hintText: '例如 123456789012345678',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: _testing ? null : _testConnection,
              child: _testing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('測試連線'),
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 8),
              Text(_testResult!, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saveAndContinue,
              child: const Text('儲存並開始使用'),
            ),
          ],
        ),
      ),
    );
  }
}
