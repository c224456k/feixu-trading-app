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
  String _banner = '';
  double _bannerT = 0;
  double _clock = 0;
  final Map<int, double> _aim = {}; // 塔 index → 砲口/弓朝向

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
    final dt0 = (d - _last).inMicroseconds / 1e6;
    _clock += dt0;
    if (_bannerT > 0) _bannerT -= dt0;
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
      _banner = won ? '🎉 過關！' : '💀 失敗';
      _bannerT = 2.2;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(won ? '🎉 過關！擊殺 ${r['kills']} 隻、漏掉 ${r['leaks']} 隻，+${r['crystals']} 水晶' : '💀 失敗，漏掉 ${r['leaks']} 隻。塔都還在，調整後再試'),
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
          _aim.clear();
          _banner = '第 ${_data!['round']} 回合';
          _bannerT = 1.4;
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

  String _money(dynamic v) {
    final n = (v as num).round();
    if (n.abs() >= 10000) {
      final w = n / 10000;
      return '${w == w.roundToDouble() ? w.round() : w.toStringAsFixed(1)}萬';
    }
    return '$n';
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
        _chip('💰 ${_money(d['cash'])}', const Color(0xFFFFE08A)),
        _chip('💎 ${d['crystals']}', const Color(0xFF8FD3FF)),
        _chip('🍖 ${(d['meat'] as num).floor()}/${d['meat_max']}', const Color(0xFFFFA070)),
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
                    Text('💰 ${_money(types[k]['cost'])}', style: const TextStyle(color: Color(0xFFFFE08A), fontSize: 12)),
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
        Text('每回合消耗 ${d['meat_cost']} 塊肉（塔防自己的肉，每分鐘恢復 1 塊）。過關可得 ${d['crystal_reward']} 水晶。',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 4),
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
            child: Text('賣出（💰 ${_money(tw['sell_gold'])}${(tw['sell_crystals'] as int) > 0 ? '、💎 ${tw['sell_crystals']}' : ''}）'),
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
            '• 點下面的塔種類，再點地圖空格子蓋塔，花現金。塔會讓怪物繞路，把路擋成迷宮就能多打幾下。\n'
            '• 蓋塔要花現金（箭塔 50 萬、砲塔 100 萬、冰塔 200 萬）。升級塔的等級要花水晶（過關可得，也能在勇者頁分解裝備取得）。\n'
            '• 點已蓋的塔可以升級或賣出（賣出拿回 70% 現金、50% 水晶）。\n'
            '• 路被完全堵死時，怪物會停下來打擋路的塔，塔被打爆就沒了；沒堵死就不會打塔。\n'
            '• 每漏掉一隻怪扣 1 生命。生命歸零＝回合失敗：塔不會爆掉，同一回合再來一次，但這次沒有水晶。\n'
            '• 過關後恢復 2 生命，並獲得水晶（頭目回合更多）。\n'
            '• 每開始一回合消耗 10 塊肉，塔防有自己的肉（上限 60，每分鐘恢復 1 塊），跟百層塔的肉分開算。',
            style: TextStyle(fontSize: 13),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
      ),
    );
  }
}

class _Float {
  final String text;
  final Offset pos;
  final double age;
  final Color color;
  final double size;
  _Float(this.text, this.pos, this.age, this.color, this.size);
}

class _TdPainter extends CustomPainter {
  final _TdScreenState s;
  final double cell;
  _TdPainter(this.s, this.cell) : super(repaint: s._repaint);

  // ---- 小工具：在「格子單位座標」裡畫（0~1 = 一格）----
  void _unit(Canvas c, double gx, double gy, void Function() body) {
    c.save();
    c.translate(gx * cell, gy * cell);
    c.scale(cell);
    body();
    c.restore();
  }

