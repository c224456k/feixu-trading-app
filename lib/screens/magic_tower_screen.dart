import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/battle_stage.dart';
import '../widgets/monster_art.dart';
import 'magic_tower_logic.dart';

// 魔塔（5 層試玩版）：格子地圖解謎。規則在 magic_tower_logic.dart，這裡負責畫地圖、操作，
// 撞到怪物時用百層塔的戰鬥舞台（BattleStage）播放戰鬥。單機、不連伺服器、不影響遊戲幣。

class MagicTowerScreen extends StatefulWidget {
  const MagicTowerScreen({super.key});

  @override
  State<MagicTowerScreen> createState() => _MagicTowerScreenState();
}

class _MagicTowerScreenState extends State<MagicTowerScreen> {
  var _g = MtGame();
  final _focus = FocusNode();
  String _toast = '';
  Timer? _toastTimer;
  Timer? _walkTimer;

  // 戰鬥中
  ({int r, int c, MtMonster m, List<Map<String, dynamic>> log, int hp, int atk, int def})? _battle;
  int _battleKey = 0;

  @override
  void dispose() {
    _toastTimer?.cancel();
    _walkTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _say(String s) {
    _toastTimer?.cancel();
    setState(() => _toast = s);
    _toastTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _toast = '');
    });
  }

  /// 往一個方向走一步；回傳是否還能繼續（自動走路用）。
  bool _step(int dr, int dc) {
    if (_battle != null || _g.won) return false;
    final ev = _g.move(dr, dc);
    if (ev.startsWith('blocked:')) {
      final why = ev.substring(8);
      if (why != '牆') _say(why);
      return false;
    }
    if (ev.startsWith('fight:')) {
      final p = ev.split(':');
      final m = mtMonsters[p[1]]!;
      final nr = int.parse(p[2]), nc = int.parse(p[3]);
      setState(() {
        _battle = (r: nr, c: nc, m: m, log: mtBattleLog(_g.hp, _g.atk, _g.def, m), hp: _g.hp, atk: _g.atk, def: _g.def);
        _battleKey++;
      });
      return false;
    }
    setState(() {});
    if (ev.startsWith('item:')) {
      _say('獲得 ${ev.substring(5)}');
      HapticFeedback.selectionClick();
    } else if (ev == 'stairs') {
      _say('第 ${_g.floor + 1} 層・${mtFloorNames[_g.floor]}');
      return false;
    } else if (ev == 'door') {
      HapticFeedback.lightImpact();
    }
    return true;
  }

  void _onBattleDone(int hpAfter, bool won) {
    final b = _battle;
    if (b == null) return;
    setState(() {
      _battle = null;
      _g.resolveFight(b.r, b.c, hpAfter);
    });
    if (_g.won) {
      Future.delayed(const Duration(milliseconds: 300), _showWin);
    }
  }

  void _showWin() {
    if (!mounted) return;
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
              title: const Text('🎉 通關！'),
              content: Text('你擊敗了魔王，登上塔頂！\n\n剩餘血量 ${_g.hp}\n攻擊 ${_g.atk}／防禦 ${_g.def}\n總步數 ${_g.steps}'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c), child: const Text('看看地圖')),
                FilledButton(
                    onPressed: () {
                      Navigator.pop(c);
                      _restart();
                    },
                    child: const Text('再玩一次')),
              ],
            ));
  }

  void _restart() {
    _walkTimer?.cancel();
    setState(() {
      _g = MtGame();
      _battle = null;
    });
  }

  // ---- 點地圖自動走路：BFS 找路（只走空地/道具/樓梯，終點可以是門或怪物）
  void _tapCell(int tr, int tc) {
    if (_battle != null || _g.won) return;
    _walkTimer?.cancel();
    final f = _g.floor;
    if (tr == _g.r && tc == _g.c) return;
    bool passable(int r, int c) {
      final t = _g.at(f, r, c);
      return t == '.' || mtItems.containsKey(t) || t == 'U' || t == 'D';
    }

    final prev = <int, int>{};
    final q = Queue<int>()..add(_g.r * mtSize + _g.c);
    prev[_g.r * mtSize + _g.c] = -1;
    int? found;
    while (q.isNotEmpty) {
      final p = q.removeFirst();
      final r = p ~/ mtSize, c = p % mtSize;
      if (r == tr && c == tc) {
        found = p;
        break;
      }
      for (final d in const [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        final nr = r + d[0], nc = c + d[1];
        if (nr < 0 || nc < 0 || nr >= mtSize || nc >= mtSize) continue;
        final id = nr * mtSize + nc;
        if (prev.containsKey(id)) continue;
        final isTarget = nr == tr && nc == tc;
        if (!isTarget && !passable(nr, nc)) continue;
        if (isTarget && _g.at(f, nr, nc) == '#') continue;
        prev[id] = p;
        q.add(id);
      }
    }
    if (found == null) {
      _say('走不到那裡');
      return;
    }
    final path = <int>[];
    for (var p = found; p != -1; p = prev[p]!) {
      path.add(p);
    }
    path.removeLast(); // 起點
    final steps = path.reversed.toList();
    var i = 0;
    _walkTimer = Timer.periodic(const Duration(milliseconds: 70), (t) {
      if (!mounted || i >= steps.length) {
        t.cancel();
        return;
      }
      final p = steps[i++];
      final ok = _step(p ~/ mtSize - _g.r, p % mtSize - _g.c);
      if (!ok) t.cancel();
    });
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    _walkTimer?.cancel();
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyW) {
      _step(-1, 0);
    } else if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.keyS) {
      _step(1, 0);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA) {
      _step(0, -1);
    } else if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyD) {
      _step(0, 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _help() {
    showDialog(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('魔塔玩法'),
              content: const SingleChildScrollView(
                  child: Text('目標：爬到第 5 層，打倒魔王。\n\n'
                      '• 方向鍵／WASD 或畫面按鈕移動；點地圖上的格子會自動走過去。\n'
                      '• 撞到怪物就戰鬥：你先出手，雙方輪流攻擊，傷害＝攻擊−對方防禦。怪物頭上的數字是「打贏會損失的血量」，「？」是現在打不贏。\n'
                      '• 黃／藍／紅鑰匙開同色的門，鑰匙是有限的，想清楚再開。\n'
                      '• 紅寶石加攻擊、藍寶石加防禦、血瓶補血。部分怪物防禦很高，要先找到更強的武器。\n'
                      '• 沒有回血的地方，血量就是你的本錢：先撿道具再打怪，通常會省很多血。\n'
                      '• 可以隨時上下樓回頭找漏掉的東西。')),
              actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('知道了'))],
            ));
  }

  @override
  Widget build(BuildContext context) {
    final b = _battle;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: const Color(0xFF14121C),
        appBar: AppBar(
          title: Text('🗼 魔塔・第 ${_g.floor + 1} 層 ${mtFloorNames[_g.floor]}'),
          backgroundColor: const Color(0xFF241F33),
          actions: [
            IconButton(onPressed: _help, icon: const Icon(Icons.help_outline), tooltip: '玩法'),
            IconButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                            title: const Text('重新開始？'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                              TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('重來')),
                            ],
                          ));
                  if (ok == true) _restart();
                },
                icon: const Icon(Icons.refresh),
                tooltip: '重來'),
          ],
        ),
        body: SafeArea(
          child: Column(children: [
            _hud(),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(children: [
                    LayoutBuilder(builder: (context, box) {
                      final cell = box.maxWidth / mtSize;
                      return GestureDetector(
                        onTapUp: (d) => _tapCell((d.localPosition.dy / cell).floor().clamp(0, mtSize - 1), (d.localPosition.dx / cell).floor().clamp(0, mtSize - 1)),
                        child: CustomPaint(size: box.biggest, painter: _MapPainter(_g)),
                      );
                    }),
                    if (_toast.isNotEmpty)
                      Positioned(
                          left: 0,
                          right: 0,
                          top: 6,
                          child: Center(
                              child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(14)),
                            child: Text(_toast, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          ))),
                    if (b != null)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.78),
                          alignment: Alignment.center,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: BattleStage(
                              key: ValueKey(_battleKey),
                              monsters: [
                                {'name': b.m.name, 'kind': b.m.kind, 'band': mtBands[_g.floor], 'boss': b.m.boss, 'hp': b.m.hp, 'max_hp': b.m.hp}
                              ],
                              log: b.log,
                              heroHp: b.hp,
                              heroMax: math.max(b.hp, mtStartHp),
                              band: mtBands[_g.floor],
                              speed: (b.log.length / 8).clamp(1.5, 4.0),
                              onDone: _onBattleDone,
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
            _pad(),
          ]),
        ),
      ),
    );
  }

  Widget _stat(String icon, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(icon, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 3),
          Text(v, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color ?? Colors.white)),
        ]),
      );

  Widget _hud() {
    return Container(
      color: const Color(0xFF1C1829),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Wrap(alignment: WrapAlignment.center, children: [
        _stat('❤️', '${_g.hp}', color: const Color(0xFFFF8A80)),
        _stat('⚔️', '${_g.atk}'),
        _stat('🛡️', '${_g.def}'),
        _stat('🟡', '${_g.ky}', color: const Color(0xFFFFD54F)),
        _stat('🔵', '${_g.kb}', color: const Color(0xFF64B5F6)),
        _stat('🔴', '${_g.kr}', color: const Color(0xFFE57373)),
      ]),
    );
  }

  Widget _padBtn(IconData icon, int dr, int dc) {
    return GestureDetector(
      onTap: () {
        _walkTimer?.cancel();
        _step(dr, dc);
      },
      child: Container(
        width: 62,
        height: 52,
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white24)),
        child: Icon(icon, size: 30, color: Colors.white),
      ),
    );
  }

  Widget _pad() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _padBtn(Icons.keyboard_arrow_up, -1, 0),
        Row(mainAxisSize: MainAxisSize.min, children: [_padBtn(Icons.keyboard_arrow_left, 0, -1), _padBtn(Icons.keyboard_arrow_down, 1, 0), _padBtn(Icons.keyboard_arrow_right, 0, 1)]),
      ]),
    );
  }
}

