import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../models.dart';
import '../settings_store.dart';
import '../update_checker.dart';
import 'boss_screen.dart';
import 'baccarat_screen.dart';
import 'poker_screen.dart';
import 'horse_screen.dart';
import 'sicbo_screen.dart';
import 'slot_screen.dart';
import 'hero_screen.dart';
import 'leaderboard_screen.dart';
import 'fx_screen.dart';

// 台股習慣：紅漲、綠跌（跟美股相反），這個 App 是給台灣玩家用的，顏色要照這個規則，
// 不能套用國外套件常見的預設「綠漲紅跌」。
const upColor = Color(0xFFFF5A5F);
const downColor = Color(0xFF2ECC71);

class HomeScreen extends StatefulWidget {
  // 登入過期（token 失效）或使用者主動登出時呼叫，交給上層（_StartupGate）決定
  // 要導回登入頁，這個畫面本身不做導頁邏輯，職責單純一點。
  final VoidCallback onLoggedOut;

  const HomeScreen({super.key, required this.onLoggedOut});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = ApiClient();
  final _store = SettingsStore();

  Portfolio? _portfolio;
  String? _error;
  bool _loading = true;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _checkForUpdate();
  }

  Future<void> _checkForUpdate() async {
    final info = await UpdateChecker().checkForUpdate();
    if (info == null || !mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('有新版本囉'),
        content: Text('最新版本是 v${info.latestVersion}，建議更新才能玩到最新功能。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍後再說')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await launchUrl(Uri.parse(info.releaseUrl), mode: LaunchMode.externalApplication);
            },
            child: const Text('前往下載'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _refreshAll();
    // 每 5 秒刷新一次總資產（久留美幣報價面板自己另有 3 秒的計時器）
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshAll(silent: true));
  }

  Future<void> _refreshAll({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final portfolio = await _api.fetchPortfolio();
      if (!mounted) return;
      setState(() {
        _portfolio = portfolio;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        _timer?.cancel();
        await _store.clearSession();
        widget.onLoggedOut();
        return;
      }
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _logout() async {
    _timer?.cancel();
    await _store.clearSession();
    widget.onLoggedOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('久留美幣（96）'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BossScreen()),
            ),
            icon: const Icon(Icons.local_fire_department),
            tooltip: '打 Boss',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PokerScreen()),
            ),
            icon: const Icon(Icons.filter_vintage),
            tooltip: '德州撲克',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HorseScreen()),
            ),
            icon: const Icon(Icons.emoji_events),
            tooltip: '賭馬',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BaccaratScreen()),
            ),
            icon: const Icon(Icons.style),
            tooltip: '百家樂',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SicBoScreen()),
            ),
            icon: const Icon(Icons.casino),
            tooltip: '骰寶',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SlotScreen()),
            ),
            icon: const Icon(Icons.stars),
            tooltip: '老虎機',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HeroScreen()),
            ),
            icon: const Icon(Icons.shield),
            tooltip: '勇者裝備',
          ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
            ),
            icon: const Icon(Icons.leaderboard),
            tooltip: '排行榜',
          ),
          IconButton(onPressed: _logout, icon: const Icon(Icons.logout), tooltip: '登出'),
        ],
      ),      body: RefreshIndicator(
        onRefresh: () => _refreshAll(),
        child: _loading && _portfolio == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _portfolio == null
                ? _buildErrorView()
                : _buildContent(),
      ),
    );
  }

  Widget _buildErrorView() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 60),
        Icon(Icons.cloud_off, size: 48, color: Colors.grey[600]),
        const SizedBox(height: 12),
        Text(_error ?? '', textAlign: TextAlign.center),
        const SizedBox(height: 20),
        FilledButton(onPressed: () => _refreshAll(), child: const Text('重試')),
        const SizedBox(height: 8),
        TextButton(onPressed: _logout, child: const Text('登出、重新設定連線')),
      ],
    );
  }
  Widget _buildContent() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FxPanel(onTraded: () => _refreshAll(silent: true)),
        const SizedBox(height: 16),
        if (_portfolio != null) _buildPortfolio(_portfolio!),
      ],
    );
  }

  Widget _buildPortfolio(Portfolio p) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('我的投資組合', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            _statRow('現金部位', '${_fmt(p.cash)} 元'),
            _statRow('股票部位', '${_fmt(p.totalMarketValue)} 元'),
            _statRow('總資產', '${_fmt(p.totalAssets)} 元'),
            _statRow('已實現損益', '${_fmtSigned(p.realizedPnl)} 元',
                color: p.realizedPnl >= 0 ? upColor : downColor),
            _statRow('未實現損益', '${_fmtSigned(p.totalUnrealizedPnl)} 元',
                color: p.totalUnrealizedPnl >= 0 ? upColor : downColor),
            if (p.holdings.isNotEmpty) ...[
              const Divider(height: 24),
              const Text('持股明細', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...p.holdings.map(
                (h) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${h.code} ${h.name}　${h.lots}${h.unit}　均價 ${h.avgCost.toStringAsFixed(2)}'
                    '${h.price != null ? '　現價 ${h.price!.toStringAsFixed(2)}' : ''}',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  String _fmt(double v) => NumberFormat('#,##0').format(v);
  String _fmtSigned(double v) => (v >= 0 ? '+' : '') + NumberFormat('#,##0').format(v);
}
