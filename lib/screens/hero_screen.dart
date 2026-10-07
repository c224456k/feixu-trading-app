import 'package:flutter/material.dart';

import '../api_client.dart';
import '../widgets/hero_art.dart';
import 'hero_shop_screen.dart';
import 'tower_screen.dart';

// 勇者紙娃娃（裝備欄）：中間是勇者剪影，左右各 5 個裝備欄，點欄位看裝備說明。
// 裝備資料全由伺服器（hero_game.py）提供，這裡只負責顯示。

const _tierNames = ['破舊', '普通', '精良', '稀有', '史詩', '傳說'];
const _tierColors = [
  Color(0xFF8D8D8D),
  Color(0xFFE8E8E8),
  Color(0xFF4CD964),
  Color(0xFF3FA9FF),
  Color(0xFFB36BFF),
  Color(0xFFFFB02E),
];
const _statLabels = {
  'atk': '攻擊',
  'def': '防禦',
  'hp': '生命',
  'agi': '敏捷',
  'luk': '幸運',
};
const _statOrder = ['atk', 'def', 'hp', 'agi', 'luk'];

class HeroScreen extends StatefulWidget {
  const HeroScreen({super.key});

  @override
  State<HeroScreen> createState() => _HeroScreenState();
}

class _HeroScreenState extends State<HeroScreen> {
  final _api = ApiClient();
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _api.fetchHeroEquipment();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
      final drops = ((d['new_drops'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      if (drops.isNotEmpty) {
        _api.heroAckDrops().catchError((_) => <String, dynamic>{});
        _showDrops(drops);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Map<String, dynamic>? _slot(String key) {
    for (final s in (_data!['slots'] as List)) {
      if (s['key'] == key) return s as Map<String, dynamic>;
    }
    return null;
  }

  void _showDrops(List<Map<String, dynamic>> drops) {
    const reasons = {
      'participant': '參戰獎勵',
      'top_damage': '傷害第一名',
      'last_hit': '最後一擊',
    };
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B1710),
        title: const Text(
          '🎁 Boss 掉落',
          style: TextStyle(color: Color(0xFFFFD36B)),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final d in drops)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _SlotBox(
                    slot: (d['item'] as Map)['slot'] as String,
                    item: d['item'] as Map<String, dynamic>,
                    size: 48,
                  ),
                  title: Text(
                    '${(d['item'] as Map)['name']}',
                    style: TextStyle(
                      color:
                          _tierColors[((d['item'] as Map)['tier'] as num)
                              .toInt()
                              .clamp(0, 5)],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    '${_tierNames[((d['item'] as Map)['tier'] as num).toInt().clamp(0, 5)]}・${reasons[d['reason']] ?? ''}\n${_statLine(d['item'] as Map<String, dynamic>)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 4),
              const Text(
                '已放進物品欄',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('收下'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDiscard(Map<String, dynamic> entry) async {
    final item = entry['item'] as Map<String, dynamic>;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('丟棄裝備？'),
        content: Text('「${item['name']}」丟掉就拿不回來了，也沒有補償。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('丟棄'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _act(() => _api.heroDiscard((entry['inv_id'] as num).toInt()));
    }
  }

  List<Map<String, dynamic>> get _inventory =>
      ((_data!['inventory'] as List?) ?? const []).cast<Map<String, dynamic>>();

  bool _fits(Map<String, dynamic> item, String slotKey) {
    final t = item['slot'] as String;
    return t == slotKey ||
        (t == 'ring' && (slotKey == 'ring1' || slotKey == 'ring2'));
  }

  Future<void> _act(Future<Map<String, dynamic>> Function() call) async {
    try {
      final r = await call();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _sheet(Widget child) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1710),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: SingleChildScrollView(child: child),
        ),
      ),
    );
  }

  // 點裝備欄：有裝備 → 看說明＋脫下；空的 → 列出物品欄裡能放這格的裝備
  void _showSlot(Map<String, dynamic> slot) {
    final item = slot['item'] as Map<String, dynamic>?;
    if (item != null) {
      _sheet(
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _itemDetail(slot['key'] as String, slot['name'] as String, item),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _act(() => _api.heroUnequip(slot['key'] as String));
                },
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('脫下'),
              ),
            ),
          ],
        ),
      );
      return;
    }
    final candidates = _inventory
        .where(
          (e) =>
              _fits(e['item'] as Map<String, dynamic>, slot['key'] as String),
        )
        .toList();
    _sheet(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${slot['name']}（空）',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          if (candidates.isEmpty)
            const Text(
              '物品欄裡沒有可以放這格的裝備',
              style: TextStyle(color: Colors.white54),
            )
          else
            for (final c in candidates)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _SlotBox(
                  slot: slot['key'] as String,
                  item: c['item'] as Map<String, dynamic>,
                  size: 48,
                ),
                title: Text(
                  '${(c['item'] as Map)['name']}',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  _statLine(c['item'] as Map<String, dynamic>),
                  style: const TextStyle(
                    color: Color(0xFF7DFFA0),
                    fontSize: 12,
                  ),
                ),
                trailing: const Text(
                  '裝備',
                  style: TextStyle(color: Color(0xFFFFD36B)),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _act(
                    () => _api.heroEquip(
                      (c['inv_id'] as num).toInt(),
                      slot: slot['key'] as String,
                    ),
                  );
                },
              ),
        ],
      ),
    );
  }

  // 點物品欄的裝備：看說明、跟目前穿的比較、裝備
  void _showInventoryItem(Map<String, dynamic> entry) {
    final item = entry['item'] as Map<String, dynamic>;
    String target = item['slot'] as String;
    if (target == 'ring') {
      final r1 = _slot('ring1')!['item'];
      target = r1 == null
          ? 'ring1'
          : (_slot('ring2')!['item'] == null ? 'ring2' : 'ring1');
    }
    final current = _slot(target)?['item'] as Map<String, dynamic>?;
    _sheet(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _itemDetail(target, '${_slot(target)?['name']}', item),
          const SizedBox(height: 12),
          if (current != null) ...[
            Text(
              '目前穿著：${current['name']}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 4),
            for (final k in _statOrder)
              if ((item[k] as num) != (current[k] as num))
                Text(
                  '${_statLabels[k]} ${(item[k] as num) - (current[k] as num) > 0 ? '+' : ''}${(item[k] as num) - (current[k] as num)}',
                  style: TextStyle(
                    color: (item[k] as num) > (current[k] as num)
                        ? const Color(0xFF7DFFA0)
                        : const Color(0xFFFF7D7D),
                    fontSize: 13,
                  ),
                ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _act(
                  () => _api.heroEquip(
                    (entry['inv_id'] as num).toInt(),
                    slot: item['slot'] == 'ring' ? target : null,
                  ),
                );
              },
              icon: const Icon(Icons.file_upload_outlined),
              label: Text(current == null ? '裝備' : '換上'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _confirmDiscard(entry);
              },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('丟棄'),
              style: TextButton.styleFrom(foregroundColor: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }

  String _statLine(Map<String, dynamic> item) =>
      [
        for (final k in _statOrder)
          if ((item[k] as num) != 0) '${_statLabels[k]}+${item[k]}',
      ].join('  ') +
      (item['quality'] != null ? '  （品質 ${item['quality']}%）' : '');

  // 品質：這件裝備數值相對基礎值的百分比（掉落/商店裝備才有；90% 以下偏弱、110% 以上算好貨）
  Color _qualityColor(int q) => q >= 110 ? const Color(0xFFFFD36B) : (q >= 100 ? const Color(0xFF7DFFA0) : (q >= 90 ? Colors.white70 : const Color(0xFFFF8A80)));

  Widget _itemDetail(
    String slotKey,
    String slotName,
    Map<String, dynamic> item,
  ) {
    final tier = (item['tier'] as num).toInt().clamp(0, 5);
    final color = _tierColors[tier];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SlotBox(slot: slotKey, item: item, size: 60),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${item['name']}',
                    style: TextStyle(
                      color: color,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                      children: [
                        TextSpan(text: '${_tierNames[tier]}・$slotName'),
                        if (item['quality'] != null)
                          TextSpan(
                            text: '・品質 ${item['quality']}%',
                            style: TextStyle(color: _qualityColor((item['quality'] as num).toInt()), fontWeight: FontWeight.bold),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        for (final k in _statOrder)
          if ((item[k] as num) != 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${_statLabels[k]}  +${item[k]}',
                style: const TextStyle(color: Color(0xFF7DFFA0), fontSize: 15),
              ),
            ),
        const SizedBox(height: 10),
        Text(
          '${item['desc']}',
          style: const TextStyle(
            color: Colors.white60,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF14110B),
      appBar: AppBar(
        title: const Text('勇者裝備'),
        backgroundColor: const Color(0xFF1B1710),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HeroShopScreen()),
              );
              if (mounted) _load(); // 回來時重抓物品欄（可能買了新裝備）
            },
            icon: const Icon(Icons.storefront, color: Color(0xFFFFD36B)),
            label: const Text('商店', style: TextStyle(color: Color(0xFFFFD36B))),
          ),
          TextButton.icon(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TowerScreen()),
              );
              if (mounted) _load(); // 塔裡掉的新裝備要在回來時重抓物品欄
            },
            icon: const Icon(Icons.fort, color: Color(0xFFFFD36B)),
            label: const Text('百層塔', style: TextStyle(color: Color(0xFFFFD36B))),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _load, child: const Text('重試')),
                ],
              ),
            )
          : _data == null
          ? const Center(child: CircularProgressIndicator())
          : _body(),
    );
  }

  Widget _body() {
    final name = (_data!['name'] as String?) ?? '勇者';
    final stats = _data!['stats'] as Map<String, dynamic>;
    final base = _data!['base_stats'] as Map<String, dynamic>;
    final left = ['head', 'armor', 'gloves', 'belt', 'boots'];
    final right = ['weapon', 'cloak', 'ring1', 'ring2', 'amulet'];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            children: [
              Text(
                name,
                style: const TextStyle(
                  color: Color(0xFFFFD36B),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const Text(
                '勇者',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF2A2318), Color(0xFF18130C)],
                  ),
                  border: Border.all(color: const Color(0xFF6B5A2E), width: 2),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      height: 480,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [for (final k in left) _slotCell(k)],
                      ),
                    ),
                    Expanded(
                      child: SizedBox(
                        height: 480,
                        child: CustomPaint(
                          painter: HeroPaperDoll(_equippedMap()),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 480,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [for (final k in right) _slotCell(k)],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _statsCard(base, stats),
              const SizedBox(height: 16),
              _inventoryCard(),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, ({String id, int tier})> _equippedMap() {
    final m = <String, ({String id, int tier})>{};
    for (final s in (_data!['slots'] as List)) {
      final it = s['item'] as Map<String, dynamic>?;
      if (it != null) {
        m[s['key'] as String] = (
          id: it['id'] as String,
          tier: (it['tier'] as num).toInt(),
        );
      }
    }
    return m;
  }

  Widget _slotCell(String key) {
    final slot = _slot(key)!;
    final item = slot['item'] as Map<String, dynamic>?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GestureDetector(
        onTap: () => _showSlot(slot),
        child: SizedBox(
          width: 60,
          child: Column(
            children: [
              _SlotBox(slot: key, item: item, size: 56),
              const SizedBox(height: 2),
              Text(
                '${slot['name']}',
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inventoryCard() {
    final inv = _inventory;
    final cap = (_data!['inventory_capacity'] as num?)?.toInt() ?? 40;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1710),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF3D3320)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '物品欄',
                style: TextStyle(
                  color: Color(0xFFFFD36B),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                '${inv.length} / $cap',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (inv.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('物品欄是空的', style: TextStyle(color: Colors.white38)),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in inv)
                  GestureDetector(
                    onTap: () => _showInventoryItem(e),
                    child: _SlotBox(
                      slot: (e['item'] as Map)['slot'] as String,
                      item: e['item'] as Map<String, dynamic>,
                      size: 56,
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          const Text(
            '點裝備欄可以脫下，點物品欄裡的裝備可以換上。',
            style: TextStyle(color: Colors.white30, fontSize: 11),
          ),
        ],
      ),
    );
  }

  // 攻擊 → Boss 炸彈傷害（上限 +atk_cap%）
  Widget _bombRow() {
    final dmg = (_data!['bomb_damage'] as num?)?.toInt();
    if (dmg == null) return const SizedBox.shrink();
    final cap = (_data!['atk_cap'] as num?)?.toInt() ?? 60;
    final atk = ((_data!['stats'] as Map)['atk'] as num).toInt();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x22FF8A3D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Text('💣', style: TextStyle(fontSize: 18)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '炸彈傷害 $dmg（基礎 50，裝備攻擊 +${atk > cap ? cap : atk}%${atk >= cap ? '・已達上限' : '・上限 +$cap%'}）',
              style: const TextStyle(color: Color(0xFFFFB27A), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statsCard(Map<String, dynamic> base, Map<String, dynamic> bonus) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1710),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF3D3320)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '勇者屬性',
            style: TextStyle(
              color: Color(0xFFFFD36B),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _bombRow(),
          for (final k in _statOrder)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      _statLabels[k]!,
                      style: const TextStyle(color: Colors.white60),
                    ),
                  ),
                  Text(
                    '${(base[k] as num) + (bonus[k] as num)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if ((bonus[k] as num) != 0)
                    Flexible(
                      child: Text(
                        '(基礎 ${base[k]} + 裝備 ${bonus[k]})',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF7DFFA0),
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SlotBox extends StatelessWidget {
  final String slot;
  final Map<String, dynamic>? item;
  final double size;
  const _SlotBox({required this.slot, required this.item, required this.size});

  @override
  Widget build(BuildContext context) {
    final filled = item != null;
    final tier = filled ? (item!['tier'] as num).toInt().clamp(0, 5) : 0;
    final color = _tierColors[tier];
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: filled
            ? RadialGradient(
                center: const Alignment(-0.3, -0.4),
                radius: 1.0,
                colors: [
                  color.withValues(alpha: 0.34),
                  const Color(0xFF14110B),
                ],
              )
            : null,
        color: filled ? null : const Color(0xFF100D08),
        border: Border.all(
          color: filled ? color : const Color(0xFF3D3320),
          width: filled ? 2 : 1.5,
        ),
        boxShadow: filled
            ? [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 8)]
            : null,
      ),
      child: ItemIcon(
        slot: slot,
        itemId: filled ? item!['id'] as String : null,
        tier: tier,
        size: size * 0.8,
      ),
    );
  }
}
