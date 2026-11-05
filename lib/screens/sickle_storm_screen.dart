// 鐮刀風暴（試玩）畫面：全部用 Canvas 自己畫（草地、鐮刀、人、金光暴風、粒子），
// 規則在 sickle_storm_logic.dart。前端單機、不連伺服器、沒有獎金。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'sickle_storm_logic.dart';

const _gold = Color(0xFFFFD54F);
const _goldDeep = Color(0xFFFF8F00);
const _bgDark = Color(0xFF0E1A10);

class SickleStormScreen extends StatefulWidget {
  final int? seed; // 測試用
  final bool autoStart; // 測試用：跳過開始畫面
  const SickleStormScreen({super.key, this.seed, this.autoStart = false});

  @visibleForTesting
  static SsGame? debugGame; // 測試截圖時用來直接改局面

  @override
  State<SickleStormScreen> createState() => _SickleStormScreenState();
}

enum _Phase { menu, play, over }

// ---------------- 特效 ----------------
class _Particle {
  double x, y, vx, vy, life, maxLife, size, rot, vr;
  final int kind; // 0 火花 1 金粉 2 塵土 3 碎片
  final Color color;
  _Particle(this.x, this.y, this.vx, this.vy, this.life, this.size, this.color, this.kind, {this.rot = 0, this.vr = 0}) : maxLife = life;
}

class _FlyBlade {
  // 收割時從死者身上飛向擊殺者的鐮刀
  final double sx, sy;
  final int target;
  final double delay, dur, spin, arc;
  double t = 0;
  final int tier;
  _FlyBlade(this.sx, this.sy, this.target, this.delay, this.dur, this.spin, this.arc, this.tier);
}

class _Wave {
  final double x, y, maxR;
  final Color color;
  double t = 0;
  final double dur;
  _Wave(this.x, this.y, this.maxR, this.color, this.dur);
}

class _FloatText {
  final double x, y;
  final String text;
  final Color color;
  final double size;
  double t = 0;
  _FloatText(this.x, this.y, this.text, this.color, this.size);
}

class _Feed {
  final String text;
  final Color color;
  double t = 0;
  _Feed(this.text, this.color);
}

class _Fx {
  final parts = <_Particle>[];
  final flies = <_FlyBlade>[];
  final waves = <_Wave>[];
  final texts = <_FloatText>[];
  double shake = 0;
}

class _SickleStormScreenState extends State<SickleStormScreen> with SingleTickerProviderStateMixin {
  late SsGame _g;
  late final Ticker _ticker;
  final _repaint = ValueNotifier<int>(0);
  final _focus = FocusNode();
  final _fx = _Fx();
  final _rng = math.Random();
  final _feed = <_Feed>[];
  _Phase _phase = _Phase.menu;
  Duration _last = Duration.zero;
  double _acc = 0;
  double _hudAcc = 0;
  Offset? _joyOrigin, _joyNow;
  // 鏡頭
  double _camX = 0, _camY = 0, _zoom = 1;
  String? _banner;
  Color _bannerColor = _gold;
  double _bannerT = 0;
  bool _introHint = true;
  int _seedBase = 0;

  @override
  void initState() {
    super.initState();
    _seedBase = widget.seed ?? DateTime.now().millisecondsSinceEpoch;
    _g = SsGame(seed: _seedBase);
    SickleStormScreen.debugGame = _g;
    _snapCamera();
    _ticker = createTicker(_onTick)..start();
    if (widget.autoStart) _phase = _Phase.play;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    setState(() {
      _g = SsGame(seed: ++_seedBase);
      SickleStormScreen.debugGame = _g;
      _fx.parts.clear();
      _fx.flies.clear();
      _fx.waves.clear();
      _fx.texts.clear();
      _feed.clear();
      _banner = null;
      _introHint = true;
      _phase = _Phase.play;
      _snapCamera();
    });
    _focus.requestFocus();
  }

  void _snapCamera() {
    _camX = _g.player.x;
    _camY = _g.player.y;
    _zoom = _targetZoom();
  }

  double _targetZoom() => 1 / math.max(1.0, _g.player.ringR / 105); // 拉遠得慢一點，大圈才看起來真的「超巨大」

  (double, double) _input() {
    var mx = 0.0, my = 0.0;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    if (keys.contains(LogicalKeyboardKey.keyA) || keys.contains(LogicalKeyboardKey.arrowLeft)) mx -= 1;
    if (keys.contains(LogicalKeyboardKey.keyD) || keys.contains(LogicalKeyboardKey.arrowRight)) mx += 1;
    if (keys.contains(LogicalKeyboardKey.keyW) || keys.contains(LogicalKeyboardKey.arrowUp)) my -= 1;
    if (keys.contains(LogicalKeyboardKey.keyS) || keys.contains(LogicalKeyboardKey.arrowDown)) my += 1;
    if (mx != 0 || my != 0) {
      final l = math.sqrt(mx * mx + my * my);
      return (mx / l, my / l);
    }
    final o = _joyOrigin, n = _joyNow;
    if (o == null || n == null) return (0, 0);
    final d = n - o;
    final l = d.distance;
    if (l < 6) return (0, 0);
    final k = math.min(1.0, l / 50) / l;
    return (d.dx * k, d.dy * k);
  }

