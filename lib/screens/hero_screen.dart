import 'package:flutter/material.dart';

import '../api_client.dart';

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
const _statLabels = {'atk': '攻擊', 'def': '防禦', 'hp': '生命', 'agi': '敏捷', 'luk': '幸運'};
const _statOrder = ['atk', 'def', 'hp', 'agi', 'luk'];

// 欄位 → 圖示（用內建圖示畫，不另外塞圖檔）
const _slotIcons = <String, IconData>{
  'head': Icons.sports_motorsports,
  'weapon': Icons.hardware,
  'armor': Icons.checkroom,
  'boots': Icons.snowshoeing,
  'gloves': Icons.back_hand,
  'cloak': Icons.flag,
  'belt': Icons.horizontal_rule,
  'ring1': Icons.radio_button_unchecked,
  'ring2': Icons.radio_button_unchecked,
  'amulet': Icons.diamond,
};

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

  List<Map<String, dynamic>> get _inventory =>
      ((_data!['inventory'] as List?) ?? const []).cast<Map<String, dynamic>>();

  bool _fits(Map<String, dynamic> item, String slotKey) {
    final t = item['slot'] as String;
    return t == slotKey || (t == 'ring' && (slotKey == 'ring1' || slotKey == 'ring2'));
  }

  Future<void> _act(Future<Map<String, dynamic>> Function() call) async {
    try {
      final r = await call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}')));
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 24), child: SingleChildScrollView(child: child)),
      ),
    );
  }

  // 點裝備欄：有裝備 → 看說明＋脫下；空的 → 列出物品欄裡能放這格的裝備
  void _showSlot(Map<String, dynamic> slot) {
    final item = slot['item'] as Map<String, dynamic>?;
    if (item != null) {
      _sheet(Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
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
      ]));
      return;
    }
    final candidates = _inventory.where((e) => _fits(e['item'] as Map<String, dynamic>, slot['key'] as String)).toList();
    _sheet(Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${slot['name']}（空）', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      if (candidates.isEmpty)
        const Text('物品欄裡沒有可以放這格的裝備', style: TextStyle(color: Colors.white54))
      else
        for (final c in candidates)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _SlotBox(
                icon: _slotIcons[slot['key']] ?? Icons.help,
                color: _tierColors[((c['item'] as Map)['tier'] as num).toInt().clamp(0, 5)],
                filled: true,
                size: 44),
            title: Text('${(c['item'] as Map)['name']}', style: const TextStyle(color: Colors.white)),
            subtitle: Text(_statLine(c['item'] as Map<String, dynamic>), style: const TextStyle(color: Color(0xFF7DFFA0), fontSize: 12)),
            trailing: const Text('裝備', style: TextStyle(color: Color(0xFFFFD36B))),
            onTap: () {
              Navigator.pop(context);
              _act(() => _api.heroEquip((c['inv_id'] as num).toInt(), slot: slot['key'] as String));
            },
          ),
    ]));
  }

  // 點物品欄的裝備：看說明、跟目前穿的比較、裝備
  void _showInventoryItem(Map<String, dynamic> entry) {
    final item = entry['item'] as Map<String, dynamic>;
    String target = item['slot'] as String;
    if (target == 'ring') {
      final r1 = _slot('ring1')!['item'];
      target = r1 == null ? 'ring1' : (_slot('ring2')!['item'] == null ? 'ring2' : 'ring1');
    }
    final current = _slot(target)?['item'] as Map<String, dynamic>?;
    _sheet(Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      _itemDetail(target, '${_slot(target)?['name']}', item),
      const SizedBox(height: 12),
      if (current != null) ...[
        Text('目前穿著：${current['name']}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 4),
        for (final k in _statOrder)
          if ((item[k] as num) != (current[k] as num))
            Text(
              '${_statLabels[k]} ${(item[k] as num) - (current[k] as num) > 0 ? '+' : ''}${(item[k] as num) - (current[k] as num)}',
              style: TextStyle(
                  color: (item[k] as num) > (current[k] as num) ? const Color(0xFF7DFFA0) : const Color(0xFFFF7D7D), fontSize: 13),
            ),
      ],
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () {
            Navigator.pop(context);
            _act(() => _api.heroEquip((entry['inv_id'] as num).toInt(), slot: item['slot'] == 'ring' ? target : null));
          },
          icon: const Icon(Icons.file_upload_outlined),
          label: Text(current == null ? '裝備' : '換上'),
        ),
      ),
    ]));
  }

  String _statLine(Map<String, dynamic> item) => [
        for (final k in _statOrder)
          if ((item[k] as num) != 0) '${_statLabels[k]}+${item[k]}'
      ].join('  ');

  Widget _itemDetail(String slotKey, String slotName, Map<String, dynamic> item) {
    final tier = (item['tier'] as num).toInt().clamp(0, 5);
    final color = _tierColors[tier];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _SlotBox(icon: _slotIcons[slotKey] ?? Icons.help, color: color, filled: true, size: 56),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${item['name']}', style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text('${_tierNames[tier]}・$slotName', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        for (final k in _statOrder)
          if ((item[k] as num) != 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('${_statLabels[k]}  +${item[k]}', style: const TextStyle(color: Color(0xFF7DFFA0), fontSize: 15)),
            ),
        const SizedBox(height: 10),
        Text('${item['desc']}', style: const TextStyle(color: Colors.white60, fontStyle: FontStyle.italic)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF14110B),
      appBar: AppBar(title: const Text('勇者裝備'), backgroundColor: const Color(0xFF1B1710)),
      body: _error != null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                FilledButton(onPressed: _load, child: const Text('重試')),
              ]),
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
          child: Column(children: [
            Text(name, style: const TextStyle(color: Color(0xFFFFD36B), fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2)),
            const Text('勇者', style: TextStyle(color: Colors.white38, fontSize: 12)),
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
                  Column(children: [for (final k in left) _slotCell(k)]),
                  Expanded(
                    child: SizedBox(
                      height: 5 * 72.0,
                      child: CustomPaint(painter: _HeroPainter(_slot('weapon')?['item'] != null)),
                    ),
                  ),
                  Column(children: [for (final k in right) _slotCell(k)]),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _statsCard(base, stats),
            const SizedBox(height: 16),
            _inventoryCard(),
          ]),
        ),
      ),
    );
  }

  Widget _slotCell(String key) {
    final slot = _slot(key)!;
    final item = slot['item'] as Map<String, dynamic>?;
    final tier = item == null ? 0 : (item['tier'] as num).toInt().clamp(0, 5);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GestureDetector(
        onTap: () => _showSlot(slot),
        child: Column(children: [
          _SlotBox(icon: _slotIcons[key] ?? Icons.help, color: _tierColors[tier], filled: item != null, size: 56),
          const SizedBox(height: 2),
          Text('${slot['name']}', style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ]),
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('物品欄', style: TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold)),
          const Spacer(),
          Text('${inv.length} / $cap', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ]),
        const SizedBox(height: 10),
        if (inv.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('物品欄是空的', style: TextStyle(color: Colors.white38)),
          )
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in inv)
              GestureDetector(
                onTap: () => _showInventoryItem(e),
                child: _SlotBox(
                  icon: _slotIcons[(e['item'] as Map)['slot'] == 'ring' ? 'ring1' : (e['item'] as Map)['slot']] ?? Icons.help,
                  color: _tierColors[((e['item'] as Map)['tier'] as num).toInt().clamp(0, 5)],
                  filled: true,
                  size: 52,
                ),
              ),
          ]),
        const SizedBox(height: 8),
        const Text('點裝備欄可以脫下，點物品欄裡的裝備可以換上。', style: TextStyle(color: Colors.white30, fontSize: 11)),
      ]),
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('勇者屬性', style: TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        for (final k in _statOrder)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 44, child: Text(_statLabels[k]!, style: const TextStyle(color: Colors.white60))),
              Text('${(base[k] as num) + (bonus[k] as num)}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(width: 8),
              if ((bonus[k] as num) != 0)
                Text('(基礎 ${base[k]} + 裝備 ${bonus[k]})', style: const TextStyle(color: Color(0xFF7DFFA0), fontSize: 12)),
            ]),
          ),
      ]),
    );
  }
}

