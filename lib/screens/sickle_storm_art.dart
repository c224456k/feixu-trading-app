// 鐮刀風暴（試玩）：角色小怪獸與地圖大怪的畫法（全部原創造型，用 Canvas 畫）。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'sickle_storm_logic.dart';

/// 角色種族：0 火尾狐 1 雷電兔 2 葉芽蛙 3 水泡獺 4 岩角龍 5 幽靈貓 6 星羽雛 7 雲朵羊
const ssSpeciesNames = ['火尾狐', '雷電兔', '葉芽蛙', '水泡獺', '岩角龍', '幽靈貓', '星羽雛', '雲朵羊'];

/// 每個人是哪一種（真人照座位，NPC 照 id 打散）
int ssSpeciesOf(SsFighter f) => (f.human ? f.id : f.id * 5 + 3) % ssSpeciesNames.length;

Color _shade(Color c, double k) {
  final h = HSLColor.fromColor(c);
  return h.withLightness((h.lightness * k).clamp(0.0, 0.95)).toColor();
}

Paint _fill(Color c) => Paint()..color = c;

// 漸層筆刷快取：漸層都以原點為中心畫（畫之前先 translate），所以同一種顏色/大小建一次就能一直用，
// 不用每幀每隻都重建（網頁上建 shader 很貴）。
final Map<String, Paint> _shaderCache = {};
Paint _cached(String key, Shader Function() make) {
  if (_shaderCache.length > 300) _shaderCache.clear();
  return _shaderCache.putIfAbsent(key, () => Paint()..shader = make());
}
Paint _stroke(Color c, double w) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round
  ..color = c;

// 角色身體的圖快取：同一種族/顏色/朝向/動畫格只畫一次成 Picture，之後一個 drawPicture 就好；
// 只有眼珠（會跟著移動方向轉）每幀現畫。
final Map<String, ui.Picture> _picCache = {};

/// 畫一隻小怪獸角色（正面、圓滾滾），中心 (0,0)，身體半徑 [r]。
/// [fx],[fy] 臉朝的方向（眼睛會往那邊看、尾巴在反方向）。
void ssDrawCreature(Canvas c, int species, double r, Color body, double fx, double fy, double time,
    {Color? pupil, bool angry = false}) {
  final side = fx >= 0 ? 1.0 : -1.0;
  final frame = (time * 8).floor() % 8;
  final tq = frame / 8;
  final key = '$species|${body.toARGB32()}|$side|$frame|$r';
  var pic = _picCache[key];
  if (pic == null) {
    if (_picCache.length > 500) {
      for (final p in _picCache.values) {
        p.dispose();
      }
      _picCache.clear();
    }
    final rec = ui.PictureRecorder();
    _creature(Canvas(rec), species, r, body, side, 0, tq, pupils: false);
    pic = rec.endRecording();
    _picCache[key] = pic;
  }
  c.drawPicture(pic);
  // 眼珠
  final bob = math.sin(tq * 6) * 0.8;
  final lx = fx * r * 0.12, ly = fy * r * 0.1;
  final eyeY = (species == 2 ? -r * 0.55 : -r * 0.12) + bob;
  final eyeDX = species == 2 ? r * 0.5 : r * 0.36;
  final eyeR = species == 2 ? r * 0.3 : r * 0.24;
  final pc = _fill(angry ? const Color(0xFFD50000) : (pupil ?? const Color(0xFF212121)));
  final hi = _fill(Colors.white);
  for (final s in [-1.0, 1.0]) {
    final e = Offset(s * eyeDX, eyeY);
    c.drawCircle(e + Offset(lx, ly), eyeR * 0.62, pc);
    c.drawCircle(e + Offset(lx - eyeR * 0.22, ly - eyeR * 0.25), eyeR * 0.22, hi);
    if (angry) c.drawLine(e + Offset(-s * eyeR, -eyeR * 1.3), e + Offset(s * eyeR * 0.8, -eyeR * 0.75), _stroke(const Color(0xFF212121), 1.6));
  }
}