  void _onTick(Duration now) {
    var dt = _last == Duration.zero ? 0.0 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (dt > 0.1) dt = 0.1; // 分頁切走再回來不要一次補太多
    if (_phase == _Phase.play) {
      _acc += dt;
      final (ix, iy) = _input();
      while (_acc >= ssDt) {
        _acc -= ssDt;
        _g.step(ix, iy);
      }
      _consumeEvents();
      if (_g.over) {
        _phase = _Phase.over;
        setState(() {});
      }
    }
    _updateFx(dt);
    // 鏡頭跟著玩家（死掉時看著兇手）
    final p = _g.player;
    var fx = p.x, fy = p.y;
    if (!p.alive && _g.killedBy != null) {
      final k = _g.byId(_g.killedBy!);
      if (k != null && k.alive) {
        fx = k.x;
        fy = k.y;
      }
    }
    final ck = 1 - math.exp(-8 * dt);
    _camX += (fx - _camX) * ck;
    _camY += (fy - _camY) * ck;
    _zoom += (_targetZoom() - _zoom) * (1 - math.exp(-2.5 * dt));
    _repaint.value++;
    _hudAcc += dt;
    if (_hudAcc > 0.1) {
      _hudAcc = 0;
      if (mounted) setState(() {});
    }
  }

  void _consumeEvents() {
    final p = _g.player;
    for (final e in _g.events) {
      switch (e.type) {
        case SsEvType.clash:
          final mine = e.a == p.id || e.b == p.id;
          final n = math.min(14, 4 + e.count * 2);
          for (var i = 0; i < n; i++) {
            final a = _rng.nextDouble() * math.pi * 2;
            final s = 150 + _rng.nextDouble() * 380;
            _fx.parts.add(_Particle(e.x, e.y, math.cos(a) * s, math.sin(a) * s, 0.18 + _rng.nextDouble() * 0.25, 1.5 + _rng.nextDouble() * 2,
                i.isEven ? const Color(0xFFFFF59D) : Colors.white, 0));
          }
          for (var i = 0; i < math.min(e.count, 6); i++) {
            final a = _rng.nextDouble() * math.pi * 2;
            final s = 80 + _rng.nextDouble() * 160;
            _fx.parts.add(_Particle(e.x, e.y, math.cos(a) * s, math.sin(a) * s, 0.6, 10, const Color(0xFFB0BEC5), 3,
                rot: _rng.nextDouble() * 6, vr: (_rng.nextDouble() - 0.5) * 20));
          }
          if (mine) _fx.shake = math.max(_fx.shake, 4 + e.count * 1.5);
        case SsEvType.kill:
          final killer = _g.byId(e.a);
          final victim = _g.byId(e.b);
          final tier = killer?.tier ?? 0;
          final k = math.min(e.count, 40);
          for (var i = 0; i < k; i++) {
            _fx.flies.add(_FlyBlade(e.x + (_rng.nextDouble() - 0.5) * 30, e.y + (_rng.nextDouble() - 0.5) * 30, e.a, i * 0.012,
                0.42 + _rng.nextDouble() * 0.2, (_rng.nextDouble() - 0.5) * 30, (_rng.nextDouble() - 0.5) * 1.6, tier));
          }
          _fx.waves.add(_Wave(e.x, e.y, 120, Colors.white, 0.35));
          for (var i = 0; i < 26; i++) {
            final a = _rng.nextDouble() * math.pi * 2;
            final s = 60 + _rng.nextDouble() * 260;
            _fx.parts.add(_Particle(e.x, e.y, math.cos(a) * s, math.sin(a) * s, 0.5 + _rng.nextDouble() * 0.4, 3 + _rng.nextDouble() * 4,
                Color(victim?.color ?? 0xFFFFFFFF), 2));
          }
          if (e.a == p.id) {
            _fx.shake = math.max(_fx.shake, 10);
            _fx.texts.add(_FloatText(e.x2, e.y2 - 40, '+${e.count}', _gold, 30));
            _introHint = false;
            _pushFeed('你 收割了 ${victim?.name ?? '?'}（+${e.count}）', _gold);
          } else if (e.b == p.id) {
            _fx.shake = 16;
            _pushFeed('${killer?.name ?? '?'} 收割了 你', const Color(0xFFFF5252));
          } else if (e.count >= 15 || (killer?.n ?? 0) >= ssGold) {
            _pushFeed('${killer?.name ?? '?'} 收割了 ${victim?.name ?? '?'}（${e.count} 把）', Colors.white70);
          }
        case SsEvType.gold:
          if (e.a == p.id) {
            _showBanner('⚡ 金光暴風圈 ⚡', _gold);
            _fx.shake = 14;
            _fx.waves.add(_Wave(p.x, p.y, 420, _gold, 0.8));
            _fx.waves.add(_Wave(p.x, p.y, 260, Colors.white, 0.5));
            for (var i = 0; i < 60; i++) {
              final a = _rng.nextDouble() * math.pi * 2;
              final s = 200 + _rng.nextDouble() * 400;
              _fx.parts.add(_Particle(p.x, p.y, math.cos(a) * s, math.sin(a) * s, 0.8 + _rng.nextDouble() * 0.6, 2 + _rng.nextDouble() * 3, _gold, 1));
            }
          } else {
            final f = _g.byId(e.a);
            if (f != null) _pushFeed('${f.name} 化身金光暴風圈！', _gold);
          }
        case SsEvType.silver:
          if (e.a == p.id) {
            _showBanner('銀月旋風', const Color(0xFFB3E5FC));
            _fx.waves.add(_Wave(p.x, p.y, 220, const Color(0xFFB3E5FC), 0.6));
          }
        case SsEvType.pickup:
          _fx.parts.add(_Particle(e.x, e.y, 0, -40, 0.35, 3, Colors.white, 1));
        case SsEvType.over:
          break;
      }
    }
    _g.events.clear();
  }

