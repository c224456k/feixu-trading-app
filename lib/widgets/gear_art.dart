part of 'hero_art.dart';

// 怪物專屬裝備的造型與配色（骷髏王雙手劍、哥布林頭巾…）。
// 造型（shape）與所屬怪物由後端表產生的 gear_catalog.dart 決定；這裡負責畫。

class _MobStyle {
  final _Pal pal;
  final String motif;
  final Color acc;
  const _MobStyle(this.pal, this.motif, this.acc);
}

const _mobStyles = <String, _MobStyle>{
  'slime': _MobStyle(_Pal(Color(0xFF5CC8F2), Color(0xFF1F7FA8), Color(0xFFC9F4FF)), 'drip', Color(0xFF7CFFB2)),
  'bat': _MobStyle(_Pal(Color(0xFF6D4B8F), Color(0xFF2E1B45), Color(0xFFB394D6)), 'wing', Color(0xFFFF5C7A)),
  'goblin': _MobStyle(_Pal(Color(0xFF7DBE4A), Color(0xFF3C6B22), Color(0xFFC5EC9A)), 'fang', Color(0xFFFFC107)),
  'wolf': _MobStyle(_Pal(Color(0xFF9AA3AD), Color(0xFF4A525C), Color(0xFFE2E8EE)), 'fur', Color(0xFFFFD27F)),
  'skeleton': _MobStyle(_Pal(Color(0xFFE6E0C8), Color(0xFF8C846A), Color(0xFFFFFFF0)), 'skull', Color(0xFF7FE8FF)),
  'orc': _MobStyle(_Pal(Color(0xFF6E8B3D), Color(0xFF3B4A20), Color(0xFFB5CC7A)), 'fang', Color(0xFFE0C080)),
  'ghost': _MobStyle(_Pal(Color(0xFFBFD8F2), Color(0xFF6A86AE), Color(0xFFFFFFFF)), 'flame', Color(0xFF9EFFF0)),
  'gargoyle': _MobStyle(_Pal(Color(0xFF8A8D96), Color(0xFF44464E), Color(0xFFC9CBD3)), 'crack', Color(0xFFFF9A3C)),
  'wyvern': _MobStyle(_Pal(Color(0xFF2FA08B), Color(0xFF145548), Color(0xFF8AF0D8)), 'scale', Color(0xFFFFE066)),
  'demon': _MobStyle(_Pal(Color(0xFFB0202F), Color(0xFF4A0A12), Color(0xFFFF7A86)), 'eye', Color(0xFFFFD43B)),
  'slimeking': _MobStyle(_Pal(Color(0xFF3F7BE0), Color(0xFF1A3A82), Color(0xFFA8C8FF)), 'drip', Color(0xFFFFD84D)),
  'batking': _MobStyle(_Pal(Color(0xFF4B2A6B), Color(0xFF1E0F30), Color(0xFF9A6BD0)), 'wing', Color(0xFFFF3B5C)),
  'skullking': _MobStyle(_Pal(Color(0xFFD9D2B4), Color(0xFF5A4F7A), Color(0xFFFFFFFF)), 'skull', Color(0xFFB36BFF)),
  'wolfking': _MobStyle(_Pal(Color(0xFFB8C6DA), Color(0xFF4C5E7A), Color(0xFFFFFFFF)), 'fur', Color(0xFF8FD3FF)),
  'lich': _MobStyle(_Pal(Color(0xFF3DAF8A), Color(0xFF163D33), Color(0xFFA2FFE0)), 'flame', Color(0xFF7CFF4D)),
  'colossus': _MobStyle(_Pal(Color(0xFF9C6B3F), Color(0xFF4E3018), Color(0xFFD9A874)), 'crack', Color(0xFFFF8A2B)),
  'firedrake': _MobStyle(_Pal(Color(0xFFE8501C), Color(0xFF6A1608), Color(0xFFFFB07A)), 'flame', Color(0xFFFFD83B)),
  'frostgiant': _MobStyle(_Pal(Color(0xFFA9DCF5), Color(0xFF3F7DA6), Color(0xFFFFFFFF)), 'frost', Color(0xFFE0FBFF)),
  'skydragon': _MobStyle(_Pal(Color(0xFFFFE08A), Color(0xFFA06A12), Color(0xFFFFFFFF)), 'scale', Color(0xFF62E6FF)),
  'demonlord': _MobStyle(_Pal(Color(0xFF2B1B3D), Color(0xFF0C0614), Color(0xFF8A4FC0)), 'eye', Color(0xFFFF2E63)),
};

