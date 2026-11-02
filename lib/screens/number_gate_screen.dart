import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'number_gate_logic.dart';

/// 數字門（試玩）：單機、不連伺服器、沒有獎金。
/// 流程：選關 → 全圖預覽（先規劃路線）→ 開始跑（點左／右半邊或 ←→ 換道，兩排之間只能換一次）→ 結算。
class NumberGateScreen extends StatefulWidget {
  const NumberGateScreen({super.key});

  @override
  State<NumberGateScreen> createState() => _NumberGateScreenState();
}

enum _Ph { menu, preview, run, won, lost }

class _Floater {
  final String text;
  final bool good;
  double t = 0;
  _Floater(this.text, this.good);
}

class _NumberGateScreenState extends State<NumberGateScreen> with SingleTickerProviderStateMixin {
  static const _saveKey = 'number_gate_unlocked_v1';
  static const _lead = 2.2; // 開跑前的準備秒數（可以先選起始道）
  static const _rowGap = 150.0; // 兩排之間的畫面距離

  late final Ticker _ticker;
  final _repaint = ValueNotifier<int>(0);
  final _focus = FocusNode();
  Duration _last = Duration.zero;

  _Ph _ph = _Ph.menu;
  int _unlocked = 1;
  int _level = 1;
  late NgLevel _lv;
  bool _hint = false;
  List<int>? _hintPath;

  // 跑關狀態
  double _t = -_lead;
  int _next = 0; // 下一個要穿過的排
  int _lane = 0;
  double _laneX = 0; // 畫面上的橫向位置（以道為單位，動畫用）
  bool _shifted = false; // 這一段（上一排到下一排之間）已經換過道
  double _lockFlash = 0;
  int _count = 0;
  int _shown = 0; // 畫面上跑到的人數（數字滾動）
  final List<int> _path = [];
  final List<_Floater> _floats = [];
  String _loseWhy = '';
  double _hitFlash = 0;

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

  void _openLevel(int i, {bool hint = false}) {
    setState(() {
      _level = i;
      _lv = ngLevel(i);
      _hint = hint;
      _hintPath = hint ? ngSolvePath(_lv) : null;
      _ph = _Ph.preview;
    });
  }

  void _start() {
    _t = -_lead;
    _next = 0;
    _lane = _lv.lanes ~/ 2;
    _laneX = _lane.toDouble();
    _shifted = false;
    _count = _lv.start;
    _shown = _count;
    _path.clear();
    _floats.clear();
    _loseWhy = '';
    _hitFlash = 0;
    setState(() => _ph = _Ph.run);
    _focus.requestFocus();
  }

  // ---------------- 主迴圈 ----------------
  void _onTick(Duration now) {
    final dt = _last == Duration.zero ? 0.0 : math.min(0.05, (now - _last).inMicroseconds / 1e6);
    _last = now;
    if (_ph != _Ph.run) return;
    _t += dt;
    _laneX += (_lane - _laneX) * math.min(1.0, dt * 16);
    if (_lockFlash > 0) _lockFlash -= dt;
    if (_hitFlash > 0) _hitFlash -= dt;
    if (_shown != _count) {
      final d = _count - _shown;
      _shown += d.abs() < 3 ? d : (d * math.min(1.0, dt * 10)).round();
      if (_shown == _count - d && d != 0) _shown = _count; // 小數誤差保險
    }
    for (final f in _floats) {
      f.t += dt;
    }
    _floats.removeWhere((f) => f.t > 1.1);
    // 穿過排
    while (_next < _lv.rows.length && _t >= (_next + 1) * _lv.interval) {
      if (!_cross()) break;
    }
    _repaint.value++;
  }

  /// 穿過第 _next 排；回傳 false＝這一關結束了
  bool _cross() {
    final row = _lv.rows[_next];
    _path.add(_lane);
    final before = _count;
    final after = row.pass(before, _lane);
    if (row.isFight) {
      if (after <= 0) {
        _count = 0;
        _shown = 0;
        _loseWhy = '${row.emoji} 敵人有 ${ngFmt(row.enemy)}，你只有 ${ngFmt(before)}，輸了';
        _end(false);
        return false;
      }
      _count = after;
      _floats.add(_Floater('${row.emoji} −${ngFmt(row.enemy)}', false));
      _hitFlash = 0.25;
    } else {
      final g = row.gates![_lane];
      if (after <= 0) {
        _count = 0;
        _shown = 0;
        _loseWhy = '穿過 ${g.label}：${ngFmt(before)} 變成 0，全軍覆沒';
        _end(false);
        return false;
      }
      _count = after;
      _floats.add(_Floater(g.label, after >= before));
      if (after < before) _hitFlash = 0.2;
    }
    _next++;
    _shifted = false; // 過了一排，可以再換一次道
    if (_next >= _lv.rows.length) {
      _end(true);
      return false;
    }
    return true;
  }