void _creature(Canvas c, int species, double r, Color body, double fx, double fy, double time,
    {Color? pupil, bool angry = false, bool pupils = true}) {
  final dark = _shade(body, 0.55);
  final light = _shade(body, 1.25);
  final side = fx >= 0 ? 1.0 : -1.0; // 尾巴長在背後那一側
  final bob = math.sin(time * 6) * 0.8;
  c.save();
  c.translate(0, bob);

  // ---- 身體後面的東西（尾巴、翅膀、羊毛） ----
  switch (species) {
    case 0: // 火尾狐：蓬鬆大尾巴，尾巴尖是火
      final tail = Path()
        ..moveTo(-side * r * 0.5, r * 0.4)
        ..quadraticBezierTo(-side * r * 1.9, r * 0.6, -side * r * 1.7, -r * 0.5)
        ..quadraticBezierTo(-side * r * 1.2, -r * 0.1, -side * r * 0.6, r * 0.1)
        ..close();
      c.drawPath(tail, _fill(body));
      final fl = 0.85 + 0.15 * math.sin(time * 18);
      final tip = Offset(-side * r * 1.72, -r * 0.55);
      c.save();
      c.translate(tip.dx, tip.dy);
      c.drawCircle(Offset.zero, r * 0.42 * fl,
          _cached('flame$r', () => ui.Gradient.radial(Offset.zero, r * 0.5, [const Color(0xFFFFF59D), const Color(0xFFFF9800), const Color(0x00FF5722)], [0, 0.5, 1])));
      c.restore();
      final flame = Path()
        ..moveTo(tip.dx - r * 0.25, tip.dy + r * 0.1)
        ..quadraticBezierTo(tip.dx, tip.dy - r * 0.9 * fl, tip.dx + r * 0.25, tip.dy + r * 0.1)
        ..close();
      c.drawPath(flame, _fill(const Color(0xFFFFB300)));
    case 1: // 雷電兔：閃電尾巴
      final z = Path()
        ..moveTo(-side * r * 0.7, r * 0.3)
        ..lineTo(-side * r * 1.3, r * 0.1)
        ..lineTo(-side * r * 1.05, -r * 0.15)
        ..lineTo(-side * r * 1.7, -r * 0.45)
        ..lineTo(-side * r * 1.25, r * 0.0)
        ..lineTo(-side * r * 1.5, r * 0.25)
        ..close();
      c.drawPath(z, _fill(const Color(0xFFFFEB3B)));
      c.drawPath(z, _stroke(const Color(0xFFF57F17), 1.2));
    case 3: // 水泡獺：扁扁的槳尾
      c.save();
      c.translate(-side * r * 1.15, r * 0.45);
      c.rotate(-side * 0.5);
      c.drawOval(Rect.fromCenter(center: Offset.zero, width: r * 1.2, height: r * 0.55), _fill(dark));
      c.restore();
    case 4: // 岩角龍：小蝙蝠翅膀 + 尖尾
      for (final s in [-1.0, 1.0]) {
        final w = Path()
          ..moveTo(s * r * 0.6, -r * 0.2)
          ..lineTo(s * r * 1.55, -r * 0.95)
          ..lineTo(s * r * 1.35, -r * 0.35)
          ..lineTo(s * r * 1.6, -r * 0.1)
          ..lineTo(s * r * 1.2, r * 0.05)
          ..lineTo(s * r * 1.35, r * 0.35)
          ..lineTo(s * r * 0.7, r * 0.25)
          ..close();
        c.drawPath(w, _fill(dark));
      }
      final t = Path()
        ..moveTo(-side * r * 0.6, r * 0.6)
        ..quadraticBezierTo(-side * r * 1.4, r * 1.0, -side * r * 1.6, r * 0.4)
        ..lineTo(-side * r * 1.95, r * 0.2)
        ..lineTo(-side * r * 1.7, r * 0.7)
        ..quadraticBezierTo(-side * r * 1.3, r * 1.25, -side * r * 0.4, r * 0.85)
        ..close();
      c.drawPath(t, _fill(body));
    case 5: // 幽靈貓：捲捲的細尾巴
      final t = Path()
        ..moveTo(-side * r * 0.8, r * 0.3)
        ..quadraticBezierTo(-side * r * 1.6, r * 0.2, -side * r * 1.5, -r * 0.4)
        ..quadraticBezierTo(-side * r * 1.4, -r * 0.8, -side * r * 1.15, -r * 0.55);
      c.drawPath(t, _stroke(body.withValues(alpha: 0.8), r * 0.22));
    case 6: // 星羽雛：兩邊小翅膀
      for (final s in [-1.0, 1.0]) {
        c.save();
        c.translate(s * r * 0.95, r * 0.15);
        c.rotate(s * (0.5 + 0.25 * math.sin(time * 14)));
        c.drawOval(Rect.fromCenter(center: Offset(s * r * 0.2, 0), width: r * 0.75, height: r * 0.45), _fill(dark));
        c.restore();
      }
    case 7: // 雲朵羊：一圈羊毛
      final wool = _fill(const Color(0xFFF5F5F5));
      for (var i = 0; i < 10; i++) {
        final a = i * math.pi * 2 / 10;
        c.drawCircle(Offset(math.cos(a) * r * 0.95, math.sin(a) * r * 0.95), r * 0.42, wool);
      }
      for (var i = 0; i < 10; i++) {
        final a = i * math.pi * 2 / 10;
        c.drawCircle(Offset(math.cos(a) * r * 0.95, math.sin(a) * r * 0.95), r * 0.42, _stroke(const Color(0x22000000), 1));
      }
  }

  // ---- 身體 ----
  if (species == 5) {
    // 幽靈貓：下襬波浪、半透明
    final p = Path()..moveTo(-r, 0);
    p.arcTo(Rect.fromCircle(center: Offset.zero, radius: r), math.pi, math.pi, false);
    p.lineTo(r, r * 0.9);
    final wv = math.sin(time * 8) * r * 0.08;
    for (var i = 0; i < 4; i++) {
      final x0 = r - i * r * 0.5;
      p.quadraticBezierTo(x0 - r * 0.25, r * (i.isEven ? 0.55 : 1.15) + wv, x0 - r * 0.5, r * 0.9);
    }
    p.close();
    c.drawPath(
        p,
        _cached('ghost${body.toARGB32()}$r', () => ui.Gradient.radial(Offset(-r * 0.3, -r * 0.4), r * 1.8,
            [light.withValues(alpha: 0.95), body.withValues(alpha: 0.85), dark.withValues(alpha: 0.75)], [0, 0.55, 1])));
  } else {
    c.drawCircle(Offset.zero, r,
        _cached('body${body.toARGB32()}$r', () => ui.Gradient.radial(Offset(-r * 0.3, -r * 0.4), r * 1.6, [light, body, dark], [0, 0.55, 1])));
    // 肚子
    c.drawOval(Rect.fromCenter(center: Offset(0, r * 0.45), width: r * 1.1, height: r * 0.8), _fill(Colors.white.withValues(alpha: 0.28)));
  }

  // ---- 頭上的東西 ----
  switch (species) {
    case 0: // 狐狸耳
    case 5: // 貓耳
      for (final s in [-1.0, 1.0]) {
        final e = Path()
          ..moveTo(s * r * 0.25, -r * 0.85)
          ..lineTo(s * r * (species == 0 ? 0.85 : 0.75), -r * (species == 0 ? 1.65 : 1.35))
          ..lineTo(s * r * 0.92, -r * 0.45)
          ..close();
        c.drawPath(e, _fill(species == 5 ? body.withValues(alpha: 0.9) : body));
        final inner = Path()
          ..moveTo(s * r * 0.42, -r * 0.8)
          ..lineTo(s * r * (species == 0 ? 0.8 : 0.72), -r * (species == 0 ? 1.4 : 1.18))
          ..lineTo(s * r * 0.82, -r * 0.6)
          ..close();
        c.drawPath(inner, _fill(const Color(0xFFFFCDD2)));
      }
    case 1: // 長兔耳 + 小電花
      for (final s in [-1.0, 1.0]) {
        c.save();
        c.translate(s * r * 0.42, -r * 1.25);
        c.rotate(s * 0.22 + math.sin(time * 5 + s) * 0.06);
        c.drawOval(Rect.fromCenter(center: Offset.zero, width: r * 0.55, height: r * 1.35), _fill(body));
        c.drawOval(Rect.fromCenter(center: Offset(0, r * 0.05), width: r * 0.26, height: r * 0.95), _fill(const Color(0xFFFFF59D)));
        c.restore();
      }
      if ((time * 3).floor().isEven) {
        final sp = Path()
          ..moveTo(r * 0.95, -r * 1.3)
          ..lineTo(r * 1.2, -r * 1.05)
          ..lineTo(r * 1.05, -r * 1.0)
          ..lineTo(r * 1.3, -r * 0.75);
        c.drawPath(sp, _stroke(const Color(0xFFFFEB3B), 1.6));
      }
    case 2: // 葉芽蛙：頭上兩片葉子
      for (final s in [-1.0, 1.0]) {
        c.save();
        c.translate(0, -r * 0.95);
        c.rotate(s * 0.7 + math.sin(time * 4) * 0.1);
        final leaf = Path()
          ..moveTo(0, 0)
          ..quadraticBezierTo(r * 0.35, -r * 0.5, 0, -r * 0.95)
          ..quadraticBezierTo(-r * 0.35, -r * 0.5, 0, 0);
        c.drawPath(leaf, _fill(const Color(0xFF66BB6A)));
        c.drawLine(Offset.zero, Offset(0, -r * 0.8), _stroke(const Color(0xFF2E7D32), 1));
        c.restore();
      }
    case 3: // 水泡獺：圓耳 + 頭上一顆水泡
      for (final s in [-1.0, 1.0]) {
        c.drawCircle(Offset(s * r * 0.7, -r * 0.72), r * 0.24, _fill(dark));
      }
      final bp = Offset(r * 0.15, -r * 1.35 + math.sin(time * 3) * 2);
      c.drawCircle(bp, r * 0.38, _fill(const Color(0x5581D4FA)));
      c.drawCircle(bp, r * 0.38, _stroke(const Color(0xCCB3E5FC), 1.4));
      c.drawCircle(bp + Offset(-r * 0.12, -r * 0.12), r * 0.08, _fill(Colors.white));
    case 4: // 岩角龍：兩支小角
      for (final s in [-1.0, 1.0]) {
        final h = Path()
          ..moveTo(s * r * 0.3, -r * 0.85)
          ..quadraticBezierTo(s * r * 0.55, -r * 1.55, s * r * 0.85, -r * 1.45)
          ..quadraticBezierTo(s * r * 0.7, -r * 1.1, s * r * 0.72, -r * 0.62)
          ..close();
        c.drawPath(h, _fill(const Color(0xFFFFF3E0)));
        c.drawPath(h, _stroke(const Color(0x55000000), 0.8));
      }
    case 6: // 星羽雛：三根冠毛
      for (var i = -1; i <= 1; i++) {
        c.save();
        c.translate(i * r * 0.2, -r * 0.9);
        c.rotate(i * 0.45);
        c.drawOval(Rect.fromCenter(center: Offset(0, -r * 0.35), width: r * 0.28, height: r * 0.75), _fill(i == 0 ? const Color(0xFFFFD54F) : dark));
        c.restore();
      }
    case 7: // 雲朵羊：兩邊捲角
      for (final s in [-1.0, 1.0]) {
        final ctr = Offset(s * r * 0.85, -r * 0.45);
        c.drawCircle(ctr, r * 0.32, _fill(const Color(0xFFBCAAA4)));
        c.drawArc(Rect.fromCircle(center: ctr, radius: r * 0.17), 0, math.pi * 1.5, false, _stroke(const Color(0xFF6D4C41), 1.4));
      }
  }

  // ---- 臉 ----
  final lx = fx * r * 0.12, ly = fy * r * 0.1;
  final eyeY = species == 2 ? -r * 0.55 : -r * 0.12;
  final eyeDX = species == 2 ? r * 0.5 : r * 0.36;
  final eyeR = species == 2 ? r * 0.3 : r * 0.24;
  for (final s in [-1.0, 1.0]) {
    final e = Offset(s * eyeDX, eyeY);
    if (species == 2) c.drawCircle(e, eyeR * 1.25, _fill(body)); // 蛙眼凸起
    c.drawCircle(e, eyeR, _fill(Colors.white));
    if (!pupils) continue; // 眼珠由 ssDrawCreature 每幀現畫
    final pc = angry ? const Color(0xFFD50000) : (pupil ?? const Color(0xFF212121));
    c.drawCircle(e + Offset(lx, ly), eyeR * 0.62, _fill(pc));
    c.drawCircle(e + Offset(lx - eyeR * 0.22, ly - eyeR * 0.25), eyeR * 0.22, _fill(Colors.white));
    if (angry) c.drawLine(e + Offset(-s * eyeR, -eyeR * 1.3), e + Offset(s * eyeR * 0.8, -eyeR * 0.75), _stroke(const Color(0xFF212121), 1.6));
  }
  // 臉頰
  if (species != 5) {
    final cheek = species == 1 ? const Color(0x9940C4FF) : const Color(0x66FF8A80);
    for (final s in [-1.0, 1.0]) {
      c.drawOval(Rect.fromCenter(center: Offset(s * r * 0.62, r * 0.18), width: r * 0.36, height: r * 0.22), _fill(cheek));
    }
  }
  // 嘴
  if (species == 6) {
    final beak = Path()
      ..moveTo(-r * 0.15, r * 0.12)
      ..lineTo(r * 0.15, r * 0.12)
      ..lineTo(0, r * 0.38)
      ..close();
    c.drawPath(beak, _fill(const Color(0xFFFF9800)));
  } else if (species == 2) {
    c.drawArc(Rect.fromCenter(center: Offset(0, r * 0.05), width: r * 0.9, height: r * 0.5), 0.2, math.pi - 0.4, false, _stroke(const Color(0xFF1B5E20), 1.4));
  } else {
    final m = Path()
      ..moveTo(-r * 0.18, r * 0.2)
      ..quadraticBezierTo(-r * 0.09, r * 0.32, 0, r * 0.22)
      ..quadraticBezierTo(r * 0.09, r * 0.32, r * 0.18, r * 0.2);
    c.drawPath(m, _stroke(const Color(0xCC3E2723), 1.2));
  }
  if (species == 3) {
    // 鬍鬚
    for (final s in [-1.0, 1.0]) {
      for (final k in [-1.0, 1.0]) {
        c.drawLine(Offset(s * r * 0.3, r * 0.2), Offset(s * r * 0.85, r * (0.12 + k * 0.1)), _stroke(const Color(0x88FFFFFF), 0.8));
      }
    }
  }
  if (species == 6) {
    // 肚子上的星星
    _star(c, Offset(0, r * 0.6), r * 0.22, _fill(const Color(0xFFFFE082)));
  }
  c.restore();
}

