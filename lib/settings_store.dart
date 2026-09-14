import 'package:shared_preferences/shared_preferences.dart';

// serverUrl / apiKey 是連線用的設定；token 是登入後拿到的通行證（不是密碼本身），
// 之後每次呼叫 API 都靠這個反推身分，伺服器不會再相信客戶端自己講的 user_id。
class SettingsStore {
  static const _keyServerUrl = 'server_url';
  static const _keyApiKey = 'api_key';
  static const _keyToken = 'auth_token';
  static const _keyDisplayUserId = 'display_user_id';

  Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyServerUrl);
  }

  Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyApiKey);
  }

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyToken);
  }

  Future<String?> getDisplayUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDisplayUserId);
  }

  Future<void> saveConnection({required String serverUrl, required String apiKey}) async {
    final prefs = await SharedPreferences.getInstance();
    // 去掉網址結尾的斜線，避免組出 "https://xxx//api/..." 這種雙斜線路徑
    final cleanUrl = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    await prefs.setString(_keyServerUrl, cleanUrl);
    await prefs.setString(_keyApiKey, apiKey.trim());
  }

  Future<void> saveSession({required String token, required String userId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyToken, token);
    await prefs.setString(_keyDisplayUserId, userId);
  }

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken);
    await prefs.remove(_keyDisplayUserId);
  }

  Future<bool> hasConnectionInfo() async {
    final url = await getServerUrl();
    final key = await getApiKey();
    return url != null && url.isNotEmpty && key != null && key.isNotEmpty;
  }

  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }
}
