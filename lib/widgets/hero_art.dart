import 'dart:math' as math;

import 'package:flutter/material.dart';

// 勇者紙娃娃的手繪素材：每個裝備欄一種圖示、依材質上色，勇者本人會穿上裝備顯示出來。
// 全部用 CustomPainter 畫（不用圖檔），座標統一用 0~100 的方框，再縮放到實際大小。

class _Pal {
  final Color main, dark, light;
  final bool rusty;
  const _Pal(this.main, this.dark, this.light, {this.rusty = false});
}

const _iron = _Pal(Color(0xFF8A9099), Color(0xFF4B5058), Color(0xFFC4CAD2));
const _rustIron = _Pal(
  Color(0xFF7C7F84),
  Color(0xFF45474B),
  Color(0xFFB0B3B8),
  rusty: true,
);
const _cloth = _Pal(Color(0xFFBBA67E), Color(0xFF7D6A48), Color(0xFFE3D6B4));
const _leather = _Pal(Color(0xFF8E5C2D), Color(0xFF56351A), Color(0xFFBC8650));
const _wood = _Pal(Color(0xFF9E6C3B), Color(0xFF5E3D1E), Color(0xFFC99759));
const _copper = _Pal(Color(0xFFC97C3C), Color(0xFF7A4318), Color(0xFFF2B374));
const _silver = _Pal(Color(0xFFCBD4DE), Color(0xFF76818E), Color(0xFFFFFFFF));
const _gold = _Pal(Color(0xFFE2B33C), Color(0xFF8A6612), Color(0xFFFFE58A));

const _steel = _Pal(Color(0xFF9DB0C4), Color(0xFF4F6176), Color(0xFFDCE8F5));
const _mithril = _Pal(Color(0xFF69D2E7), Color(0xFF2B7A8C), Color(0xFFD5F8FF));
const _jade = _Pal(Color(0xFF4CC38A), Color(0xFF1F6E49), Color(0xFFBFF5D8));
const _dragon = _Pal(Color(0xFFC8423B), Color(0xFF6E1B18), Color(0xFFFF9C8F));
const _shadow = _Pal(Color(0xFF7A5BC0), Color(0xFF38245F), Color(0xFFC8B2F5));
const _star = _Pal(Color(0xFFFFE9A0), Color(0xFF9C7A22), Color(0xFFFFFFFF));

_Pal _palFor(String id, int tier) {
  if (id.startsWith('bronze')) return _copper;
  if (id.startsWith('iron')) return _iron;
  if (id.startsWith('steel')) return _steel;
  if (id.startsWith('mithril')) return _mithril;
  if (id.startsWith('jade')) return _jade;
  if (id.startsWith('dragon')) return _dragon;
  if (id.startsWith('shadow')) return _shadow;
  if (id.startsWith('holy')) return _gold;
  if (id.startsWith('star')) return _star;
  if (id.startsWith('rusty')) return _rustIron;
  if (id.contains('silver')) return _silver;
  if (id.contains('copper')) return _copper;
  if (id.contains('leather')) return _leather;
  if (id.contains('wood')) return _wood;
  if (id.contains('cloth') ||
      id.contains('straw') ||
      id.contains('rope') ||
      id.contains('work') ||
      id.contains('old_')) {
    return _cloth;
  }
  return tier >= 4 ? _gold : _iron;
}

Path _poly(List<Offset> pts) {
  final p = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (final o in pts.skip(1)) {
    p.lineTo(o.dx, o.dy);
  }
  return p..close();
}

void _fillStroke(Canvas c, Path p, Color fill, Color edge, {double w = 2}) {
  c.drawPath(p, Paint()..color = fill);
  c.drawPath(
    p,
    Paint()
      ..color = edge
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeJoin = StrokeJoin.round,
  );
}

void _shine(Canvas c, Path p, _Pal pal) {
  // 左上角打亮、右下角壓暗，讓平面圖形有立體感
  c.save();
  c.clipPath(p);
  final b = p.getBounds();
  c.drawRect(
    b,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          pal.light.withValues(alpha: 0.55),
          Colors.transparent,
          pal.dark.withValues(alpha: 0.45),
        ],
        stops: const [0, 0.45, 1],
      ).createShader(b),
  );
  c.restore();
}

void _rustSpots(Canvas c, Path p, List<Offset> spots) {
  c.save();
  c.clipPath(p);
  for (final s in spots) {
    c.drawCircle(s, 3.2, Paint()..color = const Color(0xAA8B4A1E));
    c.drawCircle(
      s.translate(2.5, 1.5),
      1.8,
      Paint()..color = const Color(0x99A8581F),
    );
  }
  c.restore();
}

/// 單件裝備圖示。slot 用 head/weapon/armor/boots/gloves/cloak/belt/ring/amulet（ring1、ring2 也可以）。
/// itemId 為 null 代表空欄位：畫一個暗淡的輪廓。
class ItemIcon extends StatelessWidget {
  final String slot;
  final String? itemId;
  final int tier;
  final double size;
  const ItemIcon({
    super.key,
    required this.slot,
    this.itemId,
    this.tier = 0,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: ItemIconPainter(slot, itemId, tier)),
  );
}

class ItemIconPainter extends CustomPainter {
  final String slot;
  final String? itemId;
  final int tier;
  ItemIconPainter(this.slot, this.itemId, this.tier);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    if (itemId == null) {
      canvas.saveLayer(
        const Rect.fromLTWH(0, 0, 100, 100),
        Paint()..color = const Color(0x40FFFFFF),
      );
      _drawItem(
        canvas,
        slot,
        'empty',
        const _Pal(Color(0xFF6B6048), Color(0xFF3A3322), Color(0xFF8C8062)),
        0,
      );
      canvas.restore();
    } else {
      _drawItem(canvas, slot, itemId!, _palFor(itemId!, tier), tier);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ItemIconPainter old) =>
      old.slot != slot || old.itemId != itemId || old.tier != tier;
}