void _star(Canvas c, Offset o, double r, Paint p) {
  final path = Path();
  for (var i = 0; i < 10; i++) {
    final a = -math.pi / 2 + i * math.pi / 5;
    final rr = i.isEven ? r : r * 0.45;
    final pt = o + Offset(math.cos(a) * rr, math.sin(a) * rr);
    i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
  }
  c.drawPath(path..close(), p);
}

/// 畫地圖大怪（中心在 m.x, m.y）
void ssDrawMonster(Canvas c, SsMonster m, double time) {
  final r = m.r;
  final breathe = 1 + 0.03 * math.sin(time * 2.2 + m.id);
  c.save();
  c.translate(m.x, m.y);
  // 影子
  c.drawOval(Rect.fromCenter(center: Offset(4, r * 0.75), width: r * 2.1, height: r * 0.7), _fill(const Color(0x55000000)));
  c.scale(1, breathe);
  final facing = m.vx >= 0 ? 1.0 : -1.0;
  switch (m.kind) {
    case 0:
      _turtle(c, r, time, facing);
    case 1:
      _pumpkin(c, r, time);
    default:
      _cloud(c, r, time);
  }
  if (m.flash > 0) {
    c.drawCircle(Offset.zero, r, _fill(Colors.white.withValues(alpha: (m.flash / 0.1).clamp(0.0, 1.0) * 0.55)));
  }
  c.restore();
}