Color _acc = const Color(0xFFFFD36B);

_Pal? _mobPal(String id) {
  final g = gearCatalog[id];
  return g == null ? null : _mobStyles[g.$2]?.pal;
}

// ---------- 通用小工具 ----------
Paint _line(Color color, double w) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

Path _bladePath(Offset base, Offset tip, double w, {double shoulder = 0.82}) {
  final d = tip - base;
  final len = d.distance;
  final u = d / len;
  final n = Offset(-u.dy, u.dx);
  final s = base + u * (len * shoulder);
  return _poly([base + n * (w / 2), s + n * (w / 2), tip, s - n * (w / 2), base - n * (w / 2)]);
}

/// 護手 + 握把 + 劍首（沿著 u 方向）
void _hilt(Canvas c, Offset guardC, Offset u, double guardLen, Offset gripEnd, {double gripW = 7}) {
  final n = Offset(-u.dy, u.dx);
  c.drawLine(guardC - n * (guardLen / 2), guardC + n * (guardLen / 2), _line(_gold.dark, 7.5));
  c.drawLine(guardC - n * (guardLen / 2), guardC + n * (guardLen / 2), _line(_gold.main, 5));
  c.drawLine(guardC - n * (guardLen / 2 - 1), guardC + n * (guardLen / 2 - 1), _line(_gold.light.withValues(alpha: 0.7), 1.2));
  c.drawLine(guardC, gripEnd, _line(_leather.dark, gripW + 1.6));
  c.drawLine(guardC, gripEnd, _line(_leather.main, gripW));
  final d = gripEnd - guardC;
  for (var i = 1; i < 4; i++) {
    final q = guardC + d * (i / 4);
    c.drawLine(q - n * (gripW / 2), q + n * (gripW / 2), _line(_leather.dark, 1.2));
  }
  c.drawCircle(gripEnd - u * 1.5, 5.6, Paint()..color = _gold.dark);
  c.drawCircle(gripEnd - u * 1.5, 4.4, Paint()..color = _gold.main);
  c.drawCircle(gripEnd - u * 1.5, 2.2, Paint()..color = _acc);
}

// ---------- 武器 ----------
void _greatsword(Canvas c, _Pal p) {
  const base = Offset(34, 66), tip = Offset(93, 6);
  final blade = _bladePath(base, tip, 18, shoulder: 0.88);
  _fillStroke(c, blade, p.main, p.dark);
  _shine(c, blade, p);
  c.drawLine(const Offset(38, 64), const Offset(86, 13), _line(p.light.withValues(alpha: 0.85), 2.2));
  c.drawLine(const Offset(41, 68), const Offset(88, 18), _line(p.dark.withValues(alpha: 0.55), 1.6));
  // 刃上的符文
  for (final t in [0.25, 0.45, 0.65]) {
    final q = Offset.lerp(base, tip, t)!;
    c.drawCircle(q.translate(3, 3), 1.6, Paint()..color = _acc);
  }
  _hilt(c, const Offset(30, 70), const Offset(0.695, -0.719), 38, const Offset(11, 90), gripW: 8);
  // 護手兩端的尖角
  for (final o in const [Offset(44, 83), Offset(16, 56)]) {
    c.drawCircle(o, 3.2, Paint()..color = _acc);
    c.drawCircle(o, 3.2, _line(_gold.dark, 1));
  }
}

void _dagger(Canvas c, _Pal p) {
  final blade = Path()
    ..moveTo(38, 66)
    ..quadraticBezierTo(60, 54, 88, 10)
    ..quadraticBezierTo(80, 44, 46, 72)
    ..close();
  _fillStroke(c, blade, p.main, p.dark);
  _shine(c, blade, p);
  c.drawPath(Path()..moveTo(44, 66)..quadraticBezierTo(64, 54, 82, 20), _line(p.light.withValues(alpha: 0.8), 1.6));
  _hilt(c, const Offset(36, 70), const Offset(0.7, -0.7), 24, const Offset(16, 88), gripW: 6);
}