/// 在 0~100 方框內畫一件裝備（紙娃娃也會重複用，畫在人物身上）
void _drawItem(Canvas c, String slot, String id, _Pal pal, int tier, {bool sparkles = true}) {
  final s = slot.startsWith('ring') ? 'ring' : slot;
  switch (s) {
    case 'weapon':
      id.contains('club') ? _club(c, pal) : _sword(c, pal);
    case 'head':
      id.contains('cap') ? _cap(c, pal) : _helm(c, pal);
    case 'armor':
      id.contains('cloth') ? _tunic(c, pal) : _plate(c, pal);
    case 'boots':
      id.contains('straw') ? _sandals(c, pal) : _boots(c, pal);
    case 'gloves':
      _gloves(c, pal);
    case 'cloak':
      _cloak(c, pal);
    case 'belt':
      id.contains('rope') ? _ropeBelt(c, pal) : _belt(c, pal);
    case 'ring':
      _ring(c, pal, id.contains('silver'));
    case 'amulet':
      _amulet(c, pal);
  }
  if (id != 'empty') _ornament(c, s, tier, sparkles: sparkles);
}

const _gemColors = [
  Color(0xFF9A9A9A),
  Color(0xFFE8D9A8),
  Color(0xFF4CD964),
  Color(0xFF3FA9FF),
  Color(0xFFB36BFF),
  Color(0xFFFFD36B),
];

void _sparkle(Canvas c, Offset o, double r, Color color) {
  final p = Path()
    ..moveTo(o.dx, o.dy - r)
    ..quadraticBezierTo(o.dx, o.dy, o.dx + r, o.dy)
    ..quadraticBezierTo(o.dx, o.dy, o.dx, o.dy + r)
    ..quadraticBezierTo(o.dx, o.dy, o.dx - r, o.dy)
    ..quadraticBezierTo(o.dx, o.dy, o.dx, o.dy - r)
    ..close();
  c.drawPath(p, Paint()..color = color);
}

