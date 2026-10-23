import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'hero_art.dart';
import 'monster_art.dart';

// 百層塔式的回合戰鬥舞台（勇者在左、怪物在右、自動攻擊、傷害數字與打擊特效）。
// 從 tower_screen.dart 的舞台抽出來獨立使用（魔塔小遊戲用）；傳入一場戰鬥的紀錄，播完呼叫 onDone。
// log 格式與伺服器 tower_game.fight 相同：{a: 'h' 或怪物 index, d, dmg, crit, miss, hp(被打者剩餘血量)}。

enum _Phase { walking, waiting, battle, after, idle, entering }

const _skyTop = [0xFF8FD3F4, 0xFF1B1626, 0xFF1D2340, 0xFF2E5E3A, 0xFF4B5A2A, 0xFF2A2A30, 0xFF4A1208, 0xFF9ED8F5, 0xFF5BA8F0, 0xFF1A0510];
const _skyBottom = [0xFFDFF3D0, 0xFF3A2E4A, 0xFF4A4F7A, 0xFF9CCB7A, 0xFFA6B86B, 0xFF5A5A66, 0xFFFF7A2E, 0xFFEAF8FF, 0xFFFFE4B8, 0xFF7A1630];
const _groundCol = [0xFF4C8C3A, 0xFF4A3B33, 0xFF3A3D4A, 0xFF3B6B2E, 0xFF4A5A2F, 0xFF5A5148, 0xFF3A2018, 0xFFDCEEF7, 0xFFEFE2C8, 0xFF2A1018];
const _farCol = [0xFF6BAF5B, 0xFF2B2234, 0xFF2A2E4A, 0xFF1F4A2A, 0xFF3A4A22, 0xFF3A3A44, 0xFF5A2210, 0xFFB0D4EA, 0xFFFFFFFF, 0xFF3A0C1C];

class _Mon {
  final String name;
  final int kind;
  final int band;
  final bool boss;
  final int maxHp;
  int hp;
  double flash = 0;
  double dying = 0; // 0 活著，>0 淡出中
  double shown; // 血條顯示值（平滑追上 hp）
  double ghost; // 殘影血條（被打掉的那一段，延遲後慢慢縮）
  double ghostHold = 0;
  double knock = 0; // 被打到的後仰 0~1
  _Mon(Map<String, dynamic> m)
      : name = m['name'] as String,
        kind = (m['kind'] as num).toInt(),
        band = (m['band'] as num).toInt(),
        boss = m['boss'] == true,
        maxHp = (m['max_hp'] as num).toInt(),
        hp = (m['hp'] as num).toInt(),
        shown = (m['hp'] as num).toDouble(),
        ghost = (m['hp'] as num).toDouble();
}

// 打擊特效：劈砍 / 爪擊 + 擴散環；火花粒子另外一個 list
class _Fx {
  final double x;
  final double y;
  final double size;
  final bool claw;
  final bool crit;
  final bool flip; // 勇者打怪物 = 由左上劈向右下；怪物打勇者反向
  double age = 0;
  static const dur = 0.38;
  _Fx(this.x, this.y, this.size, {this.claw = false, this.crit = false, this.flip = false});
}

class _Spark {
  double x;
  double y;
  double vx;
  double vy;
  final Color color;
  final double size;
  double age = 0;
  final double life;
  _Spark(this.x, this.y, this.vx, this.vy, this.color, this.size, this.life);
}

class _Float {
  final String text;
  final double x;
  final double y;
  final Color color;
  final double size;
  double age = 0;
  _Float(this.text, this.x, this.y, this.color, this.size);
}

class BattleStage extends StatefulWidget {
  final List<Map<String, dynamic>> monsters; // name, kind, band, boss, hp, max_hp
  final List<Map<String, dynamic>> log;
  final int heroHp, heroMax;
  final int band;
  final Map<String, ({String id, int tier})> equipped;
  final double speed;
  final void Function(int heroHpAfter, bool won) onDone;
  const BattleStage({
    super.key,
    required this.monsters,
    required this.log,
    required this.heroHp,
    required this.heroMax,
    required this.band,
    required this.onDone,
    this.equipped = const {},
    this.speed = 1,
  });

  @override
  State<BattleStage> createState() => _BattleStageState();
}

