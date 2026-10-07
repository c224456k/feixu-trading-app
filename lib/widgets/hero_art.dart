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

_Pal _palFor(String id, int tier) {
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
void _drawItem(Canvas c, String slot, String id, _Pal pal, int tier) {
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

  static const _skin = Color(0xFFF1C9A0);
  static const _skinDark = Color(0xFFC99872);

  @override
  void paint(Canvas canvas, Size size) {
    final k = math.min(size.width / 200, size.height / 400);
    canvas.save();
    canvas.translate((size.width - 200 * k) / 2, (size.height - 400 * k) / 2);
    canvas.scale(k);
    _scene(canvas);
    canvas.restore();
  }

  // 把 0~100 的裝備圖示放到人物座標：中心 (cx,cy)、寬 w、可旋轉
  void _place(
    Canvas c,
    String slot,
    String id,
    _Pal pal,
    int tier,
    double cx,
    double cy,
    double w, {
    double rot = 0,
    bool flip = false,
  }) {
    c.save();
    c.translate(cx, cy);
    c.rotate(rot);
    final s = w / 100;
    c.scale(flip ? -s : s, s);
    c.translate(-50, -50);
    _drawItem(c, slot, id, pal, tier);
    c.restore();
  }

  void _limb(
    Canvas c,
    Offset a,
    Offset b,
    double w,
    Color color, {
    Color? edge,
  }) {
    c.drawLine(
      a,
      b,
      Paint()
        ..color = edge ?? Colors.black.withValues(alpha: 0.35)
        ..strokeWidth = w + 3
        ..strokeCap = StrokeCap.round,
    );
    c.drawLine(
      a,
      b,
      Paint()
        ..color = color
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round,
    );
  }

  void _scene(Canvas c) {
    // 地面光圈與影子
    c.drawOval(
      const Rect.fromLTWH(30, 372, 140, 22),
      Paint()..color = const Color(0x66000000),
    );
    c.drawOval(
      const Rect.fromLTWH(52, 378, 96, 12),
      Paint()..color = const Color(0x55000000),
    );

    final cloak = equipped['cloak'];
    if (cloak != null) {
      // 斗篷披在背後（比身體寬、往下垂）
      final p = _palFor(cloak.id, cloak.tier);
      final path = Path()
        ..moveTo(66, 112)
        ..lineTo(134, 112)
        ..lineTo(160, 300)
        ..quadraticBezierTo(148, 322, 134, 304)
        ..quadraticBezierTo(116, 326, 100, 306)
        ..quadraticBezierTo(84, 326, 66, 304)
        ..quadraticBezierTo(52, 322, 40, 300)
        ..close();
      _fillStroke(c, path, p.dark, Colors.black.withValues(alpha: 0.5), w: 2.5);
      c.drawLine(
        const Offset(100, 120),
        const Offset(100, 302),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.25)
          ..strokeWidth = 2,
      );
      c.drawLine(
        const Offset(80, 120),
        const Offset(60, 296),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.2)
          ..strokeWidth = 2,
      );
      c.drawLine(
        const Offset(120, 120),
        const Offset(140, 296),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.2)
          ..strokeWidth = 2,
      );
    }

    // 腿（褲子）
    const pants = Color(0xFF3F4A66);
    _limb(c, const Offset(86, 252), const Offset(84, 346), 22, pants);
    _limb(c, const Offset(114, 252), const Offset(116, 346), 22, pants);
    // 腳 / 鞋
    final boots = equipped['boots'];
    if (boots == null) {
      c.drawOval(const Rect.fromLTWH(64, 346, 30, 16), Paint()..color = _skin);
      c.drawOval(const Rect.fromLTWH(106, 346, 30, 16), Paint()..color = _skin);
      c.drawOval(
        const Rect.fromLTWH(64, 346, 30, 16),
        Paint()
          ..color = _skinDark
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      c.drawOval(
        const Rect.fromLTWH(106, 346, 30, 16),
        Paint()
          ..color = _skinDark
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    } else {
      final p = _palFor(boots.id, boots.tier);
      _place(c, 'boots', boots.id, p, boots.tier, 78, 340, 52, flip: true);
      _place(c, 'boots', boots.id, p, boots.tier, 122, 340, 52);
    }

    // 軀幹
    final armor = equipped['armor'];
    final torso = Path()
      ..moveTo(68, 116)
      ..quadraticBezierTo(100, 104, 132, 116)
      ..lineTo(128, 256)
      ..quadraticBezierTo(100, 266, 72, 256)
      ..close();
    if (armor == null) {
      _fillStroke(
        c,
        torso,
        const Color(0xFFEDE3CC),
        const Color(0xFF8B7E5E),
        w: 2.5,
      );
      c.drawLine(
        const Offset(100, 120),
        const Offset(100, 250),
        Paint()
          ..color = const Color(0x22000000)
          ..strokeWidth = 2,
      );
    } else {
      final p = _palFor(armor.id, armor.tier);
      _fillStroke(c, torso, p.main, p.dark, w: 2.5);
      _shine(c, torso, p);
      if (armor.id.contains('cloth')) {
        for (var y = 140.0; y < 250; y += 12) {
          c.drawLine(
            Offset(100, y),
            Offset(100, y + 6),
            Paint()
              ..color = p.dark
              ..strokeWidth = 1.6,
          );
        }
        c.drawLine(
          const Offset(90, 112),
          const Offset(90, 134),
          Paint()
            ..color = p.dark
            ..strokeWidth = 2,
        );
        c.drawLine(
          const Offset(110, 112),
          const Offset(110, 134),
          Paint()
            ..color = p.dark
            ..strokeWidth = 2,
        );
      } else {
        c.drawLine(
          const Offset(100, 120),
          const Offset(100, 252),
          Paint()
            ..color = p.dark
            ..strokeWidth = 2.5,
        );
        c.drawArc(
          const Rect.fromLTWH(78, 130, 44, 50),
          0.2,
          math.pi - 0.4,
          false,
          Paint()
            ..color = p.dark
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }
    }
    // 肩膀（有裝備時加肩甲）
    if (armor != null && !armor.id.contains('cloth')) {
      final p = _palFor(armor.id, armor.tier);
      for (final x in [62.0, 138.0]) {
        c.drawCircle(Offset(x, 124), 15, Paint()..color = p.main);
        c.drawCircle(
          Offset(x, 124),
          15,
          Paint()
            ..color = p.dark
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }
    }

    // 腰帶
    final belt = equipped['belt'];
    if (belt != null) {
      final p = _palFor(belt.id, belt.tier);
      _place(c, 'belt', belt.id, p, belt.tier, 100, 244, 64);
    }

    // 手臂
    final sleeve = armor != null
        ? _palFor(armor.id, armor.tier).main
        : const Color(0xFFEDE3CC);
    _limb(c, const Offset(62, 126), const Offset(46, 214), 18, sleeve);
    _limb(c, const Offset(138, 126), const Offset(154, 214), 18, sleeve);
    _limb(
      c,
      const Offset(49, 196),
      const Offset(44, 228),
      15,
      _skin,
      edge: _skinDark,
    );
    _limb(
      c,
      const Offset(151, 196),
      const Offset(156, 228),
      15,
      _skin,
      edge: _skinDark,
    );
    final gloves = equipped['gloves'];
    if (gloves != null) {
      final p = _palFor(gloves.id, gloves.tier);
      _place(c, 'gloves', gloves.id, p, gloves.tier, 44, 226, 38);
      _place(c, 'gloves', gloves.id, p, gloves.tier, 156, 226, 38, flip: true);
    } else {
      c.drawCircle(const Offset(44, 232), 9, Paint()..color = _skin);
      c.drawCircle(const Offset(156, 232), 9, Paint()..color = _skin);
    }

    // 武器：握在右手（畫面右側），劍尖朝上
    final weapon = equipped['weapon'];
    if (weapon != null) {
      final p = _palFor(weapon.id, weapon.tier);
      c.save();
      c.translate(158, 228);
      c.rotate(-0.62);
      c.scale(1.35);
      c.translate(-18, -86);
      _drawItem(c, 'weapon', weapon.id, p, weapon.tier);
      c.restore();
      // 手指蓋在握把上
      c.drawCircle(
        const Offset(158, 230),
        8,
        Paint()
          ..color = gloves != null
              ? _palFor(gloves.id, gloves.tier).main
              : _skin,
      );
    }

    // 脖子與頭
    c.drawRect(const Rect.fromLTWH(91, 98, 18, 18), Paint()..color = _skinDark);
    // 護身符項鍊
    final amulet = equipped['amulet'];
    if (amulet != null) {
      final p = _palFor(amulet.id, amulet.tier);
      c.drawPath(
        Path()
          ..moveTo(88, 112)
          ..quadraticBezierTo(100, 146, 112, 112),
        Paint()
          ..color = const Color(0xFFB4342C)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      _place(c, 'amulet', amulet.id, p, amulet.tier, 100, 146, 24);
    }

    const head = Offset(100, 72);
    c.drawCircle(
      head,
      32,
      Paint()..color = Colors.black.withValues(alpha: 0.3),
    );
    c.drawCircle(head, 30, Paint()..color = _skin);
    // 耳朵
    c.drawCircle(const Offset(70, 76), 6, Paint()..color = _skin);
    c.drawCircle(const Offset(130, 76), 6, Paint()..color = _skin);
    // 頭髮（沒戴頭盔時）
    final helm = equipped['head'];
    if (helm == null || helm.id.contains('cap')) {
      final hair = Path()
        ..moveTo(68, 70)
        ..cubicTo(66, 34, 134, 34, 132, 70)
        ..cubicTo(122, 56, 112, 54, 100, 52)
        ..cubicTo(88, 56, 76, 58, 68, 70)
        ..close();
      c.drawPath(hair, Paint()..color = const Color(0xFF4A2F1B));
      c.drawPath(
        hair,
        Paint()
          ..color = const Color(0xFF2A1A0E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    // 臉
    if (helm == null || helm.id.contains('cap')) {
      for (final x in [88.0, 112.0]) {
        c.drawOval(
          Rect.fromCenter(center: Offset(x, 80), width: 7, height: 10),
          Paint()..color = const Color(0xFF2A1A0E),
        );
        c.drawCircle(Offset(x - 1, 77), 1.6, Paint()..color = Colors.white);
      }
      c.drawArc(
        const Rect.fromLTWH(92, 88, 16, 10),
        0.2,
        math.pi - 0.4,
        false,
        Paint()
          ..color = const Color(0xFF8B4A3A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
      c.drawCircle(
        const Offset(79, 90),
        5,
        Paint()..color = const Color(0x33FF6B6B),
      );
      c.drawCircle(
        const Offset(121, 90),
        5,
        Paint()..color = const Color(0x33FF6B6B),
      );
    }
    if (helm != null) {
      final p = _palFor(helm.id, helm.tier);
      if (helm.id.contains('cap')) {
        _place(c, 'head', helm.id, p, helm.tier, 100, 56, 78);
      } else {
        _place(c, 'head', helm.id, p, helm.tier, 100, 66, 84);
      }
    }

    // 戒指：戴在左手（畫面左側）手上，閃一下光
    for (final key in ['ring1', 'ring2']) {
      final r = equipped[key];
      if (r == null) continue;
      final p = _palFor(r.id, r.tier);
      final dx = key == 'ring1' ? -4.0 : 6.0;
      c.drawCircle(
        Offset(44 + dx, 236),
        3.6,
        Paint()
          ..color = p.main
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4,
      );
      c.drawCircle(Offset(44 + dx, 232.5), 2, Paint()..color = p.light);
    }
  }

  @override
  bool shouldRepaint(covariant HeroPaperDoll old) =>
      old.equipped.toString() != equipped.toString();
}
