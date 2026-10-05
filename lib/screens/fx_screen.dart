import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';

// 台股習慣：紅漲綠跌。
const _upColor = Color(0xFFFF5A5F);
const _downColor = Color(0xFF2ECC71);

/// 第二季：久留美幣（96）兌日圓的保證金交易。價格是遊戲自己模擬的，不跟真實匯率連動。
/// 買進 = 做多久留美幣，賣出 = 做空。1 手 = 1 萬久留美幣，槓桿 20 倍，權益低於保證金一半會被強平。
class FxScreen extends StatelessWidget {
  const FxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('💴 久留美幣 96（第二季）')),
      body: ListView(padding: const EdgeInsets.all(16), children: const [FxPanel()]),
    );
  }
}

/// 久留美幣的交易面板（報價、走勢、持倉、下單、成交紀錄），首頁與獨立頁面共用。
class FxPanel extends StatefulWidget {
  // 下單 / 平倉成功後通知上層（首頁用來立刻刷新總資產）
  final VoidCallback? onTraded;

  const FxPanel({super.key, this.onTraded});

  @override
  State<FxPanel> createState() => _FxPanelState();
}

class _FxPanelState extends State<FxPanel> {
  final _api = ApiClient();
  final _lotsController = TextEditingController(text: '1');
  int _leverage = 20;