// 高階裝備的裝飾：精良起鑲寶石、史詩起加閃光（寶石顏色對應品階）
void _ornament(Canvas c, String slot, int tier, {bool sparkles = true}) {
  if (tier < 2) return;
  final color = _gemColors[tier.clamp(0, 5)];
  final pos = {
    'head': const Offset(50, 36),
    'weapon': const Offset(36, 71),
    'armor': const Offset(50, 54),
    'boots': const Offset(43, 36),
    'gloves': const Offset(50, 56),
    'cloak': const Offset(50, 14),
    'belt': const Offset(50, 50),
    'amulet': const Offset(50, 72),
  }[slot];
  if (pos != null) {
    final r = 3.2 + tier * 0.7;
    final g = _poly([pos.translate(0, -r), pos.translate(r * 0.85, 0), pos.translate(0, r), pos.translate(-r * 0.85, 0)]);
    c.drawPath(g, Paint()..color = color);
    c.drawPath(
        g,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
    c.drawPath(_poly([pos.translate(0, -r), pos.translate(r * 0.4, -r * 0.1), pos.translate(0, 0), pos.translate(-r * 0.4, -r * 0.1)]),
        Paint()..color = Colors.white.withValues(alpha: 0.75));
  }
  if (!sparkles) return;
  if (tier >= 4) {
    _sparkle(c, const Offset(88, 14), 7, Colors.white.withValues(alpha: 0.9));
    _sparkle(c, const Offset(12, 34), 4.5, color.withValues(alpha: 0.9));
  }
  if (tier >= 5) {
    _sparkle(c, const Offset(90, 84), 5, Colors.white.withValues(alpha: 0.85));
  }
}

void _sword(Canvas c, _Pal p) {
  final blade = _poly(const [
    Offset(32, 66),
    Offset(78, 12),
    Offset(90, 10),
    Offset(88, 22),
    Offset(42, 76),
  ]);
  _fillStroke(c, blade, p.main, p.dark);
  _shine(c, blade, p);
  // 血槽
  c.drawLine(
    const Offset(40, 66),
    const Offset(82, 17),
    Paint()
      ..color = p.dark.withValues(alpha: 0.5)
      ..strokeWidth = 1.6,
  );
  if (p.rusty) {
    _rustSpots(c, blade, const [
      Offset(50, 52),
      Offset(66, 34),
      Offset(76, 20),
      Offset(40, 66),
    ]);
    // 缺口
    c.drawPath(
      _poly(const [Offset(60, 42), Offset(66, 44), Offset(63, 48)]),
      Paint()..color = const Color(0xFF14110B),
    );
  }
  // 護手
  final guard = _poly(const [
    Offset(20, 60),
    Offset(30, 58),
    Offset(46, 74),
    Offset(44, 82),
    Offset(36, 84),
  ]);
  _fillStroke(c, guard, _wood.dark, const Color(0xFF2E1D0C));
  c.drawLine(
    const Offset(24, 62),
    const Offset(40, 80),
    Paint()
      ..color = _gold.main
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round,
  );
  // 握把與劍首
  c.drawLine(
    const Offset(30, 72),
    const Offset(14, 88),
    Paint()
      ..color = _leather.main
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round,
  );
  c.drawLine(
    const Offset(26, 76),
    const Offset(20, 82),
    Paint()
      ..color = _leather.dark
      ..strokeWidth = 2,
  );
  c.drawCircle(const Offset(12, 90), 5, Paint()..color = _gold.main);
  c.drawCircle(const Offset(11, 89), 1.8, Paint()..color = _gold.light);
}

void _club(Canvas c, _Pal p) {
  final body = Path()
    ..moveTo(18, 88)
    ..lineTo(26, 92)
    ..lineTo(56, 56)
    ..cubicTo(64, 62, 86, 42, 84, 22)
    ..cubicTo(82, 8, 62, 8, 54, 20)
    ..cubicTo(46, 30, 52, 42, 52, 46)
    ..close();
  _fillStroke(c, body, p.main, p.dark);
  _shine(c, body, p);
  // 木紋與鐵釘
  final grain = Paint()
    ..color = p.dark.withValues(alpha: 0.55)
    ..strokeWidth = 1.4
    ..style = PaintingStyle.stroke;
  c.drawArc(const Rect.fromLTWH(56, 14, 24, 28), 0.4, 2.0, false, grain);
  c.drawArc(const Rect.fromLTWH(60, 20, 18, 20), 0.2, 2.0, false, grain);
  for (final o in const [Offset(64, 20), Offset(76, 24), Offset(70, 34)]) {
    c.drawCircle(o, 1.8, Paint()..color = const Color(0xFFB9BEC6));
  }
  c.drawLine(
    const Offset(24, 84),
    const Offset(34, 76),
    Paint()
      ..color = _leather.main
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round,
  );
}

void _helm(Canvas c, _Pal p) {
  final dome = Path()
    ..moveTo(18, 70)
    ..lineTo(18, 50)
    ..cubicTo(18, 22, 82, 22, 82, 50)
    ..lineTo(82, 70)
    ..lineTo(66, 70)
    ..lineTo(66, 58)
    ..lineTo(34, 58)
    ..lineTo(34, 70)
    ..close();
  _fillStroke(c, dome, p.main, p.dark);
  _shine(c, dome, p);
  // 鼻樑護甲與面罩縫
  _fillStroke(
    c,
    _poly(const [
      Offset(46, 40),
      Offset(54, 40),
      Offset(54, 66),
      Offset(50, 72),
      Offset(46, 66),
    ]),
    p.dark,
    p.dark.withValues(alpha: 0.8),
    w: 1,
  );
  c.drawLine(
    const Offset(30, 52),
    const Offset(70, 52),
    Paint()
      ..color = const Color(0xFF14110B)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round,
  );
  // 鉚釘
  for (final x in [26.0, 74.0]) {
    c.drawCircle(Offset(x, 64), 2, Paint()..color = p.light);
  }
  c.drawArc(
    const Rect.fromLTWH(24, 28, 52, 36),
    math.pi * 1.1,
    math.pi * 0.5,
    false,
    Paint()
      ..color = p.light.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round,
  );
  if (p.rusty) {
    _rustSpots(c, dome, const [
      Offset(28, 40),
      Offset(70, 36),
      Offset(60, 62),
      Offset(24, 60),
    ]);
    c.drawPath(
      _poly(const [
        Offset(42, 30),
        Offset(50, 36),
        Offset(46, 40),
        Offset(40, 36),
      ]),
      Paint()..color = const Color(0xFF14110B),
    );
  }
}

void _cap(Canvas c, _Pal p) {
  final cap = Path()
    ..moveTo(16, 66)
    ..cubicTo(14, 30, 86, 30, 84, 66)
    ..cubicTo(70, 72, 30, 72, 16, 66)
    ..close();
  _fillStroke(c, cap, p.main, p.dark);
  _shine(c, cap, p);
  c.drawArc(
    const Rect.fromLTWH(18, 56, 64, 16),
    0.1,
    math.pi - 0.2,
    false,
    Paint()
      ..color = p.dark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3,
  );
  final st = Paint()
    ..color = p.light
    ..strokeWidth = 1.2;
  for (var i = 0; i < 7; i++) {
    c.drawLine(
      Offset(24.0 + i * 8.5, 66 + (i % 2)),
      Offset(25.0 + i * 8.5, 69),
      st,
    );
  }
  _fillStroke(
    c,
    _poly(const [
      Offset(60, 34),
      Offset(76, 20),
      Offset(80, 30),
      Offset(66, 40),
    ]),
    _cloth.light,
    _cloth.dark,
    w: 1.5,
  ); // 羽毛
}

void _plate(Canvas c, _Pal p) {
  final body = Path()
    ..moveTo(20, 30)
    ..lineTo(38, 20)
    ..quadraticBezierTo(50, 32, 62, 20)
    ..lineTo(80, 30)
    ..lineTo(76, 52)
    ..lineTo(70, 82)
    ..quadraticBezierTo(50, 94, 30, 82)
    ..lineTo(24, 52)
    ..close();
  _fillStroke(c, body, p.main, p.dark);
  _shine(c, body, p);
  c.drawLine(
    const Offset(50, 30),
    const Offset(50, 88),
    Paint()
      ..color = p.dark
      ..strokeWidth = 2,
  );
  c.drawArc(
    const Rect.fromLTWH(28, 36, 44, 30),
    0.2,
    math.pi - 0.4,
    false,
    Paint()
      ..color = p.dark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );
  for (final o in const [
    Offset(30, 32),
    Offset(70, 32),
    Offset(34, 74),
    Offset(66, 74),
  ]) {
    c.drawCircle(o, 2, Paint()..color = p.light);
  }
}

void _tunic(Canvas c, _Pal p) {
  final body = Path()
    ..moveTo(12, 36)
    ..lineTo(34, 18)
    ..quadraticBezierTo(50, 30, 66, 18)
    ..lineTo(88, 36)
    ..lineTo(78, 50)
    ..lineTo(74, 46)
    ..lineTo(74, 88)
    ..lineTo(26, 88)
    ..lineTo(26, 46)
    ..lineTo(22, 50)
    ..close();
  _fillStroke(c, body, p.main, p.dark);
  _shine(c, body, p);
  // 領口綁帶、縫線、補丁
  c.drawLine(
    const Offset(44, 24),
    const Offset(44, 40),
    Paint()
      ..color = p.dark
      ..strokeWidth = 1.6,
  );
  c.drawLine(
    const Offset(56, 24),
    const Offset(56, 40),
    Paint()
      ..color = p.dark
      ..strokeWidth = 1.6,
  );
  final dash = Paint()
    ..color = p.dark
    ..strokeWidth = 1.2;
  for (var y = 50.0; y < 86; y += 6) {
    c.drawLine(Offset(50, y), Offset(50, y + 3), dash);
  }
  _fillStroke(
    c,
    Path()..addRect(const Rect.fromLTWH(56, 58, 14, 12)),
    _leather.main,
    _leather.dark,
    w: 1.2,
  );
  c.drawRect(
    const Rect.fromLTWH(58, 60, 10, 8),
    Paint()
      ..color = _leather.dark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8,
  );
}

void _boots(Canvas c, _Pal p) {
  final b = Path()
    ..moveTo(30, 14)
    ..lineTo(56, 14)
    ..lineTo(56, 56)
    ..cubicTo(70, 58, 86, 64, 88, 78)
    ..lineTo(88, 86)
    ..lineTo(26, 86)
    ..lineTo(26, 74)
    ..lineTo(30, 70)
    ..close();
  _fillStroke(c, b, p.main, p.dark);
  _shine(c, b, p);
  c.drawRect(const Rect.fromLTWH(24, 82, 66, 6), Paint()..color = p.dark);
  c.drawRect(
    const Rect.fromLTWH(28, 12, 30, 9),
    Paint()..color = p.light.withValues(alpha: 0.8),
  );
  c.drawRect(
    const Rect.fromLTWH(28, 12, 30, 9),
    Paint()
      ..color = p.dark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4,
  );
  final lace = Paint()
    ..color = p.dark
    ..strokeWidth = 1.6;
  for (var y = 28.0; y < 54; y += 8) {
    c.drawLine(Offset(34, y), Offset(52, y + 4), lace);
  }
  c.drawCircle(const Offset(44, 56), 2, Paint()..color = _gold.main);
}

void _sandals(Canvas c, _Pal p) {
  final sole = Path()
    ..moveTo(20, 74)
    ..cubicTo(20, 62, 36, 58, 50, 62)
    ..cubicTo(70, 54, 90, 62, 90, 76)
    ..cubicTo(90, 88, 60, 90, 40, 88)
    ..cubicTo(26, 88, 20, 84, 20, 74)
    ..close();
  _fillStroke(c, sole, p.main, p.dark);
  _shine(c, sole, p);
  final straw = Paint()
    ..color = p.dark.withValues(alpha: 0.7)
    ..strokeWidth = 1.2;
  for (var x = 28.0; x < 86; x += 7) {
    c.drawLine(Offset(x, 66 + (x < 50 ? 6 : 0)), Offset(x - 4, 86), straw);
  }
  c.drawLine(
    const Offset(40, 60),
    const Offset(52, 40),
    Paint()
      ..color = _leather.main
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round,
  );
  c.drawLine(
    const Offset(70, 60),
    const Offset(54, 40),
    Paint()
      ..color = _leather.main
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round,
  );
}

void _gloves(Canvas c, _Pal p) {
  final g = Path()
    ..moveTo(30, 52)
    ..lineTo(26, 32)
    ..quadraticBezierTo(26, 26, 32, 28)
    ..lineTo(34, 40)
    ..lineTo(36, 18)
    ..quadraticBezierTo(37, 12, 43, 14)
    ..lineTo(45, 38)
    ..lineTo(47, 14)
    ..quadraticBezierTo(49, 8, 55, 11)
    ..lineTo(56, 38)
    ..lineTo(60, 18)
    ..quadraticBezierTo(63, 12, 68, 16)
    ..lineTo(66, 44)
    ..lineTo(74, 36)
    ..quadraticBezierTo(80, 34, 80, 40)
    ..lineTo(70, 62)
    ..lineTo(68, 72)
    ..lineTo(34, 72)
    ..close();
  _fillStroke(c, g, p.main, p.dark);
  _shine(c, g, p);
  final cuff = Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(30, 70, 40, 20),
        const Radius.circular(3),
      ),
    );
  _fillStroke(c, cuff, p.dark, const Color(0xFF2A2214));
  final seam = Paint()
    ..color = p.light.withValues(alpha: 0.6)
    ..strokeWidth = 1.4;
  c.drawLine(const Offset(36, 76), const Offset(64, 76), seam);
  c.drawLine(const Offset(36, 84), const Offset(64, 84), seam);
}