void _turtle(Canvas c, double r, double time, double facing) {
  final step = math.sin(time * 5);
  // 腳
  for (final p in [Offset(-0.65, -0.55), Offset(0.65, -0.55), Offset(-0.7, 0.55), Offset(0.7, 0.55)]) {
    c.drawOval(Rect.fromCenter(center: Offset(p.dx * r, p.dy * r + step * 2 * p.dx.sign), width: r * 0.42, height: r * 0.34), _fill(const Color(0xFF8D6E63)));
  }
  // 頭
  final head = Offset(facing * r * 0.95, -r * 0.1);
  c.drawCircle(head, r * 0.34, _fill(const Color(0xFFA1887F)));
  for (final s in [-1.0, 1.0]) {
    c.drawLine(head + Offset(facing * r * 0.05 + s * r * 0.1, -r * 0.08), head + Offset(facing * r * 0.05 + s * r * 0.1 + r * 0.08, -r * 0.08),
        _stroke(const Color(0xFF3E2723), 2));
  }
  c.drawOval(Rect.fromCenter(center: head + Offset(facing * r * 0.1, r * 0.1), width: r * 0.16, height: r * 0.08), _fill(const Color(0xFF5D4037)));
  // 殼
  c.drawCircle(
      Offset.zero,
      r * 0.92,
      _cached('shell$r', () => ui.Gradient.radial(Offset(-r * 0.3, -r * 0.4), r * 1.4, [const Color(0xFF9CCC65), const Color(0xFF558B2F), const Color(0xFF33691E)], [0, 0.55, 1])));
  final plate = _stroke(const Color(0xFF2E4A12), 2.2);
  Path hex(Offset o, double s) {
    final p = Path();
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3 + math.pi / 6;
      final pt = o + Offset(math.cos(a) * s, math.sin(a) * s);
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    return p..close();
  }

  c.drawPath(hex(Offset.zero, r * 0.3), plate);
  for (var i = 0; i < 6; i++) {
    final a = i * math.pi / 3;
    c.drawPath(hex(Offset(math.cos(a) * r * 0.55, math.sin(a) * r * 0.55), r * 0.24), plate);
  }
  // 青苔與小石頭
  c.drawCircle(Offset(-r * 0.35, -r * 0.55), r * 0.12, _fill(const Color(0xFF7CB342)));
  c.drawCircle(Offset(r * 0.25, -r * 0.62), r * 0.09, _fill(const Color(0xFF9E9E9E)));
  c.drawCircle(Offset.zero, r * 0.92, _stroke(const Color(0xFF1B3409), 3));
}

