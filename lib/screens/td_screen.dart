import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api_client.dart';
import '../widgets/monster_art.dart';

// 塔防：方格地圖，蓋塔把路擋成迷宮。戰鬥由伺服器算好，這裡只播放影格。

const _towerColors = {
  'arrow': Color(0xFF8D6E3F),
  'cannon': Color(0xFF546E7A),
  'frost': Color(0xFF4FC3F7),
};
const _towerIcons = {'arrow': '🏹', 'cannon': '💣', 'frost': '❄️'};

class TdScreen extends StatefulWidget {
  const TdScreen({super.key});

  @override
  State<TdScreen> createState() => _TdScreenState();
}

class _TdScreenState extends State<TdScreen> with SingleTickerProviderStateMixin {
  final _api = ApiClient();
  Map<String, dynamic>? _data;
  String? _error;
  String _build = 'arrow';
  (int, int)? _sel;
  bool _busy = false;
  // 播放
  late final Ticker _ticker;
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  List<dynamic>? _frames;
  Map<String, dynamic>? _pending;
  Map<String, dynamic>? _result;
  double _speed = 1.0;
  double _t = 0;
  Duration _last = Duration.zero;

  bool get _playing => _frames != null;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _load();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  void _onTick(Duration d) {
    if (_frames != null) {
      final dt = (d - _last).inMicroseconds / 1e6;
      _t += dt * _speed;
      if (_t / 0.2 >= _frames!.length - 1) {
        _finishPlayback();
      }
    }
    _last = d;
    _repaint.value++;
  }