  double _hash(int x, int y, int k) {
    var h = (x * 73856093) ^ (y * 19349663) ^ (k * 83492791);
    h = (h ^ (h >> 13)) * 1274126177;
    h = h ^ (h >> 16);
    return (h & 0xFFFF) / 0xFFFF;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final d = s._data;
    if (d == null) return;
    final cols = d['cols'] as int, rows = d['rows'] as int;
    final clock = s._clock;
    _ground(canvas, cols, rows);
    _road(canvas, d);
    final spawn = (d['spawn'] as List).cast<int>(), goal = (d['goal'] as List).cast<int>();
    _portal(canvas, spawn, clock);
    _castle(canvas, goal, clock);

    final sel = s._sel;
    final towers = (d['towers'] as List).cast<Map>();
    final frames = s._frames;
    Map<String, dynamic>? curTh;
    int fi = 0;
    double frac = 0;
    List<dynamic>? cur, nxt;
    if (frames != null) {
      final ft = s._t / 0.2;
      fi = ft.floor().clamp(0, frames.length - 1);
      frac = (ft - fi).clamp(0.0, 1.0);
      curTh = ((frames[fi] as Map)['th'] as Map?)?.cast<String, dynamic>();
      cur = (frames[fi] as Map)['m'] as List;
      nxt = (frames[math.min(fi + 1, frames.length - 1)] as Map)['m'] as List;
      // 更新塔的朝向 / 射擊
      for (final sh in ((frames[fi] as Map)['s'] as List)) {
        final ti = sh[0] as int, mi = sh[1] as int;
        if (ti < towers.length && (cur[mi] as List).length >= 3) {
          final t = towers[ti];
          final m = cur[mi] as List;
          s._aim[ti] = math.atan2((m[1] as num) / 100 - ((t['y'] as int) + 0.5), (m[0] as num) / 100 - ((t['x'] as int) + 0.5));
        }
      }
    }
    // 選取格射程
    if (sel != null) {
      final tw = s._towerAt(sel.$1, sel.$2);
      if (tw != null) {
        final r = ((tw['stats'] as Map)['range'] as num).toDouble() * cell;
        final c = Offset((sel.$1 + 0.5) * cell, (sel.$2 + 0.5) * cell);
        canvas.drawCircle(c, r, Paint()..color = const Color(0x22FFFFFF));
        canvas.drawCircle(c, r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = const Color(0xAAFFFFFF));
      }
    }
    // 塔（由上而下畫，下面的塔蓋住上面的）
    final order = List.generate(towers.length, (i) => i)..sort((a, b) => (towers[a]['y'] as int).compareTo(towers[b]['y'] as int));
    final shotNow = <int, bool>{};
    if (frames != null) {
      for (final sh in ((frames[fi] as Map)['s'] as List)) {
        shotNow[sh[0] as int] = true;
      }
    }
    for (final i in order) {
      final t = towers[i];
      final th = curTh?['$i'];
      if (th == 0) continue;
      _tower(canvas, t, selected: sel != null && sel.$1 == t['x'] && sel.$2 == t['y'], hpPct: th is num ? th.toInt() : null,
          aim: s._aim[i] ?? 0, fire: shotNow[i] == true ? (1 - frac) : 0, clock: clock);
    }
    if (frames != null && cur != null && nxt != null) {
      _monsters(canvas, d, towers, frames, fi, frac, cur, nxt);
    }
    // 橫幅
    if (s._bannerT > 0 && s._banner.isNotEmpty) {
      final a = (s._bannerT / 0.5).clamp(0.0, 1.0);
      final rect = Rect.fromLTWH(0, size.height * 0.38, size.width, size.height * 0.24);
      canvas.drawRect(rect, Paint()..color = Colors.black.withValues(alpha: 0.5 * a));
      _text(canvas, s._banner, rect.center, 30, const Color(0xFFFFE08A).withValues(alpha: a), bold: true);
    }
  }