class _BattleStageState extends State<BattleStage> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final _phase = _Phase.battle;
  late List<_Mon> _mons;
  late List<Map<String, dynamic>> _log;
  int _logIdx = 0;
  double _actionT = 0;
  bool _applied = false;
  double _t = 0;
  final double _scroll = 0;
  double _stageW = 360;
  static const double _stageH = 290;
  double get _groundY => _stageH * 0.80;
  double get _heroX => _stageW * 0.20;
  Map<String, ({String id, int tier})> get _equipped => widget.equipped;
  bool _heroDown = false;
  double _heroFlash = 0, _heroKnock = 0, _shake = 0;
  late int _heroHp;
  late double _heroShown;
  final List<_Float> _floats = [];
  final List<_Fx> _fx = [];
  final List<_Spark> _sparks = [];
  final math.Random _rnd = math.Random();
  double _endT = -1;
  bool _done = false;
  bool _fast = false;

  @override
  void initState() {
    super.initState();
    _mons = [for (final m in widget.monsters) _Mon(m)];
    _log = widget.log;
    _heroHp = widget.heroHp;
    _heroShown = widget.heroHp.toDouble();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double _monSize(_Mon m) => m.boss ? 128 : 92;

  Offset _monPos(int i, int n) {
    final xs = n == 1 ? [0.66] : n == 2 ? [0.60, 0.80] : [0.56, 0.72, 0.88];
    final ys = n == 1 ? [0.0] : n == 2 ? [4.0, -6.0] : [6.0, -2.0, -10.0];
    return Offset(_stageW * xs[i], _groundY + ys[i]);
  }

  void _onTick(Duration elapsed) {
    final dt = math.min(0.1, (elapsed - _last).inMicroseconds / 1e6);
    _last = elapsed;
    if (!mounted) return;
    _t += dt;
    for (final m in _mons) {
      m.shown += (m.hp - m.shown) * math.min(1.0, dt * 14);
      m.ghost = _stepGhost(m.ghost, m.hp.toDouble(), m.maxHp.toDouble(), m.ghostHold, dt);
      m.ghostHold = math.max(0, m.ghostHold - dt);
      m.knock = math.max(0, m.knock - dt * 4.5);
      m.flash = math.max(0, m.flash - dt * 4);
      if (m.dying > 0) m.dying = math.min(1, m.dying + dt * 2.2);
    }
    _heroFlash = math.max(0, _heroFlash - dt * 4);
    _heroShown += (_heroHp - _heroShown) * math.min(1.0, dt * 14);
    _heroKnock = math.max(0, _heroKnock - dt * 4.5);
    _shake = math.max(0, _shake - dt * 40);
    for (final f in _fx) {
      f.age += dt;
    }
    _fx.removeWhere((f) => f.age > _Fx.dur);
    for (final sp in _sparks) {
      sp.age += dt;
      sp.x += sp.vx * dt;
      sp.y += sp.vy * dt;
      sp.vy += 700 * dt;
      sp.vx *= 1 - dt * 1.5;
    }
    _sparks.removeWhere((sp) => sp.age > sp.life);
    for (final f in _floats) {
      f.age += dt;
    }
    _floats.removeWhere((f) => f.age > 1.0);
    final sp = widget.speed * (_fast ? 5 : 1);
    if (_logIdx < _log.length) {
      _stepBattle(dt * sp);
    } else if (!_done) {
      _endT = _endT < 0 ? 0 : _endT + dt * sp;
      if (_endT >= 0.8) {
        _done = true;
        final won = _heroHp > 0;
        widget.onDone(_heroHp, won);
      }
    }
    setState(() {});
  }

  double _stepGhost(double ghost, double hp, double max, double hold, double dt) {
    if (hp >= ghost) return hp;
    if (hold > 0) return ghost;
    return math.max(hp, ghost - (max * 0.5 + (ghost - hp) * 3) * dt);
  }

  void _burst(double x, double y, int n, List<Color> colors, {double speed = 260, double size = 3.5}) {
    for (var i = 0; i < n; i++) {
      final a = _rnd.nextDouble() * math.pi * 2;
      final v = speed * (0.35 + _rnd.nextDouble() * 0.65);
      _sparks.add(_Spark(x, y, math.cos(a) * v, math.sin(a) * v - 90, colors[_rnd.nextInt(colors.length)], size * (0.6 + _rnd.nextDouble() * 0.8), 0.35 + _rnd.nextDouble() * 0.3));
    }
  }

  static const _actionDur = 0.6;
  static const _hitAt = 0.25;

  void _stepBattle(double dt) {
    _actionT += dt;
    final ev = _log[_logIdx];
    if (!_applied && _actionT >= _hitAt) {
      _applied = true;
      _applyEvent(ev);
    }
    if (_actionT >= _actionDur) {
      _logIdx++;
      _actionT = 0;
      _applied = false;
    }
  }

  void _applyEvent(Map<String, dynamic> ev) {
    final miss = ev['miss'] == true;
    final crit = ev['crit'] == true;
    final dmg = (ev['dmg'] as num).toInt();
    final hp = (ev['hp'] as num).toInt();
    final d = ev['d'];
    if (d == 'h') {
      _floats.add(_Float(miss ? 'MISS' : '-$dmg', _heroX, _groundY - 150, miss ? Colors.white70 : const Color(0xFFFF6B6B), crit ? 26 : 20));
      if (!miss) {
        _heroFlash = 1;
        _heroKnock = 1;
        final hy = _groundY - 90;
        _fx.add(_Fx(_heroX, hy, 70, claw: true, crit: crit, flip: true));
        _burst(_heroX, hy, crit ? 18 : 10, const [Color(0xFFFF5252), Color(0xFFFFB199), Colors.white]);
        _shake = math.max(_shake, crit ? 9 : 5);
      }
      _heroHp = hp;
      if (hp <= 0) {
        _heroDown = true;
      }
    } else {
      final i = (d as num).toInt();
      if (i < _mons.length) {
        final m = _mons[i];
        final pos = _monPos(i, _mons.length);
        _floats.add(_Float(miss ? 'MISS' : (crit ? '$dmg!' : '$dmg'), pos.dx, pos.dy - _monSize(m) - 16,
            miss ? Colors.white70 : (crit ? const Color(0xFFFFD93D) : Colors.white), crit ? 28 : 20));
        if (!miss) {
          m.flash = 1;
          m.knock = 1;
          m.ghostHold = 0.45;
          final cy = pos.dy - _monSize(m) * 0.5;
          _fx.add(_Fx(pos.dx, cy, _monSize(m) * 0.62, crit: crit));
          _burst(pos.dx, cy, crit ? 22 : 11,
              crit ? const [Color(0xFFFFD93D), Colors.white, Color(0xFFFF9F1C)] : const [Colors.white, Color(0xFFBFE6FF), Color(0xFFFFE9A8)],
              speed: crit ? 340 : 250);
          _shake = math.max(_shake, crit ? 9 : (m.boss ? 4 : 3));
        }
        m.hp = hp;
        if (hp <= 0) {
          m.dying = 0.01;
          _burst(pos.dx, pos.dy - _monSize(m) * 0.45, 22, const [Color(0xFFEEEEEE), Color(0xFFB0BEC5), Color(0xFFFFE082)], speed: 200, size: 5);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _stageW = c.maxWidth;
      return GestureDetector(
        onTap: () => _fast = !_fast,
        child: SizedBox(
          height: _stageH,
          width: double.infinity,
          child: Stack(children: [
            Positioned.fill(child: ClipRect(child: CustomPaint(painter: _StagePainter(this)))),
            Positioned(
                left: 10,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                  child: Text('勇者 ${_heroShown.round().clamp(0, 999999)} / ${widget.heroMax}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                )),
            const Positioned(right: 10, top: 8, child: Text('點一下加速', style: TextStyle(color: Colors.white54, fontSize: 11))),
          ]),
        ),
      );
    });
  }
}

class _StagePainter extends CustomPainter {
  final _BattleStageState s;
  _StagePainter(this.s);

  @override
  void paint(Canvas canvas, Size size) {
    final band = s.widget.band % 10;
    canvas.save();
    if (s._shake > 0) {
      canvas.translate(math.sin(s._t * 130) * s._shake, math.cos(s._t * 110) * s._shake * 0.6);
    }
    _background(canvas, size, band);
    final gy = s._groundY;

    // 勇者
    _drawHero(canvas, gy);

    // 怪物（後排先畫）
    final n = s._mons.length;
    final order = List.generate(n, (i) => i)..sort((a, b) => s._monPos(a, n).dy.compareTo(s._monPos(b, n).dy));
    for (final i in order) {
      final m = s._mons[i];
      if (s._phase == _Phase.idle || s._phase == _Phase.entering) {
        continue;
      }
      final pos = s._monPos(i, n);
      final sz = s._monSize(m);
      var lunge = 0.0;
      var attacking = false;
      if (s._phase == _Phase.battle && s._logIdx < s._log.length && s._log[s._logIdx]['a'] == i) {
        lunge = -_lungeCurve(s._actionT) * 60;
        attacking = true;
      }
      if (m.dying >= 1) {
        continue;
      }
      // 影子（死亡時跟著縮小）
      canvas.drawOval(Rect.fromCenter(center: Offset(pos.dx, pos.dy + 2), width: sz * 0.62 * (1 - m.dying * 0.5), height: 9), Paint()..color = Color.fromRGBO(0, 0, 0, 0.28 * (1 - m.dying)));
      // 被打：往後仰＋壓扁；出招：蓄力時前傾、撞到時拉長；死亡：縮小並往上飄
      final k = Curves.easeOut.transform(m.knock);
      final lean = attacking ? _lungeCurve(s._actionT).clamp(-1.0, 1.0) : 0.0;
      canvas.save();
      canvas.translate(pos.dx + lunge + k * 16, pos.dy - m.dying * 18);
      canvas.rotate(k * 0.12 - lean * 0.08);
      canvas.scale((1 + k * -0.10 + (attacking ? lean.abs() * 0.06 : 0)) * (1 - m.dying * 0.3), (1 + k * 0.10 - (attacking ? lean.abs() * 0.04 : 0)) * (1 - m.dying * 0.3));
      canvas.translate(-sz / 2, -sz);
      MonsterPainter(kind: m.kind, band: m.band, boss: m.boss, flash: m.flash, opacity: 1 - m.dying, t: s._t + i)
          .paint(canvas, Size(sz, sz));
      canvas.restore();
      if (m.dying == 0 && (s._phase == _Phase.battle || s._phase == _Phase.after)) {
        _hpBar(canvas, Offset(pos.dx, pos.dy - sz - 4), m.boss ? 96 : 66, m, attacking);
      } else if (m.dying == 0 && (s._phase == _Phase.walking || s._phase == _Phase.waiting)) {
        _label(canvas, Offset(pos.dx, pos.dy - sz - 2), m.name, 10, Colors.white70);
      }
    }

    // 打擊特效與火花
    for (final f in s._fx) {
      _drawFx(canvas, f);
    }
    for (final sp in s._sparks) {
      final a = (1 - sp.age / sp.life).clamp(0.0, 1.0);
      canvas.drawCircle(Offset(sp.x, sp.y), sp.size * (0.4 + 0.6 * a), Paint()..color = sp.color.withValues(alpha: a));
    }

    // 浮動數字
    for (final f in s._floats) {
      final a = (1 - f.age).clamp(0.0, 1.0);
      final pop = f.age < 0.12 ? 1 + (1 - f.age / 0.12) * 0.6 : 1.0; // 數字彈出放大再縮回
      _label(canvas, Offset(f.x, f.y - Curves.easeOut.transform(f.age.clamp(0.0, 1.0)) * 40), f.text, f.size * pop, f.color.withValues(alpha: a), bold: true, outline: true);
    }
    canvas.restore();
  }

  // 出招曲線：先往後蓄力一下（-0.18），再快速衝出（到 1 時正好命中），之後緩緩收回
  double _lungeCurve(double t) {
    if (t < 0.1) {
      return -0.18 * Curves.easeOut.transform(t / 0.1);
    }
    if (t < 0.25) {
      return -0.18 + 1.18 * Curves.easeIn.transform((t - 0.1) / 0.15);
    }
    return math.max(0, 1 - Curves.easeOut.transform((t - 0.25) / 0.35));
  }

  void _drawFx(Canvas canvas, _Fx f) {
    final p = (f.age / _Fx.dur).clamp(0.0, 1.0);
    final grow = Curves.easeOut.transform(math.min(1.0, p * 2.2));
    final alpha = (1 - Curves.easeIn.transform(p)).clamp(0.0, 1.0);
    final glow = f.crit ? const Color(0xFFFFD93D) : (f.claw ? const Color(0xFFFF5252) : const Color(0xFF8FD3FF));
    // 擴散環
    canvas.drawCircle(
        Offset(f.x, f.y),
        f.size * (0.3 + 0.9 * grow),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (f.crit ? 5 : 3) * (1 - p)
          ..color = glow.withValues(alpha: alpha * 0.8));
    if (f.crit) {
      // 暴擊：放射線
      final rp = Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFFFF3B0).withValues(alpha: alpha);
      for (var i = 0; i < 10; i++) {
        final a = i * math.pi / 5 + 0.3;
        canvas.drawLine(Offset(f.x + math.cos(a) * f.size * 0.45 * grow, f.y + math.sin(a) * f.size * 0.45 * grow),
            Offset(f.x + math.cos(a) * f.size * (0.6 + 0.5 * grow), f.y + math.sin(a) * f.size * (0.6 + 0.5 * grow)), rp);
      }
    }
    final slashes = f.claw ? 3 : (f.crit ? 2 : 1);
    for (var i = 0; i < slashes; i++) {
      final off = (i - (slashes - 1) / 2) * (f.claw ? 14.0 : 16.0);
      final dir = f.flip ? -1.0 : 1.0;
      final L = f.size * (f.crit ? 1.0 : 0.8);
      final a = Offset(f.x - L * 0.7 * dir + off, f.y - L * 0.85);
      final b = Offset(f.x + L * 0.7 * dir + off, f.y + L * 0.85);
      final ctrl = Offset(f.x + off + 14 * dir, f.y);
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
      for (final m in path.computeMetrics()) {
        // 前半段把線「劃出去」，後半段從尾巴開始收掉，形成劃過去的殘影
        final head = m.length * grow;
        final tail = m.length * Curves.easeIn.transform(math.max(0.0, (p - 0.35) / 0.65));
        if (head <= tail) continue;
        final seg = m.extractPath(tail, head);
        canvas.drawPath(
            seg,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = (f.crit ? 14 : 10)
              ..color = glow.withValues(alpha: 0.45 * alpha)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
        canvas.drawPath(
            seg,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = f.crit ? 5 : 3.5
              ..color = Colors.white.withValues(alpha: alpha));
      }
    }
  }

  void _drawHero(Canvas canvas, double gy) {
    const hh = 178.0;
    const hw = hh * 0.45;
    var x = s._heroX;
    var y = gy + 6;
    if (s._phase == _Phase.walking) {
      y -= (math.sin(s._t * 12)).abs() * 5;
    }
    if (s._phase == _Phase.battle && s._logIdx < s._log.length && s._log[s._logIdx]['a'] == 'h') {
      final tIdx = s._log[s._logIdx]['d'];
      final tx = tIdx is int && tIdx < s._mons.length ? s._monPos(tIdx, s._mons.length).dx : s._stageW * 0.6;
      x += _lungeCurve(s._actionT) * math.max(30.0, (tx - x) - 70);
    }
    final hk = Curves.easeOut.transform(s._heroKnock);
    x -= hk * 14;
    canvas.save();
    canvas.translate(x, y);
    if (hk > 0 && !s._heroDown) {
      canvas.rotate(-hk * 0.1);
    }
    if (s._heroDown) {
      canvas.rotate(math.pi / 2 * 0.9);
      canvas.translate(0, -hh * 0.2);
    }
    canvas.translate(-hw / 2, -hh);
    if (s._heroFlash > 0) {
      canvas.saveLayer(const Rect.fromLTWH(-40, -40, 200, 260), Paint());
    }
    HeroPaperDoll(s._equipped).paint(canvas, const Size(hw, hh));
    if (s._heroFlash > 0) {
      canvas.drawRect(const Rect.fromLTWH(-40, -40, 200, 260), Paint()
        ..color = Colors.white.withValues(alpha: s._heroFlash * 0.7)
        ..blendMode = BlendMode.srcATop);
      canvas.restore();
    }
    canvas.restore();
    // 影子
    canvas.drawOval(Rect.fromCenter(center: Offset(x, gy + 8), width: 56, height: 10), Paint()..color = const Color(0x44000000));
  }

  void _hpBar(Canvas canvas, Offset bottomCenter, double w, _Mon m, bool active) {
    final h = m.boss ? 10.0 : 8.0;
    final r = Rect.fromLTWH(bottomCenter.dx - w / 2, bottomCenter.dy - h - 1, w, h);
    final rr = RRect.fromRectAndRadius(r, Radius.circular(h / 2));
    final ratio = (m.shown / m.maxHp).clamp(0.0, 1.0);
    final ghostRatio = (m.ghost / m.maxHp).clamp(0.0, 1.0);
    canvas.drawRRect(rr.inflate(1.5), Paint()..color = active ? const Color(0xFFFFD93D) : Colors.black87);
    canvas.drawRRect(rr, Paint()..color = const Color(0xFF1A1A1A));
    canvas.save();
    canvas.clipRRect(rr);
    // 殘影（剛被打掉的那一段）
    canvas.drawRect(Rect.fromLTWH(r.left, r.top, w * ghostRatio, h), Paint()..color = const Color(0xFFFFE9A8));
    final base = m.boss ? const Color(0xFFFF5252) : (ratio > 0.5 ? const Color(0xFF4CD964) : ratio > 0.25 ? const Color(0xFFFFC107) : const Color(0xFFFF5252));
    final fillRect = Rect.fromLTWH(r.left, r.top, w * ratio, h);
    canvas.drawRect(
        fillRect,
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(base, Colors.white, 0.35)!, base, Color.lerp(base, Colors.black, 0.25)!])
              .createShader(r));
    // 上緣高光
    canvas.drawRect(Rect.fromLTWH(r.left, r.top + 1, w * ratio, h * 0.28), Paint()..color = Colors.white.withValues(alpha: 0.25));
    canvas.restore();
    _label(canvas, Offset(bottomCenter.dx, r.top - 2), m.boss ? '👑 ${m.name}' : m.name, m.boss ? 12 : 10, Colors.white);
    if (m.boss) {
      _label(canvas, Offset(bottomCenter.dx, r.bottom + 12), '${m.hp} / ${m.maxHp}', 9, Colors.white70);
    }
  }

  void _label(Canvas canvas, Offset bottomCenter, String text, double size, Color color, {bool bold = false, bool outline = false}) {
    void draw(Color col, {Paint? fg}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: TextStyle(color: fg == null ? col : null, foreground: fg, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(bottomCenter.dx - tp.width / 2, bottomCenter.dy - tp.height));
    }

    if (outline) {
      draw(Colors.black, fg: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = Colors.black.withValues(alpha: color.a));
    } else {
      draw(Colors.black54, fg: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.black54);
    }
    draw(color);
  }

  // ---------- 背景 ----------
  void _background(Canvas canvas, Size size, int band) {
    final w = size.width;
    final gy = s._groundY;
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, size.height),
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(_skyTop[band]), Color(_skyBottom[band])])
              .createShader(Rect.fromLTWH(0, 0, w, gy)));
    // 遠景山丘（慢速捲動）
    final far = Path()..moveTo(0, gy);
    for (var x = 0.0; x <= w + 20; x += 20) {
      final wx = x + s._scroll * 0.25;
      far.lineTo(x, gy - 40 - math.sin(wx / 53) * 18 - math.sin(wx / 23) * 8);
    }
    far.lineTo(w + 20, gy);
    far.close();
    canvas.drawPath(far, Paint()..color = Color(_farCol[band]).withValues(alpha: band == 8 ? 0.55 : 0.85));
    // 中景裝飾
    final period = 150.0;
    final off = s._scroll * 0.6 % period;
    for (var i = -1; i * period - off < w + 80; i++) {
      final x = i * period - off + 40;
      final seed = ((i + (s._scroll * 0.6 / period).floor()) * 7919) & 0xFF;
      _deco(canvas, band, x + (seed % 40), gy, 0.8 + (seed % 5) * 0.08);
    }
    // 地面
    canvas.drawRect(Rect.fromLTWH(0, gy, w, size.height - gy), Paint()..color = Color(_groundCol[band]));
    canvas.drawRect(Rect.fromLTWH(0, gy, w, 3), Paint()..color = Colors.white.withValues(alpha: 0.18));
    final dash = Paint()
      ..color = Colors.black.withValues(alpha: 0.18)
      ..strokeWidth = 2;
    final doff = s._scroll % 60;
    for (var x = -60.0 - doff; x < w + 60; x += 60) {
      canvas.drawLine(Offset(x, gy + 22), Offset(x + 30, gy + 22), dash);
      canvas.drawLine(Offset(x + 18, gy + 44), Offset(x + 52, gy + 44), dash);
    }
    // 魔界血月 / 熔岩光
    if (band == 9) {
      canvas.drawCircle(Offset(w * 0.78, 50), 28, Paint()..color = const Color(0xFFFF4D4D).withValues(alpha: 0.85));
    }
    if (band == 6) {
      canvas.drawRect(Rect.fromLTWH(0, gy - 6, w, 8), Paint()..color = const Color(0x55FF8A2E));
    }
  }

  void _deco(Canvas c, int band, double x, double gy, double k) {
    final p = Paint();
    switch (band) {
      case 0:
        p.color = const Color(0xFF2E7D32);
        for (var i = -1; i <= 1; i++) {
          c.drawPath(Path()..moveTo(x + i * 6, gy)..lineTo(x + i * 6 - 3, gy - 14 * k)..lineTo(x + i * 6 + 3, gy)..close(), p);
        }
        c.drawCircle(Offset(x + 10, gy - 6 * k), 3, Paint()..color = const Color(0xFFFF8FA3));
      case 1:
        c.drawPath(Path()..moveTo(x, gy)..lineTo(x + 10, gy - 38 * k)..lineTo(x + 22, gy)..close(), p..color = const Color(0xFF5C4B66));
      case 2:
        c.drawRRect(RRect.fromRectAndCorners(Rect.fromLTWH(x, gy - 30 * k, 20, 30 * k), topLeft: const Radius.circular(10), topRight: const Radius.circular(10)), p..color = const Color(0xFF8A8FA8));
        c.drawLine(Offset(x + 10, gy - 24 * k), Offset(x + 10, gy - 12 * k), Paint()
          ..color = Colors.black38
          ..strokeWidth = 2);
        c.drawLine(Offset(x + 5, gy - 19 * k), Offset(x + 15, gy - 19 * k), Paint()
          ..color = Colors.black38
          ..strokeWidth = 2);
      case 3:
        c.drawRect(Rect.fromLTWH(x + 8, gy - 30 * k, 8, 30 * k), p..color = const Color(0xFF5D4037));
        c.drawCircle(Offset(x + 12, gy - 40 * k), 20 * k, p..color = const Color(0xFF1F6B34));
        c.drawCircle(Offset(x + 2, gy - 32 * k), 12 * k, p..color = const Color(0xFF2E8B45));
      case 4:
        for (var i = 0; i < 3; i++) {
          c.drawLine(Offset(x + i * 6, gy), Offset(x + i * 6 + (i - 1) * 3, gy - 30 * k), Paint()
            ..color = const Color(0xFF55692A)
            ..strokeWidth = 2.4);
        }
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + 3, gy - 38 * k, 5, 12 * k), const Radius.circular(2)), p..color = const Color(0xFF6D4C41));
      case 5:
        c.drawPath(Path()..moveTo(x, gy)..lineTo(x + 8, gy - 30 * k)..lineTo(x + 16, gy - 8)..lineTo(x + 22, gy)..close(), p..color = const Color(0xFF4DD0E1));
        c.drawPath(Path()..moveTo(x + 8, gy - 30 * k)..lineTo(x + 12, gy - 6)..lineTo(x + 4, gy - 6)..close(), p..color = Colors.white30);
      case 6:
        c.drawPath(Path()..moveTo(x, gy)..quadraticBezierTo(x + 10, gy - 34 * k, x + 28, gy)..close(), p..color = const Color(0xFF2A1410));
        c.drawCircle(Offset(x + 14, gy - 8), 4, Paint()..color = const Color(0xFFFF8A2E));
      case 7:
        c.drawPath(Path()..moveTo(x, gy)..lineTo(x + 8, gy - 42 * k)..lineTo(x + 18, gy)..close(), p..color = const Color(0xFF9AD6F2));
        c.drawPath(Path()..moveTo(x + 14, gy)..lineTo(x + 20, gy - 24 * k)..lineTo(x + 28, gy)..close(), p..color = const Color(0xFFBFE6F8));
      case 8:
        p.color = Colors.white.withValues(alpha: 0.8);
        c.drawCircle(Offset(x, gy - 50 * k), 14, p);
        c.drawCircle(Offset(x + 14, gy - 54 * k), 18, p);
        c.drawCircle(Offset(x + 30, gy - 50 * k), 13, p);
        c.drawRect(Rect.fromLTWH(x + 10, gy - 36 * k, 10, 36 * k), Paint()..color = const Color(0xFFD7C9A8));
      case 9:
        c.drawPath(Path()..moveTo(x, gy)..lineTo(x + 10, gy - 58 * k)..lineTo(x + 20, gy)..close(), p..color = const Color(0xFF1A0A12));
        c.drawRect(Rect.fromLTWH(x + 8, gy - 26 * k, 4, 6), Paint()..color = const Color(0xFFFFB300));
    }
  }

  @override
  bool shouldRepaint(covariant _StagePainter old) => true;
}

