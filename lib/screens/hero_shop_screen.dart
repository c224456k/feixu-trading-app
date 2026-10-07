import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../widgets/hero_art.dart';

// 勇者商店：用現金買裝備（價格與庫存全由伺服器 hero_game.py 決定，這裡只顯示與送出購買）。
// 買到的裝備直接進物品欄；現金是消耗掉的，不能賣回。

const _tierNames = ['破舊', '普通', '精良', '稀有', '史詩', '傳說'];
const _tierColors = [
  Color(0xFF8D8D8D),
  Color(0xFFE8E8E8),
  Color(0xFF4CD964),
  Color(0xFF3FA9FF),
  Color(0xFFB36BFF),
  Color(0xFFFFB02E),
];
const _slotNames = {
  'head': '頭盔',
  'weapon': '武器',
  'armor': '鎧甲',
  'boots': '鞋子',
  'gloves': '手套',
  'cloak': '斗篷',
  'belt': '腰帶',
  'ring': '戒指',
  'amulet': '護身符',
};
const _statLabels = {'atk': '攻擊', 'def': '防禦', 'hp': '生命', 'agi': '敏捷', 'luk': '幸運'};
final _money = NumberFormat('#,##0');

class HeroShopScreen extends StatefulWidget {
  const HeroShopScreen({super.key});

  @override
  State<HeroShopScreen> createState() => _HeroShopScreenState();
}

class _HeroShopScreenState extends State<HeroShopScreen> {
  final _api = ApiClient();
  List<Map<String, dynamic>> _items = [];
  double _cash = 0;
  int _invCount = 0;
  int _invCap = 40;
  int _tier = 1; // 目前篩選的品階
  String? _error;
  bool _loading = true;
  bool _buying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.fetchHeroShop();
      if (!mounted) return;
      setState(() {
        _items = [for (final i in (r['items'] as List)) (i as Map).cast<String, dynamic>()];
        _cash = (r['cash'] as num).toDouble();
        _invCount = (r['inventory_count'] as num).toInt();
        _invCap = (r['inventory_capacity'] as num).toInt();
        _error = null;
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

  String _statLine(Map<String, dynamic> item) => [
        for (final k in _statLabels.keys)
          if ((item[k] as num) != 0) '${_statLabels[k]}+${item[k]}',
      ].join('  ');

  Future<void> _buy(Map<String, dynamic> item) async {
    if (_buying) return;
    final price = (item['price'] as num).toInt();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('買下 ${item['name']}？'),
        content: Text('${_statLine(item)}\n\n要花 ${_money.format(price)} 元（現金不會退，也不能賣回）。\n你現在有 ${_money.format(_cash)} 元。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('買下')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _buying = true);
    try {
      final r = await _api.heroShopBuy(item['id'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message']}')));
      if (r['ok'] == true) {
        setState(() {
          _cash = (r['cash'] as num).toDouble();
          _invCount += 1;
        });
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('購買失敗：$e')));
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _items.where((i) => (i['tier'] as num).toInt() == _tier).toList();
    return Scaffold(
      backgroundColor: const Color(0xFF14110B),
      appBar: AppBar(title: const Text('勇者商店'), backgroundColor: const Color(0xFF1B1710)),
      body: _error != null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                FilledButton(
                    onPressed: () {
                      setState(() {
                        _error = null;
                        _loading = true;
                      });
                      _load();
                    },
                    child: const Text('重試')),
              ]),
            )
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                    child: Row(children: [
                      Text('💰 ${_money.format(_cash)} 元', style: const TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text('物品欄 $_invCount / $_invCap', style: TextStyle(color: _invCount >= _invCap ? const Color(0xFFFF8A80) : Colors.white54, fontSize: 12)),
                    ]),
                  ),
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      children: [
                        for (var t = 1; t <= 5; t++)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: ChoiceChip(
                              label: Text(_tierNames[t], style: TextStyle(color: _tier == t ? Colors.black : _tierColors[t])),
                              selected: _tier == t,
                              selectedColor: _tierColors[t],
                              onSelected: (_) => setState(() => _tier = t),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
                      itemCount: shown.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return const Padding(
                            padding: EdgeInsets.only(bottom: 6),
                            child: Text('買到的裝備直接放進物品欄；現金花掉就沒了，不能賣回。', style: TextStyle(color: Colors.white38, fontSize: 11)),
                          );
                        }
                        return _itemCard(shown[i - 1]);
                      },
                    ),
                  ),
                ]),
    );
  }

  Widget _itemCard(Map<String, dynamic> item) {
    final tier = (item['tier'] as num).toInt().clamp(0, 5);
    final price = (item['price'] as num).toInt();
    final canAfford = _cash >= price;
    final full = _invCount >= _invCap;
    final locked = item['locked'] == true;
    return Card(
      color: const Color(0xFF1B1710),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: _tierColors[tier].withValues(alpha: 0.5))),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          ItemIcon(slot: item['slot'] as String, itemId: item['id'] as String, tier: tier, size: 52),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item['name'] as String, style: TextStyle(color: _tierColors[tier], fontWeight: FontWeight.bold)),
              Text('${_tierNames[tier]}・${_slotNames[item['slot']] ?? item['slot']}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
              const SizedBox(height: 2),
              Text(_statLine(item), style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_money.format(price), style: TextStyle(color: (canAfford && !locked) ? const Color(0xFFFFD36B) : const Color(0xFFFF8A80), fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SizedBox(
              height: 32,
              child: FilledButton(
                onPressed: (_buying || locked || !canAfford || full) ? null : () => _buy(item),
                child: Text(locked ? '🔒 未開放' : (full ? '物品欄滿' : (canAfford ? '購買' : '錢不夠'))),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