// ==================================================================== 地圖繪製
class _MapPainter extends CustomPainter {
  final MtGame g;
  _MapPainter(this.g);

  static const _wallA = Color(0xFF4A4458), _wallB = Color(0xFF383245), _floorA = Color(0xFF2A2536), _floorB = Color(0xFF302B3F);
  static const _doorCol = {'Y': Color(0xFFFFC107), 'B': Color(0xFF42A5F5), 'R': Color(0xFFEF5350)};

  @override
  void paint(Canvas canvas, Size size) {
    final cs = size.width / mtSize;
    final f = g.floor;
    for (var r = 0; r < mtSize; r++) {
      for (var c = 0; c < mtSize; c++) {
        final rect = Rect.fromLTWH(c * cs, r * cs, cs, cs);
        final t = g.at(f, r, c);
        if (t == '#') {
          canvas.drawRect(rect, Paint()..color = (r + c).isEven ? _wallA : _wallB);
          canvas.drawRect(rect.deflate(cs * 0.04), Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.black26);
          continue;
        }
        canvas.drawRect(rect, Paint()..color = (r + c).isEven ? _floorA : _floorB);
        _tile(canvas, t, rect, cs);
      }
    }
    // 勇者
    final hr = Rect.fromLTWH(g.c * cs, g.r * cs, cs, cs);
    canvas.drawOval(Rect.fromCenter(center: hr.bottomCenter.translate(0, -cs * 0.08), width: cs * 0.6, height: cs * 0.16), Paint()..color = Colors.black45);
    _hero(canvas, hr, cs);
  }