  void _end(bool win) {
    if (win && _level >= _unlocked && _level < ngLevels) {
      _unlocked = _level + 1;
      _save();
    }
    setState(() => _ph = win ? _Ph.won : _Ph.lost);
  }

  void _shift(int d) {
    if (_ph != _Ph.run) return;
    final n = _lane + d;
    if (n < 0 || n >= _lv.lanes) return;
    // 開跑前可以隨便選起始道；開跑後每段只能換一次
    if (_t >= 0) {
      if (_shifted) {
        _lockFlash = 0.35;
        return;
      }
      _shifted = true;
    }
    _lane = n;
  }

  // ---------------- 畫面 ----------------
  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (n, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        final k = e.logicalKey;
        if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA) {
          _shift(-1);
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyD) {
          _shift(1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B1020),
        appBar: AppBar(
          title: Text(_ph == _Ph.menu ? '數字門（試玩）' : '數字門 第 $_level 關'),
          backgroundColor: const Color(0xFF111833),
          leading: _ph == _Ph.menu ? null : BackButton(onPressed: () => setState(() => _ph = _Ph.menu)),
        ),
        body: SafeArea(
          child: switch (_ph) {
            _Ph.menu => _menu(),
            _Ph.preview => _preview(),
            _ => _game(),
          },
        ),
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
              const Text('🚪 數字門', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('試玩版：單機、沒有獎金', style: TextStyle(color: Colors.amberAccent)),
              const SizedBox(height: 12),
              const Text(
                '• 自動往前跑，穿過哪一道門，人數就照上面的算式變\n'
                '• 路上有敵人／頭目：人數要「大於」牠才過得去，過去後剩 人數−敵人\n'
                '• 點畫面左半邊／右半邊（或 ← →）換道；兩排之間只能換一次，不能一次跨兩道\n'
                '• 每一關開跑前會先給你看整張地圖，先想好路線再開始\n'
                '• 每排只挑眼前最大的門一定會輸，要往前看好幾排',
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
                      onTap: i <= _unlocked ? () => _openLevel(i) : null,
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

  Widget _chip(NgGate g, {bool onPath = false}) {
    final good = g.isGood;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(3),
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: good ? const Color(0xFF1B5E20) : const Color(0xFFB71C1C),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: onPath ? Colors.amberAccent : Colors.white12, width: onPath ? 3 : 1),
        ),
        child: Text(g.label, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _preview() {
    final rows = _lv.rows;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            '先看地圖想路線：從最下面（起點 ${_lv.start} 人）往上跑，${rows.length} 排・${_lv.lanes} 條道・每排 ${_lv.interval.toStringAsFixed(2)} 秒',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                children: [
                  for (var i = rows.length - 1; i >= 0; i--)
                    if (rows[i].isFight)
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: rows[i].boss ? const Color(0xFF4A148C) : const Color(0xFF3E2723),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: rows[i].boss ? Colors.purpleAccent : Colors.orangeAccent),
                        ),
                        child: Text(
                          '${rows[i].emoji} ${rows[i].boss ? '頭目' : '敵人'} ${ngFmt(rows[i].enemy)}（人數要大於牠）',
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      )
                    else
                      Row(children: [
                        for (var l = 0; l < _lv.lanes; l++) _chip(rows[i].gates![l], onPath: _hintPath != null && _hintPath![i] == l),
                      ]),
                  Container(
                    margin: const EdgeInsets.all(6),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(10),
                    child: Text('🧍 起點 ${_lv.start} 人（開跑前可以自己選起始道）', style: const TextStyle(color: Colors.white54)),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(onPressed: _start, icon: const Icon(Icons.play_arrow), label: const Text('開始')),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: () => setState(() {
                  _hint = !_hint;
                  _hintPath = _hint ? ngSolvePath(_lv) : null;
                }),
                child: Text(_hint ? '藏起解法' : '看解法'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _game() {
    return LayoutBuilder(builder: (context, c) {
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _shift(d.localPosition.dx < c.maxWidth / 2 ? -1 : 1),
              child: CustomPaint(painter: _GatePainter(this, _repaint)),
            ),
          ),
          if (_ph == _Ph.won || _ph == _Ph.lost) Positioned.fill(child: _result()),
        ],
      );
    });
  }

  Widget _result() {
    final win = _ph == _Ph.won;
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
            child: Text(win ? '剩下 ${ngFmt(_count)} 人' : _loseWhy,
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15)),
          ),
          const SizedBox(height: 18),
          if (win && _level < ngLevels) btn('▶ 下一關', () => _openLevel(_level + 1), primary: true),
          if (win && _level >= ngLevels) const Text('🏆 30 關全部通過！', style: TextStyle(color: Colors.amberAccent, fontSize: 18)),
          if (!win) btn('🔄 重新挑戰', () => _openLevel(_level), primary: true),
          const SizedBox(height: 8),
          if (win) btn('🔄 再玩一次', () => _openLevel(_level)),
          if (!win) btn('💡 看解法', () => _openLevel(_level, hint: true)),
          const SizedBox(height: 8),
          btn('回選關', () => setState(() => _ph = _Ph.menu)),
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
    final lv = s._lv;
    final lanes = lv.lanes;
    final laneW = math.min(size.width / lanes, 118.0);
    final left = (size.width - laneW * lanes) / 2;
    final playerY = size.height * 0.8;
    final pps = _NumberGateScreenState._rowGap / lv.interval; // 每秒走的畫面距離
    final travel = s._t * pps;