class _SlotBox extends StatelessWidget {
  final IconData icon;
  final Color color;
  final bool filled;
  final double size;
  const _SlotBox({required this.icon, required this.color, required this.filled, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: filled
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color.withValues(alpha: 0.28), color.withValues(alpha: 0.08)],
              )
            : null,
        color: filled ? null : const Color(0xFF100D08),
        border: Border.all(color: filled ? color : const Color(0xFF3D3320), width: filled ? 2 : 1.5),
        boxShadow: filled ? [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 8)] : null,
      ),
      child: Icon(icon, size: size * 0.5, color: filled ? color : const Color(0xFF3D3320)),
    );
  }
}

// 勇者剪影：頭、身體、雙手雙腳，簡單幾何拼起來；有武器時右手多畫一把劍。
class _HeroPainter extends CustomPainter {
  final bool hasWeapon;
  _HeroPainter(this.hasWeapon);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final h = size.height;
    final glow = Paint()
      ..shader = const RadialGradient(colors: [Color(0x33FFD36B), Color(0x00FFD36B)])
          .createShader(Rect.fromCircle(center: Offset(cx, h * 0.5), radius: h * 0.5));
    canvas.drawCircle(Offset(cx, h * 0.5), h * 0.5, glow);

    final body = Paint()..color = const Color(0xFF3A3122);
    final edge = Paint()
      ..color = const Color(0xFF8A7440)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    void shape(RRect r) {
      canvas.drawRRect(r, body);
      canvas.drawRRect(r, edge);
    }

    final u = h / 10;
    // 頭
    canvas.drawCircle(Offset(cx, u * 1.4), u * 0.9, body);
    canvas.drawCircle(Offset(cx, u * 1.4), u * 0.9, edge);
    // 軀幹
    shape(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, u * 4.0), width: u * 2.2, height: u * 3.2), Radius.circular(u * 0.5)));
    // 手臂
    shape(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx - u * 1.7, u * 4.0), width: u * 0.8, height: u * 3.0), Radius.circular(u * 0.4)));
    shape(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx + u * 1.7, u * 4.0), width: u * 0.8, height: u * 3.0), Radius.circular(u * 0.4)));
    // 腿
    shape(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx - u * 0.6, u * 7.4), width: u * 0.95, height: u * 3.2), Radius.circular(u * 0.4)));
    shape(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx + u * 0.6, u * 7.4), width: u * 0.95, height: u * 3.2), Radius.circular(u * 0.4)));

    if (hasWeapon) {
      final blade = Paint()..color = const Color(0xFFB9B9B9);
      final bx = cx + u * 2.4;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bx - u * 0.18, u * 1.4, u * 0.36, u * 3.4), Radius.circular(2)), blade);
      canvas.drawRect(Rect.fromLTWH(bx - u * 0.6, u * 4.8, u * 1.2, u * 0.26), Paint()..color = const Color(0xFF8A6A2E));
      canvas.drawRect(Rect.fromLTWH(bx - u * 0.12, u * 5.05, u * 0.24, u * 0.7), Paint()..color = const Color(0xFF5B3F1C));
    }
  }

  @override
  bool shouldRepaint(covariant _HeroPainter old) => old.hasWeapon != hasWeapon;
}