  void _hero(Canvas canvas, Rect r, double cs) {
    final p = Paint();
    final cx = r.center.dx;
    // 身體（藍披風）、頭、劍
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, r.center.dy + cs * 0.12), width: cs * 0.42, height: cs * 0.44), Radius.circular(cs * 0.1)), p..color = const Color(0xFF3F6FD8));
    canvas.drawCircle(Offset(cx, r.center.dy - cs * 0.17), cs * 0.17, p..color = const Color(0xFFF3CFA7));
    canvas.drawArc(Rect.fromCenter(center: Offset(cx, r.center.dy - cs * 0.2), width: cs * 0.38, height: cs * 0.34), math.pi, math.pi, true, p..color = const Color(0xFFB0BEC5));
    canvas.drawRect(Rect.fromCenter(center: Offset(cx + cs * 0.3, r.center.dy), width: cs * 0.07, height: cs * 0.55), p..color = const Color(0xFFECEFF1));
    canvas.drawRect(Rect.fromCenter(center: Offset(cx + cs * 0.3, r.center.dy + cs * 0.2), width: cs * 0.2, height: cs * 0.06), p..color = const Color(0xFFFFB300));
  }

  void _tile(Canvas canvas, String t, Rect r, double cs) {
    final p = Paint();
    final cx = r.center.dx, cy = r.center.dy;
    final door = _doorCol[t];
    if (door != null) {
      canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(cs * 0.08), Radius.circular(cs * 0.1)), p..color = door.withValues(alpha: 0.85));
      canvas.drawRect(Rect.fromCenter(center: Offset(cx, cy), width: cs * 0.06, height: cs * 0.7), p..color = Colors.black38);
      canvas.drawCircle(Offset(cx + cs * 0.14, cy), cs * 0.06, p..color = Colors.white70);
      return;
    }
    if (t == 'U' || t == 'D') {
      canvas.drawRect(r.deflate(cs * 0.1), p..color = const Color(0xFF1B1726));
      for (var i = 0; i < 4; i++) {
        final w = cs * (0.62 - i * 0.12);
        final y = t == 'U' ? r.bottom - cs * 0.18 - i * cs * 0.16 : r.top + cs * 0.18 + i * cs * 0.16;
        canvas.drawRect(Rect.fromCenter(center: Offset(cx, y), width: w, height: cs * 0.1), Paint()..color = const Color(0xFFB39DDB));
      }
      _text(canvas, t == 'U' ? '▲' : '▼', Offset(cx, cy), cs * 0.34, Colors.white);
      return;
    }
    final m = mtMonsters[t];
    if (m != null) {
      final sz = cs * (m.boss ? 1.0 : 0.92);
      canvas.save();
      canvas.translate(cx - sz / 2, r.bottom - sz - cs * 0.02);
      MonsterPainter(kind: m.kind, band: mtBands[g.floor], boss: m.boss).paint(canvas, Size(sz, sz));
      canvas.restore();
      final loss = mtLoss(g.hp, g.atk, g.def, m);
      final txt = loss == null ? '？' : (loss == 0 ? '0' : '-$loss');
      final col = loss == null ? const Color(0xFFFF5252) : (loss == 0 ? const Color(0xFF69F0AE) : (loss < g.hp * 0.25 ? Colors.white : const Color(0xFFFFB74D)));
      _text(canvas, txt, Offset(cx, r.bottom - cs * 0.14), cs * 0.26, col, outline: true);
      return;
    }
    final it = mtItems[t];
    if (it != null) {
      _item(canvas, t, r, cs);
    }
  }

  void _item(Canvas canvas, String t, Rect r, double cs) {
    final p = Paint();
    final cx = r.center.dx, cy = r.center.dy;
    switch (t) {
      case 'y':
      case 'b':
      case 'r':
        final col = t == 'y' ? const Color(0xFFFFC107) : (t == 'b' ? const Color(0xFF42A5F5) : const Color(0xFFEF5350));
        canvas.drawCircle(Offset(cx - cs * 0.1, cy - cs * 0.12), cs * 0.13, p..color = col);
        canvas.drawCircle(Offset(cx - cs * 0.1, cy - cs * 0.12), cs * 0.05, Paint()..color = _floorA);
        canvas.drawRect(Rect.fromCenter(center: Offset(cx + cs * 0.02, cy + cs * 0.06), width: cs * 0.1, height: cs * 0.42), Paint()..color = col);
        canvas.drawRect(Rect.fromLTWH(cx + cs * 0.02, cy + cs * 0.12, cs * 0.18, cs * 0.07), Paint()..color = col);
        canvas.drawRect(Rect.fromLTWH(cx + cs * 0.02, cy + cs * 0.24, cs * 0.14, cs * 0.07), Paint()..color = col);
      case 'h':
      case 'H':
        final big = t == 'H';
        final s = cs * (big ? 0.62 : 0.46);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, cy + cs * 0.06), width: s * 0.8, height: s * 0.8), Radius.circular(s * 0.3)), p..color = big ? const Color(0xFFE91E63) : const Color(0xFFFF7043));
        canvas.drawRect(Rect.fromCenter(center: Offset(cx, cy - s * 0.42), width: s * 0.32, height: s * 0.34), Paint()..color = const Color(0xFFCFD8DC));
        canvas.drawOval(Rect.fromCenter(center: Offset(cx - s * 0.14, cy), width: s * 0.2, height: s * 0.3), Paint()..color = Colors.white38);
      case 'a':
      case 'd':
        final col = t == 'a' ? const Color(0xFFFF5252) : const Color(0xFF448AFF);
        final s = cs * 0.3;
        final path = Path()
          ..moveTo(cx, cy - s)
          ..lineTo(cx + s, cy - s * 0.15)
          ..lineTo(cx + s * 0.6, cy + s)
          ..lineTo(cx - s * 0.6, cy + s)
          ..lineTo(cx - s, cy - s * 0.15)
          ..close();
        canvas.drawPath(path, p..color = col);
        canvas.drawPath(Path()..moveTo(cx, cy - s)..lineTo(cx - s * 0.2, cy)..lineTo(cx - s, cy - s * 0.15)..close(), Paint()..color = Colors.white38);
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white70);
      case 'w':
        canvas.save();
        canvas.translate(cx, cy);
        canvas.rotate(math.pi / 4);
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: cs * 0.1, height: cs * 0.7), p..color = const Color(0xFFE3F2FD));
        canvas.drawRect(Rect.fromCenter(center: Offset(0, cs * 0.18), width: cs * 0.3, height: cs * 0.07), Paint()..color = const Color(0xFFFFB300));
        canvas.drawRect(Rect.fromCenter(center: Offset(0, cs * 0.28), width: cs * 0.08, height: cs * 0.14), Paint()..color = const Color(0xFF6D4C41));
        canvas.restore();
        _text(canvas, '★', Offset(cx + cs * 0.25, cy - cs * 0.22), cs * 0.2, const Color(0xFFFFEB3B));
      case 'x':
        final path = Path()
          ..moveTo(cx - cs * 0.3, cy - cs * 0.3)
          ..lineTo(cx + cs * 0.3, cy - cs * 0.3)
          ..lineTo(cx + cs * 0.3, cy + cs * 0.05)
          ..quadraticBezierTo(cx + cs * 0.3, cy + cs * 0.3, cx, cy + cs * 0.38)
          ..quadraticBezierTo(cx - cs * 0.3, cy + cs * 0.3, cx - cs * 0.3, cy + cs * 0.05)
          ..close();
        canvas.drawPath(path, p..color = const Color(0xFF90A4AE));
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFFFD54F));
        canvas.drawRect(Rect.fromCenter(center: Offset(cx, cy), width: cs * 0.08, height: cs * 0.5), Paint()..color = const Color(0xFFFFD54F));
        _text(canvas, '★', Offset(cx + cs * 0.25, cy - cs * 0.22), cs * 0.2, const Color(0xFFFFEB3B));
    }
  }

  void _text(Canvas canvas, String s, Offset center, double size, Color color, {bool outline = false}) {
    TextPainter mk(Paint? fg, Color? col) => TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: size, fontWeight: FontWeight.w900, color: col, foreground: fg)), textDirection: TextDirection.ltr)
      ..layout();
    if (outline) {
      final o = mk(Paint()..style = PaintingStyle.stroke..strokeWidth = size * 0.22..color = Colors.black, null);
      o.paint(canvas, Offset(center.dx - o.width / 2, center.dy - o.height / 2));
    }
    final t = mk(null, color);
    t.paint(canvas, Offset(center.dx - t.width / 2, center.dy - t.height / 2));
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) => true;
}