  void _finishPlayback() {
    setState(() {
      _frames = null;
      if (_pending != null) _data = _pending;
      _pending = null;
    });
    final r = _result;
    if (r != null && mounted) {
      final won = r['won'] == true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(won ? '🎉 過關！擊殺 ${r['kills']} 隻、漏掉 ${r['leaks']} 隻，+${r['reward']} 金幣' : '💀 失敗，漏掉 ${r['leaks']} 隻。塔都還在，調整後再試'),
      ));
    }
  }

  Future<void> _load() async {
    try {
      final d = await _api.tdState();
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

  Future<void> _act(Future<Map<String, dynamic>> Function() call, {bool play = false}) async {
    if (_busy || _playing) return;
    setState(() => _busy = true);
    try {
      final r = await call();
      if (!mounted) return;
      if (r['ok'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}')));
      } else if (play) {
        setState(() {
          _frames = r['frames'] as List;
          _pending = (r['state'] as Map).cast<String, dynamic>();
          _result = (r['result'] as Map).cast<String, dynamic>();
          _t = 0;
          _sel = null;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}')));
        setState(() {
          _data = (r['state'] as Map).cast<String, dynamic>();
          final s = _sel;
          if (s != null && _towerAt(s.$1, s.$2) == null) _sel = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic>? _towerAt(int x, int y) {
    for (final t in (_data!['towers'] as List)) {
      if (t['x'] == x && t['y'] == y) return (t as Map).cast<String, dynamic>();
    }
    return null;
  }

  void _tapCell(int x, int y) {
    if (_playing || _busy) return;
    final d = _data!;
    final spawn = (d['spawn'] as List).cast<int>(), goal = (d['goal'] as List).cast<int>();
    if ((x == spawn[0] && y == spawn[1]) || (x == goal[0] && y == goal[1])) return;
    if (_towerAt(x, y) != null) {
      setState(() => _sel = (x, y));
      return;
    }
    setState(() => _sel = null);
    _act(() => _api.tdBuild(_build, x, y));
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: const Color(0xFF14110B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1710),
        title: const Text('塔防', style: TextStyle(color: Color(0xFFFFD36B))),
        iconTheme: const IconThemeData(color: Color(0xFFFFD36B)),
        actions: [
          TextButton(
            onPressed: () => _showHelp(),
            child: const Text('玩法', style: TextStyle(color: Color(0xFFFFD36B))),
          ),
        ],
      ),
      body: _error != null && d == null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)))
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(child: Column(children: [_hud(d), _board(d), _controls(d)])),
    );
  }

  Widget _chip(String s, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withValues(alpha: 0.5))),
        child: Text(s, style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 13)),
      );

  Widget _hud(Map<String, dynamic> d) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Wrap(spacing: 8, runSpacing: 6, children: [
        _chip('第 ${d['round']} 回合', const Color(0xFFFFD36B)),
        _chip('❤️ ${d['lives']}/${d['max_lives']}', const Color(0xFFFF6B6B)),
        _chip('🪙 ${d['gold']}', const Color(0xFFFFE08A)),
        _chip('💎 ${d['crystals']}', const Color(0xFF8FD3FF)),
        _chip('最高 ${d['best_round']}', Colors.white54),
      ]),
    );
  }

  Widget _board(Map<String, dynamic> d) {
    final cols = d['cols'] as int, rows = d['rows'] as int;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final h = w * rows / cols;
      return GestureDetector(
        onTapDown: (e) {
          final x = (e.localPosition.dx / (w / cols)).floor();
          final y = (e.localPosition.dy / (h / rows)).floor();
          if (x >= 0 && x < cols && y >= 0 && y < rows) _tapCell(x, y);
        },
        child: SizedBox(
          width: w,
          height: h,
          child: ClipRect(child: CustomPaint(painter: _TdPainter(this, w / cols))),
        ),
      );
    });
  }

  Widget _controls(Map<String, dynamic> d) {
    final types = (d['tower_types'] as Map).cast<String, dynamic>();
    final nxt = (d['next'] as Map).cast<String, dynamic>();
    final sel = _sel;
    final tw = sel == null ? null : _towerAt(sel.$1, sel.$2);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (d['blocked'] == true)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0x33FF5252), borderRadius: BorderRadius.circular(8)),
            child: const Text('⚠️ 路被堵死了！怪物會停下來打擋路的塔，塔被打爆會消失。', style: TextStyle(color: Color(0xFFFF8A80), fontSize: 12)),
          ),
        const Text('蓋塔（選一種，再點空格子）', style: TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Row(children: [
          for (final k in ['arrow', 'cannon', 'frost'])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: OutlinedButton(
                  onPressed: _playing ? null : () => setState(() => _build = k),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: _build == k ? _towerColors[k]!.withValues(alpha: 0.3) : null,
                    side: BorderSide(color: _build == k ? _towerColors[k]! : Colors.white24, width: _build == k ? 2 : 1),
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  ),
                  child: Column(children: [
                    Text('${_towerIcons[k]} ${types[k]['name']}', style: const TextStyle(color: Colors.white, fontSize: 12)),
                    Text('🪙 ${types[k]['cost']}', style: const TextStyle(color: Color(0xFFFFE08A), fontSize: 12)),
                  ]),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 4),
        Text(types[_build]['desc'] as String, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        if (tw != null) ...[
          const Divider(height: 24),
          _towerPanel(tw, types),
        ],
        const Divider(height: 24),
        Text('下一回合：${nxt['band']}，${nxt['count']} 隻（每隻血量約 ${nxt['hp']}）${nxt['boss'] != null ? '，最後一隻頭目「${nxt['boss']}」' : ''}',
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _playing || _busy ? null : () => _act(_api.tdStart, play: true),
              icon: const Icon(Icons.play_arrow),
              label: Text(_playing ? '戰鬥中…' : '開始第 ${d['round']} 回合'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => setState(() => _speed = _speed == 1.0 ? 2.0 : 1.0),
            child: Text('${_speed.toStringAsFixed(0)}x'),
          ),
        ]),
      ]),
    );
  }

  Widget _towerPanel(Map<String, dynamic> tw, Map<String, dynamic> types) {
    final st = (tw['stats'] as Map).cast<String, dynamic>();
    final t = tw['t'] as String;
    final maxL = _data!['max_level'] as int;
    final cost = tw['upgrade_cost'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_towerIcons[t]} ${types[t]['name']}　Lv.${tw['l']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(
        '傷害 ${(st['dmg'] as num).toStringAsFixed(0)}　射程 ${(st['range'] as num).toStringAsFixed(1)}　攻速 ${(st['interval'] as num).toStringAsFixed(2)}s'
        '${(st['slow'] as num) > 0 ? '　減速 ${((st['slow'] as num) * 100).round()}%' : ''}${(st['splash'] as num) > 0 ? '　範圍 ${st['splash']}' : ''}',
        style: const TextStyle(color: Colors.white60, fontSize: 12),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: FilledButton(
            onPressed: _playing || _busy || (tw['l'] as int) >= maxL ? null : () => _act(() => _api.tdUpgrade(tw['x'] as int, tw['y'] as int)),
            child: Text((tw['l'] as int) >= maxL ? '已滿級' : '升級（💎 $cost）'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: _playing || _busy ? null : () => _act(() => _api.tdSell(tw['x'] as int, tw['y'] as int)),
            child: Text('賣出（🪙 ${tw['sell_gold']}${(tw['sell_crystals'] as int) > 0 ? '、💎 ${tw['sell_crystals']}' : ''}）'),
          ),
        ),
      ]),
    ]);
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('塔防玩法'),
        content: const SingleChildScrollView(
          child: Text(
            '• 怪物從左邊紅色入口出來，走到右邊藍色終點。每回合固定 20 隻，每 10 回合最後一隻是頭目。\n'
            '• 點下面的塔種類，再點地圖空格子蓋塔，花金幣。塔會讓怪物繞路，把路擋成迷宮就能多打幾下。\n'
            '• 金幣靠打怪和過關賺。升級塔的等級要花水晶（到勇者頁把用不到的裝備分解可得）。\n'
            '• 點已蓋的塔可以升級或賣出（賣出拿回 70% 金幣、50% 水晶）。\n'
            '• 路被完全堵死時，怪物會停下來打擋路的塔，塔被打爆就沒了；沒堵死就不會打塔。\n'
            '• 每漏掉一隻怪扣 1 生命。生命歸零＝回合失敗：塔不會爆掉，同一回合再來一次，但這次沒有金幣。\n'
            '• 過關後恢復 2 生命。',
            style: TextStyle(fontSize: 13),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
      ),
    );
  }
}