  void _pushFeed(String t, Color c) {
    _feed.insert(0, _Feed(t, c));
    if (_feed.length > 5) _feed.removeLast();
  }

  void _showBanner(String t, Color c) {
    _banner = t;
    _bannerColor = c;
    _bannerT = 0;
  }

  void _updateFx(double dt) {
    for (final p in _fx.parts) {
      p.life -= dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      final drag = p.kind == 1 ? 2.5 : 4.0;
      p.vx *= math.exp(-drag * dt);
      p.vy *= math.exp(-drag * dt);
      p.rot += p.vr * dt;
    }
    _fx.parts.removeWhere((p) => p.life <= 0);
    if (_fx.parts.length > 900) _fx.parts.removeRange(0, _fx.parts.length - 900);
    for (final f in _fx.flies) {
      f.t += dt;
    }
    _fx.flies.removeWhere((f) => f.t > f.delay + f.dur);
    for (final w in _fx.waves) {
      w.t += dt;
    }
    _fx.waves.removeWhere((w) => w.t > w.dur);
    for (final t in _fx.texts) {
      t.t += dt;
    }
    _fx.texts.removeWhere((t) => t.t > 1.2);
    for (final f in _feed) {
      f.t += dt;
    }
    _feed.removeWhere((f) => f.t > 5);
    _fx.shake *= math.exp(-9 * dt);
    if (_banner != null) {
      _bannerT += dt;
      if (_bannerT > 2.2) _banner = null;
    }
    // 金圈持續噴金粉
    for (final f in _g.fighters) {
      if (!f.alive || f.tier < 2) continue;
      if (_rng.nextDouble() < 0.6) {
        final a = _rng.nextDouble() * math.pi * 2;
        final r = f.ringR * (0.9 + _rng.nextDouble() * 0.4);
        final tx = -math.sin(a), ty = math.cos(a);
        _fx.parts.add(_Particle(f.x + math.cos(a) * r, f.y + math.sin(a) * r, tx * 120 + f.vx * 0.5, ty * 120 + f.vy * 0.5,
            0.5 + _rng.nextDouble() * 0.5, 1.5 + _rng.nextDouble() * 2, _rng.nextBool() ? _gold : Colors.white, 1));
      }
    }
  }

