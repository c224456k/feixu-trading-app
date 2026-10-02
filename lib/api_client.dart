import 'dart:convert';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:http/http.dart' as http;

import 'models.dart';
import 'settings_store.dart';

class ApiException implements Exception {
  final String message;
  final bool isAuthError; // token 過期/無效，畫面層看到這個要導去重新登入
  ApiException(this.message, {this.isAuthError = false});
  @override
  String toString() => message;
}

// 所有跟後端（feixu_api.py）溝通的地方都集中在這，畫面層不用自己組網址/處理 header。
class ApiClient {
  final SettingsStore _settings = SettingsStore();

  // 不能用 dart:io 的 Platform（網頁版不支援它，會直接編譯失敗），改用 kIsWeb / defaultTargetPlatform。
  String _clientPlatform() {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform == TargetPlatform.windows ? 'windows' : 'app';
  }

  Future<Map<String, String>> _headers({bool withAuth = false}) async {
    final apiKey = await _settings.getApiKey();
    final headers = {
      'Content-Type': 'application/json',
      'X-API-Key': apiKey ?? '',
      // 讓後端知道這次是 App（手機）還是 Windows 軟體打的，Boss 攻擊會拿這個去 Discord 公告，
      // 讓 Discord 那邊也看得到「誰在哪個平台丟了炸彈」。
      'X-Client-Platform': _clientPlatform(),
    };
    if (withAuth) {
      final token = await _settings.getToken();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    return headers;
  }

  Future<String> _baseUrl() async {
    final url = await _settings.getServerUrl();
    if (url == null || url.isEmpty) {
      throw ApiException('還沒設定伺服器網址，先去設定頁面填一下');
    }
    return url;
  }

  Future<T> _get<T>(String path, T Function(dynamic json) parse, {bool withAuth = false}) async {
    final base = await _baseUrl();
    final headers = await _headers(withAuth: withAuth);
    http.Response resp;
    try {
      resp = await http.get(Uri.parse('$base$path'), headers: headers).timeout(
            const Duration(seconds: 20),
          );
    } catch (e) {
      throw ApiException('連不到伺服器，檢查一下網址或網路：$e');
    }
    _checkStatus(resp);
    return parse(jsonDecode(utf8.decode(resp.bodyBytes)));
  }

  Future<T> _post<T>(
    String path,
    Map<String, dynamic> body,
    T Function(dynamic json) parse, {
    bool withAuth = false,
  }) async {
    final base = await _baseUrl();
    final headers = await _headers(withAuth: withAuth);
    http.Response resp;
    try {
      resp = await http
          .post(Uri.parse('$base$path'), headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw ApiException('連不到伺服器，檢查一下網址或網路：$e');
    }
    _checkStatus(resp);
    return parse(jsonDecode(utf8.decode(resp.bodyBytes)));
  }

  void _checkStatus(http.Response resp) {
    if (resp.statusCode == 401) {
      String detail = '沒有登入或登入已過期，請重新登入';
      try {
        final body = jsonDecode(utf8.decode(resp.bodyBytes));
        if (body is Map && body['detail'] != null) detail = body['detail'].toString();
      } catch (_) {}
      throw ApiException(detail, isAuthError: true);
    }
    if (resp.statusCode >= 400) {
      throw ApiException('伺服器回應錯誤（HTTP ${resp.statusCode}）：${resp.body}');
    }
  }

  Future<FeixuSnapshot> fetchSnapshot() =>
      _get('/api/feixu/snapshot', (j) => FeixuSnapshot.fromJson(j as Map<String, dynamic>));

  Future<FeixuChart> fetchChart() =>
      _get('/api/feixu/chart', (j) => FeixuChart.fromJson(j as Map<String, dynamic>));

  // 故意不接受 user_id 參數：只能查詢/操作「登入的那個人」自己的帳號，反推身分靠 token。
  Future<Portfolio> fetchPortfolio() => _get(
        '/api/portfolio',
        (j) => Portfolio.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<TradeResult> buy(int lots) => _post(
        '/api/feixu/buy',
        {'lots': lots},
        (j) => TradeResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<TradeResult> sell(int lots) => _post(
        '/api/feixu/sell',
        {'lots': lots},
        (j) => TradeResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<BossStatus> fetchBossStatus() =>
      _get('/api/boss/status', (j) => BossStatus.fromJson(j as Map<String, dynamic>));

  Future<SicBoState> fetchSicBoState() => _get(
        '/api/sicbo/state',
        (j) => SicBoState.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> sitSicBo(int seat) => _post(
        '/api/sicbo/sit',
        {'seat': seat},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> leaveSicBo() => _post(
        '/api/sicbo/leave',
        {},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<BaccaratState> fetchBaccaratState() => _get(
        '/api/baccarat/state',
        (j) => BaccaratState.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> placeBaccaratBet(String betType, int amount) => _post(
        '/api/baccarat/bet',
        {'bet_type': betType, 'amount': amount},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> sitBaccarat(int seat) => _post(
        '/api/baccarat/sit',
        {'seat': seat},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> leaveBaccarat() => _post(
        '/api/baccarat/leave',
        {},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<HorseState> fetchHorseState() => _get(
        '/api/horse/state',
        (j) => HorseState.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  // betType 格式：win:3（壓 3 號冠軍）/ second:3（壓 3 號亞軍）
  Future<SicBoBetResult> placeHorseBet(String betType, int amount) => _post(
        '/api/horse/bet',
        {'bet_type': betType, 'amount': amount},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> sitHorse(int seat) => _post(
        '/api/horse/sit',
        {'seat': seat},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> leaveHorse() => _post(
        '/api/horse/leave',
        {},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> placeSicBoBet(String betType, int amount) => _post(
        '/api/sicbo/bet',
        {'bet_type': betType, 'amount': amount},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<BossAttackResult> attackBoss() => _post(
        '/api/boss/attack',
        {},
        (j) => BossAttackResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  /// 登入：用 Discord user id + 密碼（密碼要先在 Discord 私訊機器人設定）換一組 token。
  /// 成功會把 token 存到本機，之後的呼叫就不用再傳密碼。
  Future<void> login(String userId, String password) async {
    final base = await _baseUrl();
    final headers = await _headers();
    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$base/api/auth/login'),
            headers: headers,
            body: jsonEncode({'user_id': userId, 'password': password}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw ApiException('連不到伺服器，檢查一下網址或網路：$e');
    }
    _checkStatus(resp);
    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    await _settings.saveSession(token: json['token'] as String, userId: json['user_id'] as String);
  }

  Future<List<LeaderboardEntry>> fetchLeaderboard() => _get(
        '/api/leaderboard',
        (j) => (j as List).map((e) => LeaderboardEntry.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Future<bool> healthCheck() async {
    final base = await _baseUrl();
    try {
      final resp = await http
          .get(Uri.parse('$base/api/health'))
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