void _axe(Canvas c, _Pal p) {
  c.drawLine(const Offset(16, 90), const Offset(72, 26), _line(_wood.dark, 8));
  c.drawLine(const Offset(16, 90), const Offset(72, 26), _line(_wood.main, 5.5));
  c.drawLine(const Offset(20, 84), const Offset(26, 78), _line(_leather.dark, 2));
  final head = Path()
    ..moveTo(58, 30)
    ..quadraticBezierTo(56, 2, 88, 6)
    ..quadraticBezierTo(100, 26, 84, 46)
    ..quadraticBezierTo(80, 32, 66, 38)
    ..close();
  _fillStroke(c, head, p.main, p.dark);
  _shine(c, head, p);
  c.drawPath(Path()..moveTo(66, 24)..quadraticBezierTo(76, 12, 88, 14), _line(p.light.withValues(alpha: 0.9), 2));
  _fillStroke(c, _poly(const [Offset(58, 26), Offset(44, 16), Offset(52, 36), Offset(62, 38)]), p.dark, p.dark, w: 1.2);
  c.drawCircle(const Offset(68, 30), 3, Paint()..color = _acc);
  c.drawCircle(const Offset(14, 92), 4, Paint()..color = _gold.main);
}

void _hammer(Canvas c, _Pal p) {
  c.drawLine(const Offset(16, 90), const Offset(66, 34), _line(_wood.dark, 8));
  c.drawLine(const Offset(16, 90), const Offset(66, 34), _line(_wood.main, 5.5));
  c.save();
  c.translate(70, 28);
  c.rotate(-0.78);
  final head = RRect.fromRectAndRadius(const Rect.fromLTWH(-24, -15, 48, 30), const Radius.circular(5));
  final hp = Path()..addRRect(head);
  _fillStroke(c, hp, p.main, p.dark);
  _shine(c, hp, p);
  c.drawRect(const Rect.fromLTWH(-24, -15, 6, 30), Paint()..color = p.dark);
  c.drawRect(const Rect.fromLTWH(18, -15, 6, 30), Paint()..color = p.dark);
  c.drawLine(const Offset(-12, -8), const Offset(12, -8), _line(p.light.withValues(alpha: 0.8), 2));
  c.drawCircle(Offset.zero, 4.5, Paint()..color = _acc);
  c.drawCircle(Offset.zero, 4.5, _line(p.dark, 1.2));
  c.restore();
  c.drawCircle(const Offset(14, 92), 4, Paint()..color = _gold.main);
}

void _spear(Canvas c, _Pal p) {
  c.drawLine(const Offset(12, 92), const Offset(78, 22), _line(_wood.dark, 6.5));
  c.drawLine(const Offset(12, 92), const Offset(78, 22), _line(_wood.main, 4));
  final head = Path()
    ..moveTo(70, 30)
    ..quadraticBezierTo(70, 10, 94, 4)
    ..quadraticBezierTo(90, 28, 74, 34)
    ..close();
  _fillStroke(c, head, p.main, p.dark);
  _shine(c, head, p);
  c.drawLine(const Offset(74, 28), const Offset(90, 9), _line(p.light, 1.4));
  // 紅色纓穗
  final tassel = Path()
    ..moveTo(66, 36)
    ..quadraticBezierTo(54, 38, 52, 54)
    ..quadraticBezierTo(62, 48, 70, 40)
    ..close();
  c.drawPath(tassel, Paint()..color = _acc);
  c.drawLine(const Offset(63, 40), const Offset(75, 28), _line(_gold.main, 4));
}

void _staff(Canvas c, _Pal p) {
  c.drawLine(const Offset(14, 92), const Offset(64, 36), _line(p.dark, 7.5));
  c.drawLine(const Offset(14, 92), const Offset(64, 36), _line(Color.lerp(p.main, _wood.main, 0.5)!, 5));
  c.drawLine(const Offset(30, 74), const Offset(36, 68), _line(_gold.main, 3));
  c.drawLine(const Offset(46, 56), const Offset(52, 50), _line(_gold.main, 3));
  // 頂端的法球與支架
  c.drawPath(Path()..moveTo(58, 44)..quadraticBezierTo(56, 22, 68, 18), _line(_gold.main, 3));
  c.drawPath(Path()..moveTo(70, 40)..quadraticBezierTo(84, 36, 82, 22), _line(_gold.main, 3));
  c.drawCircle(const Offset(72, 28), 18, Paint()..shader = RadialGradient(colors: [_acc.withValues(alpha: 0.5), Colors.transparent]).createShader(Rect.fromCircle(center: const Offset(72, 28), radius: 18)));
  c.drawCircle(const Offset(72, 28), 10, Paint()..color = _acc);
  c.drawCircle(const Offset(72, 28), 10, _line(p.dark, 1.6));
  c.drawCircle(const Offset(69, 25), 3.4, Paint()..color = Colors.white.withValues(alpha: 0.85));
}

