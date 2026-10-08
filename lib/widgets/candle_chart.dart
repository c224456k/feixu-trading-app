import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';

// 台股習慣：紅漲綠跌。
const _up = Color(0xFFFF5A5F);
const _down = Color(0xFF2ECC71);

/// 圖上的水平參考線（例如強制平倉線、進場價）。
class CandleLine {
  final double price;
  final String label;
  final Color color;
  final bool bold;
  const CandleLine(this.price, this.label, this.color, {this.bold = false});
}

/// K 線圖：自己用 CustomPainter 畫（fl_chart 沒有 K 線）。
/// 滑鼠移動 / 手指按住拖曳會顯示十字線與該根的開高低收；
/// 滑鼠滾輪（或雙指開合）縮放、橫向捲動 / 雙指拖曳平移，右下「還原」回到全部。
class CandleChart extends StatefulWidget {
  final List<Candle> candles;
  final bool daily;
  final int decimals; // 價格小數位數（外匯 3 位，股票 2 位）
  final List<CandleLine> lines;

  const CandleChart({super.key, required this.candles, required this.daily, this.decimals = 2, this.lines = const []});

  @override
  State<CandleChart> createState() => _CandleChartState();
}

class _CandleChartState extends State<CandleChart> {
  static const double _leftPad = 52;
  static const double _bottomPad = 22;
  static const double _topPad = 8;
  static const double _rightPad = 8;

  int? _hover;

  // 縮放狀態：_count = 畫面上顯示幾根；_right = 右邊被藏起來幾根（0 = 貼著最新一根，新 K 棒進來會自動跟著走）
  double? _count;
  double _right = 0;
  double _startCount = 0, _startFirst = 0, _startFrac = 0;

  static const int _minCount = 8;

  int get _n => widget.candles.length;
  double get _cnt => (_count ?? _n.toDouble()).clamp(math.min(_minCount, _n).toDouble(), _n.toDouble());
  double get _first => (_n - _right - _cnt).clamp(0, _n - _cnt);
  bool get _zoomed => _count != null && _cnt < _n - 0.5;

  void _clampView() {
    if (_count == null) return;
    final c = _cnt;
    if (c >= _n - 0.5) {
      _count = null;
      _right = 0;
      return;
    }
    _count = c;
    _right = _right.clamp(0, _n - c);
  }

  /// 讓 [idx]（浮點的 K 棒位置）停在 plot 內水平比例 [frac]，並把顯示根數設成 [count]。
  void _applyView(double count, double idx, double frac) {
    final c = count.clamp(math.min(_minCount, _n).toDouble(), _n.toDouble());
    final first = (idx - frac * c).clamp(0.0, _n - c);
    setState(() {
      _count = c;
      _right = _n - first - c;
      _clampView();
      _hover = null;
    });
  }

  double _frac(double dx, double width) =>
      ((dx - _leftPad) / (width - _leftPad - _rightPad)).clamp(0.0, 1.0);

  void _onWheel(PointerSignalEvent e, double width) {
    if (e is! PointerScrollEvent || _n < 2) return;
    // 註冊搶下這個滾輪事件，外層頁面就不會跟著捲動
    GestureBinding.instance.pointerSignalResolver.register(e, (ev) => _doWheel(ev as PointerScrollEvent, width));
  }

  void _doWheel(PointerScrollEvent e, double width) {
    final frac = _frac(e.localPosition.dx, width);
    final dx = e.scrollDelta.dx, dy = e.scrollDelta.dy;
    if (dx.abs() > dy.abs()) {
      // 橫向捲動（觸控板 / shift+滾輪）= 左右平移
      final shift = dx / (width - _leftPad - _rightPad) * _cnt;
      _applyView(_cnt, _first + shift, 0);
      return;
    }
    final idx = _first + frac * _cnt;
    _applyView(_cnt * math.exp(dy * 0.0015), idx, frac);
  }

  void _setHover(double dx, double width) {
    final n = _visible().length;
    if (n == 0) return;
    final plotW = width - _leftPad - _rightPad;
    final i = ((dx - _leftPad) / plotW * n).floor().clamp(0, n - 1);
    if (i != _hover) setState(() => _hover = i);
  }

  List<Candle> _visible() {
    if (!_zoomed) return widget.candles;
    final f = _first.round().clamp(0, _n - 1);
    final e = (f + _cnt.round()).clamp(f + 1, _n);
    return widget.candles.sublist(f, e);
  }