  // ---------------- 畫面 ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        title: const Text('鐮刀風暴（試玩）'),
        backgroundColor: const Color(0xFF13241A),
        foregroundColor: Colors.white,
      ),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (n, e) {
          if (e.logicalKey == LogicalKeyboardKey.space && e is KeyDownEvent && _phase != _Phase.play) {
            _start();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: LayoutBuilder(builder: (context, c) {
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => _joyOrigin = _joyNow = d.localPosition,
                  onPanUpdate: (d) => _joyNow = d.localPosition,
                  onPanEnd: (_) => _joyOrigin = _joyNow = null,
                  onPanCancel: () => _joyOrigin = _joyNow = null,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _WorldPainter(this),
                      size: Size(c.maxWidth, c.maxHeight),
                    ),
                  ),
                ),
              ),
              if (_phase != _Phase.menu) ..._hud(c),
              if (_banner != null) _bannerWidget(),
              if (_phase == _Phase.menu) Positioned.fill(child: _menu()),
              if (_phase == _Phase.over) Positioned.fill(child: _overPanel()),
            ],
          );
        }),
      ),
    );
  }

  List<Widget> _hud(BoxConstraints c) {
    final p = _g.player;
    final left = math.max(0.0, ssRoundSec - _g.time);
    final mm = left ~/ 60, ss = (left % 60).floor();
    final rank = _g.ranking();
    final narrow = c.maxWidth < 520;
    return [
      Positioned(
        left: 10,
        top: 10,
        child: _glass(Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 26, height: 26, child: CustomPaint(painter: _IconSickle(p.tier))),
          const SizedBox(width: 6),
          Text('${p.n}', style: TextStyle(color: _tierColor(p.tier), fontSize: 24, fontWeight: FontWeight.w900, height: 1)),
          const SizedBox(width: 10),
          const Icon(Icons.dangerous, size: 16, color: Colors.white54),
          Text(' ${p.kills}', style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w700)),
        ])),
      ),
      Positioned(
        top: 10,
        left: 0,
        right: 0,
        child: Center(
          child: _glass(Text('$mm:${ss.toString().padLeft(2, '0')}',
              style: TextStyle(
                  color: left < 20 ? const Color(0xFFFF5252) : Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()]))),
        ),
      ),
      Positioned(
        right: 10,
        top: 10,
        child: _glass(
          SizedBox(
            width: narrow ? 128 : 170,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('排行', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w700)),
              for (var i = 0; i < math.min(5, rank.length); i++) _rankRow(i + 1, rank[i]),
              if (!rank.take(5).contains(p)) ...[
                const Divider(height: 6, color: Colors.white24),
                _rankRow(_g.playerRank(), p),
              ],
            ]),
          ),
        ),
      ),
      Positioned(
        left: 10,
        top: 56,
        child: IgnorePointer(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final f in _feed)
              Opacity(
                opacity: (1 - (f.t - 4).clamp(0.0, 1.0)),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(6)),
                  child: Text(f.text, style: TextStyle(color: f.color, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
        ),
      ),
      Positioned(
        right: 10,
        bottom: 10,
        child: IgnorePointer(
          child: Container(
            width: narrow ? 96 : 130,
            height: narrow ? 96 : 130,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.45),
              border: Border.all(color: Colors.white24),
            ),
            child: CustomPaint(painter: _MiniMap(_g)),
          ),
        ),
      ),
      if (_introHint && _g.time < 12 && _phase == _Phase.play)
        Positioned(
          left: 0,
          right: 0,
          bottom: 28,
          child: IgnorePointer(
            child: Center(
              child: _glass(const Text('前面有個也拿鐮刀的傢伙衝過來了！用鐮刀撞他、掃到他身體就能收割 ⚔️',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600))),
            ),
          ),
        ),
    ];
  }

  Widget _rankRow(int i, SsFighter f) {
    final me = f.player;
    final c = me ? const Color(0xFF64B5F6) : (f.tier == 2 ? _gold : Colors.white);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        SizedBox(width: 18, child: Text('$i', style: TextStyle(color: c.withValues(alpha: 0.7), fontSize: 12, fontWeight: FontWeight.w800))),
        Expanded(
            child: Text(f.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c, fontSize: 12.5, fontWeight: me ? FontWeight.w900 : FontWeight.w600))),
        Text('${f.n}', style: TextStyle(color: c, fontSize: 12.5, fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _glass(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: child,
      );

  Widget _bannerWidget() {
    final t = _bannerT;
    final scale = t < 0.25 ? 0.6 + Curves.easeOutBack.transform(t / 0.25) * 0.4 : 1.0;
    final op = t > 1.7 ? (1 - (t - 1.7) / 0.5).clamp(0.0, 1.0) : 1.0;
    return Positioned(
      left: 0,
      right: 0,
      top: 90,
      child: IgnorePointer(
        child: Center(
          child: Opacity(
            opacity: op,
            child: Transform.scale(
              scale: scale,
              child: Text(_banner!,
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                    color: _bannerColor,
                    shadows: [
                      Shadow(color: _bannerColor.withValues(alpha: 0.9), blurRadius: 24),
                      const Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 2)),
                    ],
                  )),
            ),
          ),
        ),
      ),
    );
  }

  Widget _menu() {
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(colors: [Color(0xFFFFF8E1), _gold, _goldDeep], begin: Alignment.topCenter, end: Alignment.bottomCenter)
                .createShader(r),
            child: const Text('鐮刀風暴',
                style: TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 6, shadows: [
                  Shadow(color: Color(0xAAFF8F00), blurRadius: 30),
                ])),
          ),
          const SizedBox(height: 4),
          const Text('試玩版・單機・沒有獎金', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 18),
          _glass(const Text(
            '你手上只有一把小鐮刀。\n'
            '撞上別人時，鐮刀會互相磨損——鐮刀多、正在往前衝的一方佔上風。\n'
            '掃到對方的身體就是「收割」：他全部的鐮刀瞬間歸你！\n'
            '收集 30 把化身【金光暴風圈】。3 分鐘後鐮刀最多的人獲勝，被收割就出局。',
            style: TextStyle(color: Colors.white, fontSize: 14, height: 1.6),
          )),
          const SizedBox(height: 10),
          const Text('操作：手指在畫面任一處拖曳（虛擬搖桿）／ WASD、方向鍵', style: TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 18),
          _bigButton('開始', _start),
        ]),
      ),
    );
  }

  Widget _bigButton(String t, VoidCallback onTap) => FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: _goldDeep,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
          textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(t),
      );

  Widget _overPanel() {
    final p = _g.player;
    final dead = _g.overReason == 'dead';
    final killer = _g.killedBy == null ? null : _g.byId(_g.killedBy!);
    final rank = _g.playerRank();
    final title = dead ? '你被收割了' : (rank == 1 ? '🏆 收割之王' : '時間到');
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title,
              style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  color: dead ? const Color(0xFFFF5252) : _gold,
                  shadows: [Shadow(color: (dead ? Colors.red : _goldDeep).withValues(alpha: 0.8), blurRadius: 20)])),
          if (dead && killer != null) ...[
            const SizedBox(height: 4),
            Text('兇手：${killer.name}（${killer.n} 把）', style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ],
          const SizedBox(height: 16),
          _glass(Column(children: [
            _statRow('名次', '第 $rank 名'),
            _statRow('最多鐮刀', '${p.peak} 把'),
            _statRow('收割人數', '${p.kills} 人'),
            _statRow('存活時間', '${_g.time.floor()} 秒'),
          ])),
          const SizedBox(height: 18),
          _bigButton('再來一局', _start),
          const SizedBox(height: 6),
          const Text('空白鍵也可以重來', style: TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
      ),
    );
  }

  Widget _statRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(k, style: const TextStyle(color: Colors.white60, fontSize: 15)),
          const Spacer(),
          Text(v, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
        ]),
      );
}

Color _tierColor(int tier) => const [Color(0xFFE0E0E0), Color(0xFFB3E5FC), _gold][tier];

// ---------------- 鐮刀形狀（單位座標：-y 朝外、+x 是旋轉前進方向） ----------------
final Path _bladePath = () {
  final p = Path();
  p.moveTo(-0.05, -0.08);
  p.cubicTo(-0.10, -0.62, 0.52, -0.86, 0.80, -0.10); // 外緣（刀背）
  p.cubicTo(0.58, -0.52, 0.12, -0.50, 0.06, -0.06); // 內緣（刀刃）
  p.close();
  return p;
}();

