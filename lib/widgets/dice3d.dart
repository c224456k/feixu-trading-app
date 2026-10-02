import 'dart:math' as math;

import 'package:flutter/material.dart';

// 真正的 3D 骰子：用 3D 座標 + 透視投影畫出一顆立方體（六個面都有正確的點數、光影、圓角），
// 不是貼圖。翻滾動畫就是把立方體在 3D 空間裡旋轉，最後停在「指定點數朝正面」的角度。
// 點數對面相加 = 7（1-6、2-5、3-4），跟真的骰子一樣。
class Dice3D extends StatelessWidget {
  final int value; // 1~6；0 = 還沒開骰（正面畫問號）
  final double size;
  final double rollT; // 0~1：翻滾進度，1 = 已停下；中途是旋轉中
  final int seed; // 每顆骰子翻滾的旋轉軸不同，看起來才不會三顆一模一樣
  final double wobble; // 靜止時微微晃動（弧度），讓桌面看起來有生氣

  const Dice3D({super.key, required this.value, required this.size, this.rollT = 1, this.seed = 0, this.wobble = 0});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: Dice3DPainter(value: value, rollT: rollT, seed: seed, wobble: wobble)),
    );
  }
}

class _V {
  final double x, y, z;
  const _V(this.x, this.y, this.z);
  _V operator +(_V o) => _V(x + o.x, y + o.y, z + o.z);
  _V operator -(_V o) => _V(x - o.x, y - o.y, z - o.z);
  _V operator *(double k) => _V(x * k, y * k, z * k);
  double dot(_V o) => x * o.x + y * o.y + z * o.z;
  _V cross(_V o) => _V(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get len => math.sqrt(x * x + y * y + z * z);
  _V get unit => len == 0 ? this : this * (1 / len);
}

class _M {
  final List<double> m; // 3x3，列優先寫法：m[r*3+c]
  const _M(this.m);

  static const identity = _M([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  static _M rotX(double a) {
    final c = math.cos(a), s = math.sin(a);
    return _M([1, 0, 0, 0, c, -s, 0, s, c]);
  }

  static _M rotY(double a) {
    final c = math.cos(a), s = math.sin(a);
    return _M([c, 0, s, 0, 1, 0, -s, 0, c]);
  }

  // 羅德里格旋轉公式：繞任意軸旋轉
  static _M axisAngle(_V axis, double a) {
    final u = axis.unit;
    final c = math.cos(a), s = math.sin(a), t = 1 - c;
    return _M([
      t * u.x * u.x + c, t * u.x * u.y - s * u.z, t * u.x * u.z + s * u.y,
      t * u.x * u.y + s * u.z, t * u.y * u.y + c, t * u.y * u.z - s * u.x,
      t * u.x * u.z - s * u.y, t * u.y * u.z + s * u.x, t * u.z * u.z + c,
    ]);
  }

  _M operator *(_M o) {
    final r = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        r[i * 3 + j] = m[i * 3] * o.m[j] + m[i * 3 + 1] * o.m[3 + j] + m[i * 3 + 2] * o.m[6 + j];
      }
    }
    return _M(r);
  }

  _V apply(_V v) => _V(
        m[0] * v.x + m[1] * v.y + m[2] * v.z,
        m[3] * v.x + m[4] * v.y + m[5] * v.z,
        m[6] * v.x + m[7] * v.y + m[8] * v.z,
      );
}

class _Face {
  final _V n, u, v; // 法向量與面上的兩個座標軸
  final int value;
  const _Face(this.n, this.u, this.v, this.value);
}

// 立方體的六個面（對面相加 = 7）
const _faces = [
  _Face(_V(0, 0, 1), _V(1, 0, 0), _V(0, 1, 0), 1),
  _Face(_V(0, 0, -1), _V(-1, 0, 0), _V(0, 1, 0), 6),
  _Face(_V(1, 0, 0), _V(0, 0, -1), _V(0, 1, 0), 3),
  _Face(_V(-1, 0, 0), _V(0, 0, 1), _V(0, 1, 0), 4),
  _Face(_V(0, 1, 0), _V(1, 0, 0), _V(0, 0, -1), 2),
  _Face(_V(0, -1, 0), _V(1, 0, 0), _V(0, 0, 1), 5),
];

// 點數在 3x3 格子上的位置（0~2, 0~2）
const _pipLayout = {
  1: [(1, 1)],
  2: [(0, 0), (2, 2)],
  3: [(0, 0), (1, 1), (2, 2)],
  4: [(0, 0), (2, 0), (0, 2), (2, 2)],
  5: [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)],
  6: [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)],
};

class Dice3DPainter extends CustomPainter {
  final int value;
  final double rollT;
  final int seed;
  final double wobble;

  Dice3DPainter({required this.value, required this.rollT, required this.seed, required this.wobble});

