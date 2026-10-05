import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';

// 台股習慣：紅漲綠跌。
const _upColor = Color(0xFFFF5A5F);
const _downColor = Color(0xFF2ECC71);

/// 第二季：外匯保證金交易（TWD/JPY）。
/// 買進 = 做多台幣（日圓貶值賺），賣出 = 做空台幣。1 手 = 1 萬台幣，槓桿 20 倍，權益低於保證金一半會被強平。
class FxScreen extends StatefulWidget {
  const FxScreen({super.key});

  @override
  State<FxScreen> createState() => _FxScreenState();
}

class _FxScreenState extends State<FxScreen> {
  final _api = ApiClient();
  final _lotsController = TextEditingController(text: '1');

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
      final quote = await _api.fetchFxQuote();
      final account = await _api.fetchFxAccount();
      // 走勢圖變動慢，每 10 次（約 30 秒）才重抓
      final chart = (_tick % 10 == 0 || _chart.isEmpty) ? await _api.fetchFxChart() : _chart;
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
      final r = await _api.fxTrade(side, _lots);
      _snack(r.message);
      await _refresh();
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
    return Scaffold(
      appBar: AppBar(title: const Text('💴 外匯 TWD/JPY（第二季）')),
      body: _quote == null
          ? Center(
              child: _error != null
                  ? Padding(padding: const EdgeInsets.all(20), child: Text(_error!))
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
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
                  '1 手 = 1 萬台幣名目本金，槓桿 ${_quote!.leverage} 倍（每手保證金 ${_money(_quote!.marginPerLot)} 元）。'
                  '買進＝做多台幣、賣出＝做空台幣；權益低於保證金 50% 會被強制平倉，最多賠光保證金。'
                  '行情來自真實外匯報價，約有數分鐘延遲；週末休市不能交易。',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
    );
  }

  Widget _buildQuoteCard(FxQuote q) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(q.mid.toStringAsFixed(4), style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold)),
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
                  ? '報價時間 ${DateFormat('HH:mm:ss').format(q.quoteTime.toLocal())}（約 ${(q.ageSeconds / 60).floor()} 分鐘前）'
                  : '⏸ 休市中，最後報價 ${DateFormat('MM/dd HH:mm').format(q.quoteTime.toLocal())}',
              style: TextStyle(fontSize: 12, color: q.open ? Colors.grey[500] : Colors.orange),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart() {
    final spots = <FlSpot>[
      for (var i = 0; i < _chart.length; i++) FlSpot(i.toDouble(), _chart[i].price),
    ];
    final lo = _chart.map((p) => p.price).reduce((a, b) => a < b ? a : b);
    final hi = _chart.map((p) => p.price).reduce((a, b) => a > b ? a : b);
    final pad = (hi - lo) * 0.1 + 0.001;
    return SizedBox(
      height: 200,
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
                    interval: (_chart.length / 4).clamp(1, 9999),
                    getTitlesWidget: (v, meta) {
                      final i = v.toInt();
                      if (i < 0 || i >= _chart.length) return const SizedBox.shrink();
                      return Text(DateFormat('HH:mm').format(_chart[i].time.toLocal()),
                          style: const TextStyle(fontSize: 10));
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots.map((s) {
                    final i = s.x.toInt().clamp(0, _chart.length - 1);
                    return LineTooltipItem(
                      '${DateFormat('HH:mm').format(_chart[i].time.toLocal())}\n${s.y.toStringAsFixed(4)}',
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
                    '${p.side == 'long' ? '多單（做多台幣）' : '空單（做空台幣）'}　${p.lots.toStringAsFixed(0)} 手',
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
    final need = _lots * q.marginPerLot;
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
              decoration: const InputDecoration(labelText: '手數（1 手 = 1 萬台幣）'),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final n in [1, 5, 10, 50, 100])
                  ActionChip(
                    label: Text('$n'),
                    onPressed: () => setState(() => _lotsController.text = '$n'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '開新倉需保證金約 ${_money(need)} 元；與現有部位反向會先平倉',
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
