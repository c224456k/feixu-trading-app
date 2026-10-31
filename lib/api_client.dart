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

  Future<List<Candle>> fetchCandles(int interval, {int count = 60}) => _get(
        '/api/feixu/candles?interval=$interval&count=$count',
        (j) => (((j as Map<String, dynamic>)['candles']) as List)
            .map((e) => Candle.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<OrderBook> fetchBook() =>
      _get('/api/feixu/book', (j) => OrderBook.fromJson(j as Map<String, dynamic>));

  Future<TradeQuote> fetchQuote(bool isBuy, int lots) => _get(
        '/api/feixu/quote?side=${isBuy ? 'buy' : 'sell'}&lots=$lots',
        (j) => TradeQuote.fromJson(j as Map<String, dynamic>),
      );

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

  Future<PokerState> fetchPokerState() => _get(
        '/api/poker/state',
        (j) => PokerState.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> sitPoker(int seat, int buyin) => _post(
        '/api/poker/sit',
        {'seat': seat, 'buyin': buyin},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> leavePoker() => _post(
        '/api/poker/leave',
        {},
        (j) => SicBoBetResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<SicBoBetResult> pokerAction(String action, {int? amount}) => _post(
        '/api/poker/action',
        {'action': action, if (amount != null) 'amount': amount},
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

  Future<Map<String, dynamic>> fetchHeroEquipment() =>
      _get('/api/hero/equipment', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> fetchHeroShop() =>
      _get('/api/hero/shop', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> heroShopBuy(String itemId) =>
      _post('/api/hero/shop/buy', {'item_id': itemId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> heroEquip(int invId, {String? slot}) => _post(
      '/api/hero/equip', {'inv_id': invId, if (slot != null) 'slot': slot}, (j) => j as Map<String, dynamic>,
      withAuth: true);

  // 弓箭肉鴿
  Future<Map<String, dynamic>> rogueState() => _get('/api/rogue/state', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> rogueStart() => _post('/api/rogue/start', {}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> rogueBegin(int runId) =>
      _post('/api/rogue/begin', {'run_id': runId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> rogueProgress(int runId, int chapter, Map<String, dynamic> stats) => _post(
      '/api/rogue/progress', {'run_id': runId, 'chapter': chapter, 'stats': stats}, (j) => j as Map<String, dynamic>,
      withAuth: true);

  Future<Map<String, dynamic>> rogueRevive(int runId) =>
      _post('/api/rogue/revive', {'run_id': runId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> rogueGiveUp(int runId) =>
      _post('/api/rogue/give_up', {'run_id': runId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> rogueResume(int runId) =>
      _post('/api/rogue/resume', {'run_id': runId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> fetchTowerState() =>
      _get('/api/tower/state', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> towerEnter(int floor) =>
      _post('/api/tower/enter', {'floor': floor}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> towerFight() =>
      _post('/api/tower/fight', {}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> towerLeave() =>
      _post('/api/tower/leave', {}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> heroDismantle(int invId) =>
      _post('/api/hero/dismantle', {'inv_id': invId}, (j) => j as Map<String, dynamic>, withAuth: true);
  Future<Map<String, dynamic>> heroDiscard(int invId) =>
      _post('/api/hero/discard', {'inv_id': invId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> heroAckDrops() =>
      _post('/api/hero/drops/ack', {}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> heroEnhance(String scroll, {int? invId, String? slot}) => _post(
      '/api/hero/enhance',
      {'scroll': scroll, if (invId != null) 'inv_id': invId, if (slot != null) 'slot': slot},
      (j) => j as Map<String, dynamic>,
      withAuth: true);

  Future<Map<String, dynamic>> heroDiscardCard(String cardId, {int n = 1}) =>
      _post('/api/hero/discard_card', {'card_id': cardId, 'n': n}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> arenaState() =>
      _get('/api/arena/state', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> arenaPlayers(String q) =>
      _get('/api/arena/players?q=${Uri.encodeQueryComponent(q)}', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> arenaChallenge(String targetId) =>
      _post('/api/arena/challenge', {'target_id': targetId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> arenaRespond(int duelId, bool accept) =>
      _post('/api/arena/respond', {'duel_id': duelId, 'accept': accept}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> arenaCancel(int duelId) =>
      _post('/api/arena/cancel', {'duel_id': duelId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> heroSocket(String cardId, {int? invId, String? slot}) => _post(
      '/api/hero/socket',
      {'card_id': cardId, if (invId != null) 'inv_id': invId, if (slot != null) 'slot': slot},
      (j) => j as Map<String, dynamic>,
      withAuth: true);

  Future<Map<String, dynamic>> heroUnsocket(int index, {int? invId, String? slot}) => _post(
      '/api/hero/unsocket',
      {'index': index, if (invId != null) 'inv_id': invId, if (slot != null) 'slot': slot},
      (j) => j as Map<String, dynamic>,
      withAuth: true);

  Future<Map<String, dynamic>> heroUnequip(String slot) =>
      _post('/api/hero/unequip', {'slot': slot}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> fetchSlotInfo() =>
      _get('/api/slot/info', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> fetchSlotJackpot() =>
      _get('/api/slot/jackpot', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> slotSpin(int bet) =>
      _post('/api/slot/spin', {'bet': bet}, (j) => j as Map<String, dynamic>, withAuth: true);

  // 回傳 {seconds: 冷卻剩餘秒數, bomb_damage: 我現在一顆炸彈的傷害（含裝備加成）}
  Future<Map<String, dynamic>> fetchBossCooldown() =>
      _get('/api/boss/cooldown', (j) => j as Map<String, dynamic>, withAuth: true);

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

  Future<FxQuote> fetchFxQuote() =>
      _get('/api/fx/quote', (j) => FxQuote.fromJson(j as Map<String, dynamic>));

  Future<List<ChartPoint>> fetchFxChart({int hours = 1}) => _get(
        '/api/fx/chart?hours=$hours',
        (j) => ((j as Map<String, dynamic>)['points'] as List)
            .map((e) => ChartPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<List<Candle>> fetchFxCandles({int minutes = 60}) => _get(
        '/api/fx/candles?minutes=$minutes',
        (j) => ((j as Map<String, dynamic>)['candles'] as List)
            .map((e) => Candle.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Future<FxAccount> fetchFxAccount() => _get(
        '/api/fx/account',
        (j) => FxAccount.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<TradeResult> fxTrade(String side, int lots, {int? leverage}) => _post(
        '/api/fx/trade',
        {'side': side, 'lots': lots, if (leverage != null) 'leverage': leverage},
        (j) => TradeResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<TradeResult> fxClose() => _post(
        '/api/fx/close',
        {},
        (j) => TradeResult.fromJson(j as Map<String, dynamic>),
        withAuth: true,
      );

  Future<List<LeaderboardEntry>> fetchLeaderboard({int season = 0}) => _get(
        '/api/leaderboard?top_n=50&season=$season',
        (j) => (j as List).map((e) => LeaderboardEntry.fromJson(e as Map<String, dynamic>)).toList(),
      );

  Future<Map<String, dynamic>> marketState({String card = ''}) =>
      _get('/api/market/state?card=${Uri.encodeQueryComponent(card)}', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> marketSell(String cardId, int price) =>
      _post('/api/market/sell', {'card_id': cardId, 'price': price}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> marketBuy(int listingId) =>
      _post('/api/market/buy', {'listing_id': listingId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> marketCancel(int listingId) =>
      _post('/api/market/cancel', {'listing_id': listingId}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> tdState() =>
      _get('/api/td/state', (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> tdBuild(String type, int x, int y) =>
      _post('/api/td/build', {'type': type, 'x': x, 'y': y}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> tdUpgrade(int x, int y) =>
      _post('/api/td/upgrade', {'x': x, 'y': y}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> tdSell(int x, int y) =>
      _post('/api/td/sell', {'x': x, 'y': y}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> tdMove(int x, int y, int nx, int ny) =>
      _post('/api/td/move', {'x': x, 'y': y, 'nx': nx, 'ny': ny}, (j) => j as Map<String, dynamic>, withAuth: true);

  Future<Map<String, dynamic>> tdStart() =>
      _post('/api/td/start', {}, (j) => j as Map<String, dynamic>, withAuth: true);

  /// 怪物打排球的 WebSocket 連線資訊：(wss 網址, API key, 登入 token)。
  Future<(String, String, String)> volleyConnectInfo() async {
    final base = await _baseUrl();
    final key = await _settings.getApiKey() ?? '';
    final token = await _settings.getToken() ?? '';
    if (token.isEmpty) throw ApiException('登入已過期，請重新登入', isAuthError: true);
    final ws = base.replaceFirst(RegExp(r'^http'), 'ws');
    return ('$ws/ws/volley', key, token);
  }

  /// 弓箭肉鴿雙人合作的 WebSocket 連線資訊（同排球，只是路徑不同）。
  Future<(String, String, String)> rogueCoopConnectInfo() async {
    final (url, key, token) = await volleyConnectInfo();
    return (url.replaceFirst(RegExp(r'/ws/volley$'), '/ws/rogue2'), key, token);
  }

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