void _cloak(Canvas c, _Pal p) {
  final body = Path()
    ..moveTo(32, 12)
    ..quadraticBezierTo(50, 4, 68, 12)
    ..lineTo(88, 82)
    ..quadraticBezierTo(80, 92, 72, 84)
    ..quadraticBezierTo(62, 94, 50, 86)
    ..quadraticBezierTo(38, 94, 28, 84)
    ..quadraticBezierTo(20, 92, 12, 82)
    ..close();
  _fillStroke(c, body, p.main, p.dark);
  _shine(c, body, p);
  final fold = Paint()
    ..color = p.dark.withValues(alpha: 0.6)
    ..strokeWidth = 1.6
    ..style = PaintingStyle.stroke;
  c.drawLine(const Offset(42, 18), const Offset(30, 82), fold);
  c.drawLine(const Offset(50, 18), const Offset(50, 84), fold);
  c.drawLine(const Offset(58, 18), const Offset(70, 82), fold);
  // 補丁與領扣
  c.drawRect(
    const Rect.fromLTWH(58, 50, 14, 12),
    Paint()..color = _leather.main,
  );
  c.drawRect(
    const Rect.fromLTWH(58, 50, 14, 12),
    Paint()
      ..color = _leather.dark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1,
  );
  c.drawRect(
    const Rect.fromLTWH(26, 66, 11, 10),
    Paint()..color = _cloth.light,
  );
  c.drawRect(
    const Rect.fromLTWH(26, 66, 11, 10),
    Paint()
      ..color = _cloth.dark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1,
  );
  c.drawCircle(const Offset(50, 14), 4.5, Paint()..color = _gold.main);
  c.drawCircle(const Offset(49, 13), 1.6, Paint()..color = _gold.light);
}