  // ---- 地面 ----
  void _ground(Canvas canvas, int cols, int rows) {
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final h = _hash(x, y, 1);
        final base = (x + y) % 2 == 0 ? const Color(0xFF3E6B34) : const Color(0xFF437339);
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), Paint()..color = Color.lerp(base, const Color(0xFF2F5A2B), h * 0.35)!);
        // 草叢 / 花 / 小石頭（純裝飾）
        final k = _hash(x, y, 2);
        final ox = x * cell + _hash(x, y, 3) * cell * 0.7 + cell * 0.1, oy = y * cell + _hash(x, y, 4) * cell * 0.7 + cell * 0.15;
        if (k < 0.35) {
          final gp = Paint()..color = const Color(0xFF5E9C4A)..strokeWidth = 1.4..strokeCap = StrokeCap.round;
          for (var j = -1; j <= 1; j++) {
            canvas.drawLine(Offset(ox + j * 2.5, oy), Offset(ox + j * 3.5, oy - cell * 0.14), gp);
          }
        } else if (k < 0.47) {
          final colors = [const Color(0xFFFF8FA3), const Color(0xFFFFE08A), const Color(0xFFB39DDB), Colors.white];
          final c = colors[(h * 4).floor() % 4];
          canvas.drawCircle(Offset(ox, oy), cell * 0.045, Paint()..color = c);
          canvas.drawCircle(Offset(ox, oy), cell * 0.02, Paint()..color = const Color(0xFFFFA000));
        } else if (k < 0.55) {
          canvas.drawOval(Rect.fromCenter(center: Offset(ox, oy), width: cell * 0.16, height: cell * 0.1), Paint()..color = const Color(0xFF8E9A8A));
          canvas.drawOval(Rect.fromCenter(center: Offset(ox - 1, oy - 1), width: cell * 0.1, height: cell * 0.05), Paint()..color = const Color(0xFFB4BDB0));
        }
      }
    }
    // 淡淡的格線
    final gl = Paint()..color = const Color(0x14000000)..strokeWidth = 1;
    for (var x = 1; x < cols; x++) {
      canvas.drawLine(Offset(x * cell, 0), Offset(x * cell, rows * cell), gl);
    }
    for (var y = 1; y < rows; y++) {
      canvas.drawLine(Offset(0, y * cell), Offset(cols * cell, y * cell), gl);
    }
  }

  // ---- 道路（目前最短路）----
  void _road(Canvas canvas, Map<String, dynamic> d) {
    final pts = [for (final p in (d['path'] as List)) Offset(((p[0] as int) + 0.5) * cell, ((p[1] as int) + 0.5) * cell)];
    if (pts.length < 2) return;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    Paint line(double w, Color c) => Paint()..style = PaintingStyle.stroke..strokeWidth = w..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round..color = c;
    canvas.drawPath(path, line(cell * 0.86, const Color(0xFF6E5233)));
    canvas.drawPath(path, line(cell * 0.74, const Color(0xFFB8955E)));
    canvas.drawPath(path, line(cell * 0.5, const Color(0xFFC9A66F)));
    // 路面小石子
    for (var i = 0; i < pts.length; i++) {
      final p = d['path'][i] as List;
      for (var k = 0; k < 2; k++) {
        final ox = pts[i].dx + (_hash(p[0] as int, p[1] as int, 10 + k) - 0.5) * cell * 0.5;
        final oy = pts[i].dy + (_hash(p[0] as int, p[1] as int, 20 + k) - 0.5) * cell * 0.5;
        canvas.drawCircle(Offset(ox, oy), cell * 0.03, Paint()..color = const Color(0xFF9C7A48));
      }
    }
  }

  void _text(Canvas canvas, String text, Offset center, double size, Color color, {bool bold = false, bool outline = true}) {
    TextPainter mk(Paint? fg, Color? col) => TextPainter(
        text: TextSpan(text: text, style: TextStyle(fontSize: size, fontWeight: bold ? FontWeight.w900 : FontWeight.bold, color: col, foreground: fg)),
        textDirection: TextDirection.ltr)
      ..layout();
    if (outline) {
      final o = mk(Paint()..style = PaintingStyle.stroke..strokeWidth = size * 0.18..color = Colors.black.withValues(alpha: color.a), null);
      o.paint(canvas, Offset(center.dx - o.width / 2, center.dy - o.height / 2));
    }
    final t = mk(null, color);
    t.paint(canvas, Offset(center.dx - t.width / 2, center.dy - t.height / 2));
  }

  // ---- 入口：傳送門 ----
  void _portal(Canvas canvas, List<int> p, double clock) {
    final c = Offset((p[0] + 0.5) * cell, (p[1] + 0.5) * cell);
    canvas.drawCircle(c, cell * 0.5, Paint()..shader = RadialGradient(colors: [const Color(0xAAFF5252), const Color(0x00FF5252)]).createShader(Rect.fromCircle(center: c, radius: cell * 0.5)));
    for (var i = 0; i < 3; i++) {
      final r = cell * (0.42 - i * 0.1);
      final a = clock * (2.0 + i) * (i.isEven ? 1 : -1);
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a, math.pi * 1.4, false,
          Paint()..style = PaintingStyle.stroke..strokeWidth = cell * 0.06..strokeCap = StrokeCap.round..color = [const Color(0xFFFF8A80), const Color(0xFFE040FB), const Color(0xFFFFFFFF)][i]);
    }
    canvas.drawCircle(c, cell * 0.1 + math.sin(clock * 4) * cell * 0.02, Paint()..color = const Color(0xFF311B92));
  }

  // ---- 終點：城堡 ----
  void _castle(Canvas canvas, List<int> p, double clock) {
    _unit(canvas, p[0].toDouble(), p[1].toDouble(), () {
      canvas.drawRect(const Rect.fromLTWH(0.1, 0.35, 0.8, 0.6), Paint()..color = const Color(0xFF9AA3B0));
      canvas.drawRect(const Rect.fromLTWH(0.1, 0.35, 0.8, 0.6), Paint()..style = PaintingStyle.stroke..strokeWidth = 0.025..color = const Color(0xFF4A5260));
      for (final x in [0.1, 0.32, 0.54, 0.76]) {
        canvas.drawRect(Rect.fromLTWH(x, 0.27, 0.14, 0.1), Paint()..color = const Color(0xFFB5BDC9));
      }
      canvas.drawRRect(RRect.fromRectAndCorners(const Rect.fromLTWH(0.38, 0.58, 0.24, 0.37), topLeft: const Radius.circular(0.12), topRight: const Radius.circular(0.12)), Paint()..color = const Color(0xFF4E342E));
      canvas.drawLine(const Offset(0.5, 0.27), const Offset(0.5, 0.04), Paint()..color = const Color(0xFF5D4037)..strokeWidth = 0.03);
      final wave = math.sin(clock * 5) * 0.03;
      canvas.drawPath(Path()..moveTo(0.5, 0.04)..lineTo(0.78, 0.11 + wave)..lineTo(0.5, 0.18)..close(), Paint()..color = const Color(0xFF29B6F6));
    });
  }

  // ---- 塔 ----
  void _tower(Canvas canvas, Map t, {required bool selected, int? hpPct, required double aim, required double fire, required double clock}) {
    final gx = (t['x'] as int).toDouble(), gy = (t['y'] as int).toDouble();
    final lv = t['l'] as int;
    final type = t['t'] as String;
    _unit(canvas, gx, gy, () {
      // 地基（石頭台座）
      canvas.drawOval(const Rect.fromLTWH(0.1, 0.72, 0.8, 0.24), Paint()..color = const Color(0x55000000));
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0.14, 0.62, 0.72, 0.3), const Radius.circular(0.08)), Paint()..color = const Color(0xFF7A808A));
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0.14, 0.62, 0.72, 0.3), const Radius.circular(0.08)), Paint()..style = PaintingStyle.stroke..strokeWidth = 0.02..color = const Color(0xFF3C4048));
      for (final x in [0.3, 0.5, 0.7]) {
        canvas.drawLine(Offset(x, 0.64), Offset(x, 0.9), Paint()..color = const Color(0x33000000)..strokeWidth = 0.015);
      }
      if (selected) {
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0.06, 0.04, 0.88, 0.9), const Radius.circular(0.1)), Paint()..style = PaintingStyle.stroke..strokeWidth = 0.04..color = const Color(0xFFFFD36B));
      }
      switch (type) {
        case 'arrow':
          _arrowTower(canvas, lv, aim, fire);
        case 'cannon':
          _cannonTower(canvas, lv, aim, fire);
        default:
          _frostTower(canvas, lv, clock, fire);
      }
      // 等級星
      for (var i = 0; i < lv; i++) {
        _star(canvas, Offset(0.5 + (i - (lv - 1) / 2) * 0.13, 0.9), 0.055, lv >= 5 ? const Color(0xFFFFD54F) : const Color(0xFFFFF59D));
      }
      if (hpPct != null && hpPct < 100) {
        canvas.drawRect(const Rect.fromLTWH(0.12, 0.02, 0.76, 0.07), Paint()..color = Colors.black54);
        canvas.drawRect(Rect.fromLTWH(0.12, 0.02, 0.76 * hpPct / 100, 0.07), Paint()..color = const Color(0xFFFF5C5C));
      }
    });
  }

  void _star(Canvas c, Offset o, double r, Color col) {
    final p = Path();
    for (var i = 0; i < 10; i++) {
      final rr = i.isEven ? r : r * 0.45;
      final a = -math.pi / 2 + i * math.pi / 5;
      final pt = Offset(o.dx + math.cos(a) * rr, o.dy + math.sin(a) * rr);
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    p.close();
    c.drawPath(p, Paint()..color = col);
    c.drawPath(p, Paint()..style = PaintingStyle.stroke..strokeWidth = 0.012..color = const Color(0xFF6D4C00));
  }

  void _arrowTower(Canvas c, int lv, double aim, double fire) {
    final h = 0.34 + lv * 0.035; // 塔身高度隨等級增加
    final wood = const Color(0xFF8D6E4B), dark = const Color(0xFF5D4630);
    c.drawPath(Path()..moveTo(0.3, 0.66)..lineTo(0.7, 0.66)..lineTo(0.62, 0.66 - h)..lineTo(0.38, 0.66 - h)..close(), Paint()..color = wood);
    c.drawPath(Path()..moveTo(0.3, 0.66)..lineTo(0.7, 0.66)..lineTo(0.62, 0.66 - h)..lineTo(0.38, 0.66 - h)..close(), Paint()..style = PaintingStyle.stroke..strokeWidth = 0.02..color = dark);
    for (var i = 1; i < 3; i++) {
      c.drawLine(Offset(0.34 + i * 0.01, 0.66 - h * i / 3), Offset(0.66 - i * 0.01, 0.66 - h * i / 3), Paint()..color = dark..strokeWidth = 0.015);
    }
    final top = 0.66 - h;
    // 平台與屋頂
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0.3, top - 0.05, 0.4, 0.07), const Radius.circular(0.02)), Paint()..color = dark);
    final roof = lv >= 5 ? const Color(0xFFFFB300) : lv >= 3 ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
    c.drawPath(Path()..moveTo(0.26, top - 0.05)..lineTo(0.5, top - 0.27)..lineTo(0.74, top - 0.05)..close(), Paint()..color = roof);
    c.drawPath(Path()..moveTo(0.26, top - 0.05)..lineTo(0.5, top - 0.27)..lineTo(0.74, top - 0.05)..close(), Paint()..style = PaintingStyle.stroke..strokeWidth = 0.015..color = Colors.black54);
    // 弓（朝向目標）
    c.save();
    c.translate(0.5, top - 0.09);
    c.rotate(aim);
    final bow = Paint()..style = PaintingStyle.stroke..strokeWidth = 0.03..color = const Color(0xFF4E342E)..strokeCap = StrokeCap.round;
    c.drawArc(Rect.fromCenter(center: Offset(0.04 - fire * 0.03, 0), width: 0.2, height: 0.26), -math.pi / 2, math.pi, false, bow);
    c.drawLine(Offset(0.04 - fire * 0.03, -0.13), Offset(-0.02 - fire * 0.06, 0), Paint()..color = Colors.white70..strokeWidth = 0.008);
    c.drawLine(Offset(0.04 - fire * 0.03, 0.13), Offset(-0.02 - fire * 0.06, 0), Paint()..color = Colors.white70..strokeWidth = 0.008);
    c.restore();
    if (lv >= 3) {
      c.drawLine(Offset(0.5, top - 0.27), Offset(0.5, top - 0.4), Paint()..color = Colors.black87..strokeWidth = 0.015);
      c.drawPath(Path()..moveTo(0.5, top - 0.4)..lineTo(0.64, top - 0.35)..lineTo(0.5, top - 0.3)..close(), Paint()..color = lv >= 5 ? const Color(0xFFFFD54F) : const Color(0xFFEF5350));
    }
  }

  void _cannonTower(Canvas c, int lv, double aim, double fire) {
    final stone = const Color(0xFF59606B);
    final bodyH = 0.2 + lv * 0.02;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0.24, 0.66 - bodyH, 0.52, bodyH), const Radius.circular(0.05)), Paint()..color = stone);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0.24, 0.66 - bodyH, 0.52, bodyH), const Radius.circular(0.05)), Paint()..style = PaintingStyle.stroke..strokeWidth = 0.02..color = Colors.black87);
    for (var i = 0; i < 3; i++) {
      c.drawRect(Rect.fromLTWH(0.24 + i * 0.2, 0.66 - bodyH - 0.05, 0.12, 0.06), Paint()..color = stone);
    }
    final pivot = Offset(0.5, 0.66 - bodyH - 0.01);
    c.save();
    c.translate(pivot.dx, pivot.dy);
    c.rotate(aim);
    final len = 0.22 + lv * 0.03 - fire * 0.04;
    final w = 0.09 + lv * 0.01;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(-0.04, -w, len, w * 2), const Radius.circular(0.03)), Paint()..color = const Color(0xFF263238));
    c.drawRect(Rect.fromLTWH(len - 0.1, -w - 0.015, 0.045, w * 2 + 0.03), Paint()..color = const Color(0xFF455A64));
    c.drawCircle(Offset.zero, w * 1.15, Paint()..color = const Color(0xFF37474F));
    if (fire > 0.4) {
      final f = (fire - 0.4) / 0.6;
      c.drawCircle(Offset(len + 0.06, 0), 0.12 * f + 0.03, Paint()..color = const Color(0xFFFFB74D).withValues(alpha: f));
      c.drawCircle(Offset(len + 0.06, 0), 0.06 * f, Paint()..color = const Color(0xFFFFF59D).withValues(alpha: f));
    }
    c.restore();
    c.drawCircle(pivot, 0.035, Paint()..color = lv >= 5 ? const Color(0xFFFFD54F) : const Color(0xFFB0BEC5));
  }

  void _frostTower(Canvas c, int lv, double clock, double fire) {
    final glow = 0.5 + 0.5 * math.sin(clock * 3) + fire * 0.6;
    final cc = const Offset(0.5, 0.5);
    c.drawCircle(cc, 0.34, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(129, 212, 250, 0.35 + 0.25 * glow.clamp(0, 1)), const Color(0x0081D4FA)]).createShader(Rect.fromCircle(center: cc, radius: 0.34)));
    c.drawPath(Path()..moveTo(0.3, 0.66)..lineTo(0.7, 0.66)..lineTo(0.62, 0.55)..lineTo(0.38, 0.55)..close(), Paint()..color = const Color(0xFF90A4AE));
    // 水晶叢（等級越高越多越高）
    final shards = [
      (0.5, 0.18 + lv * 0.04, 0.09, 0.0),
      (0.37, 0.12 + lv * 0.02, 0.06, -0.25),
      (0.63, 0.12 + lv * 0.02, 0.06, 0.25),
      (0.3, 0.08, 0.045, -0.5),
      (0.7, 0.08, 0.045, 0.5),
    ];
    for (var i = 0; i < math.min(shards.length, 2 + lv); i++) {
      final (x, h, w, rot) = shards[i];
      c.save();
      c.translate(x, 0.6);
      c.rotate(rot);
      final p = Path()..moveTo(-w, 0)..lineTo(0, -h - 0.2)..lineTo(w, 0)..lineTo(0, 0.04)..close();
      c.drawPath(p, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: const [Color(0xFFE1F5FE), Color(0xFF29B6F6)]).createShader(Rect.fromLTWH(-w, -h - 0.2, w * 2, h + 0.24)));
      c.drawPath(p, Paint()..style = PaintingStyle.stroke..strokeWidth = 0.012..color = const Color(0xFF0277BD));
      c.drawLine(const Offset(0, 0), Offset(0, -h - 0.15), Paint()..color = Colors.white54..strokeWidth = 0.01);
      c.restore();
    }
  }

  // ---- 怪物、射擊、特效 ----
  void _monsters(Canvas canvas, Map<String, dynamic> d, List<Map> towers, List frames, int fi, double frac, List cur, List nxt) {
    final mons = (d['next']['monsters'] as List).cast<Map>();
    final band = (((d['round'] as int) - 1) ~/ 10) % 10;
    final clock = s._clock;
    Offset? posOf(List a, List b) {
      if (a.length < 3) return null;
      double x = (a[0] as num) / 100, y = (a[1] as num) / 100;
      if (b.length >= 3) {
        x += ((b[0] as num) / 100 - x) * frac;
        y += ((b[1] as num) / 100 - y) * frac;
      }
      return Offset(x * cell, y * cell);
    }

    // 本影格被打到的怪（含砲塔範圍）
    final hit = <int>{};
    final shots = (frames[fi] as Map)['s'] as List;
    for (final sh in shots) {
      final mi = sh[1] as int;
      hit.add(mi);
      if (sh[2] == 1 && (cur[mi] as List).length >= 3) {
        final tp = Offset(((cur[mi] as List)[0] as num) / 100, ((cur[mi] as List)[1] as num) / 100);
        for (var j = 0; j < cur.length; j++) {
          final a = cur[j] as List;
          if (a.length >= 3 && (Offset((a[0] as num) / 100, (a[1] as num) / 100) - tp).distance <= 1.2) hit.add(j);
        }
      }
    }
    // 依 y 排序（遠的先畫）
    final idx = <int>[for (var i = 0; i < cur.length; i++) if ((cur[i] as List).length >= 3) i]
      ..sort((a, b) => ((cur[a] as List)[1] as num).compareTo((cur[b] as List)[1] as num));
    for (final i in idx) {
      final a = cur[i] as List, b = nxt[i] as List;
      final p = posOf(a, b)!;
      final boss = mons[i]['boss'] == true;
      final sz = cell * (boss ? 1.2 : 0.85);
      final slowed = (a.length > 3 ? a[3] : 0) == 1;
      canvas.drawOval(Rect.fromCenter(center: Offset(p.dx, p.dy + sz * 0.38), width: sz * 0.65, height: sz * 0.16), Paint()..color = const Color(0x55000000));
      if (slowed) {
        canvas.drawOval(Rect.fromCenter(center: Offset(p.dx, p.dy + sz * 0.36), width: sz * 0.85, height: sz * 0.3), Paint()..color = const Color(0x664FC3F7));
      }
      canvas.save();
      canvas.translate(p.dx - sz / 2, p.dy + sz * 0.4 - sz + math.sin(clock * 8 + i) * sz * 0.03);
      MonsterPainter(kind: mons[i]['kind'] as int, band: band, boss: boss, flash: hit.contains(i) ? 0.8 * (1 - frac) : 0, opacity: 1, t: clock + i).paint(canvas, Size(sz, sz));
      canvas.restore();
      if (slowed) {
        for (var k = 0; k < 3; k++) {
          final ang = clock * 2 + k * 2.1;
          canvas.drawCircle(Offset(p.dx + math.cos(ang) * sz * 0.3, p.dy - sz * 0.1 + math.sin(ang) * sz * 0.25), cell * 0.025, Paint()..color = const Color(0xCCB3E5FC));
        }
      }
      final hp = (a[2] as num) / 100;
      final bw = sz * 0.8;
      final bar = RRect.fromRectAndRadius(Rect.fromLTWH(p.dx - bw / 2, p.dy - sz * 0.66, bw, 5), const Radius.circular(2));
      canvas.drawRRect(bar, Paint()..color = Colors.black87);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(p.dx - bw / 2 + 0.5, p.dy - sz * 0.66 + 0.5, (bw - 1) * hp, 4), const Radius.circular(2)),
          Paint()..color = hp > 0.5 ? const Color(0xFF4CD964) : (hp > 0.2 ? const Color(0xFFFFB02E) : const Color(0xFFFF5C5C)));
    }

    // 子彈
    for (final sh in shots) {
      final ti = sh[0] as int, mi = sh[1] as int;
      if (ti >= towers.length) continue;
      final m = cur[mi] as List;
      if (m.length < 3) continue;
      final t = towers[ti];
      final from = Offset(((t['x'] as int) + 0.5) * cell, ((t['y'] as int) + 0.3) * cell);
      final to = posOf(m, nxt[mi] as List)!;
      final type = t['t'];
      final f = math.min(1.0, frac * 1.7);
      final pos = Offset.lerp(from, to, f)!;
      if (type == 'arrow') {
        final ang = (to - from).direction;
        final tail = pos - Offset(math.cos(ang), math.sin(ang)) * cell * 0.3;
        canvas.drawLine(tail, pos, Paint()..color = const Color(0xFFFFF3E0)..strokeWidth = 2.2..strokeCap = StrokeCap.round);
        canvas.drawCircle(pos, 2.4, Paint()..color = const Color(0xFFBDBDBD));
      } else if (type == 'cannon') {
        final arc = math.sin(f * math.pi) * cell * 0.5;
        final bp = pos - Offset(0, arc);
        canvas.drawCircle(Offset(pos.dx, pos.dy + 3), cell * 0.08, Paint()..color = const Color(0x44000000));
        canvas.drawCircle(bp, cell * 0.11, Paint()..color = const Color(0xFF212121));
        canvas.drawCircle(bp - Offset(cell * 0.03, cell * 0.03), cell * 0.04, Paint()..color = const Color(0xFF616161));
        if (frac > 0.55) {
          final e = ((frac - 0.55) / 0.45).clamp(0.0, 1.0);
          final r = cell * 1.1 * Curves.easeOut.transform(e);
          canvas.drawCircle(to, r, Paint()..shader = RadialGradient(colors: [Color.fromRGBO(255, 241, 118, 0.85 * (1 - e)), Color.fromRGBO(255, 112, 67, 0.55 * (1 - e)), const Color(0x00FF7043)]).createShader(Rect.fromCircle(center: to, radius: r + 1)));
        }
      } else {
        final ang = (to - from).direction;
        canvas.save();
        canvas.translate(pos.dx, pos.dy);
        canvas.rotate(ang);
        canvas.drawPath(Path()..moveTo(cell * 0.14, 0)..lineTo(0, -cell * 0.05)..lineTo(-cell * 0.12, 0)..lineTo(0, cell * 0.05)..close(), Paint()..color = const Color(0xFFB3E5FC));
        canvas.restore();
        if (frac > 0.55) {
          final e = ((frac - 0.55) / 0.45).clamp(0.0, 1.0);
          for (var k = 0; k < 6; k++) {
            final a2 = k * math.pi / 3;
            canvas.drawLine(to + Offset(math.cos(a2), math.sin(a2)) * cell * 0.1, to + Offset(math.cos(a2), math.sin(a2)) * cell * (0.1 + 0.28 * e), Paint()..color = Color.fromRGBO(179, 229, 252, 1 - e)..strokeWidth = 2);
          }
        }
      }
    }

    // 傷害數字、死亡特效、漏怪
    final floats = <_Float>[];
    for (var j = math.max(0, fi - 3); j <= fi; j++) {
      final fj = (frames[j] as Map);
      final mj = fj['m'] as List;
      final age = ((fi - j) + frac) * 0.2;
      if (age > 0.7) continue;
      for (final sh in (fj['s'] as List)) {
        final ti = sh[0] as int, mi = sh[1] as int;
        if (ti >= towers.length) continue;
        final m = mj[mi] as List;
        if (m.length < 3) continue;
        final dmg = (((towers[ti]['stats'] as Map)['dmg']) as num).round();
        floats.add(_Float('-$dmg', Offset((m[0] as num) / 100 * cell + (mi % 3 - 1) * 8, (m[1] as num) / 100 * cell - cell * 0.5 - age * 40), age, sh[2] == 1 ? const Color(0xFFFFB74D) : const Color(0xFFFFFFFF), 12));
      }
      if (j > 0) {
        final pj = (frames[j - 1] as Map)['m'] as List;
        for (var i = 0; i < mj.length; i++) {
          final m = mj[i] as List;
          final pm = pj[i] as List;
          if (m.length == 1 && pm.length >= 3) {
            final pos = Offset((pm[0] as num) / 100 * cell, (pm[1] as num) / 100 * cell);
            if (m[0] == 0) {
              final e = age / 0.7;
              canvas.drawCircle(pos, cell * 0.5 * Curves.easeOut.transform(e), Paint()..color = Color.fromRGBO(255, 255, 255, 0.5 * (1 - e)));
              for (var k = 0; k < 7; k++) {
                final a2 = k * 0.9 + i;
                canvas.drawCircle(pos + Offset(math.cos(a2), math.sin(a2) - e * 0.6) * cell * 0.5 * e, cell * 0.05 * (1 - e), Paint()..color = const Color(0xFFFFD54F).withValues(alpha: 1 - e));
              }
            } else if (m[0] == -2) {
              floats.add(_Float('-1 ❤️', Offset((d['goal'] as List)[0] * cell + cell * 0.5, ((d['goal'] as List)[1] as int) * cell - age * 30), age, const Color(0xFFFF5252), 14));
            }
          }
        }
      }
    }
    for (final f in floats) {
      final a = (1 - f.age / 0.7).clamp(0.0, 1.0);
      _text(canvas, f.text, f.pos, f.size, f.color.withValues(alpha: a), bold: true);
    }
  }

  @override
  bool shouldRepaint(covariant _TdPainter old) => true;
}
