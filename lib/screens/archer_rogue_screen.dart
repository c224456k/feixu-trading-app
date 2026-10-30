import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/monster_art.dart';
import 'archer_rogue_logic.dart';

// 弓箭肉鴿（試玩）：前端單機、不碰遊戲幣。規則在 archer_rogue_logic.dart，這裡只負責輸入、畫面與存檔。

const _saveKey = 'archer_rogue_save_v1';
const _bestKey = 'archer_rogue_best_v1';

const _floorColors = [
  (Color(0xFF7CB342), Color(0xFF689F38)), // 草原
  (Color(0xFF6D5D4E), Color(0xFF5D4E41)), // 洞窟
  (Color(0xFF5E6273), Color(0xFF51556A)), // 墓地
  (Color(0xFF4E342E), Color(0xFF3E2723)), // 熔岩
  (Color(0xFF3A2440), Color(0xFF2E1B35)), // 魔王城
];

class ArcherRogueScreen extends StatefulWidget {
  const ArcherRogueScreen({super.key});

  @override
  State<ArcherRogueScreen> createState() => _ArcherRogueScreenState();
}

class _ArcherRogueScreenState extends State<ArcherRogueScreen> with SingleTickerProviderStateMixin {
  final _g = RgGame();
  final _focus = FocusNode();
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _acc = 0;
  bool _started = false;
  bool _paused = false;
  Map<String, dynamic>? _save;
  int _best = 0;
  RgPhase _shownPhase = RgPhase.play;
  // 搖桿（arena 座標，像素）
  Offset? _joyOrigin;
  Offset? _joyNow;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _loadSave();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadSave() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_saveKey);
      setState(() {
        _save = raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
        _best = sp.getInt(_bestKey) ?? 0;
      });
    } catch (_) {}
  }

  Future<void> _writeSave() async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (_g.phase == RgPhase.victory) {
        await sp.remove(_saveKey);
        _save = null;
      } else {
        _save = {'chapter': _g.chapter, 'stats': _g.snapshot.toJson()};
        await sp.setString(_saveKey, jsonEncode(_save));
      }
      final cleared = _g.phase == RgPhase.victory ? rgChapters : _g.chapter;
      if (cleared > _best) {
        _best = cleared;
        await sp.setInt(_bestKey, _best);
      }
    } catch (_) {}
  }

  void _newRun() {
    _g.newRun();
    _started = true;
    _paused = false;
    _writeSave();
    _sync();
  }

  void _continueRun() {
    final s = _save;
    if (s == null) return;
    _g.startChapter((s['chapter'] as num).toInt(), RgStats.fromJson(Map<String, dynamic>.from(s['stats'] as Map)));
    _started = true;
    _paused = false;
    _sync();
  }

  void _sync() {
    _shownPhase = _g.phase;
    setState(() {});
    _focus.requestFocus();
  }

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
    final k = math.min(1.0, l / 40) / l;
    return (d.dx * k, d.dy * k);
  }

  void _onTick(Duration now) {
    final dt = _last == Duration.zero ? 0.0 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (!_started || _paused || _g.phase != RgPhase.play) {
      _acc = 0;
      return;
    }
    _acc += math.min(dt, 0.1);
    final (mx, my) = _input();
    var n = 0;
    final chapterBefore = _g.chapter;
    while (_acc >= rgDt && n < 6) {
      _g.step(mx, my);
      _acc -= rgDt;
      n++;
      if (_g.phase != RgPhase.play) break;
    }
    if (n > 0) _repaint.value++;
    if (_g.phase != _shownPhase || _g.chapter != chapterBefore) {
      if (_g.phase == RgPhase.victory) _writeSave();
      _sync();
    }
  }

  // ---------------- 畫面 ----------------
  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (n, e) {
        final keys = {
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.space,
        };
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyP && _started) {
          setState(() => _paused = !_paused);
          return KeyEventResult.handled;
        }
        return keys.contains(e.logicalKey) ? KeyEventResult.handled : KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF14161C),
        appBar: AppBar(
          title: const Text('弓箭肉鴿（試玩）'),
          actions: [
            if (_started)
              IconButton(
                onPressed: () => setState(() => _paused = !_paused),
                icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                tooltip: '暫停（P）',
              ),
          ],
        ),
        body: SafeArea(child: _started ? _game() : _menu()),
      ),
    );
  }

  Widget _menu() {
    final s = _save;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🏹 弓箭肉鴿', style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 16),
              const Text(
                '• 拖曳畫面（或 WASD／方向鍵）移動，移動時不會射擊\n'
                '• 停下來就會自動射最近的敵人\n'
                '• 清完房間撿經驗、升級時三選一技能\n'
                '• 每關 4 個房間 + 頭目，共 5 關；技能會一路帶下去\n'
                '• 死掉要從那一關的第 1 間重來（技能回到進關時）',
                style: TextStyle(color: Colors.white70, height: 1.7),
              ),
              const SizedBox(height: 8),
              Text('最佳紀錄：通過 $_best / $rgChapters 關', style: const TextStyle(color: Colors.amberAccent)),
              const SizedBox(height: 24),
              if (s != null) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _continueRun,
                    icon: const Icon(Icons.play_arrow),
                    label: Text('繼續：第 ${(s['chapter'] as num).toInt() + 1} 關 ${rgChapterNames[(s['chapter'] as num).toInt()]}'),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _newRun,
                  icon: const Icon(Icons.refresh),
                  label: const Text('新遊戲'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _game() {
    return Column(
      children: [
        _hud(),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final w = math.min(c.maxWidth, c.maxHeight * rgCols / rgRows);
            final h = w * rgRows / rgCols;
            return Center(
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(
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
                            painter: _ArenaPainter(_g, _repaint, () => (_joyOrigin, _joyNow)),
                            size: Size(w, h),
                          ),
                        ),
                      ),
                    ),
                    if (_g.boss != null) Positioned(left: 8, right: 8, top: 6, child: _bossBar(_g.boss!)),
                    if (_paused) Positioned.fill(child: _pauseOverlay()),
                    if (_g.phase != RgPhase.play) Positioned.fill(child: _phaseOverlay()),
                  ],
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _hud() {
    final st = _g.st;
    return ValueListenableBuilder(
      valueListenable: _repaint,
      builder: (context, _, _) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Column(
          children: [
            Row(
              children: [
                Text('第 ${_g.chapter + 1} 關 ${rgChapterNames[_g.chapter]}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text(_g.isBossRoom ? '👑 頭目' : '房間 ${_g.room + 1}/${rgRoomsPerChapter - 1}',
                    style: const TextStyle(color: Colors.white70)),
                const Spacer(),
                Text('Lv ${st.level}', style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            _bar(st.hp / st.maxHp, const Color(0xFFE53935), '${st.hp.round()} / ${st.maxHp.round()}'),
            const SizedBox(height: 3),
            _bar(st.xp / st.xpNeed, const Color(0xFF29B6F6), null, height: 5),
            if (st.sk.isNotEmpty) ...[
              const SizedBox(height: 4),
              SizedBox(
                height: 22,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final e in st.sk.entries)
                      if (e.key != 'heal')
                        Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(6)),
                          alignment: Alignment.center,
                          child: Text('${rgSkill(e.key).icon}${e.value > 1 ? '×${e.value}' : ''}',
                              style: const TextStyle(fontSize: 12, color: Colors.white)),
                        ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bar(double v, Color c, String? label, {double height = 14}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Container(color: Colors.white12),
            FractionallySizedBox(widthFactor: v.clamp(0.0, 1.0), child: Container(color: c)),
            if (label != null)
              Center(
                child: Text(label, style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bossBar(RgEnemy b) {
    return ValueListenableBuilder(
      valueListenable: _repaint,
      builder: (context, _, _) => Column(
        children: [
          Text(b.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12, shadows: [Shadow(blurRadius: 3)])),
          const SizedBox(height: 2),
          _bar(b.hp / b.maxHp, const Color(0xFFAB47BC), null, height: 8),
        ],
      ),
    );
  }

  Widget _dim(Widget child) => Container(
        color: Colors.black.withValues(alpha: 0.72),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(child: child),
      );

  Widget _pauseOverlay() => GestureDetector(
        onTap: () => setState(() => _paused = false),
        child: _dim(const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.pause_circle, size: 64, color: Colors.white),
            SizedBox(height: 8),
            Text('暫停中，點一下繼續', style: TextStyle(color: Colors.white)),
          ],
        )),
      );

  Widget _phaseOverlay() {
    switch (_g.phase) {
      case RgPhase.pick:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_g.st.sk.isEmpty ? '選一個起始技能' : '升級！選一個技能',
                style: const TextStyle(color: Colors.amberAccent, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            for (final id in _g.offer) _skillCard(id),
          ],
        ));
      case RgPhase.angel:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('😇', style: TextStyle(fontSize: 48)),
            const Text('天使出現了', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('前方就是頭目，選一個祝福', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            _choiceButton('💚 回復 50% 生命', () => _g.chooseAngel(true)),
            const SizedBox(height: 10),
            _choiceButton('✨ 額外技能（三選一）', () => _g.chooseAngel(false)),
          ],
        ));
      case RgPhase.dead:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💀', style: TextStyle(fontSize: 48)),
            const Text('你倒下了', style: TextStyle(color: Colors.redAccent, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('第 ${_g.chapter + 1} 關 ${_g.isBossRoom ? '頭目房' : '第 ${_g.room + 1} 間'}・被 ${_g.lastHitBy ?? '?'} 打倒',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            _choiceButton('🔁 從第 ${_g.chapter + 1} 關重來', () => _g.retryChapter()),
            const SizedBox(height: 10),
            _choiceButton('🏠 回主選單', () {
              _started = false;
              _loadSave();
            }),
          ],
        ));
      case RgPhase.chapterDone:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🏆', style: TextStyle(fontSize: 48)),
            Text('第 ${_g.chapter + 1} 關 通關！', style: const TextStyle(color: Colors.amberAccent, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('下一關：${rgChapterNames[_g.chapter + 1]}（進關回復 20% 生命）', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            _choiceButton('▶ 前往第 ${_g.chapter + 2} 關', () {
              _g.nextChapter();
              _writeSave();
            }),
          ],
        ));
      case RgPhase.victory:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('👑', style: TextStyle(fontSize: 56)),
            const Text('全破！魔龍被你打倒了', style: TextStyle(color: Colors.amberAccent, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('等級 ${_g.st.level}・擊殺 ${_g.kills}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            _choiceButton('🏠 回主選單', () {
              _started = false;
              _loadSave();
            }),
          ],
        ));
      case RgPhase.play:
        return const SizedBox.shrink();
    }
  }

  Widget _choiceButton(String label, VoidCallback onTap) => SizedBox(
        width: 260,
        child: FilledButton(
          onPressed: () {
            onTap();
            _sync();
          },
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(label)),
        ),
      );

  Widget _skillCard(String id) {
    final s = rgSkill(id);
    final lv = _g.st.lv(id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF263238),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            _g.choose(id);
            _sync();
          },
          child: Container(
            width: 300,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6)),
            ),
            child: Row(
              children: [
                Text(s.icon, style: const TextStyle(fontSize: 30)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.max > 1 && id != 'heal' ? '${s.name}  Lv$lv→${lv + 1}' : s.name,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(s.desc, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArenaPainter extends CustomPainter {
  final RgGame g;
  final (Offset?, Offset?) Function() joy;
  _ArenaPainter(this.g, Listenable repaint, this.joy) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / rgCols;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (g.shake > 0) {
      final k = g.shake * 10;
      canvas.translate(math.sin(g.time * 90) * k, math.cos(g.time * 77) * k);
    }
    _floor(canvas, s);
    _zones(canvas, s);
    _telegraphs(canvas, s);
    for (final h in g.hearts) {
      _heart(canvas, Offset(h.x * s, h.y * s), s * 0.22);
    }
    for (final e in g.en) {
      _enemy(canvas, e, s);
    }
    _player(canvas, s);
    _bullets(canvas, s);
    _floats(canvas, s);
    canvas.restore();
    _joystick(canvas);
  }

  void _floor(Canvas c, double s) {
    final (a, b) = _floorColors[g.chapter];
    for (var y = 0; y < rgRows; y++) {
      for (var x = 0; x < rgCols; x++) {
        c.drawRect(Rect.fromLTWH(x * s, y * s, s + 0.5, s + 0.5), Paint()..color = (x + y).isEven ? a : b);
      }
    }
    // 門
    final door = Rect.fromLTWH(3.6 * s, 0, 1.8 * s, 0.35 * s);
    if (g.cleared) {
      final pulse = 0.5 + 0.5 * math.sin(g.time * 5);
      c.drawRect(door, Paint()..color = Color.lerp(const Color(0xFF00E676), Colors.white, pulse * 0.4)!);
      final tp = TextPainter(
        text: TextSpan(text: '▲', style: TextStyle(color: Colors.white.withValues(alpha: 0.6 + 0.4 * pulse), fontSize: s * 0.6)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(4.5 * s - tp.width / 2, 0.45 * s + math.sin(g.time * 5) * s * 0.08));
    } else {
      c.drawRect(door, Paint()..color = const Color(0xFF3E2723));
      for (var i = 0; i < 5; i++) {
        c.drawLine(Offset((3.75 + i * 0.37) * s, 0), Offset((3.75 + i * 0.37) * s, 0.35 * s),
            Paint()
              ..color = Colors.grey.shade500
              ..strokeWidth = s * 0.06);
      }
    }
    for (var y = 0; y < rgRows; y++) {
      for (var x = 0; x < rgCols; x++) {
        final ch = g.grid[y][x];
        final r = Rect.fromLTWH(x * s, y * s, s, s);
        if (ch == '#') {
          final rr = RRect.fromRectAndRadius(r.deflate(s * 0.04), Radius.circular(s * 0.18));
          c.drawRRect(rr.shift(Offset(0, s * 0.06)), Paint()..color = const Color(0x66000000));
          c.drawRRect(
              rr,
              Paint()
                ..shader = LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: g.chapter == 3 ? [const Color(0xFF6D4C41), const Color(0xFF3E2723)] : [const Color(0xFF9E9E9E), const Color(0xFF616161)],
                ).createShader(r));
          c.drawLine(r.topLeft + Offset(s * 0.25, s * 0.3), r.topLeft + Offset(s * 0.5, s * 0.45),
              Paint()
                ..color = const Color(0x55000000)
                ..strokeWidth = s * 0.04);
        } else if (ch == '~') {
          final lava = g.chapter == 3 || g.chapter == 4;
          c.drawRect(r, Paint()..color = lava ? const Color(0xFFE65100) : const Color(0xFF1E88E5));
          final wave = Paint()
            ..color = (lava ? const Color(0xFFFFCA28) : Colors.white).withValues(alpha: 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.04;
          for (var k = 0; k < 2; k++) {
            final p = Path();
            final yy = y * s + s * (0.35 + k * 0.35);
            for (var i = 0; i <= 8; i++) {
              final xx = x * s + i * s / 8;
              final dy = math.sin(g.time * 3 + i * 0.8 + x + k) * s * 0.05;
              if (i == 0) {
                p.moveTo(xx, yy + dy);
              } else {
                p.lineTo(xx, yy + dy);
              }
            }
            c.drawPath(p, wave);
          }
        }
      }
    }
  }

  void _zones(Canvas c, double s) {
    for (final z in g.zones) {
      final k = 1 - (z.t / z.total).clamp(0.0, 1.0);
      final o = Offset(z.x * s, z.y * s);
      c.drawCircle(o, z.r * s, Paint()..color = const Color(0x33FF1744));
      c.drawCircle(
          o,
          z.r * s,
          Paint()
            ..color = const Color(0xCCFF1744)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      c.drawCircle(o, z.r * s * k, Paint()..color = const Color(0x66FF5722));
    }
  }

  void _telegraphs(Canvas c, double s) {
    for (final e in g.en) {
      final o = Offset(e.x * s, e.y * s);
      final dashing = (e.type == 'w' || e.type == 'B2') && e.st == 1 || e.type == 'B5' && e.st == 5;
      if (dashing) {
        final end = o + Offset(math.cos(e.ang), math.sin(e.ang)) * s * 6;
        c.drawLine(o, end,
            Paint()
              ..color = const Color(0x55FF1744)
              ..strokeWidth = e.r * 2 * s
              ..strokeCap = StrokeCap.round);
      } else if (e.type == 'a' && e.st == 1) {
        final end = o + Offset(math.cos(e.ang), math.sin(e.ang)) * s * 12;
        c.drawLine(o, end,
            Paint()
              ..color = const Color(0x99FF1744)
              ..strokeWidth = 1.5);
      } else if (e.type == 'B1' && (e.st == 1 || e.st == 2)) {
        final t = Offset(e.tx * s, e.ty * s);
        c.drawCircle(t, e.r * s * 1.1, Paint()..color = const Color(0x44FF1744));
        c.drawCircle(
            t,
            e.r * s * 1.1,
            Paint()
              ..color = const Color(0xCCFF1744)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
      }
    }
  }

  void _enemy(Canvas c, RgEnemy e, double s) {
    var o = Offset(e.x * s, e.y * s);
    final sz = e.r * 2.9 * s;
    if (e.airborne) {
      final k = (e.t / 0.7).clamp(0.0, 1.0);
      c.drawOval(Rect.fromCenter(center: o, width: e.r * 2 * s, height: e.r * s * 0.8), Paint()..color = const Color(0x55000000));
      o = o.translate(0, -math.sin(k * math.pi) * s * 2.2);
    }
    if (e.windup) {
      final pulse = 0.5 + 0.5 * math.sin(g.time * 30);
      c.drawCircle(o, e.r * s * 1.35, Paint()..color = Color.fromRGBO(255, 40, 40, 0.18 + 0.25 * pulse));
    }
    c.save();
    c.translate(o.dx - sz / 2, o.dy - sz / 2 - sz * 0.08);
    MonsterPainter(
      kind: e.kind,
      band: rgChapterBands[g.chapter],
      boss: e.boss,
      flash: e.flash > 0 ? 0.8 : 0,
      t: g.time + e.seed,
    ).paint(c, Size(sz, sz));
    c.restore();
    if (e.frozeT > 0) {
      c.drawCircle(o, e.r * s * 1.1, Paint()..color = const Color(0x7781D4FA));
    } else if (e.slowT > 0) {
      c.drawCircle(
          o,
          e.r * s * 1.1,
          Paint()
            ..color = const Color(0x8881D4FA)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
    if (e.burnT > 0) c.drawCircle(o + Offset(e.r * s * 0.7, -e.r * s * 0.5), s * 0.07, Paint()..color = const Color(0xFFFF6D00));
    if (e.poison > 0) c.drawCircle(o + Offset(-e.r * s * 0.7, -e.r * s * 0.5), s * 0.07, Paint()..color = const Color(0xFF76FF03));
    if (!e.boss) {
      final w = e.r * 2.2 * s;
      final r = Rect.fromLTWH(o.dx - w / 2, o.dy - e.r * s * 1.55, w, s * 0.09);
      c.drawRect(r, Paint()..color = Colors.black54);
      c.drawRect(Rect.fromLTWH(r.left, r.top, w * (e.hp / e.maxHp).clamp(0.0, 1.0), r.height), Paint()..color = const Color(0xFFFF5252));
    }
  }

  void _player(Canvas c, double s) {
    final o = Offset(g.px * s, g.py * s);
    final r = g.pr * s;
    // 旋轉刀刃
    final orbs = 2 * g.st.lv('orb');
    for (var i = 0; i < orbs; i++) {
      final a = g.orbAng + 2 * math.pi * i / orbs;
      final p = o + Offset(math.cos(a), math.sin(a)) * 1.15 * s;
      c.save();
      c.translate(p.dx, p.dy);
      c.rotate(g.time * 12);
      final blade = Path()
        ..moveTo(0, -s * 0.2)
        ..lineTo(s * 0.07, 0)
        ..lineTo(0, s * 0.2)
        ..lineTo(-s * 0.07, 0)
        ..close();
      c.drawPath(blade, Paint()..color = const Color(0xFFE0F7FA));
      c.rotate(math.pi / 2);
      c.drawPath(blade, Paint()..color = const Color(0xFFB2EBF2));
      c.restore();
    }
    if (g.inv > 0 && (g.time * 20).floor().isOdd && g.phase == RgPhase.play) return;
    c.drawOval(Rect.fromCenter(center: o + Offset(0, r * 0.9), width: r * 2, height: r * 0.7), Paint()..color = const Color(0x55000000));
    // 披風身體
    c.drawCircle(o, r, Paint()..color = const Color(0xFF2E7D32));
    c.drawCircle(o + Offset(0, -r * 0.15), r * 0.62, Paint()..color = const Color(0xFFFFCC80));
    // 帽子
    final hat = Path()
      ..moveTo(o.dx - r * 0.7, o.dy - r * 0.35)
      ..lineTo(o.dx + r * 0.7, o.dy - r * 0.35)
      ..lineTo(o.dx + r * 0.1, o.dy - r * 1.35)
      ..close();
    c.drawPath(hat, Paint()..color = const Color(0xFF1B5E20));
    c.drawCircle(o + Offset(r * 0.1, -r * 1.35), r * 0.12, Paint()..color = const Color(0xFFFF5252));
    // 眼睛看向面向
    final eye = Offset(g.faceX, g.faceY) * r * 0.18;
    c.drawCircle(o + Offset(-r * 0.22, -r * 0.12) + eye, r * 0.09, Paint()..color = Colors.black);
    c.drawCircle(o + Offset(r * 0.22, -r * 0.12) + eye, r * 0.09, Paint()..color = Colors.black);
    // 弓
    final a = math.atan2(g.faceY, g.faceX);
    c.save();
    c.translate(o.dx, o.dy);
    c.rotate(a);
    c.drawArc(Rect.fromCircle(center: Offset(r * 0.7, 0), radius: r * 0.75), -1.2, 2.4, false,
        Paint()
          ..color = const Color(0xFF8D6E63)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.18
          ..strokeCap = StrokeCap.round);
    final ex = r * 0.7 + math.cos(1.2) * r * 0.75, ey = math.sin(1.2) * r * 0.75;
    c.drawLine(Offset(ex, -ey), Offset(ex, ey), Paint()
      ..color = Colors.white70
      ..strokeWidth = 1);
    c.restore();
    // 血條
    final w = s * 0.9;
    final hb = Rect.fromLTWH(o.dx - w / 2, o.dy + r * 1.35, w, s * 0.1);
    c.drawRect(hb, Paint()..color = Colors.black54);
    c.drawRect(Rect.fromLTWH(hb.left, hb.top, w * (g.st.hp / g.st.maxHp).clamp(0.0, 1.0), hb.height),
        Paint()..color = const Color(0xFF00E676));
  }

  void _bullets(Canvas c, double s) {
    for (final b in g.bl) {
      final o = Offset(b.x * s, b.y * s);
      if (b.mine) {
        final sp = math.sqrt(b.vx * b.vx + b.vy * b.vy);
        final d = Offset(b.vx / sp, b.vy / sp) * s * 0.38;
        c.drawLine(o - d, o,
            Paint()
              ..color = const Color(0xFFFFF59D)
              ..strokeWidth = s * 0.07
              ..strokeCap = StrokeCap.round);
        c.drawCircle(o, s * 0.05, Paint()..color = Colors.white);
        continue;
      }
      final r = b.r * s;
      final (core, glow) = switch (b.style) {
        2 => (const Color(0xFFEA80FC), const Color(0x88AA00FF)),
        3 => (const Color(0xFF8D6E63), const Color(0x88FF6D00)),
        4 => (const Color(0xFFFFE082), const Color(0x99FF3D00)),
        _ => (const Color(0xFFFF8A80), const Color(0x88FF1744)),
      };
      c.drawCircle(o, r * 1.6, Paint()..color = glow);
      c.drawCircle(o, r, Paint()..color = core);
      c.drawCircle(o - Offset(r * 0.3, r * 0.3), r * 0.35, Paint()..color = Colors.white70);
    }
  }

  void _floats(Canvas c, double s) {
    for (final f in g.floats) {
      final a = (1 - f.t / 0.9).clamp(0.0, 1.0);
      final tp = TextPainter(
        text: TextSpan(
          text: f.s,
          style: TextStyle(
            color: Color(f.color).withValues(alpha: a),
            fontSize: s * (f.big ? 0.42 : 0.3),
            fontWeight: FontWeight.bold,
            shadows: const [Shadow(blurRadius: 2)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(f.x * s - tp.width / 2, f.y * s - tp.height / 2));
    }
  }

  void _heart(Canvas c, Offset o, double r) {
    final bob = math.sin(g.time * 4) * r * 0.2;
    final p = Path()
      ..moveTo(o.dx, o.dy + r * 0.9 + bob)
      ..cubicTo(o.dx - r * 1.6, o.dy - r * 0.2 + bob, o.dx - r * 0.6, o.dy - r * 1.2 + bob, o.dx, o.dy - r * 0.4 + bob)
      ..cubicTo(o.dx + r * 0.6, o.dy - r * 1.2 + bob, o.dx + r * 1.6, o.dy - r * 0.2 + bob, o.dx, o.dy + r * 0.9 + bob);
    c.drawPath(p, Paint()..color = const Color(0xFFFF1744));
  }

  void _joystick(Canvas c) {
    final (o, n) = joy();
    if (o == null || n == null) return;
    c.drawCircle(o, 40, Paint()..color = const Color(0x22FFFFFF));
    c.drawCircle(
        o,
        40,
        Paint()
          ..color = const Color(0x55FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    var d = n - o;
    if (d.distance > 40) d = d / d.distance * 40;
    c.drawCircle(o + d, 16, Paint()..color = const Color(0x88FFFFFF));
  }

  @override
  bool shouldRepaint(covariant _ArenaPainter old) => true;
}