void _pumpkin(Canvas c, double r, double time) {
  const base = Color(0xFFFF8F00);
  for (final k in [-0.62, 0.62, -0.32, 0.32, 0.0]) {
    c.drawOval(Rect.fromCenter(center: Offset(k * r, 0), width: r * (k == 0 ? 1.0 : 0.9), height: r * 1.75),
        _cached('pump$r', () => ui.Gradient.linear(Offset(0, -r), Offset(0, r), [const Color(0xFFFFB74D), base, const Color(0xFFE65100)], [0, 0.5, 1])));
    c.drawOval(Rect.fromCenter(center: Offset(k * r, 0), width: r * (k == 0 ? 1.0 : 0.9), height: r * 1.75), _stroke(const Color(0x55BF360C), 1.5));
  }
  // 蒂 + 藤
  c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(0, -r * 0.92), width: r * 0.2, height: r * 0.35), const Radius.circular(4)),
      _fill(const Color(0xFF558B2F)));
  final vine = Path()
    ..moveTo(r * 0.05, -r * 0.95)
    ..quadraticBezierTo(r * 0.45, -r * 1.3, r * 0.55, -r * 0.95)
    ..quadraticBezierTo(r * 0.6, -r * 0.75, r * 0.4, -r * 0.8);
  c.drawPath(vine, _stroke(const Color(0xFF7CB342), 2));
  // 小皇冠
  final cr = Path()
    ..moveTo(-r * 0.32, -r * 0.78)
    ..lineTo(-r * 0.38, -r * 1.1)
    ..lineTo(-r * 0.16, -r * 0.92)
    ..lineTo(-r * 0.0, -r * 1.18)
    ..lineTo(r * 0.16, -r * 0.92)
    ..lineTo(r * 0.38, -r * 1.1)
    ..lineTo(r * 0.32, -r * 0.78)
    ..close();
  c.save();
  c.translate(-r * 0.25, 0);
  c.rotate(-0.2);
  c.drawPath(cr, _fill(const Color(0xFFFFD54F)));
  c.drawPath(cr, _stroke(const Color(0xFFFF8F00), 1.2));
  c.restore();
  // 刻出來會發光的臉
  final glow = 0.75 + 0.25 * math.sin(time * 9);
  final face = Paint()..color = Color.lerp(const Color(0xFFFFEB3B), const Color(0xFFFFFDE7), glow)!;
  for (final s in [-1.0, 1.0]) {
    final eye = Path()
      ..moveTo(s * r * 0.15, -r * 0.1)
      ..lineTo(s * r * 0.5, -r * 0.1)
      ..lineTo(s * r * 0.32, -r * 0.42)
      ..close();
    c.drawPath(eye, face);
  }
  final mouth = Path()..moveTo(-r * 0.55, r * 0.22);
  for (var i = 0; i <= 6; i++) {
    final x = -r * 0.55 + i * r * 1.1 / 6;
    mouth.lineTo(x, i.isEven ? r * 0.22 : r * 0.36);
  }
  mouth
    ..quadraticBezierTo(0, r * 0.75, -r * 0.55, r * 0.22)
    ..close();
  c.drawPath(mouth, face);
  c.drawCircle(Offset.zero, r * 1.1, _stroke(Color.fromRGBO(255, 235, 59, 0.18 * glow), r * 0.12));
}

