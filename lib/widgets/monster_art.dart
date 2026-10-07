import 'dart:math' as math;

import 'package:flutter/material.dart';

// 百層塔的怪物：10 種造型（朝左），依「區域」換顏色。全部用 CustomPainter 在 0~100 方框內畫，
// 腳底在 y=92。頭目多一圈紅色光暈、頭上有皇冠。

const _bandTints = [
  Color(0xFF5DBB63), // 草原
  Color(0xFF8D6E63), // 洞窟
  Color(0xFF9E9EC8), // 墓地
  Color(0xFF2E9D4A), // 森林
  Color(0xFF8BA32A), // 沼澤
  Color(0xFFA0A0A8), // 礦坑
  Color(0xFFE8631A), // 熔岩
  Color(0xFF5FC7F2), // 冰霜
  Color(0xFFFFC94D), // 天空
  Color(0xFFC62828), // 魔界
];

const _kindBase = [
  Color(0xFF4DA3E8), // 史萊姆
  Color(0xFF6B4E8C), // 蝙蝠
  Color(0xFF6DBE45), // 哥布林
  Color(0xFFE8E2CC), // 骷髏
  Color(0xFF8A8A8A), // 野狼
  Color(0xFF6C8F3C), // 獸人
  Color(0xFFDCE8F5), // 幽靈
  Color(0xFF8C8C94), // 石像鬼
  Color(0xFFC0392B), // 飛龍
  Color(0xFF8E1B2F), // 惡魔
];

class MonsterPainter extends CustomPainter {
  final int kind;
  final int band;
  final bool boss;
  final double flash; // 0~1：被打到時泛白
  final double opacity;
  final double t; // 動畫時間（秒），讓怪物有呼吸感
  MonsterPainter({required this.kind, required this.band, this.boss = false, this.flash = 0, this.opacity = 1, this.t = 0});

  Color get _body => Color.lerp(_kindBase[kind % 10], _bandTints[band.clamp(0, 9)], kind == 3 || kind == 6 ? 0.18 : 0.42)!;

  @override
  void paint(Canvas c, Size size) {
    final s = math.min(size.width, size.height) / 100;
    c.save();
    c.translate((size.width - 100 * s) / 2, (size.height - 100 * s) / 2);
    c.scale(s);
    final breathe = math.sin(t * 3 + kind) * 1.5;
    if (opacity < 1) c.saveLayer(const Rect.fromLTWH(-20, -20, 140, 140), Paint()..color = Colors.white.withValues(alpha: opacity));
    if (boss) {
      c.drawCircle(
          const Offset(50, 55),
          62,
          Paint()
            ..shader = RadialGradient(colors: [const Color(0x66FF3B30), Colors.transparent])
                .createShader(Rect.fromCircle(center: const Offset(50, 55), radius: 62)));
    }
    c.translate(0, breathe * 0.4);
    c.drawOval(const Rect.fromLTWH(18, 88, 64, 9), Paint()..color = const Color(0x55000000));
    if (flash > 0) c.saveLayer(const Rect.fromLTWH(-20, -20, 140, 140), Paint());
    switch (kind % 10) {
      case 0:
        _slime(c, breathe);
      case 1:
        _bat(c, breathe);
      case 2:
        _goblin(c);
      case 3:
        _skeleton(c);
      case 4:
        _wolf(c);
      case 5:
        _orc(c);
      case 6:
        _ghost(c, breathe);
      case 7:
        _golem(c);
      case 8:
        _dragon(c, breathe);
      case 9:
        _demon(c);
    }
    if (boss) _crown(c);
    if (flash > 0) {
      c.drawRect(const Rect.fromLTWH(-20, -20, 140, 140), Paint()
        ..color = Colors.white.withValues(alpha: flash * 0.85)
        ..blendMode = BlendMode.srcATop);
      c.restore();
    }
    if (opacity < 1) c.restore();
    c.restore();
  }

