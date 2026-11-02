import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'number_gate_logic.dart';

/// 數字門（試玩）：單機、不連伺服器、沒有獎金。
/// 仿 FB 廣告：手指左右拖動整隊人，一直自動掃射，怪一直來，很久才出現一對加減乘除的大門（左邊是鎖住的大門）。
class NumberGateScreen extends StatefulWidget {
  const NumberGateScreen({super.key});

  @override
  State<NumberGateScreen> createState() => _NumberGateScreenState();
}

class _Floater {
  final String text;
  final bool good;
  final double x; // 0~1
  double y; // 畫面高度比例（0 頂 1 底）
  final double size;
  double t = 0;
  _Floater(this.text, this.good, this.x, this.y, this.size);
}

class _Part {
  double x, y, vx, vy, life;
  final double max;
  final Color color;
  final double size;
  _Part(this.x, this.y, this.vx, this.vy, this.max, this.color, this.size) : life = max;
}

const _monBody = [Color(0xFF558B2F), Color(0xFFD84315), Color(0xFF5E35B1), Color(0xFF37474F), Color(0xFF00897B)];
const _monHead = [Color(0xFFAED581), Color(0xFFFFAB91), Color(0xFFB39DDB), Color(0xFF78909C), Color(0xFF80CBC4)];

class _NumberGateScreenState extends State<NumberGateScreen> with SingleTickerProviderStateMixin {
  static const _saveKey = 'number_gate_unlocked_v1';
  static const _lead = 2.4;

  late final Ticker _ticker;
  final _repaint = ValueNotifier<int>(0);
  final _focus = FocusNode();
  Duration _last = Duration.zero;

  bool _inGame = false;
  int _unlocked = 1;
  int _level = 1;
  late NgLevel _lv;
  late NgSim _sim;