final Path _edgePath = () {
  final p = Path();
  p.moveTo(0.06, -0.06);
  p.cubicTo(0.12, -0.50, 0.58, -0.52, 0.80, -0.10);
  return p;
}();

final List<Paint> _bladeFill = [
  // 鐵
  Paint()
    ..shader = ui.Gradient.linear(const Offset(0, -0.8), const Offset(0.6, 0),
        [const Color(0xFFF5F5F5), const Color(0xFFB0BEC5), const Color(0xFF546E7A)], [0, 0.5, 1]),
  // 銀
  Paint()
    ..shader = ui.Gradient.linear(const Offset(0, -0.8), const Offset(0.6, 0),
        [Colors.white, const Color(0xFFB3E5FC), const Color(0xFF4FC3F7)], [0, 0.45, 1]),
  // 金
  Paint()
    ..shader = ui.Gradient.linear(const Offset(0, -0.8), const Offset(0.6, 0),
        [const Color(0xFFFFFDE7), _gold, _goldDeep], [0, 0.45, 1]),
];

void _drawSickle(Canvas c, double x, double y, double ang, double size, int tier, {double alpha = 1, bool handle = true}) {
  c.save();
  c.translate(x, y);
  c.rotate(ang);
  c.scale(size);
  if (handle) _drawHandle(c, alpha);
  if (alpha >= 1) {
    c.drawPath(_bladePath, _bladeFill[tier]);
  } else {
    c.drawPath(_bladePath, Paint()..color = _tierColor(tier).withValues(alpha: alpha));
  }
  c.drawPath(
      _edgePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.035
        ..color = Colors.white.withValues(alpha: 0.85 * alpha));
  c.restore();
}

void _drawHandle(Canvas c, double alpha) {
  final handle = Paint()
    ..color = Color.fromRGBO(121, 85, 72, alpha)
    ..strokeWidth = 0.11
    ..strokeCap = StrokeCap.round;
  c.drawLine(const Offset(0, 0.42), const Offset(0, -0.08), handle);
  c.drawLine(const Offset(0, 0.42), const Offset(0, 0.30),
      handle..color = Color.fromRGBO(62, 39, 35, alpha)); // 柄尾
}

double _bladeSize(int n) => math.min(46.0, 22 + 2.0 * math.sqrt(n));

// ---------------- 世界 ----------------
class _WorldPainter extends CustomPainter {
  final _SickleStormScreenState s;
  _WorldPainter(this.s) : super(repaint: s._repaint);

  static final _textCache = <String, TextPainter>{};

