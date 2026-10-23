import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/battle_stage.dart';
import '../widgets/monster_art.dart';
import 'magic_tower_logic.dart';

// 魔塔（20 層）：格子地圖解謎。規則在 magic_tower_logic.dart，這裡負責畫地圖、操作，
// 撞到怪物時用百層塔的戰鬥舞台（BattleStage）播放戰鬥。單機、不連伺服器、不影響遊戲幣。

class MagicTowerScreen extends StatefulWidget {
  const MagicTowerScreen({super.key});

  @override
  State<MagicTowerScreen> createState() => _MagicTowerScreenState();
}

const _keyColor = {'y': Color(0xFFFFC107), 'b': Color(0xFF90CAF9), 'r': Color(0xFFE040FB)};
const _keyName = {'y': '金鑰匙', 'b': '銀鑰匙', 'r': '魔鑰匙'};

class _KeyIconPainter extends CustomPainter {
  final Color color;
  _KeyIconPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    paintKey(canvas, Rect.fromLTWH(0, 0, size.width, size.height), color);
  }

  @override
  bool shouldRepaint(covariant _KeyIconPainter old) => old.color != color;
}

/// 鑰匙圖示（地圖和 HUD 共用）：斜放、帶外框，比較顯眼。
void paintKey(Canvas canvas, Rect r, Color col) {
  final cs = r.width;
  canvas.save();
  canvas.translate(r.center.dx, r.center.dy);
  canvas.rotate(-math.pi / 4);
  final dark = Paint()..color = Colors.black87;
  final fill = Paint()..color = col;
  // 柄與齒
  canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(0, cs * 0.1), width: cs * 0.2, height: cs * 0.62), Radius.circular(cs * 0.04)), dark);
  canvas.drawRect(Rect.fromLTWH(cs * 0.0, cs * 0.18, cs * 0.26, cs * 0.12), dark);
  canvas.drawRect(Rect.fromLTWH(cs * 0.0, cs * 0.34, cs * 0.2, cs * 0.12), dark);
  canvas.drawRect(Rect.fromCenter(center: Offset(0, cs * 0.1), width: cs * 0.1, height: cs * 0.56), fill);
  canvas.drawRect(Rect.fromLTWH(cs * 0.0, cs * 0.2, cs * 0.2, cs * 0.07), fill);
  canvas.drawRect(Rect.fromLTWH(cs * 0.0, cs * 0.36, cs * 0.14, cs * 0.07), fill);
  // 圓環
  canvas.drawCircle(Offset(0, -cs * 0.26), cs * 0.2, dark);
  canvas.drawCircle(Offset(0, -cs * 0.26), cs * 0.15, fill);
  canvas.drawCircle(Offset(0, -cs * 0.26), cs * 0.07, Paint()..color = const Color(0xFF241F33));
  canvas.restore();
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

  static const _saveKey = 'magic_tower_save_v5';

  @override
  void initState() {
    super.initState();
    _load();
  }

  // 網頁重新整理、版本更新都會重開 App，所以每走一步就存檔，進來時接著玩。
  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_saveKey);
      if (raw == null) return;
      final g = MtGame.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (g == null || g.won || !mounted) return;
      setState(() => _g = g);
      _say('接續上次的進度（第 ${g.floor + 1} 層）');
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (_g.won) {
        await sp.remove(_saveKey);
      } else {
        await sp.setString(_saveKey, jsonEncode(_g.toJson()));
      }
    } catch (_) {}
  }

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
    _save();
    if (ev == 'shop') {
      _walkTimer?.cancel();
      _openShop();
      return false;
    }
    if (ev.startsWith('fight:')) {
      final p = ev.split(':');
      final m = mtMonsterAt(_g.floor, p[1])!;
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
    var up = 0;
    setState(() {
      _battle = null;
      up = _g.resolveFight(b.r, b.c, hpAfter);
    });
    _save();
    if (b.m.gold > 0) {
      _say(up > 0 ? '升級！Lv.${_g.lv}　攻+${mtLevelAtk * up} 防+${mtLevelDef * up} 血+${mtLevelHp * up}　💰+${b.m.gold}' : '💰 +${b.m.gold}　經驗 +${b.m.exp}');
      if (up > 0) HapticFeedback.mediumImpact();
    }
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
    _save();
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

  void _openShop() {
    showDialog(
        context: context,
        builder: (c) => StatefulBuilder(
            builder: (c, setD) => AlertDialog(
                  backgroundColor: const Color(0xFF241F33),
                  title: Row(children: [
                    const Text('🧙 魔塔商人'),
                    const Spacer(),
                    Text('💰 ${_g.gold}', style: const TextStyle(color: Color(0xFFFFD54F), fontWeight: FontWeight.bold)),
                  ]),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('金幣只能在魔塔裡花。每位商人只賣你一樣，想清楚再買！', style: TextStyle(color: Colors.white60, fontSize: 12)),
                    const SizedBox(height: 8),
                    for (final o in mtShopAt(_g.floor))
                      ListTile(
                        dense: true,
                        title: Text(o.name),
                        trailing: FilledButton(
                          onPressed: _g.gold >= o.price
                              ? () {
                                  _g.buy(o);
                                  _save();
                                  Navigator.pop(c);
                                  setState(() {});
                                  _say('買了 ${o.name}，商人收攤走了');
                                }
                              : null,
                          child: Text('💰 ${o.price}'),
                        ),
                      ),
                  ]),
                  actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('離開'))],
                )));
  }

  void _help() {
    showDialog(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('魔塔玩法'),
              content: const SingleChildScrollView(
                  child: Text('目標：爬到第 20 層，打倒魔王。\n\n'
                      '• 淺色磚地是可以走的路，深色磚牆走不過去。方向鍵／WASD 或畫面按鈕移動；點地圖上的格子會自動走過去。\n'
                      '• 撞到怪物就戰鬥：你先出手，雙方輪流攻擊，傷害＝攻擊−對方防禦。怪物腳下的數字是「打贏會損失的血量」，「？」是現在打不贏。\n'
                      '• 打怪會得到經驗和金幣。經驗滿了自動升級，每級 +3 攻擊、+3 防禦、+80 血（當場補上）。\n'
                      '• 金幣只能在魔塔裡花：找 🧙 商人（第 3、7、11、15、19 層）買血量、攻防或鑰匙（每位商人只能買一樣），越深的樓層賣得越貴。\n'
                      '• 金鑰匙開金色的門、銀鑰匙開銀色的門、魔鑰匙開紫紅色的門，鑰匙有限，想清楚再開。\n'
                      '• 紅寶石加攻擊、藍寶石加防禦、血瓶補血。有些怪物防禦很高，要先找到更強的武器或升級。\n'
                      '• 每兩層（第 2、4、6…18 層）有一隻守門員，比一般怪強很多，打贏才能上樓。\n• 可以隨時上下樓回頭找漏掉的東西。進度會自動存檔，重新整理網頁也能接著玩。')),
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
                          key: const ValueKey('mt-toast'),
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
                        key: const ValueKey('mt-battle'),
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
                              heroMax: b.hp,
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
          Text(icon, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 3),
          Text(v, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color ?? Colors.white)),
        ]),
      );

  Widget _keyStat(String code, int n) {
    final col = _keyColor[code]!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 22, height: 22, child: CustomPaint(painter: _KeyIconPainter(col))),
        const SizedBox(width: 3),
        Text('${_keyName[code]} ×$n', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: col)),
      ]),
    );
  }

  Widget _hud() {
    final lv = _g.lv;
    final lo = mtExpNeed(lv);
    final hi = mtExpNeed(lv + 1);
    final ratio = ((_g.exp - lo) / (hi - lo)).clamp(0.0, 1.0);
    return Container(
      color: const Color(0xFF1C1829),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Wrap(alignment: WrapAlignment.center, children: [
          _stat('🎖️', 'Lv.$lv', color: const Color(0xFFFFE082)),
          _stat('❤️', '${_g.hp}', color: const Color(0xFFFF8A80)),
          _stat('⚔️', '${_g.atk}'),
          _stat('🛡️', '${_g.def}'),
          _stat('💰', '${_g.gold}', color: const Color(0xFFFFD54F)),
        ]),
        const SizedBox(height: 3),
        Wrap(alignment: WrapAlignment.center, children: [_keyStat('y', _g.ky), _keyStat('b', _g.kb), _keyStat('r', _g.kr)]),
        const SizedBox(height: 4),
        Row(children: [
          Text('經驗 ${_g.exp}/$hi', style: const TextStyle(fontSize: 11, color: Colors.white60)),
          const SizedBox(width: 8),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: ratio, minHeight: 6, backgroundColor: Colors.white12, color: const Color(0xFF7C4DFF)))),
        ]),
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

  static const _floorA = Color(0xFFB9AE96), _floorB = Color(0xFFADA189); // 淺色磚地＝可以走
  static const _doorCol = {'Y': Color(0xFFFFC107), 'B': Color(0xFF90CAF9), 'R': Color(0xFFE040FB)};

  @override
  void paint(Canvas canvas, Size size) {
    final cs = size.width / mtSize;
    final f = g.floor;
    for (var r = 0; r < mtSize; r++) {
      for (var c = 0; c < mtSize; c++) {
        final rect = Rect.fromLTWH(c * cs, r * cs, cs, cs);
        final t = g.at(f, r, c);
        if (t == '#') {
          _wall(canvas, rect, cs, r, c);
          continue;
        }
        canvas.drawRect(rect, Paint()..color = (r + c).isEven ? _floorA : _floorB);
        canvas.drawRect(rect, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = const Color(0x33000000));
        _tile(canvas, t, rect, cs);
      }
    }
    // 勇者
    final hr = Rect.fromLTWH(g.c * cs, g.r * cs, cs, cs);
    canvas.drawOval(Rect.fromCenter(center: hr.bottomCenter.translate(0, -cs * 0.08), width: cs * 0.6, height: cs * 0.16), Paint()..color = Colors.black45);
    _hero(canvas, hr, cs);
  }

  // 深色磚牆：兩排錯開的磚塊 + 上緣高光，跟淺色地板明顯分開
  void _wall(Canvas canvas, Rect rect, double cs, int r, int c) {
    canvas.drawRect(rect, Paint()..color = const Color(0xFF2B2438));
    final line = Paint()
      ..color = const Color(0xFF16121F)
      ..strokeWidth = math.max(1.0, cs * 0.04);
    final h = cs / 3;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(rect.left, rect.top + h * i), Offset(rect.right, rect.top + h * i), line);
    }
    for (var i = 0; i < 3; i++) {
      final off = (i + r) % 2 == 0 ? cs * 0.5 : cs * 0.25;
      canvas.drawLine(Offset(rect.left + off, rect.top + h * i), Offset(rect.left + off, rect.top + h * (i + 1)), line);
    }
    canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, cs, cs * 0.06), Paint()..color = const Color(0xFF4E4566));
  }

  void _hero(Canvas canvas, Rect r, double cs) {
    final cx = r.center.dx, base = r.bottom - cs * 0.04;
    final f = g.facing.toDouble(); // 面向
    final p = Paint();
    final ol = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, cs * 0.04)
      ..color = const Color(0xFF2A1B10);
    // 披風（在身體後面，往身後飄）
    final cape = Path()
      ..moveTo(cx - f * cs * 0.1, base - cs * 0.5)
      ..quadraticBezierTo(cx - f * cs * 0.42, base - cs * 0.3, cx - f * cs * 0.34, base - cs * 0.06)
      ..lineTo(cx - f * cs * 0.06, base - cs * 0.14)
      ..close();
    canvas.drawPath(cape, p..color = const Color(0xFFC62828));
    canvas.drawPath(cape, ol);
    // 腿
    for (final dx in [-0.1, 0.1]) {
      final leg = RRect.fromRectAndRadius(Rect.fromLTWH(cx + cs * dx - cs * 0.07, base - cs * 0.2, cs * 0.14, cs * 0.2), Radius.circular(cs * 0.04));
      canvas.drawRRect(leg, p..color = const Color(0xFF5D4037));
      canvas.drawRRect(leg, ol);
    }
    // 身體：銀甲 + 藍色衣襬 + 腰帶
    final body = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx, base - cs * 0.36), width: cs * 0.44, height: cs * 0.34), Radius.circular(cs * 0.1));
    canvas.drawRRect(body, p..color = const Color(0xFFCFD8DC));
    canvas.drawRect(Rect.fromCenter(center: Offset(cx, base - cs * 0.3), width: cs * 0.44, height: cs * 0.06), p..color = const Color(0xFF3949AB));
    canvas.drawRect(Rect.fromCenter(center: Offset(cx, base - cs * 0.3), width: cs * 0.08, height: cs * 0.08), p..color = const Color(0xFFFFD54F));
    canvas.drawRRect(body, ol);
    // 胸前紋章
    canvas.drawCircle(Offset(cx, base - cs * 0.42), cs * 0.05, p..color = const Color(0xFF3949AB));
    // 頭
    final hc = Offset(cx, base - cs * 0.64);
    canvas.drawCircle(hc, cs * 0.2, p..color = const Color(0xFFFFE0B2));
    canvas.drawCircle(hc, cs * 0.2, ol);
    // 頭盔：銀色半罩 + 紅色羽飾
    canvas.drawArc(Rect.fromCircle(center: hc, radius: cs * 0.21), math.pi, math.pi, true, p..color = const Color(0xFFB0BEC5));
    canvas.drawArc(Rect.fromCircle(center: hc, radius: cs * 0.21), math.pi, math.pi, true, ol);
    final plume = Path()
      ..moveTo(cx, hc.dy - cs * 0.2)
      ..quadraticBezierTo(cx - f * cs * 0.1, hc.dy - cs * 0.42, cx - f * cs * 0.26, hc.dy - cs * 0.3)
      ..quadraticBezierTo(cx - f * cs * 0.12, hc.dy - cs * 0.26, cx - f * cs * 0.02, hc.dy - cs * 0.17)
      ..close();
    canvas.drawPath(plume, p..color = const Color(0xFFE53935));
    canvas.drawPath(plume, ol);
    // 眼睛（朝面向那側偏）
    final ey = hc.dy + cs * 0.02;
    for (final dx in [-0.07, 0.08]) {
      canvas.drawOval(Rect.fromCenter(center: Offset(cx + f * cs * 0.03 + cs * dx, ey), width: cs * 0.06, height: cs * 0.09), p..color = const Color(0xFF212121));
    }
    // 盾（面向的反側手）與劍（面向那側手）
    final sc = Offset(cx - f * cs * 0.3, base - cs * 0.36);
    canvas.drawCircle(sc, cs * 0.14, p..color = const Color(0xFF3949AB));
    canvas.drawCircle(sc, cs * 0.14, ol);
    canvas.drawCircle(sc, cs * 0.05, p..color = const Color(0xFFFFD54F));
    canvas.save();
    canvas.translate(cx + f * cs * 0.3, base - cs * 0.36);
    canvas.rotate(f * 0.35);
    canvas.drawRect(Rect.fromCenter(center: Offset(0, -cs * 0.22), width: cs * 0.09, height: cs * 0.5), p..color = const Color(0xFFECEFF1));
    canvas.drawRect(Rect.fromCenter(center: Offset(0, -cs * 0.22), width: cs * 0.09, height: cs * 0.5), ol);
    canvas.drawRect(Rect.fromCenter(center: Offset(0, 0.02), width: cs * 0.26, height: cs * 0.06), p..color = const Color(0xFFFFB300));
    canvas.drawRect(Rect.fromCenter(center: Offset(0, cs * 0.08), width: cs * 0.07, height: cs * 0.12), p..color = const Color(0xFF6D4C41));
    canvas.restore();
  }

  void _tile(Canvas canvas, String t, Rect r, double cs) {
    final p = Paint();
    final cx = r.center.dx, cy = r.center.dy;
    final door = _doorCol[t];
    if (door != null) {
      final rr = RRect.fromRectAndRadius(r.deflate(cs * 0.05), Radius.circular(cs * 0.12));
      canvas.drawRRect(rr, p..color = const Color(0xFF3E2723));
      canvas.drawRRect(rr.deflate(cs * 0.07), p..color = door);
      canvas.drawRRect(rr.deflate(cs * 0.07), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.black54);
      // 兩片門板的接縫 + 鎖
      canvas.drawRect(Rect.fromCenter(center: Offset(cx, cy), width: cs * 0.05, height: cs * 0.78), p..color = Colors.black38);
      canvas.drawCircle(Offset(cx, cy), cs * 0.15, p..color = const Color(0xFF212121));
      canvas.drawCircle(Offset(cx, cy), cs * 0.1, p..color = Colors.white);
      canvas.drawRect(Rect.fromCenter(center: Offset(cx, cy + cs * 0.06), width: cs * 0.05, height: cs * 0.1), p..color = const Color(0xFF212121));
      return;
    }
    if (t == 'P') {
      _merchant(canvas, r, cs);
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
    final m = mtMonsterAt(g.floor, t);
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
      final gain = mtScaled(it.hp + it.atk + it.def, g.floor);
      if (gain > 0) _text(canvas, '+$gain', Offset(cx, r.bottom - cs * 0.12), cs * 0.22, Colors.white, outline: true);
    }
  }

  void _merchant(Canvas canvas, Rect r, double cs) {
    final p = Paint();
    final cx = r.center.dx, base = r.bottom - cs * 0.04;
    final ol = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, cs * 0.04)
      ..color = Colors.black87;
    final robe = Path()
      ..moveTo(cx - cs * 0.28, base)
      ..quadraticBezierTo(cx - cs * 0.3, base - cs * 0.4, cx, base - cs * 0.52)
      ..quadraticBezierTo(cx + cs * 0.3, base - cs * 0.4, cx + cs * 0.28, base)
      ..close();
    canvas.drawPath(robe, p..color = const Color(0xFF6A1B9A));
    canvas.drawPath(robe, ol);
    canvas.drawCircle(Offset(cx, base - cs * 0.58), cs * 0.17, p..color = const Color(0xFFFFE0B2));
    canvas.drawCircle(Offset(cx, base - cs * 0.58), cs * 0.17, ol);
    final hat = Path()
      ..moveTo(cx - cs * 0.26, base - cs * 0.62)
      ..lineTo(cx, base - cs * 0.98)
      ..lineTo(cx + cs * 0.26, base - cs * 0.62)
      ..close();
    canvas.drawPath(hat, p..color = const Color(0xFF4A148C));
    canvas.drawPath(hat, ol);
    canvas.drawCircle(Offset(cx, base - cs * 0.3), cs * 0.07, p..color = const Color(0xFFFFD54F));
    _text(canvas, '💰', Offset(r.right - cs * 0.15, r.top + cs * 0.18), cs * 0.24, Colors.white);
  }

  void _item(Canvas canvas, String t, Rect r, double cs) {
    final p = Paint();
    final cx = r.center.dx, cy = r.center.dy;
    switch (t) {
      case 'y':
      case 'b':
      case 'r':
        canvas.drawCircle(Offset(cx, cy), cs * 0.36, Paint()..color = _doorCol[t.toUpperCase()]!.withValues(alpha: 0.35));
        paintKey(canvas, Rect.fromCenter(center: Offset(cx, cy), width: cs * 0.85, height: cs * 0.85), _doorCol[t.toUpperCase()]!);
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