void _scythe(Canvas c, _Pal p) {
  c.drawLine(const Offset(14, 92), const Offset(64, 20), _line(p.dark, 7));
  c.drawLine(const Offset(14, 92), const Offset(64, 20), _line(Color.lerp(p.main, Colors.black, 0.35)!, 4.4));
  final blade = Path()
    ..moveTo(60, 20)
    ..quadraticBezierTo(92, 0, 98, 42)
    ..quadraticBezierTo(82, 16, 62, 32)
    ..close();
  _fillStroke(c, blade, p.light, p.dark);
  c.drawPath(Path()..moveTo(66, 18)..quadraticBezierTo(88, 8, 94, 32), _line(_acc.withValues(alpha: 0.9), 1.6));
  c.drawCircle(const Offset(62, 28), 3.6, Paint()..color = _acc);
  c.drawCircle(const Offset(13, 93), 4, Paint()..color = _gold.main);
}

// ---------- 頭部 ----------
void _horns(Canvas c, _Pal p, {bool big = false}) {
  final tip = big ? 2.0 : 8.0;
  for (final flip in [false, true]) {
    c.save();
    if (flip) {
      c.translate(100, 0);
      c.scale(-1, 1);
    }
    final horn = Path()
      ..moveTo(24, 52)
      ..cubicTo(6, 52, tip, 30, 14, 8)
      ..cubicTo(16, 28, 30, 36, 36, 40)
      ..close();
    _fillStroke(c, horn, const Color(0xFFF1E8CE), const Color(0xFF4A3A22), w: 1.8);
    c.drawPath(Path()..moveTo(18, 40)..quadraticBezierTo(14, 26, 14, 16), _line(Colors.white.withValues(alpha: 0.7), 1.6));
    c.restore();
  }
}

void _crown(Canvas c, _Pal p, {bool skull = false}) {
  final body = Path()
    ..moveTo(16, 70)
    ..lineTo(13, 32)
    ..lineTo(30, 52)
    ..lineTo(38, 20)
    ..lineTo(50, 46)
    ..lineTo(62, 20)
    ..lineTo(70, 52)
    ..lineTo(87, 32)
    ..lineTo(84, 70)
    ..quadraticBezierTo(50, 80, 16, 70)
    ..close();
  _fillStroke(c, body, p.main, p.dark);
  _shine(c, body, p);
  for (final o in const [Offset(13, 32), Offset(38, 20), Offset(62, 20), Offset(87, 32)]) {
    c.drawCircle(o, 3.6, Paint()..color = _acc);
    c.drawCircle(o, 3.6, _line(p.dark, 1));
    c.drawCircle(o.translate(-1, -1), 1.2, Paint()..color = Colors.white.withValues(alpha: 0.9));
  }
  c.drawPath(Path()..moveTo(18, 62)..quadraticBezierTo(50, 72, 82, 62), _line(p.light.withValues(alpha: 0.8), 2));
  if (skull) {
    _motifSkull(c, const Offset(50, 56), 9, _acc);
  } else {
    final g = _poly(const [Offset(50, 48), Offset(57, 58), Offset(50, 68), Offset(43, 58)]);
    c.drawPath(g, Paint()..color = _acc);
    c.drawPath(g, _line(p.dark, 1.4));
  }
}

