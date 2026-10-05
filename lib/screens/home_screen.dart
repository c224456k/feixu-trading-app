import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../models.dart';
import '../settings_store.dart';
import '../update_checker.dart';
import '../widgets/candle_chart.dart';
import 'boss_screen.dart';
import 'baccarat_screen.dart';
import 'poker_screen.dart';
import 'horse_screen.dart';
import 'sicbo_screen.dart';
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

  FeixuSnapshot? _snapshot;
  FeixuChart? _chart;
  OrderBook? _book;
  List<Candle>? _candles;
  bool _candleMode = false;
  int _candleInterval = 5;
  Portfolio? _portfolio;
  String? _error;
  bool _loading = true;

  Timer? _timer;
  Timer? _bookTimer;

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
    _bookTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _refreshAll();
    // 每 5 秒刷新一次，跟 Discord 版的「即時更新」按鈕同一個節奏
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshAll(silent: true));
    // 五檔變動快，另外用 1 秒的計時器只更新委託簿（一支很輕的 API）
    _bookTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshBook());
  }

  Future<void> _refreshAll({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final snapshot = await _api.fetchSnapshot();
      final chart = await _api.fetchChart();
      final book = await _api.fetchBook();
      final candles = _candleMode ? await _api.fetchCandles(_candleInterval) : null;
      final portfolio = await _api.fetchPortfolio();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _chart = chart;
        _book = book;
        if (candles != null) _candles = candles;
        _portfolio = portfolio;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        _timer?.cancel();
        _bookTimer?.cancel();
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

  Future<void> _refreshBook() async {
    try {
      final book = await _api.fetchBook();
      if (!mounted) return;
      setState(() => _book = book);
    } catch (_) {
      // 委託簿只是顯示用，失敗就等下一次，不打斷畫面
    }
  }

  Future<void> _logout() async {
    _timer?.cancel();
    _bookTimer?.cancel();
    await _store.clearSession();
    widget.onLoggedOut();
  }

  Future<void> _tradeDialog(bool isBuy) async {
    final controller = TextEditingController();
    String? hint;
    if (_portfolio != null && _snapshot != null) {
      if (isBuy) {
        final maxLots = (_portfolio!.cash / (_snapshot!.price * 1000)).floor();
        hint = '最多可買 $maxLots 張';
      } else {
        final held = _portfolio!.holdings
            .where((h) => h.code == _snapshot!.code)
            .fold<int>(0, (sum, h) => sum + h.lots);
        hint = '目前持有 $held 張';
      }
    }

    TradeQuote? quote;
    String? quoteError;
    int quotedFor = 0;
    final lots = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> updateQuote(String text) async {
            final n = int.tryParse(text);
            quotedFor = n ?? 0;
            if (n == null || n <= 0) {
              setDialogState(() {
                quote = null;
                quoteError = null;
              });
              return;
            }
            try {
              final q = await _api.fetchQuote(isBuy, n);
              if (quotedFor != n) return; // 已經改輸入了，丟掉過期的結果
              setDialogState(() {
                quote = q;
                quoteError = null;
              });
            } catch (e) {
              if (quotedFor != n) return;
              setDialogState(() {
                quote = null;
                quoteError = '試算失敗';
              });
            }
          }

          return AlertDialog(
            title: Text(isBuy ? '買進費許(7333)' : '賣出費許(7333)'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  onChanged: updateQuote,
                  decoration: InputDecoration(
                    labelText: '張數${hint != null ? '（$hint）' : ''}',
                  ),
                ),
                const SizedBox(height: 12),
                if (quote != null)
                  Text(
                    '預估成交均價 ${quote!.avgPrice.toStringAsFixed(2)}'
                    '（滑價 ${quote!.slippagePct.toStringAsFixed(2)}%）',
                  )
                else if (quoteError != null)
                  Text(quoteError!, style: const TextStyle(color: Colors.orange))
                else
                  Text('輸入張數可試算成交均價', style: TextStyle(color: Colors.grey[600])),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, int.tryParse(controller.text)),
                child: Text(isBuy ? '買進' : '賣出'),
              ),
            ],
          );
        },
      ),
    );

    if (lots == null || lots <= 0) return;

    try {
      final result = isBuy ? await _api.buy(lots) : await _api.sell(lots);
      _showSnack(result.message);
      await _refreshAll();
    } on ApiException catch (e) {
      if (e.isAuthError) {
        await _store.clearSession();
        widget.onLoggedOut();
        return;
      }
      _showSnack('失敗：$e');
    } catch (e) {
      _showSnack('失敗：$e');
    }
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('費許（7333）'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FxScreen()),
            ),
            icon: const Icon(Icons.currency_yen),
            tooltip: '久留美幣 69M',
          ),
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
              MaterialPageRoute(builder: (_) => const LeaderboardScreen()),
            ),
            icon: const Icon(Icons.leaderboard),
            tooltip: '排行榜',
          ),
          IconButton(onPressed: _logout, icon: const Icon(Icons.logout), tooltip: '登出'),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refreshAll(),
        child: _loading && _snapshot == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _snapshot == null
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
    final snapshot = _snapshot!;
    final color = snapshot.isUp ? upColor : downColor;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snapshot.price.toStringAsFixed(2),
                  style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: color),
                ),
                Text(
                  '${snapshot.change >= 0 ? '+' : ''}${snapshot.change.toStringAsFixed(2)} '
                  '(${snapshot.changePct >= 0 ? '+' : ''}${snapshot.changePct.toStringAsFixed(2)}%)',
                  style: TextStyle(fontSize: 16, color: color),
                ),
                if (snapshot.statusNote != null) ...[
                  const SizedBox(height: 8),
                  Text(snapshot.statusNote!, style: const TextStyle(color: Colors.orange)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildChartToggle(),
        if (_candleMode) _buildCandleCard() else if (_chart != null) _buildChart(_chart!, color),
        const SizedBox(height: 12),
        if (_book != null) _buildOrderBook(_book!),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: upColor),
                onPressed: snapshot.tradable ? () => _tradeDialog(true) : null,
                child: const Text('買進'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: downColor),
                onPressed: snapshot.tradable ? () => _tradeDialog(false) : null,
                child: const Text('賣出'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_portfolio != null) _buildPortfolio(_portfolio!),
      ],
    );
  }

  Widget _buildOrderBook(OrderBook book) {
    final maxLots = [...book.asks, ...book.bids].map((l) => l.lots).fold<int>(1, (a, b) => a > b ? a : b);
    Widget row(String label, BookLevel l, Color c) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Stack(
          alignment: Alignment.centerRight,
          children: [
            FractionallySizedBox(
              widthFactor: l.lots / maxLots,
              child: Container(height: 20, color: c.withValues(alpha: 0.18)),
            ),
            Row(
              children: [
                SizedBox(width: 44, child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey))),
                Expanded(
                  child: Text(l.price.toStringAsFixed(2),
                      style: TextStyle(fontWeight: FontWeight.bold, color: c)),
                ),
                Text('${l.lots} 張'),
              ],
            ),
          ],
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('五檔報價', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            for (var i = book.asks.length - 1; i >= 0; i--) row('賣${i + 1}', book.asks[i], upColor),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(vertical: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.symmetric(horizontal: BorderSide(color: Colors.grey.withValues(alpha: 0.4))),
              ),
              child: Text('中價 ${book.mid.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13)),
            ),
            for (var i = 0; i < book.bids.length; i++) row('買${i + 1}', book.bids[i], downColor),
            const SizedBox(height: 6),
            Text(
              '下單會依檔位逐檔成交，量大價格會被推動（約 10 分鐘慢慢回復）',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChartToggle() {
    const intervals = {1: '1分', 5: '5分', 15: '15分', 60: '1時', 1440: '日'};
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ChoiceChip(
            label: const Text('走勢'),
            selected: !_candleMode,
            onSelected: (_) => setState(() => _candleMode = false),
          ),
          ChoiceChip(
            label: const Text('K線'),
            selected: _candleMode,
            onSelected: (_) {
              setState(() => _candleMode = true);
              _loadCandles();
            },
          ),
          if (_candleMode)
            for (final e in intervals.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _candleInterval == e.key,
                onSelected: (_) {
                  setState(() {
                    _candleInterval = e.key;
                    _candles = null;
                  });
                  _loadCandles();
                },
              ),
        ],
      ),
    );
  }

  Future<void> _loadCandles() async {
    try {
      final interval = _candleInterval;
      final candles = await _api.fetchCandles(interval);
      if (!mounted || interval != _candleInterval) return;
      setState(() => _candles = candles);
    } catch (_) {
      // 下一輪 5 秒刷新會再試
    }
  }

  Widget _buildCandleCard() {
    return SizedBox(
      height: 300,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
          child: _candles == null
              ? const Center(child: CircularProgressIndicator())
              : CandleChart(candles: _candles!, daily: _candleInterval == 1440),
        ),
      ),
    );
  }

  Widget _buildChart(FeixuChart chart, Color lineColor) {
    if (chart.points.isEmpty) return const SizedBox.shrink();
    final spots = <FlSpot>[];
    for (var i = 0; i < chart.points.length; i++) {
      spots.add(FlSpot(i.toDouble(), chart.points[i].price));
    }
    final minY = chart.points.map((p) => p.price).reduce((a, b) => a < b ? a : b);
    final maxY = chart.points.map((p) => p.price).reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY) * 0.1 + 0.01;

    // 把事件時間對應到 X 軸的點位（用最接近的資料點索引），畫上垂直標記線，
    // 避免大漲大跌看起來像斷開的兩張圖，跟 Discord 版的圖表邏輯一致。
    final eventLines = <VerticalLine>[];
    for (final ev in chart.events) {
      var closestIndex = 0;
      var closestDiff = const Duration(days: 9999);
      for (var i = 0; i < chart.points.length; i++) {
        final diff = chart.points[i].time.difference(ev.time).abs();
        if (diff < closestDiff) {
          closestDiff = diff;
          closestIndex = i;
        }
      }
      final markerColor = ev.type == 'black_swan'
          ? Colors.redAccent
          : ev.type == 'great_news'
              ? Colors.amber
              : Colors.grey;
      eventLines.add(
        VerticalLine(
          x: closestIndex.toDouble(),
          color: markerColor.withValues(alpha: 0.85),
          strokeWidth: 1.4,
          dashArray: [4, 4],
          label: VerticalLineLabel(
            show: true,
            labelResolver: (_) => ev.label,
            style: TextStyle(color: markerColor, fontSize: 10),
            alignment: Alignment.topCenter,
          ),
        ),
      );
    }

    return SizedBox(
      height: 260,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 20, 16, 8),
          child: LineChart(
            LineChartData(
              minY: minY - pad,
              maxY: maxY + pad,
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    interval: (chart.points.length / 4).clamp(1, 999),
                    getTitlesWidget: (value, meta) {
                      final i = value.toInt();
                      if (i < 0 || i >= chart.points.length) return const SizedBox.shrink();
                      return Text(
                        DateFormat('HH:mm').format(chart.points[i].time.toLocal()),
                        style: const TextStyle(fontSize: 10),
                      );
                    },
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(showTitles: true, reservedSize: 44),
                ),
              ),
              borderData: FlBorderData(show: false),
              extraLinesData: ExtraLinesData(verticalLines: eventLines),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (touchedSpots) => touchedSpots.map((s) {
                    final i = s.x.toInt().clamp(0, chart.points.length - 1);
                    final time = DateFormat('HH:mm').format(chart.points[i].time.toLocal());
                    return LineTooltipItem(
                      '$time\n${s.y.toStringAsFixed(2)}',
                      const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    );
                  }).toList(),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: false,
                  color: lineColor,
                  barWidth: 2.4,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: true, color: lineColor.withValues(alpha: 0.15)),
                ),
              ],
            ),
          ),
        ),
      ),
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