void _belt(Canvas c, _Pal p) {
  final band = Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(6, 38, 88, 24),
        const Radius.circular(4),
      ),
    );
  _fillStroke(c, band, p.main, p.dark);
  _shine(c, band, p);
  for (var x = 14.0; x < 90; x += 9) {
    c.drawCircle(Offset(x, 50), 1.3, Paint()..color = p.light);
  }
  _fillStroke(
    c,
    Path()..addRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(36, 32, 28, 36),
        const Radius.circular(4),
      ),
    ),
    _gold.main,
    _gold.dark,
  );
  c.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(42, 38, 16, 24),
      const Radius.circular(2),
    ),
    Paint()
      ..color = _gold.dark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4,
  );
  c.drawLine(
    const Offset(50, 41),
    const Offset(50, 59),
    Paint()
      ..color = _gold.dark
      ..strokeWidth = 2,
  );
}

void _ropeBelt(Canvas c, _Pal p) {
  final base = Paint()
    ..color = p.main
    ..strokeWidth = 11
    ..strokeCap = StrokeCap.round;
  c.drawLine(const Offset(10, 50), const Offset(90, 50), base);
  final twist = Paint()
    ..color = p.dark
    ..strokeWidth = 1.8;
  for (var x = 12.0; x < 88; x += 6) {
    c.drawLine(Offset(x, 46), Offset(x + 4, 55), twist);
  }
  c.drawLine(
    const Offset(10, 45),
    const Offset(90, 45),
    Paint()
      ..color = p.light.withValues(alpha: 0.7)
      ..strokeWidth = 1.4,
  );
  // 繩結與垂下的兩端
  c.drawCircle(const Offset(50, 50), 9, Paint()..color = p.main);
  c.drawCircle(
    const Offset(50, 50),
    9,
    Paint()
      ..color = p.dark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );
  final tail = Paint()
    ..color = p.main
    ..strokeWidth = 6
    ..strokeCap = StrokeCap.round;
  c.drawLine(const Offset(46, 56), const Offset(40, 82), tail);
  c.drawLine(const Offset(54, 56), const Offset(60, 80), tail);
}