void _bandana(Canvas c, _Pal p) {
  final cap = Path()
    ..moveTo(16, 66)
    ..cubicTo(14, 34, 86, 34, 84, 66)
    ..cubicTo(70, 72, 30, 72, 16, 66)
    ..close();
  _fillStroke(c, cap, p.main, p.dark);
  _shine(c, cap, p);
  c.save();
  c.clipPath(cap);
  for (var i = 0; i < 6; i++) {
    c.drawLine(Offset(10.0 + i * 16, 80), Offset(30.0 + i * 16, 34), _line(p.dark.withValues(alpha: 0.35), 3));
  }
  c.restore();
  c.drawArc(const Rect.fromLTWH(18, 56, 64, 16), 0.1, math.pi - 0.2, false, _line(p.dark, 3));
  // 側邊的結與兩條飄帶
  for (final tail in [
    [const Offset(80, 62), const Offset(98, 70), const Offset(90, 76)],
    [const Offset(80, 64), const Offset(96, 86), const Offset(86, 80)],
  ]) {
    final t = _poly(tail);
    _fillStroke(c, t, p.main, p.dark, w: 1.5);
  }
  c.drawCircle(const Offset(80, 63), 5, Paint()..color = p.dark);
  c.drawCircle(const Offset(79, 62), 2, Paint()..color = p.light);
}

void _hood(Canvas c, _Pal p) {
  final outer = Path()..addOval(const Rect.fromLTWH(12, 10, 76, 88));
  final opening = Path()..addOval(const Rect.fromLTWH(21, 33, 58, 56));
  final hood = Path.combine(PathOperation.difference, outer, opening);
  _fillStroke(c, hood, p.main, p.dark, w: 2.4);
  _shine(c, hood, p);
  // 尖尖的帽頂與內襯
  final point = Path()
    ..moveTo(36, 18)
    ..quadraticBezierTo(50, 0, 74, 0)
    ..quadraticBezierTo(62, 8, 64, 20)
    ..close();
  _fillStroke(c, point, p.main, p.dark, w: 1.8);
  c.drawPath(opening, _line(p.dark, 2.6));
  c.drawPath(opening, _line(p.light.withValues(alpha: 0.5), 1));
  c.drawArc(const Rect.fromLTWH(14, 16, 72, 60), math.pi * 1.1, math.pi * 0.5, false, _line(p.light.withValues(alpha: 0.7), 3));
}

void _earCap(Canvas c, _Pal p, {bool bat = false, bool fur = false}) {
  for (final flip in [false, true]) {
    c.save();
    if (flip) {
      c.translate(100, 0);
      c.scale(-1, 1);
    }
    final ear = bat
        ? _poly(const [Offset(22, 50), Offset(14, 6), Offset(40, 36)])
        : _poly(const [Offset(22, 46), Offset(20, 14), Offset(44, 36)]);
    _fillStroke(c, ear, p.main, p.dark, w: 1.8);
    final inner = bat
        ? _poly(const [Offset(24, 44), Offset(20, 18), Offset(36, 36)])
        : _poly(const [Offset(25, 42), Offset(24, 22), Offset(38, 36)]);
    c.drawPath(inner, Paint()..color = _acc.withValues(alpha: 0.5));
    c.restore();
  }
  final cap = Path()
    ..moveTo(16, 66)
    ..cubicTo(14, 30, 86, 30, 84, 66)
    ..cubicTo(70, 72, 30, 72, 16, 66)
    ..close();
  _fillStroke(c, cap, p.main, p.dark);
  _shine(c, cap, p);
  if (fur) {
    final trim = Path()..moveTo(14, 64);
    for (var i = 0; i < 9; i++) {
      trim.lineTo(14.0 + i * 9 + 4.5, 76);
      trim.lineTo(14.0 + (i + 1) * 9, 64);
    }
    trim.close();
    _fillStroke(c, trim, p.light, p.dark, w: 1.4);
  } else {
    c.drawArc(const Rect.fromLTWH(18, 56, 64, 16), 0.1, math.pi - 0.2, false, _line(p.dark, 3));
  }
}

