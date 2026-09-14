import 'dart:convert';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'settings_store.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

// 所有跟後端（feixu_api.py）溝通的地方都集中在這，畫面層不用自己組網址/處理 header。
class ApiClient {
  final SettingsStore _settings = SettingsStore();

  Future<Map<String, String>> _headers() async {
    final apiKey = await _settings.getApiKey();
    return {
      'Content-Type': 'application/json',
      'X-API-Key': apiKey ?? '',
    };
  }

  Future<String> _baseUrl() async {
    final url = await _settings.getServerUrl();
    if (url == null || url.isEmpty) {
      throw ApiException('還沒設定伺服器網址，先去設定頁面填一下');
    }
    return url;
  }

  Future<T> _get<T>(String path, T Function(dynamic json) parse) async {
    final base = await _baseUrl();
    final headers = await _headers();
    http.Response resp;
    try {
      resp = await http.get(Uri.parse('$base$path'), headers: headers).timeout(
            const Duration(seconds: 10),
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
    T Function(dynamic json) parse,
  ) async {
    final base = await _baseUrl();
    final headers = await _headers();
    http.Response resp;
    try {
      resp = await http
          .post(Uri.parse('$base$path'), headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      throw ApiException('連不到伺服器，檢查一下網址或網路：$e');
    }
    _checkStatus(resp);
    return parse(jsonDecode(utf8.decode(resp.bodyBytes)));
  }

  void _checkStatus(http.Response resp) {
    if (resp.statusCode == 401) {
      throw ApiException('API Key 不對，去設定頁面確認一下');
    }
    if (resp.statusCode >= 400) {
      throw ApiException('伺服器回應錯誤（HTTP ${resp.statusCode}）：${resp.body}');
    }
  }

  Future<FeixuSnapshot> fetchSnapshot() =>
      _get('/api/feixu/snapshot', (j) => FeixuSnapshot.fromJson(j as Map<String, dynamic>));

  Future<FeixuChart> fetchChart() =>
      _get('/api/feixu/chart', (j) => FeixuChart.fromJson(j as Map<String, dynamic>));

  Future<Portfolio> fetchPortfolio(String userId) => _get(
        '/api/portfolio/$userId',
        (j) => Portfolio.fromJson(j as Map<String, dynamic>),
      );

  Future<TradeResult> buy(String userId, int lots) => _post(
        '/api/feixu/buy',
        {'user_id': userId, 'lots': lots},
        (j) => TradeResult.fromJson(j as Map<String, dynamic>),
      );

  Future<TradeResult> sell(String userId, int lots) => _post(
        '/api/feixu/sell',
        {'user_id': userId, 'lots': lots},
        (j) => TradeResult.fromJson(j as Map<String, dynamic>),
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