  double _acc = 0;
  double _lead0 = _lead;
  double _target = 0.5;
  int _keyDir = 0;
  double _clock = 0;
  double _hitFlash = 0;
  double _shake = 0;
  double _bossFlash = 0;
  final List<_Floater> _floats = [];
  final List<_Part> _parts = [];
  final _rnd = math.Random(3);
  bool _over = false;

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
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final u = sp.getInt(_saveKey) ?? 1;
      if (mounted) setState(() => _unlocked = u.clamp(1, ngLevels));
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_saveKey, _unlocked);
    } catch (_) {}
  }

  void _start(int level) {
    _level = level;
    _lv = ngLevel(level);
    _sim = NgSim(_lv);
    _acc = 0;
    _lead0 = _lead;
    _target = 0.5;
    _floats.clear();
    _parts.clear();
    _hitFlash = _shake = _bossFlash = 0;
    _over = false;
    setState(() => _inGame = true);
    _focus.requestFocus();
  }

  // ---------------- 主迴圈 ----------------
  void _onTick(Duration now) {
    final dt = _last == Duration.zero ? 0.0 : math.min(0.05, (now - _last).inMicroseconds / 1e6);
    _last = now;
    if (!_inGame) return;
    _clock += dt;
    if (_hitFlash > 0) _hitFlash -= dt;
    if (_shake > 0) _shake -= dt;
    if (_bossFlash > 0) _bossFlash -= dt;
    for (final f in _floats) {
      f.t += dt;
      f.y -= dt * 0.12;
    }
    _floats.removeWhere((f) => f.t > 0.9);
    for (final p in _parts) {
      p.life -= dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.vy -= 1.2 * dt; // 往玩家方向掉
    }
    _parts.removeWhere((p) => p.life <= 0);
    if (_keyDir != 0) _target = (_target + _keyDir * dt * 1.5).clamp(0.0, 1.0);
    if (_lead0 > 0) {
      _lead0 -= dt;
      // 準備期間隊伍也可以先移動
      final d = (_target - _sim.px).clamp(-ngMoveSpeed * dt, ngMoveSpeed * dt);
      _sim.px = (_sim.px + d).clamp(0.04, 0.96);
    } else if (_sim.result == 0) {
      _acc += dt;
      var n = 0;
      while (_acc >= 1 / 60 && n < 6 && _sim.result == 0) {
        _sim.step(1 / 60, _target);
        _acc -= 1 / 60;
        n++;
      }
      if (_acc > 0.2) _acc = 0;
    }
    for (final e in _sim.events) {
      switch (e.kind) {
        case 'gate':
          _floats.add(_Floater(e.text, e.good, e.x, 0.66, 34));
          if (!e.good) _hitFlash = 0.25;
        case 'lock':
          _floats.add(_Floater(e.text, false, e.x, 0.66, 28));
          _hitFlash = 0.3;
          _shake = 0.3;
        case 'armor':
          _floats.add(_Floater(e.text, true, 0.25, 0.45, 30));
          _bossFlash = 0.2;
        case 'bite':
        case 'hit':
          _floats.add(_Floater(e.text, false, e.x, 0.72, 24));
          _hitFlash = 0.2;
          _shake = 0.2;
        case 'kill':
          if (_parts.length < 220) {
            final kind = int.tryParse(e.text) ?? 0;
            final col = _monBody[kind];
            for (var i = 0; i < 6; i++) {
              final a = _rnd.nextDouble() * 2 * math.pi, v = 0.15 + _rnd.nextDouble() * 0.35;
              _parts.add(_Part(e.x, e.y, math.cos(a) * v * 0.6, math.sin(a) * v, 0.35 + _rnd.nextDouble() * 0.3,
                  i < 4 ? col : const Color(0xFFB71C1C), 2.0 + _rnd.nextDouble() * 3));
            }
          }
        case 'boss':
          _floats.add(_Floater(e.text, true, 0.5, 0.3, 30));
          _bossFlash = 0.5;
        case 'slam':
          _bossFlash = 0.1;
      }
    }
    _sim.events.clear();
    if (!_over && _sim.result != 0) {
      _over = true;
      if (_sim.result == 1 && _level >= _unlocked && _level < ngLevels) {
        _unlocked = _level + 1;
        _save();
      }
      setState(() {});
    }
    _repaint.value++;
  }

  void _setTargetFromX(double dx, double width) {
    final roadW = math.min(width, 540.0);
    final left = (width - roadW) / 2;
    _target = ((dx - left) / roadW).clamp(0.0, 1.0);
  }

  // ---------------- 畫面 ----------------
  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (n, e) {
        final k = e.logicalKey;
        final left = k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA;
        final right = k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyD;
        if (!left && !right) return KeyEventResult.ignored;
        if (e is KeyUpEvent) {
          if ((left && _keyDir < 0) || (right && _keyDir > 0)) _keyDir = 0;
        } else {
          _keyDir = left ? -1 : 1;
        }
        return KeyEventResult.handled;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1020),
        appBar: AppBar(
          title: Text(_inGame ? '數字門 第 $_level 關' : '數字門（試玩）'),
          backgroundColor: const Color(0xFF111833),
          leading: _inGame ? BackButton(onPressed: () => setState(() => _inGame = false)) : null,
        ),
        body: SafeArea(child: _inGame ? _game() : _menu()),
      ),
    );
  }

  Widget _menu() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('🔫 數字門', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('試玩版：單機、沒有獎金', style: TextStyle(color: Colors.amberAccent)),
              const SizedBox(height: 12),
              const Text(
                '• 手指左右拖動整隊人（電腦用 ← →），一直自動掃射前方\n'
                '• 怪會一直從前面來；撞到你的隊伍就咬掉人數，躲開的會從旁邊過去\n'
                '• 人越多火力越強，但隊伍也越寬、越不好躲\n'
                '• 很久才出現一對大門：右邊是一般的門（＋ − × ÷），\n'
                '   左邊是「鎖住的大門」，把牠的裝甲血條打光才會開，開了是大獎；沒打開就衝過去會被鎖住、人數砍半\n'
                '• 中途和最後有頭目：怪停止出現，限時打血條，牠會預告攻擊的位置（紅柱），要閃開',
                style: TextStyle(color: Colors.white70, height: 1.7),
              ),
              const SizedBox(height: 16),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                children: [
                  for (var i = 1; i <= ngLevels; i++)
                    InkWell(
                      onTap: i <= _unlocked ? () => _start(i) : null,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: i < _unlocked ? const Color(0xFF1B5E20) : (i == _unlocked ? const Color(0xFF1565C0) : const Color(0xFF263238)),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: i == _unlocked ? Colors.amberAccent : Colors.white12, width: i == _unlocked ? 2 : 1),
                        ),
                        child: i <= _unlocked
                            ? Text('$i', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold))
                            : const Icon(Icons.lock, color: Colors.white24, size: 20),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _game() {
    return LayoutBuilder(builder: (context, c) {
      return Stack(
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) => _setTargetFromX(e.localPosition.dx, c.maxWidth),
              onPointerMove: (e) => _setTargetFromX(e.localPosition.dx, c.maxWidth),
              child: CustomPaint(painter: _GatePainter(this, _repaint)),
            ),
          ),
          if (_sim.result != 0) Positioned.fill(child: _result()),
        ],
      );
    });
  }

  Widget _result() {
    final win = _sim.result == 1;
    Widget btn(String s, VoidCallback f, {bool primary = false}) => SizedBox(
          width: 240,
          child: primary
              ? FilledButton(onPressed: f, child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(s)))
              : OutlinedButton(onPressed: f, child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(s))),
        );
    return Container(
      color: Colors.black.withValues(alpha: 0.72),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(win ? '🎉' : '💥', style: const TextStyle(fontSize: 56)),
          Text(win ? '過關！' : '失敗', style: TextStyle(color: win ? Colors.amberAccent : Colors.redAccent, fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(win ? '最後剩下 ${ngFmt(_sim.count)} 人・擊殺 ${_sim.kills}' : '${_sim.why}（擊殺 ${_sim.kills}）',
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15)),
          ),
          const SizedBox(height: 18),
          if (win && _level < ngLevels) btn('▶ 下一關', () => _start(_level + 1), primary: true),
          if (win && _level >= ngLevels) const Text('🏆 30 關全部通過！', style: TextStyle(color: Colors.amberAccent, fontSize: 18)),
          if (!win) btn('🔄 重新挑戰', () => _start(_level), primary: true),
          const SizedBox(height: 8),
          if (win) btn('🔄 再玩一次', () => _start(_level)),
          const SizedBox(height: 8),
          btn('回選關', () => setState(() => _inGame = false)),
        ],
      ),
    );
  }
}

