import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';

// 台股習慣：紅漲綠跌。
const _up = Color(0xFFFF5A5F);
const _down = Color(0xFF2ECC71);

/// K 線圖：自己用 CustomPainter 畫（fl_chart 沒有 K 線）。
/// 滑鼠移動 / 手指按住拖曳會顯示十字線與該根的開高低收。
class CandleChart extends StatefulWidget {
  final List<Candle> candles;
  final bool daily;
  final int decimals; // 價格小數位數（外匯 3 位，股票 2 位）

  const CandleChart({super.key, required this.candles, required this.daily, this.decimals = 2});

  @override
  State<CandleChart> createState() => _CandleChartState();
}

class _CandleChartState extends State<CandleChart> {
  static const double _leftPad = 52;
  static const double _bottomPad = 22;
  static const double _topPad = 8;
  static const double _rightPad = 8;

  int? _hover;

  void _setHover(double dx, double width) {
    final n = widget.candles.length;
    if (n == 0) return;
    final plotW = width - _leftPad - _rightPad;
    final i = ((dx - _leftPad) / plotW * n).floor().clamp(0, n - 1);
    if (i != _hover) setState(() => _hover = i);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.candles.isEmpty) {
      return const Center(child: Text('目前沒有資料'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final hover = (_hover != null && _hover! < widget.candles.length) ? _hover : null;
        return MouseRegion(
          onHover: (e) => _setHover(e.localPosition.dx, width),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _setHover(d.localPosition.dx, width),
            onHorizontalDragUpdate: (d) => _setHover(d.localPosition.dx, width),
            onHorizontalDragEnd: (_) => setState(() => _hover = null),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CandlePainter(
                      candles: widget.candles,
                      daily: widget.daily,
                      decimals: widget.decimals,
                      hover: hover,
                      textColor: Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey,
                      gridColor: Colors.grey.withValues(alpha: 0.25),
                    ),
                  ),
                ),
                if (hover != null) _buildInfo(widget.candles[hover], hover < widget.candles.length / 2),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfo(Candle c, bool onRight) {
    final fmt = widget.daily ? DateFormat('MM/dd') : DateFormat('MM/dd HH:mm');
    final color = c.close >= c.open ? _up : _down;
    final change = c.open == 0 ? 0.0 : (c.close - c.open) / c.open * 100;
    return Positioned(
      left: onRight ? null : _leftPad + 4,
      right: onRight ? _rightPad + 4 : null,
      top: _topPad,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '${fmt.format(c.time.toLocal())}\n'
            '開 ${c.open.toStringAsFixed(widget.decimals)}　高 ${c.high.toStringAsFixed(widget.decimals)}\n'
            '低 ${c.low.toStringAsFixed(widget.decimals)}　收 ${c.close.toStringAsFixed(widget.decimals)}\n'
            '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)}%',
            style: TextStyle(color: color, fontSize: 11, height: 1.35),
          ),
        ),
      ),
    );
  }
}

class _CandlePainter extends CustomPainter {
  final List<Candle> candles;
  final bool daily;
  final int decimals;
  final int? hover;
  final Color textColor;
  final Color gridColor;

  _CandlePainter({
    required this.candles,
    required this.daily,
    this.decimals = 2,
    required this.hover,
    required this.textColor,
    required this.gridColor,
  });

  void _text(Canvas canvas, String s, Offset at, {bool centerX = false, bool rightAlign = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: textColor, fontSize: 10)),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (centerX) dx -= tp.width / 2;
    if (rightAlign) dx -= tp.width;
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = _CandleChartState._leftPad;
    const bottom = _CandleChartState._bottomPad;
    const top = _CandleChartState._topPad;
    const right = _CandleChartState._rightPad;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);

    var lo = candles.map((c) => c.low).reduce((a, b) => a < b ? a : b);
    var hi = candles.map((c) => c.high).reduce((a, b) => a > b ? a : b);
    if (hi - lo < 0.02) {
      hi += 0.01;
      lo -= 0.01;
    }
    final pad = (hi - lo) * 0.06;
    lo -= pad;
    hi += pad;
    double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var k = 0; k <= 4; k++) {
      final v = lo + (hi - lo) * k / 4;
      final yy = y(v);
      canvas.drawLine(Offset(plot.left, yy), Offset(plot.right, yy), grid);
      _text(canvas, v.toStringAsFixed(decimals), Offset(plot.left - 4, yy), rightAlign: true);
    }

    final n = candles.length;
    final slot = plot.width / n;
    final bodyW = (slot * 0.7).clamp(1.0, 24.0);
    final fmt = daily ? DateFormat('MM/dd') : DateFormat('HH:mm');
    final labelEvery = (n / 5).ceil().clamp(1, 999);

    for (var i = 0; i < n; i++) {
      final c = candles[i];
      final cx = plot.left + slot * (i + 0.5);
      final color = c.close >= c.open ? _up : _down;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.2;
      canvas.drawLine(Offset(cx, y(c.high)), Offset(cx, y(c.low)), paint);
      final top1 = y(c.open > c.close ? c.open : c.close);
      final bot1 = y(c.open > c.close ? c.close : c.open);
      final bodyH = (bot1 - top1) < 1.2 ? 1.2 : (bot1 - top1);
      canvas.drawRect(Rect.fromLTWH(cx - bodyW / 2, top1, bodyW, bodyH), paint..style = PaintingStyle.fill);
      if (i % labelEvery == 0) {
        _text(canvas, fmt.format(c.time.toLocal()), Offset(cx, plot.bottom + 12), centerX: true);
      }
    }

    if (hover != null) {
      final c = candles[hover!];
      final cx = plot.left + slot * (hover! + 0.5);
      final cross = Paint()
        ..color = textColor.withValues(alpha: 0.6)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(cx, plot.top), Offset(cx, plot.bottom), cross);
      canvas.drawLine(Offset(plot.left, y(c.close)), Offset(plot.right, y(c.close)), cross);
    }
  }

  @override
  bool shouldRepaint(covariant _CandlePainter old) =>
      old.candles != candles || old.hover != hover || old.daily != daily || old.decimals != decimals;
}