  Paint _fill(Rect r, Color base) => Paint()
    ..shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color.lerp(base, Colors.white, 0.35)!, base, Color.lerp(base, Colors.black, 0.45)!],
      stops: const [0, 0.5, 1],
    ).createShader(r);

  void _shape(Canvas c, Path p, Color base, {double w = 2}) {
    c.drawPath(p, _fill(p.getBounds(), base));
    c.drawPath(
        p,
        Paint()
          ..color = Color.lerp(base, Colors.black, 0.75)!
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..strokeJoin = StrokeJoin.round);
  }

  void _eye(Canvas c, Offset o, {double r = 3.2, Color iris = const Color(0xFFE53935)}) {
    c.drawCircle(o, r + 1.2, Paint()..color = Colors.white);
    c.drawCircle(o, r, Paint()..color = iris);
    c.drawCircle(o.translate(-r * 0.3, 0), r * 0.5, Paint()..color = Colors.black);
    c.drawCircle(o.translate(-r * 0.5, -r * 0.5), r * 0.25, Paint()..color = Colors.white);
  }

  void _crown(Canvas c) {
    final p = Path()
      ..moveTo(34, 12)
      ..lineTo(38, 2)
      ..lineTo(44, 10)
      ..lineTo(50, 0)
      ..lineTo(56, 10)
      ..lineTo(62, 2)
      ..lineTo(66, 12)
      ..close();
    _shape(c, p, const Color(0xFFFFC107), w: 1.6);
    c.drawCircle(const Offset(50, 8), 2, Paint()..color = const Color(0xFFE53935));
  }

  void _slime(Canvas c, double b) {
    final p = Path()
      ..moveTo(12, 90)
      ..cubicTo(2, 70, 14, 40 - b, 50, 36 - b)
      ..cubicTo(86, 40 - b, 98, 70, 88, 90)
      ..cubicTo(70, 94, 30, 94, 12, 90)
      ..close();
    _shape(c, p, _body);
    c.drawOval(const Rect.fromLTWH(26, 46, 18, 10), Paint()..color = Colors.white.withValues(alpha: 0.5));
    _eye(c, const Offset(36, 66), iris: const Color(0xFF263238));
    _eye(c, const Offset(60, 66), iris: const Color(0xFF263238));
    c.drawArc(const Rect.fromLTWH(38, 70, 22, 12), 0.1, math.pi - 0.2, false, Paint()
      ..color = const Color(0xFF263238)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round);
  }

  void _bat(Canvas c, double b) {
    final wing = (Path()
      ..moveTo(50, 50)
      ..quadraticBezierTo(30, 20 + b * 2, 2, 30)
      ..quadraticBezierTo(14, 40, 10, 54)
      ..quadraticBezierTo(24, 50, 24, 62)
      ..quadraticBezierTo(38, 54, 50, 62)
      ..close());
    _shape(c, wing, Color.lerp(_body, Colors.black, 0.2)!);
    _shape(c, wing.transform((Matrix4.identity()
          ..translateByDouble(100.0, 0.0, 0.0, 1.0)
          ..scaleByDouble(-1.0, 1.0, 1.0, 1.0))
        .storage), Color.lerp(_body, Colors.black, 0.2)!);
    final body = Path()..addOval(const Rect.fromLTWH(34, 36, 32, 40));
    _shape(c, body, _body);
    _shape(c, Path()..moveTo(36, 40)..lineTo(34, 24)..lineTo(44, 36)..close(), _body, w: 1.5);
    _shape(c, Path()..moveTo(64, 40)..lineTo(66, 24)..lineTo(56, 36)..close(), _body, w: 1.5);
    _eye(c, const Offset(43, 52), r: 2.6);
    _eye(c, const Offset(57, 52), r: 2.6);
    c.drawPath(Path()..moveTo(45, 64)..lineTo(47, 70)..lineTo(49, 64), Paint()..color = Colors.white);
    c.drawPath(Path()..moveTo(51, 64)..lineTo(53, 70)..lineTo(55, 64), Paint()..color = Colors.white);
  }

  void _goblin(Canvas c) {
    final body = Path()..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(34, 54, 32, 32), const Radius.circular(8)));
    _shape(c, body, const Color(0xFF8B5A2B));
    for (final x in [38.0, 56.0]) {
      _shape(c, Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 82, 8, 10), const Radius.circular(3))), _body, w: 1.5);
    }
    _shape(c, Path()..moveTo(34, 58)..lineTo(20, 74)..lineTo(26, 80)..lineTo(38, 70)..close(), _body, w: 1.5);
    // 棍棒
    c.drawLine(const Offset(18, 78), const Offset(8, 46), Paint()
      ..color = const Color(0xFF6D4C41)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round);
    c.drawCircle(const Offset(8, 42), 8, Paint()..color = const Color(0xFF5D4037));
    // 頭與大耳朵
    _shape(c, Path()..moveTo(30, 36)..lineTo(6, 28)..lineTo(28, 46)..close(), _body, w: 1.6);
    _shape(c, Path()..moveTo(70, 36)..lineTo(94, 28)..lineTo(72, 46)..close(), _body, w: 1.6);
    _shape(c, Path()..addOval(const Rect.fromLTWH(30, 24, 40, 40)), _body);
    _eye(c, const Offset(41, 42), r: 2.8, iris: const Color(0xFFFFB300));
    _eye(c, const Offset(58, 42), r: 2.8, iris: const Color(0xFFFFB300));
    c.drawArc(const Rect.fromLTWH(40, 48, 20, 10), 0.2, math.pi - 0.4, false, Paint()
      ..color = const Color(0xFF263238)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    c.drawPath(Path()..moveTo(43, 55)..lineTo(45, 60)..lineTo(47, 55), Paint()..color = Colors.white);
  }

  void _skeleton(Canvas c) {
    final bone = _body;
    final dark = Paint()
      ..color = const Color(0xFF2B2B2B)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    // 肋骨與脊椎
    c.drawLine(const Offset(50, 46), const Offset(50, 76), Paint()
      ..color = bone
      ..strokeWidth = 4);
    for (var i = 0; i < 4; i++) {
      final y = 50.0 + i * 6.5;
      c.drawArc(Rect.fromLTWH(34, y - 4, 32, 12), 0.1, math.pi - 0.2, false, Paint()
        ..color = bone
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round);
    }
    // 腿
    c.drawLine(const Offset(44, 76), const Offset(40, 92), Paint()
      ..color = bone
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round);
    c.drawLine(const Offset(56, 76), const Offset(60, 92), Paint()
      ..color = bone
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round);
    // 手臂與劍
    c.drawLine(const Offset(38, 52), const Offset(22, 70), Paint()
      ..color = bone
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round);
    c.drawLine(const Offset(14, 78), const Offset(10, 30), Paint()
      ..color = const Color(0xFFB0BEC5)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round);
    c.drawLine(const Offset(6, 66), const Offset(22, 66), Paint()
      ..color = const Color(0xFF6D4C41)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round);
    c.drawLine(const Offset(62, 52), const Offset(76, 66), Paint()
      ..color = bone
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round);
    // 頭骨
    _shape(c, Path()..addOval(const Rect.fromLTWH(32, 14, 36, 34)), bone);
    _shape(c, Path()..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(40, 42, 20, 10), const Radius.circular(3))), bone, w: 1.6);
    c.drawOval(const Rect.fromLTWH(37, 26, 10, 11), Paint()..color = const Color(0xFF14110B));
    c.drawOval(const Rect.fromLTWH(53, 26, 10, 11), Paint()..color = const Color(0xFF14110B));
    c.drawCircle(const Offset(42, 31), 2, Paint()..color = const Color(0xFFFF5252));
    c.drawCircle(const Offset(58, 31), 2, Paint()..color = const Color(0xFFFF5252));
    for (final x in [44.0, 50.0, 56.0]) {
      c.drawLine(Offset(x, 43), Offset(x, 51), dark..strokeWidth = 1.4);
    }
  }

  void _wolf(Canvas c) {
    final body = Path()
      ..moveTo(26, 52)
      ..quadraticBezierTo(50, 40, 82, 50)
      ..quadraticBezierTo(94, 56, 92, 70)
      ..lineTo(84, 74)
      ..lineTo(26, 74)
      ..quadraticBezierTo(18, 64, 26, 52)
      ..close();
    // 尾巴
    _shape(c, Path()..moveTo(84, 52)..quadraticBezierTo(104, 40, 98, 22)..quadraticBezierTo(92, 38, 80, 48)..close(), _body, w: 1.6);
    _shape(c, body, _body);
    for (final x in [30.0, 40.0, 70.0, 80.0]) {
      _shape(c, Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 70, 8, 22), const Radius.circular(3))), Color.lerp(_body, Colors.black, 0.15)!, w: 1.5);
    }
    // 頭（朝左）
    final head = Path()
      ..moveTo(32, 40)
      ..lineTo(14, 52)
      ..lineTo(2, 54)
      ..lineTo(6, 62)
      ..lineTo(20, 64)
      ..lineTo(36, 64)
      ..quadraticBezierTo(46, 50, 42, 38)
      ..close();
    _shape(c, head, _body);
    _shape(c, Path()..moveTo(34, 40)..lineTo(34, 24)..lineTo(44, 36)..close(), _body, w: 1.5);
    _shape(c, Path()..moveTo(42, 38)..lineTo(48, 24)..lineTo(52, 40)..close(), _body, w: 1.5);
    _eye(c, const Offset(26, 52), r: 2.4, iris: const Color(0xFFFFB300));
    c.drawCircle(const Offset(4, 55), 2, Paint()..color = Colors.black);
    c.drawPath(Path()..moveTo(8, 62)..lineTo(10, 68)..lineTo(13, 62), Paint()..color = Colors.white);
    c.drawPath(Path()..moveTo(16, 63)..lineTo(18, 68)..lineTo(21, 63), Paint()..color = Colors.white);
  }

  void _orc(Canvas c) {
    final body = Path()
      ..moveTo(24, 52)
      ..quadraticBezierTo(50, 40, 76, 52)
      ..lineTo(72, 86)
      ..lineTo(28, 86)
      ..close();
    _shape(c, body, const Color(0xFF6D4C41));
    _shape(c, Path()..addRect(const Rect.fromLTWH(28, 76, 44, 8)), const Color(0xFF3E2723), w: 1.6);
    for (final x in [32.0, 54.0]) {
      _shape(c, Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 84, 14, 9), const Radius.circular(3))), _body, w: 1.5);
    }
    // 手臂與斧頭
    _shape(c, Path()..addOval(const Rect.fromLTWH(10, 50, 16, 28)), _body, w: 1.6);
    _shape(c, Path()..addOval(const Rect.fromLTWH(74, 50, 16, 28)), _body, w: 1.6);
    c.drawLine(const Offset(14, 76), const Offset(8, 28), Paint()
      ..color = const Color(0xFF5D4037)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round);
    _shape(c, Path()..moveTo(8, 26)..lineTo(-4, 20)..lineTo(-2, 44)..lineTo(8, 40)..close(), const Color(0xFFB0BEC5), w: 1.6);
    // 頭
    _shape(c, Path()..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(30, 20, 40, 38), const Radius.circular(14))), _body);
    c.drawLine(const Offset(36, 34), const Offset(46, 38), Paint()
      ..color = const Color(0xFF1B1B1B)
      ..strokeWidth = 3);
    c.drawLine(const Offset(64, 34), const Offset(54, 38), Paint()
      ..color = const Color(0xFF1B1B1B)
      ..strokeWidth = 3);
    _eye(c, const Offset(41, 42), r: 2.4, iris: const Color(0xFFFFEB3B));
    _eye(c, const Offset(59, 42), r: 2.4, iris: const Color(0xFFFFEB3B));
    _shape(c, Path()..moveTo(38, 54)..lineTo(35, 44)..lineTo(44, 52)..close(), const Color(0xFFFFF8E1), w: 1.2);
    _shape(c, Path()..moveTo(62, 54)..lineTo(65, 44)..lineTo(56, 52)..close(), const Color(0xFFFFF8E1), w: 1.2);
  }

  void _ghost(Canvas c, double b) {
    final p = Path()
      ..moveTo(20, 90)
      ..lineTo(20, 46)
      ..cubicTo(20, 10 - b, 80, 10 - b, 80, 46)
      ..lineTo(80, 90)
      ..lineTo(70, 82)
      ..lineTo(60, 92)
      ..lineTo(50, 82)
      ..lineTo(40, 92)
      ..lineTo(30, 82)
      ..close();
    c.saveLayer(const Rect.fromLTWH(0, 0, 100, 100), Paint()..color = Colors.white.withValues(alpha: 0.85));
    _shape(c, p, _body);
    c.restore();
    c.drawOval(const Rect.fromLTWH(32, 38, 12, 16), Paint()..color = const Color(0xFF1B1B2B));
    c.drawOval(const Rect.fromLTWH(56, 38, 12, 16), Paint()..color = const Color(0xFF1B1B2B));
    c.drawCircle(const Offset(38, 44), 2.4, Paint()..color = const Color(0xFF7DF9FF));
    c.drawCircle(const Offset(62, 44), 2.4, Paint()..color = const Color(0xFF7DF9FF));
    c.drawOval(const Rect.fromLTWH(43, 60, 14, 12), Paint()..color = const Color(0xFF1B1B2B));
  }

  void _golem(Canvas c) {
    final stone = _body;
    _shape(c, Path()..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(26, 50, 48, 38), const Radius.circular(6))), stone);
    _shape(c, Path()..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(6, 48, 22, 34), const Radius.circular(6))), Color.lerp(stone, Colors.black, 0.1)!);
    _shape(c, Path()..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(72, 48, 22, 34), const Radius.circular(6))), Color.lerp(stone, Colors.black, 0.1)!);
    _shape(c, Path()..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(30, 18, 40, 34), const Radius.circular(6))), stone);
    final crack = Paint()
      ..color = Colors.black.withValues(alpha: 0.45)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    c.drawPath(Path()..moveTo(40, 54)..lineTo(46, 66)..lineTo(42, 78)..lineTo(50, 88), crack);
    c.drawPath(Path()..moveTo(62, 22)..lineTo(58, 32)..lineTo(66, 40), crack);
    final glow = Paint()
      ..color = const Color(0xFFFFB300)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(37, 30, 10, 7), const Radius.circular(2)), glow);
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(53, 30, 10, 7), const Radius.circular(2)), glow);
    c.drawRect(const Rect.fromLTWH(40, 44, 20, 3), Paint()..color = Colors.black.withValues(alpha: 0.6));
  }

  void _dragon(Canvas c, double b) {
    final wing = Path()
      ..moveTo(58, 46)
      ..quadraticBezierTo(70, 6 + b * 2, 98, 12)
      ..quadraticBezierTo(88, 24, 92, 36)
      ..quadraticBezierTo(80, 32, 78, 46)
      ..quadraticBezierTo(70, 42, 66, 54)
      ..close();
    _shape(c, wing, Color.lerp(_body, Colors.black, 0.25)!);
    // 尾
    _shape(c, Path()..moveTo(72, 70)..quadraticBezierTo(98, 74, 96, 56)..quadraticBezierTo(90, 66, 70, 62)..close(), _body, w: 1.6);
    final body = Path()
      ..moveTo(30, 54)
      ..quadraticBezierTo(50, 40, 76, 52)
      ..quadraticBezierTo(84, 70, 70, 82)
      ..lineTo(36, 82)
      ..quadraticBezierTo(26, 70, 30, 54)
      ..close();
    _shape(c, body, _body);
    c.drawOval(const Rect.fromLTWH(36, 62, 30, 20), Paint()..color = const Color(0xFFFFE0A3).withValues(alpha: 0.85));
    for (final x in [38.0, 58.0]) {
      _shape(c, Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 78, 12, 14), const Radius.circular(3))), _body, w: 1.5);
    }
    // 頭、角、噴火
    final head = Path()
      ..moveTo(36, 40)
      ..lineTo(10, 38)
      ..lineTo(4, 48)
      ..lineTo(18, 54)
      ..lineTo(38, 58)
      ..close();
    _shape(c, head, _body);
    _shape(c, Path()..moveTo(30, 36)..lineTo(24, 18)..lineTo(38, 32)..close(), const Color(0xFFFFF8E1), w: 1.4);
    _shape(c, Path()..moveTo(38, 38)..lineTo(36, 20)..lineTo(46, 38)..close(), const Color(0xFFFFF8E1), w: 1.4);
    _eye(c, const Offset(26, 44), r: 2.6, iris: const Color(0xFFFFEB3B));
    c.drawCircle(const Offset(6, 46), 1.6, Paint()..color = Colors.black);
    c.drawPath(Path()..moveTo(8, 52)..lineTo(10, 58)..lineTo(13, 52), Paint()..color = Colors.white);
  }

  void _demon(Canvas c) {
    final wing = Path()
      ..moveTo(62, 50)
      ..quadraticBezierTo(80, 8, 98, 22)
      ..quadraticBezierTo(90, 30, 94, 44)
      ..quadraticBezierTo(82, 42, 76, 60)
      ..close();
    _shape(c, wing, const Color(0xFF3B0D1A));
    _shape(c, Path()..moveTo(38, 50)..quadraticBezierTo(20, 8, 2, 22)..quadraticBezierTo(10, 30, 6, 44)..quadraticBezierTo(18, 42, 24, 60)..close(), const Color(0xFF3B0D1A));
    final body = Path()
      ..moveTo(34, 50)
      ..quadraticBezierTo(50, 42, 66, 50)
      ..lineTo(64, 84)
      ..lineTo(36, 84)
      ..close();
    _shape(c, body, _body);
    for (final x in [36.0, 52.0]) {
      _shape(c, Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, 82, 12, 11), const Radius.circular(3))), Color.lerp(_body, Colors.black, 0.3)!, w: 1.5);
    }
    // 三叉戟
    c.drawLine(const Offset(18, 90), const Offset(18, 30), Paint()
      ..color = const Color(0xFF9E9E9E)
      ..strokeWidth = 3);
    _shape(c, Path()..moveTo(10, 36)..lineTo(10, 22)..lineTo(14, 30)..lineTo(18, 18)..lineTo(22, 30)..lineTo(26, 22)..lineTo(26, 36)..close(), const Color(0xFFCFD8DC), w: 1.3);
    c.drawLine(const Offset(34, 56), const Offset(20, 70), Paint()
      ..color = _body
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round);
    // 頭
    _shape(c, Path()..moveTo(34, 24)..lineTo(28, 4)..lineTo(42, 18)..close(), const Color(0xFF2B2B2B), w: 1.4);
    _shape(c, Path()..moveTo(66, 24)..lineTo(72, 4)..lineTo(58, 18)..close(), const Color(0xFF2B2B2B), w: 1.4);
    _shape(c, Path()..addOval(const Rect.fromLTWH(34, 16, 32, 36)), _body);
    c.drawLine(const Offset(38, 28), const Offset(47, 32), Paint()
      ..color = Colors.black
      ..strokeWidth = 2.6);
    c.drawLine(const Offset(62, 28), const Offset(53, 32), Paint()
      ..color = Colors.black
      ..strokeWidth = 2.6);
    _eye(c, const Offset(42, 36), r: 2.4, iris: const Color(0xFFFFEB3B));
    _eye(c, const Offset(58, 36), r: 2.4, iris: const Color(0xFFFFEB3B));
    c.drawArc(const Rect.fromLTWH(42, 40, 16, 9), 0.1, math.pi - 0.2, false, Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant MonsterPainter old) =>
      old.kind != kind || old.band != band || old.boss != boss || old.flash != flash || old.opacity != opacity || old.t != t;
}