  @override
  void didUpdateWidget(covariant CandleChart old) {
    super.didUpdateWidget(old);
    // 換了週期 / 標的（根數大幅改變）就還原；一次多一根是即時更新，保留縮放
    if (old.daily != widget.daily || (old.candles.length - widget.candles.length).abs() > 1) {
      _count = null;
      _right = 0;
      _hover = null;
    } else {
      _clampView();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.candles.isEmpty) {
      return const Center(child: Text('目前沒有資料'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final vis = _visible();
        final hover = (_hover != null && _hover! < vis.length) ? _hover : null;
        return Listener(
          onPointerSignal: (e) => _onWheel(e, width),
          child: MouseRegion(
            onHover: (e) => _setHover(e.localPosition.dx, width),
            onExit: (_) => setState(() => _hover = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _setHover(d.localPosition.dx, width),
              onScaleStart: (d) {
                _startCount = _cnt;
                _startFirst = _first;
                _startFrac = _frac(d.localFocalPoint.dx, width);
              },
              onScaleUpdate: (d) {
                if (d.pointerCount >= 2 && _n >= 2) {
                  // 雙指：縮放 + 平移（focal 點下的那根 K 棒會跟著手指走）
                  final scale = d.horizontalScale > 0.01 ? d.horizontalScale : d.scale;
                  final idx = _startFirst + _startFrac * _startCount;
                  _applyView(_startCount / scale, idx, _frac(d.localFocalPoint.dx, width));
                } else {
                  _setHover(d.localFocalPoint.dx, width);
                }
              },
              onScaleEnd: (_) => setState(() => _hover = null),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _CandlePainter(
                        candles: vis,
                        daily: widget.daily,
                        decimals: widget.decimals,
                        lines: widget.lines,
                        hover: hover,
                        textColor: Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey,
                        gridColor: Colors.grey.withValues(alpha: 0.25),
                      ),
                    ),
                  ),
                  if (hover != null) _buildInfo(vis[hover], hover < vis.length / 2),
                  if (_zoomed)
                    Positioned(
                      right: _rightPad + 2,
                      bottom: _bottomPad + 2,
                      child: GestureDetector(
                        onTap: () => setState(() {
                          _count = null;
                          _right = 0;
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text('還原', style: TextStyle(color: Colors.white, fontSize: 11)),
                        ),
                      ),
                    ),
                ],
              ),
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
  final List<CandleLine> lines;
  final int? hover;
  final Color textColor;
  final Color gridColor;

  _CandlePainter({
    required this.candles,
    required this.daily,
    this.decimals = 2,
    this.lines = const [],
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
    // 參考線離得不太遠就一起納入範圍（強平線要看得到）；太遠的話改在圖邊緣標示方向，避免 K 棒被壓扁
    final span = hi - lo;
    for (final l in lines) {
      if (l.price > hi && l.price - lo < span * 4) hi = l.price;
      if (l.price < lo && hi - l.price < span * 4) lo = l.price;
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
    final bodyW = (slot * 0.7).clamp(1.0, 40.0);
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

    for (final l in lines) {
      final inside = l.price >= lo && l.price <= hi;
      final yy = inside ? y(l.price) : (l.price > hi ? plot.top + 8 : plot.bottom - 8);
      final paint = Paint()
        ..color = l.color
        ..strokeWidth = l.bold ? 2.2 : 1.2
        ..style = PaintingStyle.stroke;
      if (inside) {
        // 虛線
        const dash = 7.0, gap = 5.0;
        for (var x = plot.left; x < plot.right; x += dash + gap) {
          canvas.drawLine(Offset(x, yy), Offset((x + dash).clamp(plot.left, plot.right), yy), paint);
        }
      }
      final tp = TextPainter(
        text: TextSpan(
          text: '${inside ? '' : (l.price > hi ? '▲ ' : '▼ ')}${l.label} ${l.price.toStringAsFixed(decimals)}',
          style: TextStyle(color: Colors.black, fontSize: 10.5, fontWeight: FontWeight.bold),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      final chip = Rect.fromLTWH(plot.left + 4, yy - tp.height - 3, tp.width + 8, tp.height + 2);
      canvas.drawRRect(RRect.fromRectAndRadius(chip, const Radius.circular(3)), Paint()..color = l.color);
      tp.paint(canvas, Offset(chip.left + 4, chip.top + 1));
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
      old.candles != candles || old.hover != hover || old.daily != daily || old.decimals != decimals || old.lines != lines;
}