    // 背景與道
    c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0B1020));
    c.drawRect(Rect.fromLTWH(left, 0, laneW * lanes, size.height), Paint()..color = const Color(0xFF141C3A));
    final line = Paint()
      ..color = Colors.white10
      ..strokeWidth = 2;
    for (var l = 0; l <= lanes; l++) {
      c.drawLine(Offset(left + l * laneW, 0), Offset(left + l * laneW, size.height), line);
    }
    // 往下流動的橫線，增加速度感
    final off = travel % 60;
    for (var y = -60 + off; y < size.height; y += 60) {
      c.drawLine(Offset(left, y), Offset(left + laneW * lanes, y), Paint()..color = Colors.white.withValues(alpha: 0.04));
    }

    // 排
    for (var i = s._next; i < lv.rows.length; i++) {
      final y = playerY - ((i + 1) * _NumberGateScreenState._rowGap - travel);
      if (y < -70) break;
      if (y > size.height + 70) continue;
      final row = lv.rows[i];
      if (row.isFight) {
        final rect = Rect.fromLTWH(left, y - 34, laneW * lanes, 68);
        c.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(10)),
            Paint()..color = row.boss ? const Color(0xFF6A1B9A) : const Color(0xFF8D3B1E));
        c.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(10)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = row.boss ? Colors.purpleAccent : Colors.orangeAccent);
        _text(c, row.emoji, Offset(rect.left + 32, y), 34);
        _text(c, ngFmt(row.enemy), Offset(rect.center.dx + 14, y), row.boss ? 34 : 28, color: Colors.white, bold: true);
      } else {
        for (var l = 0; l < lanes; l++) {
          final g = row.gates![l];
          final rect = Rect.fromLTWH(left + l * laneW + 5, y - 30, laneW - 10, 60);
          final good = g.isGood;
          c.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(12)),
              Paint()..color = good ? const Color(0xFF2E7D32) : const Color(0xFFC62828));
          c.drawRRect(
              RRect.fromRectAndRadius(rect, const Radius.circular(12)),
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2
                ..color = good ? const Color(0xFF69F0AE) : const Color(0xFFFF8A80));
          _text(c, g.label, rect.center, laneW > 90 ? 26 : 22, color: Colors.white, bold: true);
        }
      }
    }

    // 主角與人群
    final px = left + (s._laneX + 0.5) * laneW;
    final locked = s._t >= 0 && s._shifted;
    final shown = math.max(0, s._shown);
    final dots = math.min(shown, 36);
    final rng = math.Random(7);
    for (var i = 0; i < dots; i++) {
      final a = rng.nextDouble() * 2 * math.pi;
      final r = math.sqrt(rng.nextDouble()) * (14 + math.min(dots, 36) * 0.9);
      c.drawCircle(Offset(px + math.cos(a) * r, playerY + 10 + math.sin(a) * r * 0.7), 6,
          Paint()..color = s._hitFlash > 0 ? Colors.redAccent : const Color(0xFF40C4FF));
    }
    c.drawCircle(
        Offset(px, playerY),
        20,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = s._lockFlash > 0 ? Colors.redAccent : (locked ? Colors.white24 : Colors.amberAccent));
    _text(c, ngFmt(shown), Offset(px, playerY - 46), 28, color: Colors.white, bold: true);
    for (final f in s._floats) {
      _text(c, f.text, Offset(px, playerY - 80 - f.t * 50), 24,
          color: (f.good ? const Color(0xFF69F0AE) : const Color(0xFFFF8A80)).withValues(alpha: (1 - f.t / 1.1).clamp(0.0, 1.0)), bold: true);
    }

    // 準備倒數
    if (s._t < 0) {
      _text(c, '${(-s._t).ceil()}', Offset(size.width / 2, size.height * 0.4), 88, color: Colors.white.withValues(alpha: 0.85), bold: true);
      _text(c, '先點左／右半邊選起始道', Offset(size.width / 2, size.height * 0.4 + 70), 16, color: Colors.white54);
    }
    // 進度
    final prog = (s._next / lv.rows.length).clamp(0.0, 1.0);
    c.drawRect(Rect.fromLTWH(0, 0, size.width, 5), Paint()..color = Colors.white10);
    c.drawRect(Rect.fromLTWH(0, 0, size.width * prog, 5), Paint()..color = Colors.amberAccent);
  }

  void _text(Canvas c, String t, Offset center, double size, {Color color = Colors.white, bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(fontSize: size, color: color, fontWeight: bold ? FontWeight.w900 : FontWeight.w500)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _GatePainter old) => true;
}
