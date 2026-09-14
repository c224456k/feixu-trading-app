import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';
import '../settings_store.dart';

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
  Portfolio? _portfolio;
  String? _error;
  bool _loading = true;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _refreshAll();
    // 每 5 秒刷新一次，跟 Discord 版的「即時更新」按鈕同一個節奏
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshAll(silent: true));
  }

  Future<void> _refreshAll({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final snapshot = await _api.fetchSnapshot();
      final chart = await _api.fetchChart();
      final portfolio = await _api.fetchPortfolio();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _chart = chart;
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

    final lots = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isBuy ? '買進費許(7333)' : '賣出費許(7333)'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: '張數${hint != null ? '（$hint）' : ''}',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(controller.text)),
            child: Text(isBuy ? '買進' : '賣出'),
          ),
        ],
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
        if (_chart != null) _buildChart(_chart!, color),
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
                        DateFormat('HH:mm').format(chart.points[i].time),
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