  TextPainter _label(String t, Color color, double size) {
    final key = '$t|${color.toARGB32()}|$size';
    return _textCache.putIfAbsent(key, () {
      if (_textCache.length > 400) _textCache.clear();
      return TextPainter(
        text: TextSpan(
            text: t,
            style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w800, shadows: const [
              Shadow(color: Colors.black, blurRadius: 3),
            ])),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = s._g;
    final base = math.min(size.width, size.height);
    final scale = base / 470 * s._zoom;
    final shake = s._fx.shake;
    final sx = shake > 0.3 ? (s._rng.nextDouble() - 0.5) * shake : 0.0;
    final sy = shake > 0.3 ? (s._rng.nextDouble() - 0.5) * shake : 0.0;

    canvas.drawRect(Offset.zero & size, Paint()..color = _bgDark);
    canvas.save();
    canvas.translate(size.width / 2 + sx, size.height / 2 + sy);
    canvas.scale(scale);
    canvas.translate(-s._camX, -s._camY);

    final hw = size.width / 2 / scale, hh = size.height / 2 / scale;
    final view = Rect.fromLTRB(s._camX - hw - 60, s._camY - hh - 60, s._camX + hw + 60, s._camY + hh + 60);
    _drawGround(canvas, view, g.time);

    // 地上的鐮刀
    for (final p in g.pickups) {
      if (!view.contains(Offset(p.x, p.y))) continue;
      final bob = math.sin(g.time * 3 + p.phase);
      canvas.drawCircle(Offset(p.x, p.y), 13, Paint()..color = Colors.white.withValues(alpha: 0.06 + 0.04 * bob));
      _drawSickle(canvas, p.x, p.y + bob * 1.5, p.phase + g.time * 0.4, 17, 0);
      if (bob > 0.85) {
        // 閃一下
        final gx = p.x + 3, gy = p.y - 6;
        final gp = Paint()
          ..color = Colors.white.withValues(alpha: (bob - 0.85) * 6)
          ..strokeWidth = 1.2;
        canvas.drawLine(Offset(gx - 4, gy), Offset(gx + 4, gy), gp);
        canvas.drawLine(Offset(gx, gy - 4), Offset(gx, gy + 4), gp);
      }
    }

    // 衝擊波
    for (final w in s._fx.waves) {
      final k = w.t / w.dur;
      final r = w.maxR * Curves.easeOutCubic.transform(k);
      canvas.drawCircle(
          Offset(w.x, w.y),
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 10 * (1 - k) + 1
            ..color = w.color.withValues(alpha: (1 - k) * 0.8));
    }

    // 人＋鐮刀圈：小的先畫，大的蓋在上面
    final list = g.fighters.where((f) => f.alive).toList()..sort((a, b) => a.n.compareTo(b.n));
    for (final f in list) {
      final r = f.ringR + _bladeSize(f.n);
      if (!view.inflate(r).contains(Offset(f.x, f.y))) continue;
      _drawFighter(canvas, f, g.time);
    }

    // 粒子
    for (final p in s._fx.parts) {
      final a = (p.life / p.maxLife).clamp(0.0, 1.0);
      switch (p.kind) {
        case 0:
          canvas.drawLine(
              Offset(p.x, p.y),
              Offset(p.x - p.vx * 0.03, p.y - p.vy * 0.03),
              Paint()
                ..color = p.color.withValues(alpha: a)
                ..strokeWidth = p.size
                ..strokeCap = StrokeCap.round);
        case 1:
          canvas.drawCircle(Offset(p.x, p.y), p.size * (0.5 + a * 0.5), Paint()..color = p.color.withValues(alpha: a));
        case 2:
          canvas.drawCircle(Offset(p.x, p.y), p.size * a, Paint()..color = p.color.withValues(alpha: a * 0.8));
        case 3:
          _drawSickle(canvas, p.x, p.y, p.rot, p.size, 0, alpha: a * 0.8);
      }
    }

    // 收割：鐮刀飛向擊殺者
    for (final f in s._fx.flies) {
      if (f.t < f.delay) continue;
      final k = ((f.t - f.delay) / f.dur).clamp(0.0, 1.0);
      final tgt = g.byId(f.target);
      if (tgt == null) continue;
      final e = Curves.easeInCubic.transform(k);
      final dx = tgt.x - f.sx, dy = tgt.y - f.sy;
      // 走一條弧線，不要直直飛
      final px = -dy * f.arc * math.sin(k * math.pi) * 0.5, py = dx * f.arc * math.sin(k * math.pi) * 0.5;
      final x = f.sx + dx * e + px, y = f.sy + dy * e + py;
      final sz = 26 * (1 - 0.4 * k);
      canvas.drawCircle(Offset(x, y), sz * 0.7,
          Paint()..color = (f.tier == 2 ? _gold : Colors.white).withValues(alpha: 0.25 * (1 - k)));
      _drawSickle(canvas, x, y, f.spin * (f.t - f.delay), sz, f.tier);
    }

    // 飄字
    for (final t in s._fx.texts) {
      final k = t.t / 1.2;
      final tp = _label(t.text, t.color, t.size);
      canvas.save();
      canvas.translate(t.x, t.y - 50 * Curves.easeOut.transform(k));
      final sc = k < 0.15 ? 0.5 + k / 0.15 * 0.7 : 1.2 - (k - 0.15) * 0.25;
      canvas.scale(sc / s._zoom.clamp(0.4, 1.0));
      canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: (1 - math.max(0, k - 0.6) / 0.4).clamp(0, 1)));
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
      canvas.restore();
    }

    canvas.restore();

    // 虛擬搖桿（螢幕座標）
    final o = s._joyOrigin, n = s._joyNow;
    if (o != null && n != null && s._phase == _Phase.play) {
      canvas.drawCircle(o, 50, Paint()..color = Colors.white.withValues(alpha: 0.08));
      canvas.drawCircle(
          o,
          50,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white.withValues(alpha: 0.25));
      var d = n - o;
      if (d.distance > 50) d = d / d.distance * 50;
      canvas.drawCircle(o + d, 22, Paint()..color = Colors.white.withValues(alpha: 0.35));
    }

    // 暗角
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(size.center(Offset.zero), size.longestSide * 0.7,
              [Colors.transparent, Colors.black.withValues(alpha: 0.45)], [0.55, 1]));
  }

  void _drawGround(Canvas c, Rect view, double time) {
    // 場地外面：深色
    c.drawRect(view, Paint()..color = const Color(0xFF0B140C));
    // 場地：草地漸層
    c.drawCircle(
        Offset.zero,
        ssArenaR,
        Paint()
          ..shader = ui.Gradient.radial(Offset.zero, ssArenaR, [const Color(0xFF3B6B33), const Color(0xFF2E5628), const Color(0xFF223F1E)],
              [0, 0.7, 1]));
    // 格子明暗 + 草叢（以格子座標做固定亂數，捲動時不會閃）
    const cell = 120.0;
    final x0 = (view.left / cell).floor(), x1 = (view.right / cell).ceil();
    final y0 = (view.top / cell).floor(), y1 = (view.bottom / cell).ceil();
    final tuft = Paint()
      ..color = const Color(0xFF5E8F45)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final tuftDark = Paint()
      ..color = const Color(0xFF1E3A1A)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.06);
    final r2 = ssArenaR * ssArenaR;
    for (var gx = x0; gx < x1; gx++) {
      for (var gy = y0; gy < y1; gy++) {
        final cx = gx * cell, cy = gy * cell;
        if (cx * cx + cy * cy > r2 * 1.05) continue;
        var h = (gx * 73856093) ^ (gy * 19349663);
        h = (h ^ (h >> 13)) * 1274126177;
        if ((gx + gy).isEven) c.drawRect(Rect.fromLTWH(cx, cy, cell, cell), shade);
        for (var k = 0; k < 3; k++) {
          final hx = ((h >> (k * 7)) & 127) / 127.0, hy = ((h >> (k * 7 + 3)) & 127) / 127.0;
          final px = cx + hx * cell, py = cy + hy * cell;
          if (px * px + py * py > r2) continue;
          final sway = math.sin(time * 1.6 + px * 0.01) * 1.5;
          final p = k == 0 ? tuftDark : tuft;
          c.drawLine(Offset(px, py), Offset(px - 4 + sway, py - 9), p);
          c.drawLine(Offset(px, py), Offset(px + sway, py - 12), p);
          c.drawLine(Offset(px, py), Offset(px + 4 + sway, py - 8), p);
        }
        if ((h & 31) == 0) {
          // 小花
          final px = cx + 40, py = cy + 70;
          if (px * px + py * py < r2) {
            for (var i = 0; i < 5; i++) {
              final a = i * math.pi * 2 / 5;
              c.drawCircle(Offset(px + math.cos(a) * 3.5, py + math.sin(a) * 3.5), 2.6, Paint()..color = const Color(0xFFFFF59D));
            }
            c.drawCircle(Offset(px, py), 2, Paint()..color = const Color(0xFFFF8F00));
          }
        } else if ((h & 31) == 1) {
          // 石頭
          final px = cx + 60, py = cy + 30;
          if (px * px + py * py < r2) {
            c.drawOval(Rect.fromCenter(center: Offset(px + 2, py + 4), width: 22, height: 10), Paint()..color = Colors.black26);
            c.drawOval(Rect.fromCenter(center: Offset(px, py), width: 20, height: 13), Paint()..color = const Color(0xFF78909C));
            c.drawOval(Rect.fromCenter(center: Offset(px - 3, py - 2), width: 8, height: 4), Paint()..color = const Color(0xFFB0BEC5));
          }
        }
      }
    }
    // 邊界：發光的符文圈 + 木樁
    c.drawCircle(
        Offset.zero,
        ssArenaR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 26
          ..color = const Color(0x33FF5722));
    c.drawCircle(
        Offset.zero,
        ssArenaR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = const Color(0xFFFF7043).withValues(alpha: 0.7 + 0.3 * math.sin(time * 3)));
    for (var i = 0; i < 160; i++) {
      final a = i * math.pi * 2 / 160;
      final px = math.cos(a) * (ssArenaR + 10), py = math.sin(a) * (ssArenaR + 10);
      if (!view.contains(Offset(px, py))) continue;
      c.drawCircle(Offset(px + 2, py + 3), 7, Paint()..color = Colors.black38);
      c.drawCircle(Offset(px, py), 6.5, Paint()..color = const Color(0xFF5D4037));
      c.drawCircle(Offset(px - 1.5, py - 1.5), 3, Paint()..color = const Color(0xFF8D6E63));
    }
  }

  void _drawFighter(Canvas c, SsFighter f, double time) {
    final cx = f.x, cy = f.y;
    final tier = f.tier;
    final R = f.ringR;
    final bs = _bladeSize(f.n);

    // 影子
    c.drawOval(Rect.fromCenter(center: Offset(cx + 3, cy + ssBodyR * 0.9), width: ssBodyR * 2.2, height: ssBodyR * 0.9),
        Paint()..color = Colors.black.withValues(alpha: 0.35));

    // 金光暴風：外層光暈 + 旋轉風紋
    if (tier == 2) {
      final pulse = 0.5 + 0.5 * math.sin(time * 5 + f.id);
      c.drawCircle(
          Offset(cx, cy),
          R + bs * 1.2,
          Paint()
            ..shader = ui.Gradient.radial(Offset(cx, cy), R + bs * 1.2, [
              _gold.withValues(alpha: 0.0),
              _gold.withValues(alpha: 0.10 + 0.06 * pulse),
              _goldDeep.withValues(alpha: 0.28 + 0.1 * pulse),
              _goldDeep.withValues(alpha: 0),
            ], [
              0,
              0.55,
              0.8,
              1
            ]));
      final wind = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 7; i++) {
        final a0 = f.angle * 1.6 + i * math.pi * 2 / 7;
        final rr = R * (0.55 + 0.12 * (i % 3)) + bs * 0.9 * (i.isEven ? 1 : 0.4);
        wind
          ..strokeWidth = 3 + (i % 3) * 1.5
          ..color = (i.isEven ? Colors.white : _gold).withValues(alpha: 0.35);
        c.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: rr), a0, 0.9, false, wind);
      }
    } else if (tier == 1) {
      c.drawCircle(
          Offset(cx, cy),
          R + bs * 0.6,
          Paint()
            ..shader = ui.Gradient.radial(Offset(cx, cy), R + bs * 0.6,
                [const Color(0x0081D4FA), const Color(0x2281D4FA), const Color(0x0081D4FA)], [0.5, 0.85, 1]));
    }

    // 掃過的殘影圈
    if (f.n > 0) {
      c.drawCircle(
          Offset(cx, cy),
          R + bs * 0.05,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = bs * 0.75
            ..color = _tierColor(tier).withValues(alpha: tier == 2 ? 0.16 : 0.08));
    }

    // 鐮刀：數量多時只畫 40 把（刀變大），不然一圈全糊在一起
    final m = math.min(f.n, 40);
    if (m > 0) {
      final gap = math.pi * 2 / m;
      final trailLen = math.min(0.7, gap * 0.8);
      final rect = Rect.fromCircle(center: Offset(cx, cy), radius: R + bs * 0.25);
      // 刀尖後面拖光：兩段不同透明度的弧（不用漸層，網頁版比較不會卡）
      final t1 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = bs * 0.30
        ..strokeCap = StrokeCap.round
        ..color = _tierColor(tier).withValues(alpha: tier == 2 ? 0.45 : 0.28);
      final t2 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = bs * 0.18
        ..strokeCap = StrokeCap.round
        ..color = _tierColor(tier).withValues(alpha: tier == 2 ? 0.22 : 0.12);
      for (var k = 0; k < m; k++) {
        final a = f.angle + k * gap;
        c.drawArc(rect, a - trailLen * 0.45, trailLen * 0.45, false, t1);
        c.drawArc(rect, a - trailLen, trailLen * 0.55, false, t2);
      }
      final dense = m >= 18; // 刀很多時不畫柄，不然內圈一排柄像齒輪
      for (var k = 0; k < m; k++) {
        final a = f.angle + k * gap;
        final bx = cx + math.cos(a) * (R - bs * 0.15), by = cy + math.sin(a) * (R - bs * 0.15);
        _drawSickle(c, bx, by, a + math.pi / 2, bs, tier, handle: !dense);
      }
    }

    // 保護罩
    if (f.shield > 0) {
      c.drawCircle(
          Offset(cx, cy),
          ssBodyR + 8,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white.withValues(alpha: 0.3 + 0.3 * math.sin(time * 12)));
    }

    // 身體：斗篷 + 兜帽 + 眼睛
    final col = Color(f.color);
    final hsl = HSLColor.fromColor(col);
    final dark = hsl.withLightness((hsl.lightness * 0.45).clamp(0, 1)).toColor();
    final light = hsl.withLightness((hsl.lightness * 1.15).clamp(0, 0.92)).toColor();
    if (f.player) {
      c.drawCircle(
          Offset(cx, cy + 2),
          ssBodyR + 5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = const Color(0xFF64B5F6).withValues(alpha: 0.8));
    }
    c.drawCircle(
        Offset(cx, cy),
        ssBodyR,
        Paint()
          ..shader = ui.Gradient.radial(Offset(cx - 5, cy - 6), ssBodyR * 1.6, [light, col, dark], [0, 0.5, 1]));
    // 兜帽陰影（朝臉的方向開口）
    final fx = f.faceX, fy = f.faceY;
    c.drawCircle(Offset(cx + fx * 6, cy + fy * 6), ssBodyR * 0.62, Paint()..color = const Color(0xFF1A1A1A));
    final eye = Paint()..color = f.player ? const Color(0xFF80D8FF) : (tier == 2 ? _gold : Colors.white);
    final px = -fy, py = fx;
    c.drawCircle(Offset(cx + fx * 9 + px * 3.4, cy + fy * 9 + py * 3.4), 2.1, eye);
    c.drawCircle(Offset(cx + fx * 9 - px * 3.4, cy + fy * 9 - py * 3.4), 2.1, eye);
    // 手（握柄）
    c.drawCircle(Offset(cx - fy * 13 + fx * 4, cy + fx * 13 + fy * 4), 4, Paint()..color = dark);
    if (f.flash > 0) {
      c.drawCircle(Offset(cx, cy), ssBodyR + 1, Paint()..color = Colors.white.withValues(alpha: (f.flash / 0.12).clamp(0, 1) * 0.8));
    }
    if (tier == 2) {
      // 皇冠
      final crown = Path()
        ..moveTo(cx - 9, cy - ssBodyR - 2)
        ..lineTo(cx - 10, cy - ssBodyR - 12)
        ..lineTo(cx - 4, cy - ssBodyR - 6)
        ..lineTo(cx, cy - ssBodyR - 14)
        ..lineTo(cx + 4, cy - ssBodyR - 6)
        ..lineTo(cx + 10, cy - ssBodyR - 12)
        ..lineTo(cx + 9, cy - ssBodyR - 2)
        ..close();
      c.drawPath(crown, Paint()..color = _gold);
      c.drawPath(
          crown,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = _goldDeep);
    }

    // 名字＋鐮刀數
    final z = s._zoom.clamp(0.35, 1.0);
    final tp = _label('${f.name}  ${f.n}', f.player ? const Color(0xFF80D8FF) : (tier == 2 ? _gold : Colors.white), 13);
    c.save();
    c.translate(cx, cy - R - bs * 0.9 - 6 / z);
    c.scale(1 / z);
    tp.paint(c, Offset(-tp.width / 2, -tp.height));
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _WorldPainter old) => true;
}

