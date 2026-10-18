import 'package:flutter/material.dart';

import '../api_client.dart';

// 拍賣場：用水晶買賣怪物卡片（一口價）。賣出收 5% 手續費（直接消失）。

class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key});

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> with SingleTickerProviderStateMixin {
  final _api = ApiClient();
  late final TabController _tabs = TabController(length: 2, vsync: this);
  Map<String, dynamic>? _data;
  String? _error;
  String _filter = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await _api.marketState(card: _filter);
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _act(Future<Map<String, dynamic>> Function() call) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Map<String, dynamic>> _list(String k) => ((_data![k] as List?) ?? const []).cast<Map<String, dynamic>>();

  Widget _cardTile(Map<String, dynamic> card, {Widget? trailing, String? sub, int? n}) {
    final boss = card['boss'] == true;
    return Card(
      color: const Color(0xFF1F1B12),
      child: ListTile(
        title: Text('${card['name']}${n != null ? ' × $n' : ''}',
            style: TextStyle(color: boss ? const Color(0xFFFFD36B) : Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text('${card['desc']}${sub != null ? '\n$sub' : ''}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
        isThreeLine: sub != null,
        trailing: trailing,
      ),
    );
  }

  Future<void> _confirmBuy(Map<String, dynamic> l) async {
    final card = l['card'] as Map<String, dynamic>;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('購買卡片？'),
        content: Text('用 ${l['price']} 水晶買「${card['name']}」（賣家 ${l['seller_name']}）。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('購買')),
        ],
      ),
    );
    if (ok == true) await _act(() => _api.marketBuy((l['id'] as num).toInt()));
  }

  Future<void> _sellDialog(Map<String, dynamic> card) async {
    final ctrl = TextEditingController();
    final fee = ((_data!['fee_rate'] as num) * 100).round();
    final min = (_data!['price_min'] as num).toInt();
    final max = (_data!['price_max'] as num).toInt();
    final price = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('賣出 ${card['name']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(labelText: '售價（水晶）', hintText: '$min ~ $max'),
            ),
            const SizedBox(height: 8),
            Text('賣出時收 $fee% 手續費；掛上去後卡片會先離開背包，取消掛單才會退回。',
                style: const TextStyle(fontSize: 12, color: Colors.white60)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())), child: const Text('掛上去')),
        ],
      ),
    );
    ctrl.dispose();
    if (price == null) return;
    await _act(() => _api.marketSell(card['id'] as String, price));
  }

  Widget _browse() {
    final ls = _list('listings');
    final names = <String, String>{};
    for (final l in ls) {
      final c = l['card'] as Map<String, dynamic>;
      names[c['id'] as String] = c['name'] as String;
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_filter.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: ActionChip(
                label: Text('只看：${names[_filter] ?? _filter}　✕'),
                onPressed: () {
                  _filter = '';
                  _load();
                },
              ),
            ),
          if (ls.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('目前沒有人在賣', style: TextStyle(color: Colors.white38)))),
          for (final l in ls)
            _cardTile(
              l['card'] as Map<String, dynamic>,
              sub: '賣家：${l['seller_name']}',
              trailing: l['mine'] == true
                  ? const Text('我掛的', style: TextStyle(color: Colors.white38))
                  : FilledButton(
                      onPressed: _busy ? null : () => _confirmBuy(l),
                      child: Text('${l['price']} 💎'),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _sellTab() {
    final mine = _list('mine');
    final cards = _list('my_cards');
    final history = _list('history');
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('我掛的（${mine.length}/${_data!['max_listings']}）', style: const TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold)),
        if (mine.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('還沒有掛單', style: TextStyle(color: Colors.white38))),
        for (final l in mine)
          _cardTile(
            l['card'] as Map<String, dynamic>,
            sub: '售價 ${l['price']} 水晶',
            trailing: TextButton(
              onPressed: _busy ? null : () => _act(() => _api.marketCancel((l['id'] as num).toInt())),
              child: const Text('取消'),
            ),
          ),
        const SizedBox(height: 12),
        const Text('背包裡的卡片（點「賣」掛上去）', style: TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold)),
        if (cards.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('背包裡沒有卡片（插在裝備上的要先取出）', style: TextStyle(color: Colors.white38))),
        for (final c in cards)
          _cardTile(
            c,
            n: (c['n'] as num?)?.toInt(),
            trailing: FilledButton(onPressed: _busy ? null : () => _sellDialog(c), child: const Text('賣')),
          ),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('最近成交', style: TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold)),
          for (final h in history)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                h['role'] == 'sell'
                    ? '💰 賣出 ${h['card_name']} 給 ${h['other']}，收到 ${h['gain']} 水晶'
                    : '🛒 向 ${h['other']} 買了 ${h['card_name']}，花 ${h['price']} 水晶',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF14110B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1710),
        title: const Text('拍賣場', style: TextStyle(color: Color(0xFF8FD3FF))),
        iconTheme: const IconThemeData(color: Color(0xFF8FD3FF)),
        actions: [
          if (_data != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: Text('💎 ${_data!['crystals']}', style: const TextStyle(color: Color(0xFF8FD3FF), fontWeight: FontWeight.bold, fontSize: 16))),
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: const Color(0xFF8FD3FF),
          labelColor: const Color(0xFF8FD3FF),
          unselectedLabelColor: Colors.white54,
          tabs: const [Tab(text: '逛拍賣'), Tab(text: '我要賣')],
        ),
      ),
      body: _error != null && _data == null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)))
          : _data == null
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(controller: _tabs, children: [_browse(), _sellTab()]),
    );
  }
}