void _slimeCap(Canvas c, _Pal p) {
  final blob = Path()
    ..moveTo(14, 68)
    ..cubicTo(8, 30, 34, 16, 50, 16)
    ..cubicTo(66, 16, 92, 30, 86, 68)
    ..lineTo(80, 68)
    ..quadraticBezierTo(78, 82, 72, 70)
    ..quadraticBezierTo(62, 74, 56, 72)
    ..quadraticBezierTo(52, 90, 46, 72)
    ..quadraticBezierTo(34, 76, 28, 70)
    ..quadraticBezierTo(24, 80, 20, 68)
    ..close();
  c.drawPath(blob, Paint()..color = p.main.withValues(alpha: 0.92));
  _shine(c, blob, p);
  c.drawPath(blob, _line(p.dark, 2));
  c.drawOval(const Rect.fromLTWH(26, 26, 20, 10), Paint()..color = Colors.white.withValues(alpha: 0.7));
  c.drawCircle(const Offset(66, 34), 3, Paint()..color = Colors.white.withValues(alpha: 0.55));
  c.drawCircle(const Offset(50, 14), 5, Paint()..color = p.main);
  c.drawCircle(const Offset(50, 14), 5, _line(p.dark, 1.6));
}

// ---------- 披風 ----------
void _wingCloak(Canvas c, _Pal p) {
  final body = Path()
    ..moveTo(32, 12)
    ..quadraticBezierTo(50, 4, 68, 12)
    ..lineTo(97, 56)
    ..quadraticBezierTo(90, 60, 88, 68)
    ..quadraticBezierTo(82, 66, 80, 76)
    ..quadraticBezierTo(72, 72, 64, 90)
    ..quadraticBezierTo(57, 80, 50, 88)
    ..quadraticBezierTo(43, 80, 36, 90)
    ..quadraticBezierTo(28, 72, 20, 76)
    ..quadraticBezierTo(18, 66, 12, 68)
    ..quadraticBezierTo(10, 60, 3, 56)
    ..close();
  _fillStroke(c, body, p.main, p.dark);
  _shine(c, body, p);
  final bone = _line(p.dark.withValues(alpha: 0.85), 2);
  c.drawLine(const Offset(36, 14), const Offset(5, 56), bone);
  c.drawLine(const Offset(38, 16), const Offset(14, 68), bone);
  c.drawLine(const Offset(42, 18), const Offset(34, 88), bone);
  c.drawLine(const Offset(64, 14), const Offset(95, 56), bone);
  c.drawLine(const Offset(62, 16), const Offset(86, 68), bone);
  c.drawLine(const Offset(58, 18), const Offset(66, 88), bone);
  c.drawCircle(const Offset(50, 14), 5, Paint()..color = _gold.main);
  c.drawCircle(const Offset(50, 14), 5, _line(_gold.dark, 1.2));
  c.drawCircle(const Offset(50, 14), 2.2, Paint()..color = _acc);
}

// ---------- 圖騰（畫在裝備上的怪物記號） ----------
void _motifSkull(Canvas c, Offset o, double r, Color eye) {
  final skull = Path()
    ..addOval(Rect.fromCenter(center: o.translate(0, -r * 0.12), width: r * 2, height: r * 1.7))
    ..addRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: o.translate(0, r * 0.78), width: r * 1.1, height: r * 0.8), Radius.circular(r * 0.2)));
  c.drawPath(skull, Paint()..color = const Color(0xFFF4EFDC));
  c.drawPath(skull, _line(const Color(0xFF3A3224), 1.2));
  for (final dx in [-r * 0.38, r * 0.38]) {
    c.drawOval(Rect.fromCenter(center: o.translate(dx, -r * 0.1), width: r * 0.62, height: r * 0.72), Paint()..color = const Color(0xFF1B1710));
    c.drawCircle(o.translate(dx, -r * 0.08), r * 0.13, Paint()..color = eye);
  }
  c.drawPath(_poly([o.translate(0, r * 0.2), o.translate(-r * 0.12, r * 0.42), o.translate(r * 0.12, r * 0.42)]), Paint()..color = const Color(0xFF1B1710));
  for (var i = -1; i <= 1; i++) {
    c.drawLine(o.translate(i * r * 0.28, r * 0.5), o.translate(i * r * 0.28, r * 1.06), _line(const Color(0xFF3A3224), 0.9));
  }
}