void _ring(Canvas c, _Pal p, bool gem) {
  c.drawCircle(
    const Offset(50, 58),
    26,
    Paint()
      ..color = p.dark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13,
  );
  c.drawCircle(
    const Offset(50, 58),
    26,
    Paint()
      ..color = p.main
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9,
  );
  c.drawArc(
    const Rect.fromLTWH(24, 32, 52, 52),
    math.pi * 0.95,
    math.pi * 0.55,
    false,
    Paint()
      ..color = p.light
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round,
  );
  // 戒台與寶石
  final seat = _poly(const [
    Offset(38, 30),
    Offset(62, 30),
    Offset(68, 18),
    Offset(32, 18),
  ]);
  _fillStroke(c, seat, p.main, p.dark);
  if (gem) {
    final g = _poly(const [
      Offset(50, 4),
      Offset(64, 14),
      Offset(50, 28),
      Offset(36, 14),
    ]);
    _fillStroke(c, g, const Color(0xFF4FA8FF), const Color(0xFF1B4F8F));
    c.drawPath(
      _poly(const [Offset(50, 4), Offset(57, 14), Offset(50, 14)]),
      Paint()..color = const Color(0xFFB8E0FF),
    );
  } else {
    c.drawCircle(const Offset(50, 20), 6, Paint()..color = p.light);
    c.drawCircle(
      const Offset(50, 20),
      6,
      Paint()
        ..color = p.dark
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }
}

void _amulet(Canvas c, _Pal p) {
  final chain = Paint()
    ..color = const Color(0xFF8A7440)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.4;
  final cp = Path()
    ..moveTo(20, 6)
    ..quadraticBezierTo(24, 44, 50, 52)
    ..quadraticBezierTo(76, 44, 80, 6);
  c.drawPath(cp, chain);
  // 木頭護身符：圓形木片、刻符文、紅繩
  c.drawLine(
    const Offset(50, 48),
    const Offset(50, 54),
    Paint()
      ..color = const Color(0xFFB4342C)
      ..strokeWidth = 3,
  );
  c.drawCircle(const Offset(50, 72), 21, Paint()..color = p.dark);
  c.drawCircle(const Offset(50, 72), 18, Paint()..color = p.main);
  c.drawArc(
    const Rect.fromLTWH(34, 56, 32, 32),
    math.pi * 1.0,
    math.pi * 0.5,
    false,
    Paint()
      ..color = p.light
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round,
  );
  final rune = Paint()
    ..color = p.dark
    ..strokeWidth = 2.2
    ..strokeCap = StrokeCap.round;
  c.drawLine(const Offset(50, 62), const Offset(50, 82), rune);
  c.drawLine(const Offset(50, 66), const Offset(58, 60), rune);
  c.drawLine(const Offset(50, 74), const Offset(58, 68), rune);
}

/// 勇者紙娃娃：把目前穿的裝備畫在人物身上。equipped：slot key → {id, tier}
class HeroPaperDoll extends CustomPainter {
  final Map<String, ({String id, int tier})> equipped;
  HeroPaperDoll(this.equipped);

  static const _skin = Color(0xFFF3CFA7);
  static const _skinLight = Color(0xFFFFE3C4);
  static const _skinDark = Color(0xFFD3A27A);
  static const _outline = Color(0xFF3A2A1C);

  // 人物座標系 180 x 400（中心 x = 90）
  @override
  void paint(Canvas canvas, Size size) {
    final k = math.min(size.width / 180, size.height / 400);
    canvas.save();
    canvas.translate((size.width - 180 * k) / 2, (size.height - 400 * k) / 2);
    canvas.scale(k);
    canvas.translate(-10, 0); // 內部仍用 200 寬的座標，左右各裁掉 10
    _scene(canvas);
    canvas.restore();
  }

  void _place(Canvas c, String slot, String id, int tier, double cx, double cy, double w, {double rot = 0, bool flip = false}) {
    c.save();
    c.translate(cx, cy);
    c.rotate(rot);
    final s = w / 100;
    c.scale(flip ? -s : s, s);
    c.translate(-50, -50);
    _drawItem(c, slot, id, _palFor(id, tier), tier, sparkles: false);
    c.restore();
  }

  // 錐形肢體（a→b，兩端寬度不同，兩端圓角），帶左亮右暗的漸層與描邊
  void _limb(Canvas c, Offset a, Offset b, double wa, double wb, Color light, Color dark, {Color? edge}) {
    final d = b - a;
    final len = d.distance;
    final n = Offset(-d.dy / len, d.dx / len);
    final poly = _poly([
      a + n * (wa / 2),
      b + n * (wb / 2),
      b - n * (wb / 2),
      a - n * (wa / 2),
    ]);
    var path = Path.combine(PathOperation.union, poly, Path()..addOval(Rect.fromCircle(center: a, radius: wa / 2)));
    path = Path.combine(PathOperation.union, path, Path()..addOval(Rect.fromCircle(center: b, radius: wb / 2)));
    _gradFill(c, path, light, dark);
    c.drawPath(
        path,
        Paint()
          ..color = edge ?? _outline.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round);
  }

  void _gradFill(Canvas c, Path p, Color light, Color dark) {
    final b = p.getBounds();
    c.drawPath(
        p,
        Paint()
          ..shader = LinearGradient(begin: Alignment.centerLeft, end: Alignment.centerRight, colors: [light, dark]).createShader(b));
  }

  void _stroke(Canvas c, Path p, {double w = 2, Color? color}) {
    c.drawPath(
        p,
        Paint()
          ..color = color ?? _outline.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
  }

  void _scene(Canvas c) {
    final maxTier = equipped.values.fold<int>(-1, (m, e) => math.max(m, e.tier));

    // 光暈（依最高品階換顏色）與地面
    final aura = maxTier >= 0 ? _gemColors[maxTier.clamp(0, 5)] : const Color(0xFFFFD36B);
    c.drawCircle(
        const Offset(100, 210),
        190,
        Paint()
          ..shader = RadialGradient(colors: [aura.withValues(alpha: maxTier >= 3 ? 0.30 : 0.14), Colors.transparent])
              .createShader(Rect.fromCircle(center: const Offset(100, 210), radius: 190)));
    c.drawOval(const Rect.fromLTWH(22, 366, 156, 30), Paint()..color = const Color(0x55000000));
    c.drawOval(
        const Rect.fromLTWH(34, 372, 132, 20),
        Paint()
          ..color = aura.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    c.drawOval(const Rect.fromLTWH(52, 378, 96, 10), Paint()..color = const Color(0x66000000));

    final cloak = equipped['cloak'];
    if (cloak != null) {
      final p = _palFor(cloak.id, cloak.tier);
      final path = Path()
        ..moveTo(64, 112)
        ..quadraticBezierTo(100, 100, 136, 112)
        ..lineTo(166, 306)
        ..quadraticBezierTo(152, 330, 138, 308)
        ..quadraticBezierTo(120, 332, 102, 310)
        ..quadraticBezierTo(84, 332, 66, 308)
        ..quadraticBezierTo(50, 330, 34, 306)
        ..close();
      _gradFill(c, path, p.main, p.dark);
      // 內裡（較亮）與皺褶
      c.save();
      c.clipPath(path);
      c.drawPath(
          Path()
            ..moveTo(100, 108)
            ..lineTo(36, 320)
            ..lineTo(164, 320)
            ..close(),
          Paint()..color = p.light.withValues(alpha: 0.18));
      c.restore();
      for (final x in [52.0, 76.0, 100.0, 124.0, 148.0]) {
        c.drawLine(Offset(100 + (x - 100) * 0.35, 118), Offset(x, 306),
            Paint()
              ..color = Colors.black.withValues(alpha: 0.22)
              ..strokeWidth = 2);
      }
      _stroke(c, path, w: 2.5);
      if (cloak.tier >= 2) {
        c.drawPath(
            Path()
              ..moveTo(34, 306)
              ..quadraticBezierTo(50, 330, 66, 308)
              ..quadraticBezierTo(84, 332, 102, 310)
              ..quadraticBezierTo(120, 332, 138, 308)
              ..quadraticBezierTo(152, 330, 166, 306),
            Paint()
              ..color = _gold.main
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3);
      }
    }

    // 腿（褲子）
    const pantsL = Color(0xFF5B6B94);
    const pantsD = Color(0xFF2F3A58);
    _limb(c, const Offset(87, 252), const Offset(85, 346), 25, 17, pantsL, pantsD);
    _limb(c, const Offset(113, 252), const Offset(115, 346), 25, 17, pantsL, pantsD);
    for (final x in [85.0, 115.0]) {
      c.drawLine(Offset(x - 5, 298), Offset(x + 5, 300),
          Paint()
            ..color = Colors.black.withValues(alpha: 0.25)
            ..strokeWidth = 1.6);
    }
    // 腳 / 鞋
    final boots = equipped['boots'];
    if (boots == null) {
      for (final x in [72.0, 128.0]) {
        final foot = Path()..addOval(Rect.fromCenter(center: Offset(x, 354), width: 32, height: 16));
        _gradFill(c, foot, _skinLight, _skinDark);
        _stroke(c, foot, w: 1.8);
      }
    } else {
      _place(c, 'boots', boots.id, boots.tier, 80, 342, 56, flip: true);
      _place(c, 'boots', boots.id, boots.tier, 120, 342, 56);
    }

    // 軀幹
    final armor = equipped['armor'];
    final torso = Path()
      ..moveTo(66, 118)
      ..quadraticBezierTo(100, 104, 134, 118)
      ..lineTo(128, 190)
      ..lineTo(126, 258)
      ..quadraticBezierTo(100, 270, 74, 258)
      ..lineTo(72, 190)
      ..close();
    if (armor == null) {
      _gradFill(c, torso, const Color(0xFFFFF3DC), const Color(0xFFD9C9A4));
      _stroke(c, torso, w: 2.4);
      // 領口與綁帶
      final v = Path()
        ..moveTo(86, 110)
        ..lineTo(100, 138)
        ..lineTo(114, 110)
        ..close();
      c.drawPath(v, Paint()..color = _skin);
      _stroke(c, v, w: 1.6);
      for (final y in [120.0, 128.0, 136.0]) {
        c.drawLine(Offset(95, y), Offset(105, y + 3), Paint()
          ..color = const Color(0xFF8B7E5E)
          ..strokeWidth = 1.4);
      }
    } else {
      final p = _palFor(armor.id, armor.tier);
      _gradFill(c, torso, p.light, p.dark);
      _shine(c, torso, p);
      _stroke(c, torso, w: 2.6);
      if (armor.id.contains('cloth')) {
        for (var y = 146.0; y < 252; y += 12) {
          c.drawLine(Offset(100, y), Offset(100, y + 6), Paint()
            ..color = p.dark
            ..strokeWidth = 1.6);
        }
        final v = Path()
          ..moveTo(88, 110)
          ..lineTo(100, 134)
          ..lineTo(112, 110)
          ..close();
        c.drawPath(v, Paint()..color = _skin);
        _stroke(c, v, w: 1.5);
      } else {
        c.drawLine(const Offset(100, 122), const Offset(100, 258), Paint()
          ..color = p.dark
          ..strokeWidth = 2.5);
        for (final dy in [0.0, 22.0, 44.0]) {
          c.drawArc(Rect.fromLTWH(78, 136 + dy, 44, 34), 0.15, math.pi - 0.3, false,
              Paint()
                ..color = p.dark.withValues(alpha: 0.8)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2.2);
        }
        if (armor.tier >= 2) {
          c.drawPath(
              Path()
                ..moveTo(70, 252)
                ..quadraticBezierTo(100, 266, 130, 252),
              Paint()
                ..color = _gold.main
                ..style = PaintingStyle.stroke
                ..strokeWidth = 3);
        }
        if (armor.tier >= 3) {
          final g = _gemColors[armor.tier.clamp(0, 5)];
          final gp = _poly(const [Offset(100, 156), Offset(108, 168), Offset(100, 180), Offset(92, 168)]);
          c.drawPath(gp, Paint()..color = g);
          _stroke(c, gp, w: 1.5);
        }
      }
    }
    // 肩甲
    if (armor != null && !armor.id.contains('cloth')) {
      final p = _palFor(armor.id, armor.tier);
      for (final x in [62.0, 138.0]) {
        final sp = Path()..addOval(Rect.fromCenter(center: Offset(x, 124), width: 34, height: 28));
        _gradFill(c, sp, p.light, p.dark);
        _stroke(c, sp, w: 2.4);
        c.drawCircle(Offset(x, 124), 3, Paint()..color = p.light);
        if (armor.tier >= 4) {
          final spike = _poly([Offset(x + (x < 100 ? -14 : 14), 118), Offset(x + (x < 100 ? -26 : 26), 104), Offset(x + (x < 100 ? -6 : 6), 112)]);
          c.drawPath(spike, Paint()..color = p.main);
          _stroke(c, spike, w: 1.6);
        }
      }
    }

    // 腰帶
    final belt = equipped['belt'];
    if (belt != null) {
      _place(c, 'belt', belt.id, belt.tier, 100, 246, 70);
    }

    // 手臂（袖子 + 前臂）
    final sleeveL = armor != null ? _palFor(armor.id, armor.tier).light : const Color(0xFFFFF3DC);
    final sleeveD = armor != null ? _palFor(armor.id, armor.tier).dark : const Color(0xFFD9C9A4);
    for (final side in [-1.0, 1.0]) {
      final sx = 100 + side * 38;
      _limb(c, Offset(sx + side * 2, 128), Offset(100 + side * 52, 196), 22, 17, sleeveL, sleeveD);
      _limb(c, Offset(100 + side * 52, 194), Offset(100 + side * 56, 226), 16, 13, _skinLight, _skinDark);
    }
    final gloves = equipped['gloves'];
    for (final side in [-1.0, 1.0]) {
      final hx = 100 + side * 56;
      if (gloves != null) {
        // 手套：袖口在上、手指朝下（圖示本身是手指朝上，所以轉 180 度）
        _place(c, 'gloves', gloves.id, gloves.tier, hx, 236, 40, rot: math.pi, flip: side < 0);
      } else {
        final hand = Path()..addOval(Rect.fromCenter(center: Offset(hx, 234), width: 18, height: 22));
        _gradFill(c, hand, _skinLight, _skinDark);
        _stroke(c, hand, w: 1.6);
        c.drawOval(Rect.fromCenter(center: Offset(hx - side * 7, 230), width: 7, height: 11), Paint()..color = _skin);
      }
    }

    // 武器：握在右手，劍尖朝上
    final weapon = equipped['weapon'];
    if (weapon != null) {
      final p = _palFor(weapon.id, weapon.tier);
      c.save();
      c.translate(156, 232);
      c.rotate(-0.55);
      c.scale(1.12);
      c.translate(-18, -86);
      _drawItem(c, 'weapon', weapon.id, p, weapon.tier, sparkles: false);
      c.restore();
      // 拳頭蓋在握把上
      final fist = Path()..addOval(Rect.fromCenter(center: const Offset(156, 232), width: 20, height: 18));
      if (gloves != null) {
        final gp = _palFor(gloves.id, gloves.tier);
        _gradFill(c, fist, gp.light, gp.dark);
      } else {
        _gradFill(c, fist, _skinLight, _skinDark);
      }
      _stroke(c, fist, w: 1.8);
    }

    // 脖子
    final neck = Path()..addRect(const Rect.fromLTWH(91, 96, 18, 20));
    _gradFill(c, neck, _skin, _skinDark);
    // 護身符項鍊
    final amulet = equipped['amulet'];
    if (amulet != null) {
      c.drawPath(
          Path()
            ..moveTo(86, 112)
            ..quadraticBezierTo(100, 150, 114, 112),
          Paint()
            ..color = const Color(0xFFB4342C)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      _place(c, 'amulet', amulet.id, amulet.tier, 100, 148, 26);
    }

    // 頭：後髮 → 臉 → 前髮 → 五官 → 頭盔
    const head = Offset(100, 70);
    final helm = equipped['head'];
    final showHair = helm == null || helm.id.contains('cap');
    const hairLight = Color(0xFF7A4B2A);
    const hairDark = Color(0xFF3A2212);
    {
      final back = Path()
        ..moveTo(66, 70)
        ..cubicTo(60, 30, 140, 30, 134, 70)
        ..cubicTo(136, 88, 128, 96, 120, 92)
        ..lineTo(80, 92)
        ..cubicTo(72, 96, 64, 88, 66, 70)
        ..close();
      _gradFill(c, back, hairLight, hairDark);
      _stroke(c, back, w: 2);
    }
    c.drawCircle(const Offset(68, 76), 7, Paint()..color = _skin);
    c.drawCircle(const Offset(132, 76), 7, Paint()..color = _skin);
    final face = Path()..addOval(Rect.fromCenter(center: head, width: 64, height: 68));
    c.drawPath(
        face,
        Paint()
          ..shader = const RadialGradient(center: Alignment(-0.3, -0.4), colors: [_skinLight, _skin, _skinDark], stops: [0, 0.6, 1])
              .createShader(Rect.fromCenter(center: head, width: 64, height: 68)));
    _stroke(c, face, w: 2.2);
    if (showHair) {
      // 前髮：幾撮尖角
      final fringe = Path()
        ..moveTo(66, 70)
        ..cubicTo(62, 36, 138, 36, 134, 70)
        ..lineTo(128, 62)
        ..lineTo(122, 74)
        ..lineTo(114, 56)
        ..lineTo(106, 70)
        ..lineTo(98, 52)
        ..lineTo(90, 68)
        ..lineTo(82, 56)
        ..lineTo(76, 72)
        ..close();
      _gradFill(c, fringe, hairLight, hairDark);
      _stroke(c, fringe, w: 2);
      c.drawArc(Rect.fromCenter(center: const Offset(98, 46), width: 44, height: 22), math.pi * 1.1, math.pi * 0.6, false,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.22)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round);
    }
    if (showHair) {
      for (final x in [86.0, 114.0]) {
        // 眉毛
        c.drawLine(Offset(x - 7, 72), Offset(x + 7, 70 + (x < 100 ? 1 : -1) * -1.0), Paint()
          ..color = hairDark
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round);
        // 眼白、虹膜、瞳孔、高光
        c.drawOval(Rect.fromCenter(center: Offset(x, 82), width: 13, height: 15), Paint()..color = Colors.white);
        c.drawOval(Rect.fromCenter(center: Offset(x, 83), width: 9, height: 12), Paint()..color = const Color(0xFF3F7FBF));
        c.drawOval(Rect.fromCenter(center: Offset(x, 84), width: 5, height: 8), Paint()..color = const Color(0xFF14243A));
        c.drawCircle(Offset(x - 1.5, 80), 2, Paint()..color = Colors.white);
        c.drawOval(
            Rect.fromCenter(center: Offset(x, 82), width: 13, height: 15),
            Paint()
              ..color = _outline
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4);
      }
      c.drawLine(const Offset(100, 88), const Offset(98, 94), Paint()
        ..color = _skinDark
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round);
      c.drawArc(const Rect.fromLTWH(91, 94, 18, 10), 0.2, math.pi - 0.4, false,
          Paint()
            ..color = const Color(0xFF8B3A2E)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round);
      c.drawCircle(const Offset(78, 94), 5.5, Paint()..color = const Color(0x44FF6B6B));
      c.drawCircle(const Offset(122, 94), 5.5, Paint()..color = const Color(0x44FF6B6B));
    }
    if (helm != null) {
      if (helm.id.contains('cap')) {
        _place(c, 'head', helm.id, helm.tier, 100, 52, 84);
      } else {
        _place(c, 'head', helm.id, helm.tier, 100, 64, 92);
        // 頭盔下露出下半臉（嘴）
        c.drawArc(const Rect.fromLTWH(92, 92, 16, 9), 0.2, math.pi - 0.4, false,
            Paint()
              ..color = const Color(0xFF8B3A2E)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..strokeCap = StrokeCap.round);
      }
    }

    // 戒指：戴在左手（畫面左側）
    for (final key in ['ring1', 'ring2']) {
      final r = equipped[key];
      if (r == null) continue;
      final p = _palFor(r.id, r.tier);
      final dy = key == 'ring1' ? 0.0 : 8.0;
      c.drawCircle(Offset(44, 238 + dy), 3.8, Paint()
        ..color = p.main
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6);
      c.drawCircle(Offset(44, 234.5 + dy), 2.2, Paint()..color = _gemColors[r.tier.clamp(0, 5)]);
    }
  }

  @override
  bool shouldRepaint(covariant HeroPaperDoll old) => old.equipped.toString() != equipped.toString();
}