  // 把「指定點數」轉到正面朝向鏡頭的旋轉
  static _M _faceToFront(int v) {
    switch (v) {
      case 6:
        return _M.rotY(math.pi);
      case 3:
        return _M.rotY(-math.pi / 2);
      case 4:
        return _M.rotY(math.pi / 2);
      case 2:
        return _M.rotX(math.pi / 2);
      case 5:
        return _M.rotX(-math.pi / 2);
      default:
        return _M.identity;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    const camZ = 5.2; // 鏡頭離立方體中心的距離（透視強度）
    final scale = size.width / 3.0;
    final center = Offset(size.width / 2, size.height / 2);

    // 停下來之後固定的觀看角度：稍微俯視、稍微側轉，才看得到頂面跟側面（立體感來源）
    final tilt = _M.rotX(-0.5 + wobble * 0.5) * _M.rotY(0.55 + wobble);
    final base = _faceToFront(value == 0 ? 1 : value);
    var rot = tilt * base;
    var lift = 0.0;
    if (rollT < 1) {
      // 翻滾中：繞著各自的旋轉軸高速旋轉，並隨進度逐漸慢下來、回到停止的角度
      final t = rollT.clamp(0.0, 1.0);
      final eased = 1 - math.pow(1 - t, 3).toDouble();
      final axis = _V(math.sin(seed * 1.7 + 0.5), math.cos(seed * 2.3 + 1.0), math.sin(seed * 0.9 + 2.0) * 0.6 + 0.4);
      final turns = 3.0 + (seed % 3) * 0.5;
      final spin = _M.axisAngle(axis, (1 - eased) * turns * 2 * math.pi);
      rot = tilt * spin * base;
      lift = math.sin(t * math.pi * 3).abs() * (1 - t) * 0.35; // 彈跳
    }

    _V rotate(_V p) => rot.apply(p);
    Offset project(_V p) {
      final s = camZ / (camZ - p.z);
      return Offset(center.dx + p.x * s * scale, center.dy + (p.y - lift) * s * scale);
    }

    // 地面陰影：骰子彈起時變小變淡
    final shadowScale = 1 - lift * 0.8;
    canvas.drawOval(
      Rect.fromCenter(center: center + Offset(0, size.height * 0.4), width: size.width * 0.78 * shadowScale, height: size.height * 0.14 * shadowScale),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.38 * shadowScale)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    const light = _V(-0.45, -0.75, 0.5); // 光源方向（左上前方）
    final lightDir = light.unit;
    final camera = const _V(0, 0, camZ);

    // 先算出每個面的資料，再由遠到近畫（凸立方體只會有朝向鏡頭的面，不會互相遮擋，但保險起見還是排序）
    final visible = <(_Face, _V, double)>[];
    for (final f in _faces) {
      final nRot = rotate(f.n);
      final centerRot = rotate(f.n);
      // 面朝向鏡頭的判斷（透視）：法向量跟「面中心指向鏡頭」的向量夾角小於 90 度
      if ((camera - centerRot).dot(nRot) > 0) {
        visible.add((f, nRot, centerRot.z));
      }
    }
    visible.sort((a, b) => a.$3.compareTo(b.$3));

    for (final (f, nRot, _) in visible) {
      final corners = [
        f.n + f.u + f.v,
        f.n + f.u - f.v,
        f.n - f.u - f.v,
        f.n - f.u + f.v,
      ].map((c) => project(rotate(c))).toList();

      // 面的亮度：依光源方向 + 環境光
      final lambert = math.max(0.0, nRot.dot(lightDir));
      final bright = (0.58 + 0.42 * lambert).clamp(0.0, 1.0);
      final faceColor = Color.lerp(const Color(0xFFB8B8C2), const Color(0xFFFFFFFF), bright)!;
      final path = _rounded(corners, 0.16);
      canvas.drawPath(path, Paint()..color = faceColor);
      // 面的漸層高光：讓面不要死白
      final bounds = path.getBounds();
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white.withValues(alpha: 0.28 * bright), Colors.black.withValues(alpha: 0.10)],
          ).createShader(bounds),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0x44000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..strokeJoin = StrokeJoin.round,
      );

      // 點數（或問號）
      final isFrontFace = f.value == 1 && value == 0;
      if (isFrontFace) {
        final c = project(rotate(f.n));
        final tp = TextPainter(
          text: TextSpan(text: '?', style: TextStyle(fontSize: size.width * 0.5, fontWeight: FontWeight.bold, color: Colors.black38)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
        continue;
      }
      final pipColor = f.value == 1 ? const Color(0xFFD62828) : const Color(0xFF1B1B1F);
      final pipR = f.value == 1 ? 0.30 : 0.19;
      for (final (cx, cy) in _pipLayout[f.value]!) {
        final c3 = f.n * 1.002 + f.u * ((cx - 1) * 0.52) + f.v * ((cy - 1) * 0.52);
        // 圓形的點數：在面所在的平面上取一圈點，一起投影，所以斜看時會自然變成橢圓（透視縮短）
        final pts = <Offset>[];
        for (var i = 0; i < 18; i++) {
          final a = i / 18 * 2 * math.pi;
          pts.add(project(rotate(c3 + f.u * (math.cos(a) * pipR) + f.v * (math.sin(a) * pipR))));
        }
        final pipPath = Path()..addPolygon(pts, true);
        canvas.drawPath(pipPath, Paint()..color = pipColor);
        // 點數凹陷的反光
        final hc = project(rotate(c3 - f.u * (pipR * 0.35) - f.v * (pipR * 0.35)));
        canvas.drawCircle(hc, size.width * 0.012, Paint()..color = Colors.white.withValues(alpha: 0.35));
      }
    }
  }

  // 把四邊形的每個角削成圓角（二次曲線），讓骰子看起來有倒角、不是尖銳的方塊
  Path _rounded(List<Offset> pts, double frac) {
    final path = Path();
    final n = pts.length;
    for (var i = 0; i < n; i++) {
      final prev = pts[(i - 1 + n) % n];
      final cur = pts[i];
      final next = pts[(i + 1) % n];
      final a = Offset.lerp(cur, prev, frac)!;
      final b = Offset.lerp(cur, next, frac)!;
      if (i == 0) {
        path.moveTo(a.dx, a.dy);
      } else {
        path.lineTo(a.dx, a.dy);
      }
      path.quadraticBezierTo(cur.dx, cur.dy, b.dx, b.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant Dice3DPainter old) =>
      old.value != value || old.rollT != rollT || old.seed != seed || old.wobble != wobble;
}