void _motif(Canvas c, String slot, String m, _Pal p) {
  final pos = const {
    'head': Offset(50, 40),
    'armor': Offset(50, 66),
    'boots': Offset(54, 68),
    'gloves': Offset(50, 64),
    'cloak': Offset(50, 66),
    'belt': Offset(50, 50),
    'ring': Offset(50, 21),
    'amulet': Offset(50, 72),
  }[slot];
  if (pos == null) return;
  final r = const {'head': 8.0, 'armor': 10.0, 'boots': 6.0, 'gloves': 7.0, 'cloak': 9.0, 'belt': 8.0, 'ring': 5.0, 'amulet': 12.0}[slot]!;
  final dark = _line(p.dark, 1.2);
  switch (m) {
    case 'skull':
      _motifSkull(c, pos, r, _acc);
    case 'fang':
      for (final dx in [-0.5, 0.5]) {
        final f = Path()
          ..moveTo(pos.dx + dx * r * 1.4 - r * 0.35, pos.dy - r * 0.8)
          ..quadraticBezierTo(pos.dx + dx * r * 1.4, pos.dy, pos.dx + dx * r * 1.1, pos.dy + r * 0.9)
          ..quadraticBezierTo(pos.dx + dx * r * 1.4 + r * 0.1, pos.dy - r * 0.1, pos.dx + dx * r * 1.4 + r * 0.35, pos.dy - r * 0.8)
          ..close();
        c.drawPath(f, Paint()..color = const Color(0xFFFFF6DC));
        c.drawPath(f, _line(const Color(0xFF5A4A30), 1));
      }
    case 'drip':
      final d = Path()
        ..moveTo(pos.dx, pos.dy - r)
        ..quadraticBezierTo(pos.dx + r * 1.1, pos.dy + r * 0.2, pos.dx, pos.dy + r)
        ..quadraticBezierTo(pos.dx - r * 1.1, pos.dy + r * 0.2, pos.dx, pos.dy - r)
        ..close();
      c.drawPath(d, Paint()..color = _acc.withValues(alpha: 0.85));
      c.drawPath(d, dark);
      c.drawCircle(pos.translate(-r * 0.3, -r * 0.1), r * 0.22, Paint()..color = Colors.white.withValues(alpha: 0.85));
    case 'wing':
      for (final flip in [-1.0, 1.0]) {
        final w = Path()
          ..moveTo(pos.dx, pos.dy)
          ..quadraticBezierTo(pos.dx + flip * r * 0.8, pos.dy - r * 1.1, pos.dx + flip * r * 1.7, pos.dy - r * 0.5)
          ..quadraticBezierTo(pos.dx + flip * r * 1.3, pos.dy, pos.dx + flip * r * 1.4, pos.dy + r * 0.5)
          ..quadraticBezierTo(pos.dx + flip * r * 0.8, pos.dy + r * 0.2, pos.dx, pos.dy + r * 0.5)
          ..close();
        c.drawPath(w, Paint()..color = _acc);
        c.drawPath(w, dark);
      }
    case 'fur':
      final z = Path()..moveTo(pos.dx - r * 1.3, pos.dy);
      for (var i = 0; i < 5; i++) {
        z.lineTo(pos.dx - r * 1.3 + (i + 0.5) * r * 0.52, pos.dy + (i.isEven ? r * 0.9 : -r * 0.3));
        z.lineTo(pos.dx - r * 1.3 + (i + 1) * r * 0.52, pos.dy);
      }
      c.drawPath(z, _line(p.light, 2.4));
      c.drawPath(z, _line(p.dark.withValues(alpha: 0.5), 0.8));
    case 'scale':
      for (var row = 0; row < 2; row++) {
        for (var i = 0; i < 3 - row; i++) {
          final o = Offset(pos.dx + (i - (2 - row) / 2) * r * 0.9, pos.dy + row * r * 0.65 - r * 0.3);
          c.drawArc(Rect.fromCenter(center: o, width: r * 0.95, height: r * 0.95), 0, math.pi, false, _line(_acc, 1.8));
          c.drawArc(Rect.fromCenter(center: o, width: r * 0.95, height: r * 0.95), 0, math.pi, false, _line(p.dark.withValues(alpha: 0.4), 0.7));
        }
      }
    case 'flame':
      final f = Path()
        ..moveTo(pos.dx, pos.dy - r * 1.2)
        ..quadraticBezierTo(pos.dx + r * 0.2, pos.dy - r * 0.3, pos.dx + r * 0.8, pos.dy - r * 0.2)
        ..quadraticBezierTo(pos.dx + r * 1.0, pos.dy + r * 0.9, pos.dx, pos.dy + r)
        ..quadraticBezierTo(pos.dx - r * 1.0, pos.dy + r * 0.9, pos.dx - r * 0.7, pos.dy - r * 0.1)
        ..quadraticBezierTo(pos.dx - r * 0.3, pos.dy - r * 0.2, pos.dx, pos.dy - r * 1.2)
        ..close();
      c.drawPath(f, Paint()..color = _acc);
      c.drawPath(f, dark);
      c.drawCircle(pos.translate(0, r * 0.35), r * 0.38, Paint()..color = Colors.white.withValues(alpha: 0.85));
    case 'crack':
      final k = Path()
        ..moveTo(pos.dx - r * 0.2, pos.dy - r * 1.1)
        ..lineTo(pos.dx + r * 0.3, pos.dy - r * 0.3)
        ..lineTo(pos.dx - r * 0.3, pos.dy + r * 0.1)
        ..lineTo(pos.dx + r * 0.4, pos.dy + r * 0.9);
      c.drawPath(k, _line(const Color(0xFF1A1108), 3.6));
      c.drawPath(k, _line(_acc, 1.8));
    case 'frost':
      for (var i = 0; i < 3; i++) {
        final a = i * math.pi / 3;
        final d = Offset(math.cos(a), math.sin(a)) * r;
        c.drawLine(pos - d, pos + d, _line(_acc, 2));
        c.drawLine(pos - d, pos + d, _line(p.dark.withValues(alpha: 0.35), 0.7));
      }
      c.drawCircle(pos, r * 0.28, Paint()..color = Colors.white);
    case 'eye':
      final e = Path()
        ..moveTo(pos.dx - r * 1.3, pos.dy)
        ..quadraticBezierTo(pos.dx, pos.dy - r * 1.2, pos.dx + r * 1.3, pos.dy)
        ..quadraticBezierTo(pos.dx, pos.dy + r * 1.2, pos.dx - r * 1.3, pos.dy)
        ..close();
      c.drawPath(e, Paint()..color = const Color(0xFF14080C));
      c.drawPath(e, _line(_acc, 1.6));
      c.drawOval(Rect.fromCenter(center: pos, width: r * 0.8, height: r * 1.4), Paint()..color = _acc);
      c.drawOval(Rect.fromCenter(center: pos, width: r * 0.22, height: r * 1.2), Paint()..color = const Color(0xFF14080C));
  }
}

