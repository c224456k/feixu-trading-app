import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../widgets/hero_art.dart';

// 競技場：玩家之間的友誼 PK（沒有排名與賭注）。邀請 → 對方同意 → 兩邊同時看同一場。
// 整場由伺服器算好；畫面依「伺服器時間 − 開打時間」決定播到第幾筆，所以雙方畫面同步。

class ArenaScreen extends StatefulWidget {
  const ArenaScreen({super.key});

  @override
  State<ArenaScreen> createState() => _ArenaScreenState();
}

class _ArenaScreenState extends State<ArenaScreen> {
  final _api = ApiClient();
  final _qc = TextEditingController();
  Map<String, dynamic>? _state;
  List<Map<String, dynamic>> _players = [];
  double _clockOffset = 0; // 伺服器時間 − 本機時間（秒）
  Timer? _poll;
  Timer? _tick;
  int? _dismissedDuel;
  String? _error;
  bool _busy = false;

  double get _now => DateTime.now().millisecondsSinceEpoch / 1000 + _clockOffset;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadPlayers();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && _activeShown != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _qc.dispose();
    super.dispose();
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
        _clockOffset = (s['server_now'] as num).toDouble() - DateTime.now().millisecondsSinceEpoch / 1000;
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
      setState(() => _players = ((r['players'] as List?) ?? const []).cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  Future<void> _call(Future<Map<String, dynamic>> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await f();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)))
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
          const Text('你還沒有裝備，先去勇者頁穿上裝備吧。', style: TextStyle(color: Color(0xFFFF8A80))),
        for (final i in incoming)
          Card(
            color: const Color(0xFF3A2A12),
            child: ListTile(
              title: Text('${i['from_name']} 向你發起 PK！', style: const TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold)),
              subtitle: Text('${i['expires_in']} 秒內有效', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(
                  onPressed: _busy ? null : () => _call(() => _api.arenaRespond((i['duel_id'] as num).toInt(), false)),
                  child: const Text('拒絕'),
                ),
                FilledButton(
                  onPressed: _busy ? null : () => _call(() => _api.arenaRespond((i['duel_id'] as num).toInt(), true)),
                  child: const Text('同意開打'),
                ),
              ]),
            ),
          ),
        for (final o in outgoing)
          Card(
            color: const Color(0xFF1F2A3A),
            child: ListTile(
              title: Text('等待 ${o['to_name']} 同意…', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: Text('${o['expires_in']} 秒後失效', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              trailing: TextButton(
                onPressed: _busy ? null : () => _call(() => _api.arenaCancel((o['duel_id'] as num).toInt())),
                child: const Text('取消'),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _qc,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(hintText: '搜尋玩家名字', hintStyle: TextStyle(color: Colors.white38), isDense: true),
              onSubmitted: (_) => _loadPlayers(),
            ),
          ),
          IconButton(onPressed: _loadPlayers, icon: const Icon(Icons.search, color: Color(0xFFFFD36B))),
        ]),
        const SizedBox(height: 4),
        if (_players.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('沒有找到玩家（對方要有穿勇者裝備）', style: TextStyle(color: Colors.white38))),
        for (final p in _players)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${p['name']}', style: const TextStyle(color: Colors.white)),
            subtitle: Text('攻 ${p['atk']}・防 ${p['def']}・血 ${p['hp']}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            trailing: FilledButton(
              onPressed: _busy || outgoing.isNotEmpty || s['has_gear'] != true ? null : () => _call(() => _api.arenaChallenge(p['user_id'] as String)),
              child: const Text('挑戰'),
            ),
          ),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('最近對戰', style: TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold)),
          for (final h in history)
            Text(
              '${h['result'] == 'win' ? '🏆 勝' : h['result'] == 'lose' ? '💀 敗' : '🤝 平'}　對 ${h['foe_name']}',
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
      m[k as String] = (id: v['id'] as String, tier: (v['tier'] as num).toInt());
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
    return '$att 對 $def 造成 $dmg${e['crit'] == true ? '（暴擊！）' : ''}';
  }

  Widget _hpBar(Map<String, dynamic> side, int hp, bool right) {
    final max = ((side['stats'] as Map)['hp'] as num).toInt();
    final f = (hp / max).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: right ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text('${side['name']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: f,
            minHeight: 12,
            backgroundColor: Colors.white12,
            color: f > 0.5 ? const Color(0xFF4CD964) : (f > 0.2 ? const Color(0xFFFFB02E) : const Color(0xFFFF5C5C)),
          ),
        ),
        Text('$hp / $max', style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ],
    );
  }

  Widget _duelView(Map<String, dynamic> d) {
    final a = (d['a'] as Map).cast<String, dynamic>();
    final b = (d['b'] as Map).cast<String, dynamic>();
    final names = ['${a['name']}', '${b['name']}'];
    final log = (d['log'] as List).cast<Map<String, dynamic>>();
    final step = (d['step'] as num).toDouble();
    final el = _now - (d['start_at'] as num).toDouble();
    final finished = el >= log.length * step;
    final idx = el < 0 ? -1 : math.min(log.length - 1, (el / step).floor());
    final e = idx >= 0 ? log[idx] : null;
    final frac = e == null ? 0.0 : (finished ? 1.0 : (el / step) - idx).clamp(0.0, 1.0);
    final hpA = e != null ? (e['hpA'] as num).toInt() : ((a['stats'] as Map)['hp'] as num).toInt();
    final hpB = e != null ? (e['hpB'] as num).toInt() : ((b['stats'] as Map)['hp'] as num).toInt();
    // 攻擊動畫：攻擊者往前衝，被打的人晃一下
    double offA = 0, offB = 0;
    if (e != null && !finished && e['t'] != 'breath') {
      final lunge = math.sin(frac * math.pi) * 36;
      final shake = math.sin(frac * math.pi * 6) * 6 * (1 - frac);
      if ((e['a'] as num) == 0) {
        offA = lunge;
        if (e['miss'] != true) offB = shake;
      } else {
        offB = lunge;
        if (e['miss'] != true) offA = shake;
      }
    }
    final defIsA = e != null && (e['d'] as num) == 0;
    final feed = <String>[];
    for (var i = idx; i >= 0 && feed.length < 5; i--) {
      feed.add(_eventText(log[i], names));
    }
    final me = (d['me'] as num).toInt();
    final winner = d['winner'] as num?;
    String banner = '';
    if (finished) {
      banner = winner == null ? '🤝 平手' : (winner.toInt() == me ? '🏆 你贏了！' : '💀 你輸了…');
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Expanded(child: _hpBar(a, hpA, false)),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('VS', style: TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold, fontSize: 18))),
            Expanded(child: _hpBar(b, hpB, true)),
          ]),
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: Row(children: [
                Expanded(
                  child: Transform.translate(
                    offset: Offset(offA, 0),
                    child: SizedBox.expand(child: CustomPaint(painter: HeroPaperDoll(_equipped(a)))),
                  ),
                ),
                Expanded(
                  child: Transform.translate(
                    offset: Offset(-offB, 0),
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(-1, 1, 1),
                      child: SizedBox.expand(child: CustomPaint(painter: HeroPaperDoll(_equipped(b)))),
                    ),
                  ),
                ),
              ])),
              if (e != null && !finished && (e['miss'] == true || (e['dmg'] as num) > 0))
                Align(
                  alignment: Alignment(defIsA ? -0.55 : 0.55, -0.5 - frac * 0.3),
                  child: Opacity(
                    opacity: (1 - frac).clamp(0.0, 1.0),
                    child: Text(
                      e['miss'] == true ? 'MISS' : '-${e['dmg']}',
                      style: TextStyle(
                        color: e['miss'] == true ? Colors.white70 : (e['crit'] == true ? const Color(0xFFFFD93D) : const Color(0xFFFF6B6B)),
                        fontSize: e['crit'] == true ? 34 : 26,
                        fontWeight: FontWeight.w900,
                        shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
                      ),
                    ),
                  ),
                ),
              if (el < 0)
                Center(
                  child: Text('${(-el).ceil()}', style: const TextStyle(color: Color(0xFFFFD36B), fontSize: 72, fontWeight: FontWeight.w900)),
                ),
              if (finished)
                Center(
                  child: Text(banner, style: const TextStyle(color: Color(0xFFFFD36B), fontSize: 40, fontWeight: FontWeight.w900, shadows: [Shadow(color: Colors.black, blurRadius: 6)])),
                ),
            ],
          ),
        ),
        Container(
          height: 110,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: const Color(0xFF1B1710),
          child: ListView(
            children: [
              if (el < 0) const Text('準備開打…（兩邊同時開始）', style: TextStyle(color: Colors.white54, fontSize: 12)),
              for (var i = 0; i < feed.length; i++)
                Text(feed[i], style: TextStyle(color: i == 0 ? Colors.white : Colors.white38, fontSize: 12)),
            ],
          ),
        ),
        if (finished)
          Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton(
              onPressed: () => setState(() => _dismissedDuel = (d['duel_id'] as num).toInt()),
              child: const Text('回到大廳'),
            ),
          ),
      ],
    );
  }
}
