import 'package:shared_preferences/shared_preferences.dart';

// 這幾個值存在手機/電腦本機（SharedPreferences），不會傳給任何第三方。
// 目前沒有真正的登入系統，userId 就是你自己的 Discord user id（跟 Discord 版是同一個帳號、
// 同一筆現金/持股），apiKey 是後端那組共用金鑰，serverUrl 是 Cloudflare Tunnel 網址
// （目前還是臨時網址，重新開 tunnel 會換，換了要記得回來這裡改掉）。
class SettingsStore {
  static const _keyServerUrl = 'server_url';
  static const _keyApiKey = 'api_key';
  static const _keyUserId = 'user_id';

  Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyServerUrl);
  }

  Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiKey);
  }

  Future<String?> getUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUserId);
  }

  Future<void> save({
    required String serverUrl,
    required String apiKey,
    required String userId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    // 去掉網址結尾的斜線，避免組出 "https://xxx//api/..." 這種雙斜線路徑
    final cleanUrl = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    await prefs.setString(_keyServerUrl, cleanUrl);
    await prefs.setString(_keyApiKey, apiKey.trim());
    await prefs.setString(_keyUserId, userId.trim());
  }

  Future<bool> isConfigured() async {
    final url = await getServerUrl();
    final key = await getApiKey();
    final uid = await getUserId();
    return url != null &&
        url.isNotEmpty &&
        key != null &&
        key.isNotEmpty &&
        uid != null &&
        uid.isNotEmpty;
  }
}