  FxQuote? _quote;
  FxAccount? _account;
  List<ChartPoint> _chart = [];
  String? _error;
  bool _busy = false;
  Timer? _timer;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lotsController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      // 三支 API 同時送出（之前是一支等一支，經過 Cloudflare 隧道每支 0.4~0.9 秒，疊起來就很慢）
      final needChart = _tick % 4 == 0 || _chart.isEmpty;
      final quoteF = _api.fetchFxQuote();
      final accountF = _api.fetchFxAccount();
      final chartF = needChart ? _api.fetchFxChart() : null;
      final quote = await quoteF;
      final account = await accountF;
      final chart = chartF != null ? await chartF : _chart;
      _tick++;
      if (!mounted) return;
      setState(() {
        _quote = quote;
        _account = account;
        _chart = chart;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  /// 伺服器的走勢點是每分鐘一點，最後一點會落後現價；
  /// 這裡在尾端補上「目前報價」，線圖尖端就會跟著每次刷新（約 3 秒）即時移動。
  List<ChartPoint> get _points {
    final q = _quote;
    if (q == null || _chart.isEmpty) return _chart;
    return [..._chart, ChartPoint(time: q.quoteTime, price: q.mid)];
  }

  int get _lots => int.tryParse(_lotsController.text) ?? 0;

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _trade(String side) async {
    if (_lots <= 0) {
      _snack('手數要大於 0');
      return;
    }
    setState(() => _busy = true);
    try {
      // 已有同方向部位時加倉沿用原本槓桿（不送倍數）；沒部位或反向才用滑桿選的倍數
      final pos = _account?.position;
      final sameSide = pos != null && ((pos.side == 'long') == (side == 'buy'));
      final r = await _api.fxTrade(side, _lots, leverage: sameSide ? null : _leverage);
      _snack(r.message);
      await _refresh();
      widget.onTraded?.call();
    } catch (e) {
      _snack('失敗：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeAll() async {
    setState(() => _busy = true);
    try {
      final r = await _api.fxClose();
      _snack(r.message);
      await _refresh();
      widget.onTraded?.call();
    } catch (e) {
      _snack('失敗：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _money(double v) => NumberFormat('#,##0').format(v);
  String _signed(double v) => '${v >= 0 ? '+' : ''}${_money(v)}';

  @override
  Widget build(BuildContext context) {
    if (_quote == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: _error != null ? Text(_error!, textAlign: TextAlign.center) : const CircularProgressIndicator(),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildQuoteCard(_quote!),
        const SizedBox(height: 12),
        if (_chart.length > 1) _buildChart(),
        const SizedBox(height: 12),
        _buildPositionCard(),
        const SizedBox(height: 12),
        _buildOrderCard(_quote!),
        const SizedBox(height: 12),
        _buildTrades(),
        const SizedBox(height: 8),
        Text(
          '久留美幣（96）是遊戲自創的虛擬貨幣，價格為模擬走勢，不跟真實匯率連動，24 小時可交易。'
          '1 手 = 1 萬久留美幣名目本金，槓桿可選 ${_quote!.minLeverage}~${_quote!.maxLeverage} 倍（預設 ${_quote!.leverage} 倍）。'
          '買進＝做多、賣出＝做空；權益低於保證金 50% 會被強制平倉，最多賠光保證金。',
          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
        ),
      ],
    );
  }

  Widget _buildQuoteCard(FxQuote q) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1 久留美幣 =', style: TextStyle(fontSize: 12, color: Colors.grey)),
            Text('${q.mid.toStringAsFixed(4)} 日圓', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Row(
              children: [
                Text('賣價 ${q.bid.toStringAsFixed(4)}', style: const TextStyle(color: _downColor)),
                const SizedBox(width: 16),
                Text('買價 ${q.ask.toStringAsFixed(4)}', style: const TextStyle(color: _upColor)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              q.open
                  ? '報價時間 ${DateFormat('HH:mm:ss').format(q.quoteTime.toLocal())}'
                  '（${q.ageSeconds < 90 ? '${q.ageSeconds.round()} 秒前' : '約 ${(q.ageSeconds / 60).floor()} 分鐘前'}）'
                  : '⏸ 休市中，最後報價 ${DateFormat('MM/dd HH:mm').format(q.quoteTime.toLocal())}',
              style: TextStyle(fontSize: 12, color: q.open ? Colors.grey[500] : Colors.orange),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart() {
    final pts = _points;
    final spots = <FlSpot>[
      for (var i = 0; i < pts.length; i++) FlSpot(i.toDouble(), pts[i].price),
    ];
    final lo = pts.map((p) => p.price).reduce((a, b) => a < b ? a : b);
    final hi = pts.map((p) => p.price).reduce((a, b) => a > b ? a : b);
    final pad = (hi - lo) * 0.1 + 0.001;
    return SizedBox(
      height: 340,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 16, 8),
          child: LineChart(
            LineChartData(
              minY: lo - pad,
              maxY: hi + pad,
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    getTitlesWidget: (v, meta) =>
                        Text(v.toStringAsFixed(3), style: const TextStyle(fontSize: 10)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    interval: (pts.length / 4).clamp(1, 9999),
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      if (i < 0 || i >= pts.length) return const SizedBox.shrink();
                      return Text(DateFormat('HH:mm').format(pts[i].time.toLocal()),
                          style: const TextStyle(fontSize: 10));
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots.map((s) {
                    final i = s.x.toInt().clamp(0, pts.length - 1);
                    return LineTooltipItem(
                      '${DateFormat('HH:mm').format(pts[i].time.toLocal())}\n${s.y.toStringAsFixed(4)}',
                      const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    );
                  }).toList(),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: false,
                  color: Colors.lightBlueAccent,
                  barWidth: 2,
                  dotData: const FlDotData(show: false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(color: Colors.grey[500])),
            Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      );

  Widget _buildPositionCard() {
    final p = _account?.position;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: p == null
            ? const Text('目前沒有持倉', style: TextStyle(color: Colors.grey))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${p.side == 'long' ? '多單（做多久留美幣）' : '空單（做空久留美幣）'}　${p.lots.toStringAsFixed(0)} 手',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: p.side == 'long' ? _upColor : _downColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _row('進場均價', p.entry.toStringAsFixed(4)),
                  _row('平倉價（現價）', p.mark.toStringAsFixed(4)),
                  _row('浮動損益', '${_signed(p.unrealized)} 元',
                      color: p.unrealized >= 0 ? _upColor : _downColor),
                  _row('隔夜利息', '${_signed(p.swap)} 元'),
                  _row('槓桿', '${p.leverage} 倍'),
                  _row('保證金', '${_money(p.margin)} 元'),
                  _row('權益', '${_money(p.equity)} 元'),
                  _row('保證金比率', '${p.marginLevel.toStringAsFixed(0)}%（低於 50% 強平）',
                      color: p.marginLevel < 80 ? Colors.orange : null),
                  if (p.liquidationPrice != null) _row('強平價', p.liquidationPrice!.toStringAsFixed(4)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _closeAll,
                      child: const Text('全部平倉'),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildOrderCard(FxQuote q) {
    final pos = _account?.position;
    final lev = pos?.leverage ?? _leverage;
    final need = _lots * 10000 / lev;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _lotsController,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '手數（1 手 = 1 萬久留美幣）'),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final n in [100, 500, 1000, 2000, 5000, 10000])
                  ActionChip(
                    label: Text('$n'),
                    onPressed: () => setState(() => _lotsController.text = '$n'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('槓桿 ${pos != null ? pos.leverage : _leverage} 倍',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Expanded(
                  child: Slider(
                    value: _leverage.toDouble(),
                    min: q.minLeverage.toDouble(),
                    max: q.maxLeverage.toDouble(),
                    divisions: q.maxLeverage - q.minLeverage,
                    label: '$_leverage 倍',
                    onChanged: (v) => setState(() => _leverage = v.round()),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final n in [20, 30, 50, 75, 100])
                  ActionChip(label: Text('${n}x'), onPressed: () => setState(() => _leverage = n)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              pos != null
                  ? '你已有 ${pos.leverage} 倍的部位：同方向加倉沿用 ${pos.leverage} 倍；反向會先平倉，剩下的量用上面選的 $_leverage 倍開新倉。'
                      '開新倉需保證金約 ${_money(need)} 元'
                  : '開新倉需保證金約 ${_money(need)} 元（槓桿越高，價格小幅反向就會被強平）',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: _upColor),
                    onPressed: (_busy || !q.open) ? null : () => _trade('buy'),
                    child: Text('買進 @ ${q.ask.toStringAsFixed(4)}'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: _downColor),
                    onPressed: (_busy || !q.open) ? null : () => _trade('sell'),
                    child: Text('賣出 @ ${q.bid.toStringAsFixed(4)}'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrades() {
    final trades = _account?.trades ?? [];
    if (trades.isEmpty) return const SizedBox.shrink();
    const kinds = {'open': '開倉', 'close': '平倉', 'liquidation': '⚠️ 強平'};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('最近成交', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            for (final t in trades.take(10))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${DateFormat('MM/dd HH:mm').format(t.time.toLocal())}　${kinds[t.kind] ?? t.kind}　'
                  '${t.side == 'buy' ? '買' : '賣'} ${t.lots.toStringAsFixed(0)} 手 @ ${t.price.toStringAsFixed(4)}'
                  '${t.kind != 'open' ? '　${_signed(t.realized)} 元' : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