class _GatePainter extends CustomPainter {
  final _NumberGateScreenState s;
  _GatePainter(this.s, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas c, Size size) {
    final sim = s._sim;
    final lv = s._lv;
    final roadW = math.min(size.width, 540.0);
    final left = (size.width - roadW) / 2;
    final playerY = size.height * 0.84;
    final topY = size.height * 0.1;
    double X(double x) => left + x * roadW;
    double Y(double y) => playerY - (y / ngH) * (playerY - topY);
    double sc(double y) => 0.7 + 0.3 * (1 - (y / ngH).clamp(0.0, 1.0)); // 越遠越小

    c.save();
    if (s._shake > 0) c.translate(math.sin(s._clock * 90) * 4 * s._shake / 0.3, math.cos(s._clock * 77) * 3 * s._shake / 0.3);

    // 背景（沒有格子）：夜空 + 馬路 + 流動的紅白護欄 + 暗角
    c.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF241047), Color(0xFF16254A), Color(0xFF0C1B2E)])
              .createShader(Offset.zero & size));
    final road = Rect.fromLTWH(left, 0, roadW, size.height);
    c.drawRect(
        road,
        Paint()
          ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF2B3347), Color(0xFF3A4560)])
              .createShader(road));
    // 路面的淡淡反光
    c.drawRect(
        Rect.fromLTWH(left + roadW * 0.3, 0, roadW * 0.4, size.height),
        Paint()
          ..shader = LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.05), Colors.white.withValues(alpha: 0)])
              .createShader(Rect.fromLTWH(left + roadW * 0.3, 0, roadW * 0.4, size.height)));
    // 護欄
    final off = (sim.t * 150) % 104;
    final bi = (sim.t * 150) ~/ 104;
    for (var k = -2; k * 52 - 104 + off < size.height; k++) {
      final y0 = k * 52 - 104 + off;
      final red = (k + bi) % 2 == 0;
      final col = red ? const Color(0xFFE53935) : const Color(0xFFECEFF1);
      c.drawRect(Rect.fromLTWH(left - 10, y0, 10, 52), Paint()..color = col);
      c.drawRect(Rect.fromLTWH(left + roadW, y0, 10, 52), Paint()..color = col);
    }
    final srng = math.Random(11);
    for (var i = 0; i < 26; i++) {
      final px = srng.nextDouble(), py = (srng.nextDouble() + sim.t * 0.25 * (0.5 + srng.nextDouble())) % 1.0;
      c.drawCircle(Offset(left + px * roadW, py * size.height), 1.2 + srng.nextDouble() * 1.2, Paint()..color = Colors.white.withValues(alpha: 0.04 + 0.08 * py));
    }

    // 頭目預告的攻擊柱
    final boss = sim.boss;
    if (boss != null && boss.slamAt >= 0) {
      final k = (1 - (boss.slamAt - boss.fight) / 0.9).clamp(0.0, 1.0);
      for (final sx in boss.slamX) {
        final r = Rect.fromLTRB(X(sx - 0.1), 0, X(sx + 0.1), size.height);
        c.drawRect(r, Paint()..color = Colors.redAccent.withValues(alpha: 0.10 + 0.34 * k));
        c.drawRect(
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = Colors.redAccent.withValues(alpha: 0.5 + 0.4 * k));
      }
    }

    // 大門（左：鎖住的大門／右：一般的門）
    for (final g in sim.gates) {
      final y = Y(g.y);
      if (y < -60 || y > size.height + 60) continue;
      final k = sc(g.y);
      final h = 74 * k;
      final ld = g.def;
      final locked = g.armor > 0;
      final lrect = RRect.fromRectAndRadius(Rect.fromLTRB(X(0.02), y - h / 2, X(0.49), y + h / 2), const Radius.circular(14));
      final rrect = RRect.fromRectAndRadius(Rect.fromLTRB(X(0.51), y - h / 2, X(0.98), y + h / 2), const Radius.circular(14));
      // 左
      c.drawRRect(lrect.inflate(4), Paint()..color = (locked ? Colors.amber : const Color(0xFF40C4FF)).withValues(alpha: 0.25)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
      c.drawRRect(
          lrect,
          Paint()
            ..shader = LinearGradient(colors: locked ? const [Color(0xFF546E7A), Color(0xFF37474F)] : const [Color(0xFF29B6F6), Color(0xFF0277BD)])
                .createShader(lrect.outerRect));
      c.drawRRect(
          lrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = locked ? const Color(0xFFFFC107) : Colors.white70);
      _text(c, ngOpLabel(ld.lop, ld.lv), lrect.center.translate(locked ? 14 : 0, 0), 44 * k, color: locked ? Colors.white70 : Colors.white, bold: true);
      if (locked) {
        _text(c, '🔒', lrect.center.translate(-lrect.width * 0.32, 0), 30 * k);
        final full = g.armor / math.max(1.0, g.armorMax);
        final bar = Rect.fromLTWH(lrect.left + 8, lrect.top - 14, lrect.width - 16, 10);
        c.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(5)), Paint()..color = Colors.black54);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bar.left, bar.top, bar.width * full.clamp(0.0, 1.0), bar.height), const Radius.circular(5)),
            Paint()..color = const Color(0xFFFFB300));
        _text(c, ngFmt(g.armor.ceil()), Offset(bar.center.dx, bar.top - 9), 12, color: Colors.amberAccent, bold: true);
      }
      // 右
      final good = ngOpGood(ld.rop) && !(ld.rop == NgOp.sub);
      c.drawRRect(rrect.inflate(4), Paint()..color = (good ? const Color(0xFF40C4FF) : Colors.redAccent).withValues(alpha: 0.25)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
      c.drawRRect(
          rrect,
          Paint()
            ..shader = LinearGradient(colors: good ? const [Color(0xFF29B6F6), Color(0xFF0277BD)] : const [Color(0xFFEF5350), Color(0xFFB71C1C)])
                .createShader(rrect.outerRect));
      c.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = Colors.white70);
      _text(c, ngOpLabel(ld.rop, g.rv), rrect.center, 44 * k, bold: true);
    }

    // 怪（由遠到近畫）
    final mons = List.of(sim.mons)..sort((a, b) => b.y.compareTo(a.y));
    for (final m in mons) {
      final y = Y(m.y);
      if (y < -50 || y > size.height + 50) continue;
      final k = sc(m.y);
      final r = m.r * roadW * k * 1.25;
      final x = X(m.x);
      _zombie(c, x, y, r, m.kind, m.id * 0.7);
      if (m.kind == 2 || m.kind == 4) {
        final frac = (m.hp / m.maxHp).clamp(0.0, 1.0);
        final bw = r * 2.2;
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - bw / 2, y - r * 1.9, bw, 6), const Radius.circular(3)), Paint()..color = Colors.black54);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - bw / 2, y - r * 1.9, bw * frac, 6), const Radius.circular(3)),
            Paint()..color = Color.lerp(const Color(0xFFFF5252), const Color(0xFF69F0AE), frac)!);
        _text(c, ngFmt(m.hp.ceil()), Offset(x, y - r * 1.9 - 10), 12 + 2 * k, bold: true);
      }
    }
    for (final b in sim.buls) {
      final y = Y(b.y);
      c.drawCircle(Offset(X(b.x), y), 8, Paint()..color = const Color(0xFFFF8A80).withValues(alpha: 0.4));
      c.drawCircle(Offset(X(b.x), y), 5, Paint()..color = const Color(0xFFFF1744));
    }
    // 噴血／碎片
    for (final p in s._parts) {
      final a = (p.life / p.max).clamp(0.0, 1.0);
      c.drawCircle(Offset(X(p.x), Y(p.y)), p.size * (0.5 + 0.5 * a), Paint()..color = p.color.withValues(alpha: a));
    }

    // 頭目
    if (boss != null) {
      final y = Y(boss.y);
      final r = roadW * 0.28;
      c.drawOval(Rect.fromCenter(center: Offset(X(0.5), y + r * 0.8), width: r * 2.4, height: r * 0.6), Paint()..color = Colors.black45);
      _bossBody(c, X(0.5), y, r, boss.def.emoji.codeUnitAt(0) % 3, boss.stopped);
      if (s._bossFlash > 0) c.drawCircle(Offset(X(0.5), y), r, Paint()..color = Colors.white.withValues(alpha: 0.25));
      final bar = Rect.fromLTWH(left + 14, 14, roadW - 28, 18);
      c.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(9)), Paint()..color = Colors.black54);
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bar.left, bar.top, bar.width * (boss.hp / boss.maxHp).clamp(0.0, 1.0), bar.height), const Radius.circular(9)),
          Paint()..shader = const LinearGradient(colors: [Color(0xFFFF5252), Color(0xFFD50000)]).createShader(bar));
      _text(c, '${boss.def.emoji} ${ngFmt(boss.hp.ceil())}', bar.center, 13, bold: true);
      if (boss.stopped) {
        final left0 = (boss.def.limit - boss.fight).clamp(0.0, boss.def.limit);
        _text(c, '⏱ ${left0.toStringAsFixed(1)}', Offset(left + roadW - 44, 46), 16, color: left0 < 4 ? Colors.redAccent : Colors.amberAccent, bold: true);
      }
    }

    // 子彈：從隊伍往上掃，寬度＝隊伍寬
    final px = X(sim.px);
    final cw = sim.crowdW * roadW;
    if (sim.result == 0 && s._lead0 <= 0) {
      final endY = sim.fireTargetY >= 0 ? Y(sim.fireTargetY) + 10 : Y(ngRange);
      final n = math.min(10, 2 + sim.count ~/ 8);
      final phase = (s._clock * 16) % 1.0;
      for (var b = 0; b < n; b++) {
        final bx = px + ((b + 0.5) / n - 0.5) * cw * 0.9;
        for (var k = 0.0; k < 40; k++) {
          final y = playerY - 18 - (k + phase) * 30;
          if (y < endY) break;
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(bx, y), width: 3, height: 13), const Radius.circular(2)),
              Paint()..color = const Color(0xFFFFEE58).withValues(alpha: 0.95));
        }
      }
      if (sim.fireTargetY >= 0) {
        final sy = Y(sim.fireTargetY);
        for (var i = 0; i < 4; i++) {
          final a = (s._clock * 40 + i * 1.7);
          c.drawCircle(Offset(px + math.cos(a) * cw * 0.3, sy + 8 + math.sin(a * 1.3) * 6), 3, Paint()..color = const Color(0xFFFFF59D));
        }
      }
    }

    // 隊伍：一個個小士兵（有頭盔、有槍）
    final shown = math.max(0, sim.count);
    final dots = math.min(shown, 90);
    final rng = math.Random(5);
    final hit = s._hitFlash > 0;
    final depth = 16 + math.sqrt(dots.toDouble()) * 8;
    final pts = <Offset>[
      for (var i = 0; i < dots; i++) Offset((rng.nextDouble() - 0.5) * (cw - 16), rng.nextDouble() * depth),
    ]..sort((a, b) => a.dy.compareTo(b.dy));
    for (final q in pts) {
      _soldier(c, px + q.dx, playerY + q.dy, hit, q.dy < depth * 0.5 && sim.result == 0 && s._lead0 <= 0, q.dx);
    }
    final label = ngFmt(shown);
    final pill = Rect.fromCenter(center: Offset(px, playerY + depth + 34), width: 24.0 + label.length * 17, height: 36);
    c.drawRRect(RRect.fromRectAndRadius(pill, const Radius.circular(18)), Paint()..color = const Color(0xFF0D47A1).withValues(alpha: 0.92));
    c.drawRRect(
        RRect.fromRectAndRadius(pill, const Radius.circular(18)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF82B1FF));
    _text(c, label, pill.center, 24, bold: true, outline: false);

    // 飄字
    for (final f in s._floats) {
      final a = (1 - f.t / 0.9).clamp(0.0, 1.0);
      _text(c, f.text, Offset(X(f.x), f.y * size.height), f.size,
          color: (f.good ? const Color(0xFF69F0AE) : const Color(0xFFFF8A80)).withValues(alpha: a), bold: true);
    }
    c.restore();

    // 紅閃
    if (s._hitFlash > 0) {
      c.drawRect(Offset.zero & size, Paint()..color = Colors.red.withValues(alpha: 0.18 * (s._hitFlash / 0.3).clamp(0.0, 1.0)));
    }
    // 準備倒數
    if (s._lead0 > 0) {
      _text(c, '👆 手指左右拖動隊伍', Offset(size.width / 2, size.height * 0.36), 22, color: Colors.white, bold: true);
      _text(c, '${s._lead0.ceil()}', Offset(size.width / 2, size.height * 0.46), 80, color: Colors.white.withValues(alpha: 0.85), bold: true);
    }
    // 進度條
    final prog = boss != null ? 1.0 : (sim.sc / lv.length).clamp(0.0, 1.0);
    c.drawRect(Rect.fromLTWH(0, 0, size.width, 5), Paint()..color = Colors.white10);
    c.drawRect(Rect.fromLTWH(0, 0, size.width * prog, 5), Paint()..color = Colors.amberAccent);
  }

  void _soldier(Canvas c, double cx, double cy, bool hit, bool firing, double seed) {
    final body = hit ? const Color(0xFFFF8A80) : const Color(0xFF1E88E5);
    // 腳
    c.drawRect(Rect.fromLTWH(cx - 4, cy + 7, 3, 5), Paint()..color = const Color(0xFF263238));
    c.drawRect(Rect.fromLTWH(cx + 1, cy + 7, 3, 5), Paint()..color = const Color(0xFF263238));
    // 身體
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, cy + 3), width: 10, height: 11), const Radius.circular(3)), Paint()..color = body);
    // 槍
    c.drawRect(Rect.fromLTWH(cx + 2, cy - 11, 3.2, 13), Paint()..color = const Color(0xFF37474F));
    c.drawRect(Rect.fromLTWH(cx + 2, cy - 11, 1.2, 13), Paint()..color = const Color(0xFF90A4AE));
    // 頭＋頭盔
    c.drawCircle(Offset(cx - 0.5, cy - 4), 4.6, Paint()..color = const Color(0xFFFFCC80));
    c.drawArc(Rect.fromCircle(center: Offset(cx - 0.5, cy - 4.5), radius: 5.2), math.pi, math.pi, true, Paint()..color = hit ? const Color(0xFFD84315) : const Color(0xFF0D47A1));
    if (firing && ((s._clock * 30 + seed) % 1.0) < 0.55) {
      c.drawCircle(Offset(cx + 3.6, cy - 13), 3.6, Paint()..color = const Color(0xFFFFF176).withValues(alpha: 0.95));
      c.drawCircle(Offset(cx + 3.6, cy - 13), 6, Paint()..color = const Color(0xFFFFB300).withValues(alpha: 0.3));
    }
  }

  /// 頭目：大怪物（身體、角、發光的眼睛、大嘴巴）
  void _bossBody(Canvas c, double x, double y, double r, int style, bool angry) {
    final base = const [Color(0xFF6A1B9A), Color(0xFFB71C1C), Color(0xFF1B5E20)][style];
    final light = const [Color(0xFFAB47BC), Color(0xFFEF5350), Color(0xFF66BB6A)][style];
    final bob = math.sin(s._clock * 3) * r * 0.04;
    c.drawCircle(Offset(x, y + bob), r * 1.25, Paint()..color = base.withValues(alpha: 0.25)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18));
    // 手臂
    c.drawCircle(Offset(x - r * 1.0, y + r * 0.35 + bob), r * 0.38, Paint()..color = base);
    c.drawCircle(Offset(x + r * 1.0, y + r * 0.35 + bob), r * 0.38, Paint()..color = base);
    // 身體
    c.drawOval(Rect.fromCenter(center: Offset(x, y + r * 0.2 + bob), width: r * 2.1, height: r * 1.9), Paint()..color = base);
    c.drawOval(Rect.fromCenter(center: Offset(x, y + r * 0.35 + bob), width: r * 1.4, height: r * 1.2), Paint()..color = light.withValues(alpha: 0.35));
    // 角
    final horn = Path()
      ..moveTo(x - r * 0.75, y - r * 0.6 + bob)
      ..lineTo(x - r * 1.0, y - r * 1.4 + bob)
      ..lineTo(x - r * 0.3, y - r * 0.8 + bob)
      ..close()
      ..moveTo(x + r * 0.75, y - r * 0.6 + bob)
      ..lineTo(x + r * 1.0, y - r * 1.4 + bob)
      ..lineTo(x + r * 0.3, y - r * 0.8 + bob)
      ..close();
    c.drawPath(horn, Paint()..color = const Color(0xFFFFF8E1));
    // 眼睛
    final eye = Paint()..color = angry ? const Color(0xFFFF1744) : const Color(0xFFFFEE58);
    c.drawCircle(Offset(x - r * 0.42, y - r * 0.12 + bob), r * 0.2, eye);
    c.drawCircle(Offset(x + r * 0.42, y - r * 0.12 + bob), r * 0.2, eye);
    c.drawCircle(Offset(x - r * 0.42, y - r * 0.12 + bob), r * 0.2, Paint()..color = eye.color.withValues(alpha: 0.35)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    // 嘴
    final mouth = Rect.fromCenter(center: Offset(x, y + r * 0.62 + bob), width: r * 1.1, height: r * 0.5 + (angry ? math.sin(s._clock * 8).abs() * r * 0.12 : 0));
    c.drawRRect(RRect.fromRectAndRadius(mouth, Radius.circular(r * 0.2)), Paint()..color = const Color(0xFF1A0000));
    for (var i = 0; i < 5; i++) {
      final tx = mouth.left + mouth.width * (i + 0.5) / 5;
      final t = Path()
        ..moveTo(tx - r * 0.07, mouth.top)
        ..lineTo(tx + r * 0.07, mouth.top)
        ..lineTo(tx, mouth.top + r * 0.18)
        ..close();
      c.drawPath(t, Paint()..color = Colors.white);
    }
  }

  void _zombie(Canvas c, double x, double y, double r, int kind, double ph) {
    final bob = math.sin(s._clock * 9 + ph);
    final body = _monBody[kind], head = _monHead[kind];
    final dark = Paint()..color = const Color(0xFF263238);
    c.drawOval(Rect.fromCenter(center: Offset(x, y + r * 1.25), width: r * 2.1, height: r * 0.6), Paint()..color = Colors.black38);
    if (kind == 3) {
      // 蝙蝠：兩片翅膀
      final w = r * (1.6 + 0.5 * bob);
      final path = Path()
        ..moveTo(x, y - r * 0.2)
        ..lineTo(x - w, y - r * 0.9)
        ..lineTo(x - w * 0.7, y + r * 0.5)
        ..close()
        ..moveTo(x, y - r * 0.2)
        ..lineTo(x + w, y - r * 0.9)
        ..lineTo(x + w * 0.7, y + r * 0.5)
        ..close();
      c.drawPath(path, Paint()..color = body);
      c.drawCircle(Offset(x, y), r * 0.6, Paint()..color = head);
      c.drawCircle(Offset(x - r * 0.2, y - r * 0.05), r * 0.1, Paint()..color = const Color(0xFFFF1744));
      c.drawCircle(Offset(x + r * 0.2, y - r * 0.05), r * 0.1, Paint()..color = const Color(0xFFFF1744));
      return;
    }
    // 腿
    c.drawRect(Rect.fromLTWH(x - r * 0.5, y + r * 0.55 + bob * r * 0.1, r * 0.38, r * 0.7), dark);
    c.drawRect(Rect.fromLTWH(x + r * 0.12, y + r * 0.55 - bob * r * 0.1, r * 0.38, r * 0.7), dark);
    // 手臂往前（往下）伸
    final sw = bob * r * 0.12;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - r * 0.95, y - r * 0.15 + sw, r * 0.3, r * 1.0), Radius.circular(r * 0.12)), Paint()..color = head);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + r * 0.65, y - r * 0.15 - sw, r * 0.3, r * 1.0), Radius.circular(r * 0.12)), Paint()..color = head);
    // 身體
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y + r * 0.2), width: r * 1.35, height: r * 1.3), Radius.circular(r * 0.3)), Paint()..color = body);
    // 頭
    c.drawCircle(Offset(x, y - r * 0.7), r * 0.66, Paint()..color = head);
    c.drawCircle(Offset(x - r * 0.24, y - r * 0.78), r * 0.12, Paint()..color = const Color(0xFFD50000));
    c.drawCircle(Offset(x + r * 0.24, y - r * 0.78), r * 0.12, Paint()..color = const Color(0xFFD50000));
    c.drawRect(Rect.fromLTWH(x - r * 0.28, y - r * 0.45, r * 0.56, r * 0.1), dark);
    if (kind == 2) {
      // 坦克：肩甲
      c.drawCircle(Offset(x - r * 0.75, y - r * 0.1), r * 0.3, Paint()..color = const Color(0xFF455A64));
      c.drawCircle(Offset(x + r * 0.75, y - r * 0.1), r * 0.3, Paint()..color = const Color(0xFF455A64));
    }
  }

  void _text(Canvas c, String t, Offset center, double size, {Color color = Colors.white, bool bold = false, bool outline = true}) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(fontSize: size, color: color, fontWeight: bold ? FontWeight.w900 : FontWeight.w500)),
      textDirection: TextDirection.ltr,
    )..layout();
    if (outline && bold) {
      final op = TextPainter(
        text: TextSpan(
            text: t,
            style: TextStyle(
                fontSize: size,
                fontWeight: FontWeight.w900,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = math.max(2.0, size * 0.12)
                  ..color = Colors.black.withValues(alpha: 0.6 * color.a))),
        textDirection: TextDirection.ltr,
      )..layout();
      op.paint(c, center - Offset(op.width / 2, op.height / 2));
    }
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _GatePainter old) => true;
}
