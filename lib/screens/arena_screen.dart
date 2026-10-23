import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api_client.dart';
import '../widgets/elements.dart';
import '../widgets/hero_art.dart';

// 競技場：玩家之間的友誼 PK（沒有排名與賭注）。邀請 → 對方同意 → 兩邊同時看同一場。
// 整場由伺服器算好；畫面依「伺服器時間 − 開打時間」決定播到第幾筆，所以雙方畫面同步。

class ArenaScreen extends StatefulWidget {
  const ArenaScreen({super.key});

  @override
  State<ArenaScreen> createState() => _ArenaScreenState();
}

class _ArenaScreenState extends State<ArenaScreen>
    with SingleTickerProviderStateMixin {
  final _api = ApiClient();
  final _qc = TextEditingController();
  Map<String, dynamic>? _state;
  List<Map<String, dynamic>> _players = [];
  double _clockOffset = 0; // 伺服器時間 − 本機時間（秒）
  Timer? _poll;
  late final Ticker _ticker;
  final ValueNotifier<int> _frame = ValueNotifier(0);
  int _lastIdx = -99;
  bool _lastFinished = false;
  int? _eqDuel;
  Map<String, ({String id, int tier})> _eqA = {}, _eqB = {};
  int? _dismissedDuel;
  String? _error;
  bool _busy = false;

  double get _now =>
      DateTime.now().millisecondsSinceEpoch / 1000 + _clockOffset;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadPlayers();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ticker.dispose();
    _frame.dispose();
    _qc.dispose();
    super.dispose();
  }

  // 每個畫面影格只重畫舞台；只有事件換筆、倒數換秒、結束時才重建整頁（血條、戰報）
  void _onTick(Duration _) {
    final d = _activeShown;
    if (d == null || !mounted) return;
    _frame.value++;
    final c = _calc(d);
    final key = c.idx * 1000 + (c.el < 0 ? (-c.el).ceil() : 0);
    if (key != _lastIdx || c.finished != _lastFinished) {
      _lastIdx = key;
      _lastFinished = c.finished;
      setState(() {});
    }
  }

  ({double el, bool finished, int idx, double frac}) _calc(
    Map<String, dynamic> d,
  ) {
    final log = d['log'] as List;
    final step = (d['step'] as num).toDouble();
    final el = _now - (d['start_at'] as num).toDouble();
    final finished = el >= log.length * step;
    final idx = el < 0 ? -1 : math.min(log.length - 1, (el / step).floor());
    final frac = idx < 0
        ? 0.0
        : (finished ? 1.0 : (el / step) - idx).clamp(0.0, 1.0);
    return (el: el, finished: finished, idx: idx, frac: frac);
  }

  void _ensureEquipped(Map<String, dynamic> d) {
    final id = (d['duel_id'] as num).toInt();
    if (_eqDuel == id) return;
    _eqDuel = id;
    _eqA = _equipped((d['a'] as Map).cast<String, dynamic>());
    _eqB = _equipped((d['b'] as Map).cast<String, dynamic>());
  }

  Map<String, dynamic>? get _activeShown {
    final a = _state?['active'] as Map<String, dynamic>?;
    if (a == null || a['duel_id'] == _dismissedDuel) return null;
    return a;
  }

  Future<void> _refresh() async {
    try {
      final s = await _api.arenaState();
      if (!mounted) return;
      setState(() {
        _state = s;
        _clockOffset =
            (s['server_now'] as num).toDouble() -
            DateTime.now().millisecondsSinceEpoch / 1000;
        _error = null;
      });
    } catch (e) {
      if (mounted && _state == null) setState(() => _error = '$e');
    }
  }

  Future<void> _loadPlayers() async {
    try {
      final r = await _api.arenaPlayers(_qc.text.trim());
      if (!mounted) return;
      setState(
        () => _players = ((r['players'] as List?) ?? const [])
            .cast<Map<String, dynamic>>(),
      );
    } catch (_) {}
  }

  Future<void> _call(Future<Map<String, dynamic>> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await f();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => _busy = false);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeShown;
    return Scaffold(
      backgroundColor: const Color(0xFF14110B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1710),
        title: const Text('競技場', style: TextStyle(color: Color(0xFFFFD36B))),
        iconTheme: const IconThemeData(color: Color(0xFFFFD36B)),
      ),
      body: _error != null && _state == null
          ? Center(
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.white70),
              ),
            )
          : _state == null
          ? const Center(child: CircularProgressIndicator())
          : active != null
          ? _duelView(active)
          : _lobby(),
    );
  }

  // ---------- 大廳 ----------
  Widget _lobby() {
    final s = _state!;
    final incoming = (s['incoming'] as List).cast<Map<String, dynamic>>();
    final outgoing = (s['outgoing'] as List).cast<Map<String, dynamic>>();
    final history = (s['history'] as List).cast<Map<String, dynamic>>();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '友誼 PK：邀請另一位玩家，對方同意後兩邊會同時看到同一場對決。沒有排名、沒有賭注，不影響爬塔進度。雙方都以滿血、目前穿的裝備與卡片上場。',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 12),
        if (s['has_gear'] != true)
          const Text(
            '你還沒有裝備，先去勇者頁穿上裝備吧。',
            style: TextStyle(color: Color(0xFFFF8A80)),
          ),
        for (final i in incoming)
          Card(
            color: const Color(0xFF3A2A12),
            child: ListTile(
              title: Text(
                '${i['from_name']} 向你發起 PK！',
                style: const TextStyle(
                  color: Color(0xFFFFD36B),
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                '${i['expires_in']} 秒內有效',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _call(
                            () => _api.arenaRespond(
                              (i['duel_id'] as num).toInt(),
                              false,
                            ),
                          ),
                    child: const Text('拒絕'),
                  ),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _call(
                            () => _api.arenaRespond(
                              (i['duel_id'] as num).toInt(),
                              true,
                            ),
                          ),
                    child: const Text('同意開打'),
                  ),
                ],
              ),
            ),
          ),
        for (final o in outgoing)
          Card(
            color: const Color(0xFF1F2A3A),
            child: ListTile(
              title: Text(
                '等待 ${o['to_name']} 同意…',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                '${o['expires_in']} 秒後失效',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              trailing: TextButton(
                onPressed: _busy
                    ? null
                    : () => _call(
                        () => _api.arenaCancel((o['duel_id'] as num).toInt()),
                      ),
                child: const Text('取消'),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _qc,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: '搜尋玩家名字',
                  hintStyle: TextStyle(color: Colors.white38),
                  isDense: true,
                ),
                onSubmitted: (_) => _loadPlayers(),
              ),
            ),
            IconButton(
              onPressed: _loadPlayers,
              icon: const Icon(Icons.search, color: Color(0xFFFFD36B)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_players.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '沒有找到玩家（對方要有穿勇者裝備）',
              style: TextStyle(color: Colors.white38),
            ),
          ),
        for (final p in _players)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${p['name']}',
              style: const TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              '攻 ${p['atk']}・防 ${p['def']}・血 ${p['hp']}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: FilledButton(
              onPressed: _busy || outgoing.isNotEmpty || s['has_gear'] != true
                  ? null
                  : () => _call(
                      () => _api.arenaChallenge(p['user_id'] as String),
                    ),
              child: const Text('挑戰'),
            ),
          ),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            '最近對戰',
            style: TextStyle(
              color: Color(0xFFFFD36B),
              fontWeight: FontWeight.bold,
            ),
          ),
          for (final h in history)
            Text(
              '${h['result'] == 'win'
                  ? '🏆 勝'
                  : h['result'] == 'lose'
                  ? '💀 敗'
                  : '🤝 平'}　對 ${h['foe_name']}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
        ],
      ],
    );
  }

  // ---------- 對決畫面 ----------
  Map<String, ({String id, int tier})> _equipped(Map<String, dynamic> side) {
    final m = <String, ({String id, int tier})>{};
    (side['equipped'] as Map).forEach((k, v) {
      m[k as String] = (
        id: v['id'] as String,
        tier: (v['tier'] as num).toInt(),
      );
    });
    return m;
  }

  String _eventText(Map<String, dynamic> e, List<String> names) {
    final att = names[(e['a'] as num).toInt()];
    final def = names[(e['d'] as num).toInt()];
    final dmg = e['dmg'];
    if (e['miss'] == true) return '$att 的攻擊被 $def 閃開了';
    if (e['t'] == 'thorns') return '$att 反彈了 $dmg 點傷害';
    if (e['t'] == 'breath') return '$att 噴出龍息，對 $def 造成 $dmg';
    if (e['t'] == 'burn') return '🔥 $def 被灼傷 $dmg';
    if (e['t'] == 'frozen') return '❄ $att 被冰凍，這回合動不了';
    const procNames = {'sunder': '破甲', 'bind': '纏繞', 'freeze': '冰凍', 'burn': '燃燒', 'shield': '地盾'};
    final em = (e['em'] as num?)?.toDouble() ?? 1.0;
    final procs = ((e['p'] as List?) ?? const []).map((x) => procNames[x] ?? '$x').join('、');
    return '$att 對 $def 造成 $dmg${e['crit'] == true ? '（暴擊！）' : ''}'
        '${em > 1 ? '（剋制 ×${em.toStringAsFixed(em == em.roundToDouble() ? 0 : 2)}）' : (em < 1 ? '（${em < 0.6 ? '被剋' : '同屬'} ×$em）' : '')}'
        '${procs.isNotEmpty ? '【$procs】' : ''}';
  }

  Widget _hpBar(Map<String, dynamic> side, int hp, bool right) {
    final max = ((side['stats'] as Map)['hp'] as num).toInt();
    final f = (hp / max).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: right
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (right) ...[
              if (((side['aelem'] as num?)?.toInt() ?? -1) >= 0) ElemBadge(elem: (side['aelem'] as num).toInt(), size: 15),
              if (((side['welem'] as num?)?.toInt() ?? -1) >= 0) ...[const SizedBox(width: 2), ElemBadge(elem: (side['welem'] as num).toInt(), size: 15)],
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                '${side['name']}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!right) ...[
              const SizedBox(width: 4),
              if (((side['welem'] as num?)?.toInt() ?? -1) >= 0) ElemBadge(elem: (side['welem'] as num).toInt(), size: 15),
              if (((side['aelem'] as num?)?.toInt() ?? -1) >= 0) ...[const SizedBox(width: 2), ElemBadge(elem: (side['aelem'] as num).toInt(), size: 15)],
            ],
          ],
        ),
        const SizedBox(height: 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: f,
            minHeight: 12,
            backgroundColor: Colors.white12,
            color: f > 0.5
                ? const Color(0xFF4CD964)
                : (f > 0.2 ? const Color(0xFFFFB02E) : const Color(0xFFFF5C5C)),
          ),
        ),
        Text(
          '$hp / $max',
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    );
  }

  Widget _duelView(Map<String, dynamic> d) {
    _ensureEquipped(d);
    final a = (d['a'] as Map).cast<String, dynamic>();
    final b = (d['b'] as Map).cast<String, dynamic>();
    final names = ['${a['name']}', '${b['name']}'];
    final log = (d['log'] as List).cast<Map<String, dynamic>>();
    final step = (d['step'] as num).toDouble();
    final el = _now - (d['start_at'] as num).toDouble();
    final finished = el >= log.length * step;
    final idx = el < 0 ? -1 : math.min(log.length - 1, (el / step).floor());
    final e = idx >= 0 ? log[idx] : null;
    final hpA = e != null
        ? (e['hpA'] as num).toInt()
        : ((a['stats'] as Map)['hp'] as num).toInt();
    final hpB = e != null
        ? (e['hpB'] as num).toInt()
        : ((b['stats'] as Map)['hp'] as num).toInt();
    final feed = <String>[];
    for (var i = idx; i >= 0 && feed.length < 5; i--) {
      feed.add(_eventText(log[i], names));
    }
    final me = (d['me'] as num).toInt();
    final winner = d['winner'] as num?;
    String banner = '';
    if (finished) {
      banner = winner == null
          ? '🤝 平手'
          : (winner.toInt() == me ? '🏆 你贏了！' : '💀 你輸了…');
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(child: _hpBar(a, hpA, false)),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'VS',
                  style: TextStyle(
                    color: Color(0xFFFFD36B),
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
              Expanded(child: _hpBar(b, hpB, true)),
            ],
          ),
        ),
        SizedBox(
          height: 290,
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRect(
                  child: CustomPaint(painter: _ArenaPainter(this)),
                ),
              ),
              if (el < 0)
                Center(
                  child: Text(
                    '${(-el).ceil()}',
                    style: const TextStyle(
                      color: Color(0xFFFFD36B),
                      fontSize: 72,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              if (finished)
                Center(
                  child: Text(
                    banner,
                    style: const TextStyle(
                      color: Color(0xFFFFD36B),
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: const Color(0xFF1B1710),
            child: ListView(
              children: [
                if (el < 0)
                  const Text(
                    '準備開打…（兩邊同時開始）',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                for (var i = 0; i < feed.length; i++)
                  Text(
                    feed[i],
                    style: TextStyle(
                      color: i == 0 ? Colors.white : Colors.white38,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (finished)
          Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton(
              onPressed: () => setState(
                () => _dismissedDuel = (d['duel_id'] as num).toInt(),
              ),
              child: const Text('回到大廳'),
            ),
          ),
      ],
    );
  }
}

class _ArenaPainter extends CustomPainter {
  final _ArenaScreenState s;
  _ArenaPainter(this.s) : super(repaint: s._frame);

  static const double _hh = 178;
  static const double _hw = _hh * 0.45;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final gy = h * 0.80;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3B2A4D), Color(0xFF8A5A5A)],
        ).createShader(Rect.fromLTWH(0, 0, w, gy)),
    );
    final far = Path()..moveTo(0, gy);
    for (var x = 0.0; x <= w + 20; x += 20) {
      far.lineTo(x, gy - 40 - math.sin(x / 53) * 18 - math.sin(x / 23) * 8);
    }
    far.lineTo(w + 20, gy);
    far.close();
    canvas.drawPath(far, Paint()..color = const Color(0xFF2B2038));
    canvas.drawRect(
      Rect.fromLTWH(0, gy, w, h - gy),
      Paint()..color = const Color(0xFF4A3A2E),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, gy, w, 3),
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );

    final d = s._activeShown;
    if (d == null) return;
    final c = s._calc(d);
    final log = (d['log'] as List).cast<Map<String, dynamic>>();
    final e = c.idx >= 0 ? log[c.idx] : null;
    final live = e != null && !c.finished;
    final xA = w * 0.22, xB = w * 0.78;
    var offA = 0.0, offB = 0.0, shakeA = 0.0, shakeB = 0.0;
    var downA = false, downB = false;
    if (c.finished) {
      final win = d['winner'] as num?;
      downA = win != null && win.toInt() == 1;
      downB = win != null && win.toInt() == 0;
    }
    final gap = (xB - xA) - _hw - 20;
    if (live && e['t'] != 'breath' && e['t'] != 'burn' && e['t'] != 'frozen') {
      final f = c.frac;
      // 前 45% 衝過去，命中後收回
      final lunge =
          (f < 0.45
              ? Curves.easeIn.transform(f / 0.45)
              : 1 - Curves.easeOut.transform((f - 0.45) / 0.55)) *
          gap;
      final hit = f >= 0.45
          ? math.sin((f - 0.45) / 0.55 * math.pi * 5) *
                7 *
                (1 - (f - 0.45) / 0.55)
          : 0.0;
      if ((e['a'] as num) == 0) {
        offA = lunge;
        if (e['miss'] != true) shakeB = hit;
      } else {
        offB = lunge;
        if (e['miss'] != true) shakeA = hit;
      }
    }
    _hero(canvas, s._eqA, xA + offA + shakeA, gy, false, downA);
    _hero(canvas, s._eqB, xB - offB + shakeB, gy, true, downB);

    if (live) {
      final defIsA = (e['d'] as num) == 0;
      final f = c.frac;
      final tx = defIsA ? xA : xB;
      if (f >= 0.45) {
        final p = ((f - 0.45) / 0.55).clamp(0.0, 1.0);
        if (e['miss'] != true && (e['dmg'] as num) > 0) {
          final crit = e['crit'] == true;
          final col = crit ? const Color(0xFFFFD93D) : const Color(0xFF8FD3FF);
          canvas.drawCircle(
            Offset(tx, gy - 90),
            (crit ? 60 : 42) *
                (0.3 + 0.9 * Curves.easeOut.transform(math.min(1.0, p * 2.2))),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = (crit ? 5 : 3) * (1 - p)
              ..color = col.withValues(alpha: (1 - p) * 0.8),
          );
        }
        final em = (e['em'] as num?)?.toDouble() ?? 1.0;
        final txt = e['t'] == 'frozen'
            ? '❄ 凍僵'
            : (e['miss'] == true ? 'MISS' : '-${e['dmg']}${em > 1 ? ' 剋!' : ''}');
        final crit = e['crit'] == true && e['miss'] != true;
        _label(
          canvas,
          Offset(tx, gy - _hh - 6 - p * 40),
          txt,
          crit ? 34 : 26,
          (e['miss'] == true
                  ? Colors.white70
                  : (crit ? const Color(0xFFFFD93D) : const Color(0xFFFF6B6B)))
              .withValues(alpha: (1 - p).clamp(0.0, 1.0)),
        );
      }
    }
  }

  void _hero(
    Canvas canvas,
    Map<String, ({String id, int tier})> eq,
    double cx,
    double gy,
    bool mirror,
    bool down,
  ) {
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, gy + 2), width: _hw * 1.2, height: 9),
      Paint()..color = const Color.fromRGBO(0, 0, 0, 0.28),
    );
    canvas.save();
    canvas.translate(cx, gy);
    if (mirror) canvas.scale(-1, 1);
    if (down) {
      canvas.rotate(math.pi / 2 * 0.9);
      canvas.translate(0, -_hh * 0.2);
    }
    canvas.translate(-_hw / 2, -_hh);
    HeroPaperDoll(eq).paint(canvas, const Size(_hw, _hh));
    canvas.restore();
  }

  void _label(
    Canvas canvas,
    Offset bottomCenter,
    String text,
    double size,
    Color color,
  ) {
    void draw(Color col, {Paint? fg}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: fg == null ? col : null,
            foreground: fg,
            fontSize: size,
            fontWeight: FontWeight.w900,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(bottomCenter.dx - tp.width / 2, bottomCenter.dy - tp.height),
      );
    }

    draw(
      Colors.black,
      fg: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = Colors.black.withValues(alpha: color.a),
    );
    draw(color);
  }

  @override
  bool shouldRepaint(covariant _ArenaPainter old) => true;
}
