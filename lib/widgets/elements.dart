import 'dart:math' as math;

import 'package:flutter/material.dart';

// 五行（金木水火土）：與後端 hero_elements.py 對應，index 0~4；-1 = 無屬性。
// 相剋：金剋木、木剋土、土剋水、水剋火、火剋金。
const elemNames = ['金', '木', '水', '火', '土'];
const elemColors = [Color(0xFFFFE27A), Color(0xFF6FE06A), Color(0xFF4FB6FF), Color(0xFFFF6A3C), Color(0xFFD9A25A)];
const elemKe = {0: 1, 1: 4, 4: 2, 2: 3, 3: 0}; // 攻擊者 → 被剋者

String elemName(int e) => e >= 0 && e < 5 ? elemNames[e] : '無';
Color elemColor(int e) => e >= 0 && e < 5 ? elemColors[e] : Colors.white54;

/// 剋我的屬性（被誰剋）
int elemKilledBy(int e) => elemKe.entries.firstWhere((x) => x.value == e).key;

/// 小圓章：金/木/水/火/土
class ElemBadge extends StatelessWidget {
  final int elem;
  final double size;
  const ElemBadge({super.key, required this.elem, this.size = 18});

  @override
  Widget build(BuildContext context) {
    final c = elemColor(elem);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.withValues(alpha: 0.25),
        border: Border.all(color: c, width: 1.4),
      ),
      child: Text(elemName(elem), style: TextStyle(color: c, fontSize: size * 0.6, fontWeight: FontWeight.bold, height: 1)),
    );
  }
}

/// 畫在怪物/勇者身後的屬性光暈與腳下符印
void paintElemAura(Canvas canvas, Offset center, double radius, int elem, double t) {
  if (elem < 0) return;
  final c = elemColors[elem];
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = RadialGradient(colors: [c.withValues(alpha: 0.28 + 0.08 * math.sin(t * 3)), c.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: center, radius: radius)),
  );
}