void _cloud(Canvas c, double r, double time) {
  // 小腳
  for (final s in [-1.0, 1.0]) {
    c.drawOval(Rect.fromCenter(center: Offset(s * r * 0.4, r * 0.82 + math.sin(time * 5 + s) * 2), width: r * 0.3, height: r * 0.22), _fill(const Color(0xFF90A4AE)));
  }
  // 雲朵身體
  const puffs = [
    [0.0, -0.45, 0.55], [-0.5, -0.25, 0.48], [0.5, -0.25, 0.48], [-0.72, 0.18, 0.42], [0.72, 0.18, 0.42], //
    [-0.32, 0.42, 0.5], [0.32, 0.42, 0.5], [0.0, 0.05, 0.62],
  ];
  for (final p in puffs) {
    c.drawCircle(Offset(p[0] * r, p[1] * r), p[2] * r + 2, _fill(const Color(0xFFB0BEC5)));
  }
  final puffFill = _fill(const Color(0xFFF7F9FA));
  final puffHi = _fill(Colors.white);
  for (final p in puffs) {
    final o = Offset(p[0] * r, p[1] * r);
    c.drawCircle(o, p[2] * r, puffFill);
    c.drawCircle(o + Offset(-p[2] * r * 0.25, -p[2] * r * 0.3), p[2] * r * 0.55, puffHi);
  }
  // 小角
  for (final s in [-1.0, 1.0]) {
    final h = Path()
      ..moveTo(s * r * 0.22, -r * 0.88)
      ..lineTo(s * r * 0.36, -r * 1.2)
      ..lineTo(s * r * 0.45, -r * 0.82)
      ..close();
    c.drawPath(h, _fill(const Color(0xFFFFE082)));
  }
  // 臉：瞇瞇眼 + 臉頰
  for (final s in [-1.0, 1.0]) {
    c.drawArc(Rect.fromCenter(center: Offset(s * r * 0.24, -r * 0.05), width: r * 0.22, height: r * 0.18), math.pi, math.pi, false,
        _stroke(const Color(0xFF455A64), 2.4));
    c.drawOval(Rect.fromCenter(center: Offset(s * r * 0.42, r * 0.12), width: r * 0.22, height: r * 0.13), _fill(const Color(0x88F48FB1)));
  }
  c.drawArc(Rect.fromCenter(center: Offset(0, r * 0.12), width: r * 0.16, height: r * 0.12), 0, math.pi, false, _stroke(const Color(0xFF455A64), 1.8));
  // 偶爾閃一下亮晶晶
  final tw = (time * 1.3) % 1.0;
  if (tw < 0.25) {
    _star(c, Offset(r * 0.6, -r * 0.7), r * 0.12 * (1 - (tw - 0.125).abs() * 8), _fill(const Color(0xFFFFF9C4)));
  }
}
