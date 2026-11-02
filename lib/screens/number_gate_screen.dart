import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'number_gate_logic.dart';

/// 數字門（試玩）：單機、不連伺服器、沒有獎金。
/// 流程：選關 → 全圖預覽（先規劃路線）→ 開跑（玩家在下面自動機槍掃射，點左／右半邊或 ←→ 換道）→ 結算。
class NumberGateScreen extends StatefulWidget {
  const NumberGateScreen({super.key});

  @override
  State<NumberGateScreen> createState() => _NumberGateScreenState();
}

enum _Ph { menu, preview, run }

class _Floater {
  final String text;
  final bool good;
  final double x; // 以道為單位的橫向位置
  final double y; // 離玩家的高度（px）
  double t = 0;
  _Floater(this.text, this.good, this.x, this.y);
}

class _NumberGateScreenState extends State<NumberGateScreen> with SingleTickerProviderStateMixin {
  static const _saveKey = 'number_gate_unlocked_v1';
  static const _lead = 2.2; // 開跑前的準備秒數（可以先選起始道）
  static const segPx = 200.0; // 一段（兩排門之間）的畫面距離

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
  late NgRun _run;
  double _acc = 0;
  double _lead0 = _lead; // 準備倒數剩餘
  double _laneX = 0;
  double _lockFlash = 0;
  double _hitFlash = 0;
  double _bossFlash = 0;
  double _clock = 0; // 畫面動畫用
  int _shown = 0;
  final List<_Floater> _floats = [];
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
    _run = NgRun(_lv, lane: _lv.lanes ~/ 2, count: _lv.start);
    _laneX = _run.lane.toDouble();
    _lead0 = _lead;
    _acc = 0;
    _shown = _run.count;
    _floats.clear();
    _lockFlash = _hitFlash = _bossFlash = 0;
    _over = false;
    setState(() => _ph = _Ph.run);
    _focus.requestFocus();
  }

  // ---------------- 主迴圈 ----------------
  void _onTick(Duration now) {
    final dt = _last == Duration.zero ? 0.0 : math.min(0.05, (now - _last).inMicroseconds / 1e6);
    _last = now;
    if (_ph != _Ph.run) return;
    _clock += dt;
    _laneX += (_run.lane - _laneX) * math.min(1.0, dt * 16);
    if (_lockFlash > 0) _lockFlash -= dt;
    if (_hitFlash > 0) _hitFlash -= dt;
    if (_bossFlash > 0) _bossFlash -= dt;
    for (final f in _floats) {
      f.t += dt;
    }
    _floats.removeWhere((f) => f.t > 1.0);
    if (_lead0 > 0) {
      _lead0 -= dt;
    } else if (_run.result == 0) {
      _acc += dt;
      var n = 0;
      while (_acc >= ngDt && n < 6 && _run.result == 0) {
        _run.step(ngDt);
        _acc -= ngDt;
        n++;
      }
      if (_acc > 0.2) _acc = 0;
    }
    for (final e in _run.events) {
      switch (e.kind) {
        case 'gate':
          _floats.add(_Floater(e.text, e.good, _laneX, 60));
          if (!e.good) _hitFlash = 0.2;
        case 'bite':
        case 'hit':
          _floats.add(_Floater(e.text, false, _laneX, 40));
          _hitFlash = 0.25;
        case 'kill':
          _floats.add(_Floater('💥', true, e.lane.toDouble(), 150));
        case 'boss':
          _floats.add(_Floater(e.text, true, _lv.lanes / 2 - 0.5, 200));
          _bossFlash = 0.5;
        case 'slam':
          _bossFlash = 0.15;
      }
    }
    _run.events.clear();
    final d = _run.count - _shown;
    _shown += d.abs() < 4 ? d : (d * math.min(1.0, dt * 12)).round();
    if (!_over && _run.result != 0) {
      _over = true;
      if (_run.result == 1 && _level >= _unlocked && _level < ngLevels) {
        _unlocked = _level + 1;
        _save();
      }
      setState(() {});
    }
    _repaint.value++;
  }

  void _shift(int d) {
    if (_ph != _Ph.run || _run.result != 0) return;
    if (_lead0 > 0) {
      // 開跑前可以隨便選起始道
      _run.lane = (_run.lane + d).clamp(0, _lv.lanes - 1);
      return;
    }
    if (!_run.shift(d)) _lockFlash = 0.35;
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
            _Ph.run => _game(),
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
              const Text('🔫 數字門', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('試玩版：單機、沒有獎金', style: TextStyle(color: Colors.amberAccent)),
              const SizedBox(height: 12),
              const Text(
                '• 你在最下面，人數越多火力越強，自動機槍掃射前方\n'
                '• 路上有小怪：牠在你這條道、而且撞到你時還活著，就咬掉等於牠剩餘血量的人數；別條道的不會咬你\n'
                '• 數字門會改人數（+ − × ÷），但好的門前面常常有一堆小怪\n'
                '• 點畫面左半邊／右半邊（或 ← →）換道；兩排之間只能換一次，所以要往前看好幾排\n'
                '• 中途和最後有頭目：畫面停住，限時打完血條；牠會預告攻擊的道（變紅），要換道閃開\n'
                '• 每一關開跑前會先給你看整張地圖，先想好路線再開始',
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

  /// 預覽裡一排門前面的小怪：每條道一格，列出這條道的小怪（依先後）
  Widget _monStrip(NgRow r) {
    return Row(children: [
      for (var l = 0; l < _lv.lanes; l++)
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 3),
            alignment: Alignment.center,
            child: Text(
              [for (final m in r.mons.reversed.where((m) => m.lane == l)) '${m.emoji}${ngFmt(m.hp)}'].join('  '),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFFFCC80), fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ),
    ]);
  }

  Widget _preview() {
    final rows = _lv.rows;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Text(
            '先看地圖想路線：從最下面（起點 ${_lv.start} 人）往上跑，${rows.length} 排・${_lv.lanes} 條道・每段 ${_lv.interval.toStringAsFixed(2)} 秒。'
            '橘色是門前面的小怪（表情＋血量）',
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
                    if (rows[i].isBoss)
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFF4A148C),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.purpleAccent, width: 2),
                        ),
                        child: Text(
                          '${rows[i].emoji} ${rows[i].isFinal ? '最後頭目' : '中途頭目'}  血量 ${ngFmt(rows[i].bossHp)}・限時 ${rows[i].bossLimit.toStringAsFixed(0)} 秒',
                          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      )
                    else ...[
                      if (rows[i].mons.isNotEmpty) _monStrip(rows[i]),
                      Row(children: [
                        for (var l = 0; l < _lv.lanes; l++) _chip(rows[i].gates![l], onPath: _hintPath != null && _hintPath![i] == l),
                      ]),
                    ],
                  Container(
                    margin: const EdgeInsets.all(6),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(10),
                    child: Text('🔫 起點 ${_lv.start} 人（開跑前可以自己選起始道）', style: const TextStyle(color: Colors.white54)),
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
          if (_run.result != 0) Positioned.fill(child: _result()),
        ],
      );
    });
  }

  Widget _result() {
    final win = _run.result == 1;
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
            child: Text(win ? '最後剩下 ${ngFmt(_run.count)} 人' : _run.why,
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

  static const segPx = _NumberGateScreenState.segPx;

  @override
  void paint(Canvas c, Size size) {
    final lv = s._lv;
    final run = s._run;
    final lanes = lv.lanes;
    final laneW = math.min(size.width / lanes, 118.0);
    final left = (size.width - laneW * lanes) / 2;
    final playerY = size.height * 0.84;
    final pps = segPx / lv.interval;
    final trav = run.row * segPx + math.min(run.ts, lv.interval) * pps; // 目前走到的距離
    double yAt(double world) => playerY - (world - trav);
    double laneCx(double l) => left + (l + 0.5) * laneW;

    // 背景與道
    c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0B1020));
    c.drawRect(Rect.fromLTWH(left, 0, laneW * lanes, size.height), Paint()..color = const Color(0xFF141C3A));
    final line = Paint()
      ..color = Colors.white10
      ..strokeWidth = 2;
    for (var l = 0; l <= lanes; l++) {
      c.drawLine(Offset(left + l * laneW, 0), Offset(left + l * laneW, size.height), line);
    }
    final off = trav % 60;
    for (var y = -60 + off; y < size.height; y += 60) {
      c.drawLine(Offset(left, y), Offset(left + laneW * lanes, y), Paint()..color = Colors.white.withValues(alpha: 0.04));
    }

    // 頭目預告的攻擊道（紅色）
    if (run.slamAt >= 0) {
      final k = (1 - (run.slamAt - (run.ts - lv.interval)) / 0.9).clamp(0.0, 1.0);
      for (final l in run.slamLanes) {
        c.drawRect(Rect.fromLTWH(left + l * laneW, 0, laneW, size.height),
            Paint()..color = Colors.redAccent.withValues(alpha: 0.12 + 0.32 * k));
      }
    }

    // 子彈要打到的位置：目前這條道上的目標，或下一排門
    double? stopY;
    final row = run.row < lv.rows.length ? lv.rows[run.row] : null;
    if (row != null && !row.isBoss) {
      stopY = yAt(run.row * segPx + segPx) + 8;
      if (run.targetMon != null) stopY = yAt(run.row * segPx + row.mons[run.targetMon!].arrive * pps) + 14;
    } else if (row != null) {
      stopY = yAt(run.row * segPx + segPx) - 200 + 70;
    }

    // 排（由遠到近）
    for (var i = lv.rows.length - 1; i >= run.row; i--) {
      final r = lv.rows[i];
      final base = i * segPx;
      final dim = i > run.row ? 0.55 : 1.0;
      if (r.isBoss) {
        final y = yAt(base + segPx) - 200;
        if (y < -120 || y > size.height + 120) continue;
        final cx = left + laneW * lanes / 2;
        final w = laneW * lanes * 0.84;
        final rect = Rect.fromCenter(center: Offset(cx, y), width: w, height: 120);
        c.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(18)), Paint()..color = const Color(0xFF4A148C).withValues(alpha: dim));
        c.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(18)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = (s._bossFlash > 0 ? Colors.white : Colors.purpleAccent).withValues(alpha: dim));
        _text(c, r.emoji, Offset(rect.left + 56, y - 6), 62);
        // 血條
        final hp = i == run.row ? (run.bossHp / r.bossHp).clamp(0.0, 1.0) : 1.0;
        final bar = Rect.fromLTWH(rect.left + 100, y - 4, rect.width - 120, 16);
        c.drawRRect(RRect.fromRectAndRadius(bar, const Radius.circular(8)), Paint()..color = Colors.black54);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bar.left, bar.top, bar.width * hp, bar.height), const Radius.circular(8)),
            Paint()..color = const Color(0xFFFF5252));
        _text(c, ngFmt((i == run.row ? run.bossHp : r.bossHp.toDouble()).ceil().clamp(0, 1 << 40)), Offset(bar.center.dx, bar.center.dy), 12, bold: true);
        if (i == run.row && run.bossFight) {
          final left0 = (r.bossLimit - (run.ts - lv.interval)).clamp(0.0, r.bossLimit);
          _text(c, '⏱ ${left0.toStringAsFixed(1)}', Offset(rect.right - 44, y - 34), 15, color: left0 < 3 ? Colors.redAccent : Colors.amberAccent, bold: true);
        }
        continue;
      }
      // 小怪
      for (var k = 0; k < r.mons.length; k++) {
        final m = r.mons[k];
        if (i == run.row && run.gone[k]) continue;
        final y = yAt(base + m.arrive * pps);
        if (y < -40 || y > size.height + 40) continue;
        final hp = i == run.row ? run.mhp[k] : m.hp.toDouble();
        final danger = i == run.row && m.lane == run.lane;
        final cx = laneCx(m.lane.toDouble());
        c.drawCircle(Offset(cx, y + 4), 25, Paint()..color = (danger ? const Color(0xFFB71C1C) : const Color(0xFF37474F)).withValues(alpha: 0.85 * dim));
        _text(c, m.emoji, Offset(cx, y), 28);
        _text(c, ngFmt(hp.ceil().clamp(0, 1 << 40)), Offset(cx, y - 32), 14, color: (danger ? Colors.amberAccent : Colors.white70).withValues(alpha: dim), bold: true);
      }
      // 門
      final gy = yAt(base + segPx);
      if (gy < -50 || gy > size.height + 50) continue;
      for (var l = 0; l < lanes; l++) {
        final g = r.gates![l];
        final rect = Rect.fromLTWH(left + l * laneW + 5, gy - 28, laneW - 10, 56);
        final good = g.isGood;
        c.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(12)),
            Paint()..color = (good ? const Color(0xFF2E7D32) : const Color(0xFFC62828)).withValues(alpha: dim));
        c.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(12)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = (good ? const Color(0xFF69F0AE) : const Color(0xFFFF8A80)).withValues(alpha: dim));
        _text(c, g.label, rect.center, laneW > 90 ? 26 : 22, bold: true);
      }
    }

    // 主角：人群＋機槍
    final px = laneCx(s._laneX);
    final shown = math.max(0, s._shown);
    final dots = math.min(shown, 40);
    final rng = math.Random(7);
    for (var i = 0; i < dots; i++) {
      final a = rng.nextDouble() * 2 * math.pi;
      final r = math.sqrt(rng.nextDouble()) * (12 + dots * 0.8);
      c.drawCircle(Offset(px + math.cos(a) * r, playerY + 14 + math.sin(a) * r * 0.6), 5.5,
          Paint()..color = s._hitFlash > 0 ? Colors.redAccent : const Color(0xFF40C4FF));
    }
    // 子彈：從主角往上，打到目標／門為止
    if (run.result == 0 && s._lead0 <= 0 && stopY != null && stopY < playerY - 20) {
      final n = math.min(4, 1 + shown ~/ 15);
      final phase = (s._clock * 18) % 1.0;
      for (var b = 0; b < n; b++) {
        final dx = (b - (n - 1) / 2) * 7.0;
        for (var k = 0.0; k < 12; k++) {
          final y = playerY - 16 - ((k + phase) * 26);
          if (y < stopY) break;
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(px + dx, y), width: 3.5, height: 12), const Radius.circular(2)),
              Paint()..color = const Color(0xFFFFEB3B));
        }
      }
      c.drawCircle(Offset(px, playerY - 18), 8 + 3 * math.sin(s._clock * 60), Paint()..color = const Color(0xFFFFF176).withValues(alpha: 0.7));
    }
    final locked = s._lead0 <= 0 && !run.bossFight && run.shifted;
    c.drawCircle(
        Offset(px, playerY),
        20,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = s._lockFlash > 0 ? Colors.redAccent : (locked ? Colors.white24 : Colors.amberAccent));
    _text(c, ngFmt(shown), Offset(px, playerY + 46), 28, bold: true);
    for (final f in s._floats) {
      _text(c, f.text, Offset(laneCx(f.x), playerY - f.y - f.t * 50), 24,
          color: (f.good ? const Color(0xFF69F0AE) : const Color(0xFFFF8A80)).withValues(alpha: (1 - f.t).clamp(0.0, 1.0)), bold: true);
    }

    // 準備倒數
    if (s._lead0 > 0) {
      _text(c, '${s._lead0.ceil()}', Offset(size.width / 2, size.height * 0.4), 88, color: Colors.white.withValues(alpha: 0.85), bold: true);
      _text(c, '先點左／右半邊選起始道', Offset(size.width / 2, size.height * 0.4 + 70), 16, color: Colors.white54);
    }
    // 進度
    final prog = (run.row / lv.rows.length).clamp(0.0, 1.0);
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