class _TdPainter extends CustomPainter {
  final _TdScreenState s;
  final double cell;
  _TdPainter(this.s, this.cell) : super(repaint: s._repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final d = s._data;
    if (d == null) return;
    final cols = d['cols'] as int, rows = d['rows'] as int;
    // 草地
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), Paint()..color = (x + y) % 2 == 0 ? const Color(0xFF2E4A2B) : const Color(0xFF335230));
      }
    }
    // 路（目前最短路）
    for (final p in (d['path'] as List)) {
      canvas.drawRect(Rect.fromLTWH(p[0] * cell + 1, p[1] * cell + 1, cell - 2, cell - 2), Paint()..color = const Color(0x66C9A86B));
    }
    final spawn = (d['spawn'] as List).cast<int>(), goal = (d['goal'] as List).cast<int>();
    _portal(canvas, spawn, const Color(0xFFFF5252), '入口');
    _portal(canvas, goal, const Color(0xFF4FC3F7), '終點');
    // 選取格射程
    final sel = s._sel;
    final towers = (d['towers'] as List).cast<Map>();
    if (sel != null) {
      final tw = s._towerAt(sel.$1, sel.$2);
      if (tw != null) {
        final r = ((tw['stats'] as Map)['range'] as num).toDouble() * cell;
        canvas.drawCircle(Offset((sel.$1 + 0.5) * cell, (sel.$2 + 0.5) * cell), r, Paint()..color = const Color(0x22FFFFFF));
        canvas.drawCircle(
            Offset((sel.$1 + 0.5) * cell, (sel.$2 + 0.5) * cell), r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = const Color(0x99FFFFFF));
      }
    }
    // 塔
    final frames = s._frames;
    Map<String, dynamic>? curTh;
    int fi = 0;
    double frac = 0;
    if (frames != null) {
      final ft = s._t / 0.2;
      fi = ft.floor().clamp(0, frames.length - 1);
      frac = (ft - fi).clamp(0.0, 1.0);
      curTh = ((frames[fi] as Map)['th'] as Map?)?.cast<String, dynamic>();
    }
    for (var i = 0; i < towers.length; i++) {
      final t = towers[i];
      final th = curTh?['$i'];
      if (th == 0) continue;
      _tower(canvas, t, selected: sel != null && sel.$1 == t['x'] && sel.$2 == t['y'], hpPct: th is num ? th.toInt() : null);
    }
    if (frames == null) return;
    // 怪物與射擊
    final mons = (d['next']['monsters'] as List).cast<Map>();
    final band = (((d['round'] as int) - 1) ~/ 10) % 10;
    final cur = (frames[fi] as Map)['m'] as List;
    final nxt = (frames[math.min(fi + 1, frames.length - 1)] as Map)['m'] as List;
    for (var i = 0; i < cur.length; i++) {
      final a = cur[i] as List;
      if (a.length < 3) continue;
      final b = nxt[i] as List;
      double x = (a[0] as num) / 100, y = (a[1] as num) / 100;
      if (b.length >= 3) {
        x += ((b[0] as num) / 100 - x) * frac;
        y += ((b[1] as num) / 100 - y) * frac;
      }
      final boss = mons[i]['boss'] == true;
      final sz = cell * (boss ? 1.15 : 0.8);
      final cx = x * cell, cy = y * cell;
      canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy + sz * 0.38), width: sz * 0.6, height: 5), Paint()..color = const Color(0x55000000));
      canvas.save();
      canvas.translate(cx - sz / 2, cy + sz * 0.4 - sz);
      MonsterPainter(kind: mons[i]['kind'] as int, band: band, boss: boss, flash: 0, opacity: 1, t: s._t + i).paint(canvas, Size(sz, sz));
      canvas.restore();
      if ((a.length > 3 ? a[3] : 0) == 1) {
        canvas.drawCircle(Offset(cx, cy), sz * 0.45, Paint()..color = const Color(0x334FC3F7));
      }
      final hp = (a[2] as num) / 100;
      canvas.drawRect(Rect.fromLTWH(cx - sz * 0.4, cy - sz * 0.62, sz * 0.8, 3), Paint()..color = Colors.black54);
      canvas.drawRect(Rect.fromLTWH(cx - sz * 0.4, cy - sz * 0.62, sz * 0.8 * hp, 3), Paint()..color = hp > 0.5 ? const Color(0xFF4CD964) : (hp > 0.2 ? const Color(0xFFFFB02E) : const Color(0xFFFF5C5C)));
    }
    final shots = (frames[fi] as Map)['s'] as List;
    for (final sh in shots) {
      final ti = sh[0] as int, mi = sh[1] as int;
      if (ti >= towers.length) continue;
      final m = cur[mi] as List;
      if (m.length < 3) continue;
      final t = towers[ti];
      final from = Offset(((t['x'] as int) + 0.5) * cell, ((t['y'] as int) + 0.5) * cell);
      final to = Offset((m[0] as num) / 100 * cell, (m[1] as num) / 100 * cell);
      final col = _towerColors[t['t']] ?? Colors.white;
      final p = Offset.lerp(from, to, math.min(1.0, frac * 1.6))!;
      canvas.drawLine(from, p, Paint()..color = col.withValues(alpha: 0.9)..strokeWidth = sh[2] == 1 ? 4 : 2);
      if (sh[2] == 1) {
        canvas.drawCircle(to, cell * 1.1 * frac, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = const Color(0xFFFFB74D).withValues(alpha: 1 - frac));
      }
    }
  }

  void _portal(Canvas canvas, List<int> p, Color c, String label) {
    final r = Rect.fromLTWH(p[0] * cell + 2, p[1] * cell + 2, cell - 4, cell - 4);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(8)), Paint()..color = c.withValues(alpha: 0.55));
    final tp = TextPainter(text: TextSpan(text: label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(r.center.dx - tp.width / 2, r.center.dy - tp.height / 2));
  }

  void _tower(Canvas canvas, Map t, {required bool selected, int? hpPct}) {
    final x = (t['x'] as int) * cell, y = (t['y'] as int) * cell;
    final col = _towerColors[t['t']] ?? Colors.grey;
    final r = Rect.fromLTWH(x + 3, y + 3, cell - 6, cell - 6);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(8)), Paint()..color = col);
    canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(8)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 3 : 1.5
          ..color = selected ? const Color(0xFFFFD36B) : Colors.black54);
    final tp = TextPainter(text: TextSpan(text: _towerIcons[t['t']], style: TextStyle(fontSize: cell * 0.42)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(r.center.dx - tp.width / 2, r.center.dy - tp.height / 2 - 2));
    for (var i = 0; i < (t['l'] as int); i++) {
      canvas.drawCircle(Offset(x + cell * 0.2 + i * cell * 0.15, y + cell - 7), 2.2, Paint()..color = const Color(0xFFFFD36B));
    }
    if (hpPct != null && hpPct < 100) {
      canvas.drawRect(Rect.fromLTWH(x + 4, y + 1, cell - 8, 3), Paint()..color = Colors.black54);
      canvas.drawRect(Rect.fromLTWH(x + 4, y + 1, (cell - 8) * hpPct / 100, 3), Paint()..color = const Color(0xFFFF5C5C));
    }
  }

  @override
  bool shouldRepaint(covariant _TdPainter old) => true;
}