// ---------- 高階裝備的底光（只畫在圖示上，不畫在紙娃娃身上） ----------
void _tierGlow(Canvas c, int tier) {
  final g = _gemColors[tier.clamp(0, 5)];
  c.drawCircle(
    const Offset(50, 52),
    48,
    Paint()
      ..shader = RadialGradient(colors: [g.withValues(alpha: tier >= 5 ? 0.38 : 0.26), Colors.transparent])
          .createShader(Rect.fromCircle(center: const Offset(50, 52), radius: 48)),
  );
}

// 高階頭盔的盔纓（史詩以上再多一對小翅膀）
void _helmFlair(Canvas c, int tier, _Pal p, {bool wings = true}) {
  if (tier < 3) return;
  final col = _gemColors[tier.clamp(0, 5)];
  final plume = Path()
    ..moveTo(46, 30)
    ..cubicTo(40, 8, 64, 0, 90, 14)
    ..cubicTo(74, 14, 62, 24, 56, 34)
    ..close();
  _fillStroke(c, plume, col, p.dark, w: 1.4);
  c.drawPath(Path()..moveTo(52, 28)..quadraticBezierTo(64, 14, 84, 14), _line(Colors.white.withValues(alpha: 0.6), 1.2));
  if (tier >= 4 && wings) {
    for (final flip in [false, true]) {
      c.save();
      if (flip) {
        c.translate(100, 0);
        c.scale(-1, 1);
      }
      final w = Path()
        ..moveTo(18, 54)
        ..quadraticBezierTo(2, 50, 0, 30)
        ..quadraticBezierTo(8, 38, 12, 36)
        ..quadraticBezierTo(8, 28, 12, 22)
        ..quadraticBezierTo(18, 34, 22, 36)
        ..quadraticBezierTo(18, 44, 22, 48)
        ..close();
      _fillStroke(c, w, Colors.white, col, w: 1.4);
      c.restore();
    }
  }
}