class _MiniMap extends CustomPainter {
  final SsGame g;
  _MiniMap(this.g);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final k = (r - 4) / ssArenaR;
    final c = Offset(r, r);
    canvas.drawCircle(c, r - 3, Paint()..color = const Color(0xFF2E5628).withValues(alpha: 0.6));
    for (final p in g.pickups) {
      canvas.drawCircle(c + Offset(p.x * k, p.y * k), 0.8, Paint()..color = Colors.white38);
    }
    for (final f in g.fighters) {
      if (!f.alive) continue;
      final rr = math.max(2.0, f.ringR * k * 1.4);
      final col = f.player ? const Color(0xFF40C4FF) : (f.tier == 2 ? _gold : (f.n > g.player.n ? const Color(0xFFFF5252) : Colors.white70));
      canvas.drawCircle(c + Offset(f.x * k, f.y * k), f.player ? rr + 1.5 : rr, Paint()..color = col);
    }
  }

  @override
  bool shouldRepaint(covariant _MiniMap old) => true;
}

class _IconSickle extends CustomPainter {
  final int tier;
  _IconSickle(this.tier);
  @override
  void paint(Canvas canvas, Size size) {
    _drawSickle(canvas, size.width * 0.38, size.height * 0.62, 0.5, size.width * 0.95, tier);
  }

  @override
  bool shouldRepaint(covariant _IconSickle old) => old.tier != tier;
}
