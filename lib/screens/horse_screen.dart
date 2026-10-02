import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';

final _money = NumberFormat('#,##0');

// 網頁版賭馬（六人座位制）：機制跟骰寶、百家樂一樣——先入座才能下注、有人下注才開跑、
// 有下注的場次結果會公告到 Discord。名次、賠率、派彩全部由伺服器決定，
// 這個畫面只負責「顯示」跟「送出動作」；跑道上的奔跑動畫是播放伺服器給的軌跡，不影響結果。
class HorseScreen extends StatefulWidget {
  const HorseScreen({super.key});

  @override
  State<HorseScreen> createState() => _HorseScreenState();
}

class _HorseScreenState extends State<HorseScreen> {
  static const _chips = [1000, 10000, 50000, 100000, 500000];

  final _api = ApiClient();

  HorseState? _state;
  DateTime _fetchedAt = DateTime.now();
  String? _error;
  bool _busy = false;
  int _chip = 10000;
  double _displayCash = 0; // 比賽動畫沒演完前先不更新現金，避免提前劇透

  Timer? _pollTimer;
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _load());
    // 跑道動畫要順，用 50ms 重畫一次（資料每秒才抓一次，中間靠本機計時推算馬的位置）
    _tickTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await _api.fetchHorseState();
      if (!mounted) return;
      _fetchedAt = DateTime.now();
      _state = s;
      if (!s.isSettled || _animDone) _displayCash = s.cash;
      setState(() => _error = null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  double get _remaining {
    final s = _state;
    if (s == null || !s.isOpen) return 0;
    final elapsed = DateTime.now().difference(_fetchedAt).inMilliseconds / 1000.0;
    return math.max(0, s.secondsLeft - elapsed);
  }

  // 比賽開始後經過幾秒（伺服器給的秒數 + 本機計時）。馬的位置全靠這個推算，
  // 所以中途才進來的人會看到正確的進度，不會重跑也不會劇透。
  double get _raceTime {
    final s = _state;
    if (s == null || !s.isSettled) return 0;
    return s.secondsSinceSettled + DateTime.now().difference(_fetchedAt).inMilliseconds / 1000.0;
  }

  bool get _animDone {
    final s = _state;
    if (s == null || !s.isSettled || s.race == null) return false;
    return _raceTime >= s.race!.lastFinish + 1.2;
  }

  Future<void> _sit(int seat) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await _api.sitHorse(seat);
      if (!r.ok) _snack(r.message);
      await _load();
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _api.leaveHorse();
      await _load();
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bet(String betType) async {
    if (_state == null || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await _api.placeHorseBet(betType, _chip);
      _snack(r.message);
      await _load();
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Scaffold(
      appBar: AppBar(title: const Text('賭馬')),
      body: s == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                    )
                  : const CircularProgressIndicator(),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _cashRow(s),
                      const SizedBox(height: 12),
                      _trackCard(s),
                      if (s.isSettled && _animDone) ...[
                        const SizedBox(height: 10),
                        _resultPanel(s),
                      ],
                      const SizedBox(height: 12),
                      _seats(s),
                      _seatHint(s),
                      const SizedBox(height: 8),
                      _chipRow(),
                      const SizedBox(height: 12),
                      _horseList(s),
                      const SizedBox(height: 16),
                      _history(s),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '6 匹馬繞跑道一圈。可以壓某匹馬「冠軍」（第一名）或「亞軍」（第二名），賠率下注當下就固定，'
                        '賭場抽 ${(s.houseEdge * 100).round()}%。強馬賠率低、冷門馬賠率高。'
                        '每場最多下注 ${_money.format(s.maxBetPerRound)} 元。有人下注才會開跑，結果會公告到 Discord。',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _cashRow(HorseState s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('現金 ${_money.format(_displayCash)} 元', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        if (s.roundId != null) Text('第 ${s.roundId} 場', style: const TextStyle(color: Colors.white54)),
      ],
    );
  }

  // ===== 跑道 =====

  Widget _trackCard(HorseState s) {
    final remaining = _remaining;
    String status;
    if (s.isIdle) {
      status = '等待下注';
    } else if (s.isOpen) {
      status = remaining > 0 ? '下注中' : '起跑中…';
    } else {
      status = _animDone ? '比賽結束' : '比賽中！';
    }
    final t = _raceTime;
    final positions = <int, double>{};
    for (final h in s.horses) {
      positions[h.no] = s.isSettled && s.race != null ? s.race!.progressAt(h.no, t) : 0.0;
    }
    final finished = <int>{};
    if (s.isSettled && s.race != null) {
      s.race!.finishTimes.forEach((no, ft) {
        if (t >= ft) finished.add(no);
      });
    }

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final h = w * 0.78;
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: const Color(0xFF14301F),
          border: Border.all(color: const Color(0xFF8B6B2E), width: 3),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(21),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _TrackPainter(
                    horses: s.horses,
                    progress: positions,
                    raceTime: t,
                    finishTimes: s.race?.finishTimes ?? const {},
                  ),
                ),
              ),
              Align(
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(status, style: const TextStyle(color: Colors.white70, fontSize: 13, letterSpacing: 2)),
                    if (s.isOpen) ...[
                      const SizedBox(height: 4),
                      _countdown(s, remaining),
                    ],
                    if (s.isIdle)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          '入座後，第一筆下注\n就會開始倒數並起跑',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                    if (s.isSettled && !_animDone)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '已衝線 ${finished.length} / ${s.horses.length}',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _countdown(HorseState s, double remaining) {
    final ratio = (remaining / s.betSeconds).clamp(0.0, 1.0);
    final urgent = remaining <= 5;
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(
              value: ratio,
              strokeWidth: 5,
              backgroundColor: Colors.white12,
              color: urgent ? Colors.redAccent : const Color(0xFFF1C40F),
            ),
          ),
          Text(
            remaining.ceil().toString(),
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: urgent ? Colors.redAccent : Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _resultPanel(HorseState s) {
    final order = s.race!.order;
    const medals = ['🥇', '🥈', '🥉'];
    final bet = s.myTotalBet;
    final net = s.myTotalPayout - bet;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < order.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(width: 32, child: Text(i < 3 ? medals[i] : '${i + 1}.', style: const TextStyle(fontSize: 16))),
                  _numberDot(s.horse(order[i]), 22),
                  const SizedBox(width: 8),
                  Text(
                    s.horse(order[i]).name,
                    style: TextStyle(fontWeight: i < 2 ? FontWeight.bold : FontWeight.normal, color: i < 2 ? Colors.white : Colors.white70),
                  ),
                ],
              ),
            ),
          if (bet > 0) ...[
            const Divider(),
            Text(
              net > 0.005 ? '🎉 你贏了 +${_money.format(net)} 元' : (net > -0.005 ? '平手' : '你輸了 ${_money.format(-net)} 元'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: net > 0.005 ? const Color(0xFF2ECC71) : (net > -0.005 ? Colors.white70 : Colors.redAccent),
              ),
            ),
          ] else
            const Padding(padding: EdgeInsets.only(top: 6), child: Text('這場你沒有下注', style: TextStyle(color: Colors.white54))),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${s.revealSecondsLeft.ceil().clamp(0, 99)} 秒後可開下一場',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _numberDot(Horse h, double size) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: h.color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.5)),
      child: Text('${h.no}', style: TextStyle(fontSize: size * 0.55, fontWeight: FontWeight.bold, color: Colors.black87)),
    );
  }

  // ===== 座位 =====

  Widget _seats(HorseState s) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: s.seats.map((seat) => _seatWidget(s, seat)).toList(),
    );
  }

  Widget _seatWidget(HorseState s, SicBoSeat seat) {
    const avatar = 44.0;
    final mine = seat.isMe;
    Widget circle;
    String label;
    if (seat.isEmpty) {
      circle = Container(
        width: avatar,
        height: avatar,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white38, width: 1.5)),
        child: const Icon(Icons.add, color: Colors.white54),
      );
      label = '${seat.seat + 1} 號位';
    } else {
      final name = seat.name ?? '玩家';
      circle = Container(
        width: avatar,
        height: avatar,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: mine ? const Color(0xFF8B6B2E) : const Color(0xFF2C3E50),
          border: Border.all(color: mine ? const Color(0xFFF1C40F) : Colors.white30, width: mine ? 3 : 1.5),
        ),
        child: Text(name.characters.first, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
      );
      label = mine ? '$name（我）' : name;
    }
    Widget? badge;
    if (!seat.isEmpty && seat.bet > 0) {
      if (s.isSettled && _animDone && seat.payout != null) {
        final net = seat.payout! - seat.bet;
        final color = net > 0.005 ? const Color(0xFF2ECC71) : (net > -0.005 ? Colors.white70 : Colors.redAccent);
        badge = Text(
          net > 0.005 ? '+${_money.format(net)}' : (net > -0.005 ? '平手' : '-${_money.format(-net)}'),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color),
        );
      } else {
        badge = Text('押 ${_money.format(seat.bet)}', style: const TextStyle(fontSize: 11, color: Color(0xFFF1C40F)));
      }
    }
    return SizedBox(
      width: 84,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: seat.isEmpty && !_busy ? () => _sit(seat.seat) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              circle,
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: seat.isEmpty ? Colors.white38 : Colors.white),
              ),
              SizedBox(height: 16, child: badge),
            ],
          ),
        ),
      ),
    );
  }

  Widget _seatHint(HorseState s) {
    if (s.mySeat == null) {
      return const Text('👆 點一個空位入座，才能下注', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFF1C40F)));
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('你坐在 ${s.mySeat! + 1} 號位　', style: const TextStyle(color: Colors.white70, fontSize: 13)),
        TextButton(onPressed: _busy ? null : _leave, child: const Text('離座')),
        Text('（${s.idleTimeoutSeconds ~/ 60} 分鐘沒下注會自動離座）', style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    );
  }

  Widget _chipRow() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: _chips.map((c) {
        return ChoiceChip(label: Text(_money.format(c)), selected: c == _chip, onSelected: (_) => setState(() => _chip = c));
      }).toList(),
    );
  }

  // ===== 馬匹與下注 =====

  Widget _horseList(HorseState s) {
    final seated = s.mySeat != null;
    final canBet = seated && !_busy && (s.isIdle || (s.isOpen && _remaining > 0));
    final order = s.race?.order;
    final done = s.isSettled && _animDone;
    return Column(
      children: s.horses.map((h) {
        final isWinner = done && order != null && order[0] == h.no;
        final isSecond = done && order != null && order[1] == h.no;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: h.color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: h.color.withValues(alpha: 0.5), width: 1.2),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  _numberDot(h, 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(h.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        Text('冠軍機率約 ${(h.winProb * 100).round()}%', style: const TextStyle(fontSize: 11, color: Colors.white54)),
                      ],
                    ),
                  ),
                  _betButton(
                    label: '冠軍',
                    odds: h.winOdds,
                    betKey: 'win:${h.no}',
                    s: s,
                    canBet: canBet,
                    color: h.color,
                    highlight: isWinner,
                  ),
                  const SizedBox(width: 8),
                  _betButton(
                    label: '亞軍',
                    odds: h.secondOdds,
                    betKey: 'second:${h.no}',
                    s: s,
                    canBet: canBet,
                    color: h.color,
                    highlight: isSecond,
                  ),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _betButton({
    required String label,
    required double odds,
    required String betKey,
    required HorseState s,
    required bool canBet,
    required Color color,
    required bool highlight,
  }) {
    final mine = s.myBets[betKey] ?? 0;
    final pool = s.poolAmount[betKey] ?? 0;
    return SizedBox(
      width: 96,
      child: Material(
        color: color.withValues(alpha: canBet || highlight ? 0.2 : 0.07),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: canBet ? () => _bet(betKey) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: highlight ? const Color(0xFFF1C40F) : color.withValues(alpha: canBet ? 0.7 : 0.3),
                width: highlight ? 3 : 1.2,
              ),
            ),
            child: Column(
              children: [
                Text(label, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.bold)),
                Text('賠 ${odds.toStringAsFixed(2)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                Text(
                  mine > 0 ? '我押 ${_money.format(mine)}' : (pool > 0 ? '全場 ${_money.format(pool)}' : '—'),
                  style: TextStyle(fontSize: 10, color: mine > 0 ? const Color(0xFFF1C40F) : Colors.white38),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _history(HorseState s) {
    if (s.history.isEmpty) return const SizedBox.shrink();
    // 比賽動畫沒演完時，最新那場先藏起來，不要提早劇透
    final hideLatest = s.isSettled && !_animDone;
    final items = hideLatest ? s.history.skip(1).toList() : s.history;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('近期賽果（新 → 舊）', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 6),
        for (final h in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '第 ${h.id} 場　🥇 ${h.first} 號 ${h.firstName}　🥈 ${h.second} 號 ${h.secondName}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

// 橢圓形跑道（兩端半圓 + 上下直線），一圈從下方中間的起跑線出發，逆時針跑一圈回到同一條線。
// 6 匹馬各佔一條跑道（內圈到外圈），每匹馬用「號碼圓點」表示。
class _TrackPainter extends CustomPainter {
  final List<Horse> horses;
  final Map<int, double> progress; // 馬號 -> 前進比例（0~1）
  final double raceTime;
  final Map<int, double> finishTimes;

  _TrackPainter({required this.horses, required this.progress, required this.raceTime, required this.finishTimes});

  @override
  void paint(Canvas canvas, Size size) {
    const margin = 14.0;
    final outerH = size.height - margin * 2; // 外圈的高度
    final outerR = outerH / 2;
    final halfW = (size.width - margin * 2) / 2;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final straight = math.max(halfW - outerR, 0.0) * 2; // 直線段長度（兩個半圓圓心的距離）
    final lanes = horses.length;
    final laneW = math.min(outerR * 0.108, 17.0);
    final inner = outerR - lanes * laneW; // 最內圈跑道內緣的半徑

    // 跑道底色（外圈到內圈）：深棕色泥地
    final trackPaint = Paint()..color = const Color(0xFF6B4A2B);
    canvas.drawPath(_stadium(cx, cy, straight, outerR), trackPaint);
    // 內場草地
    canvas.drawPath(_stadium(cx, cy, straight, math.max(inner, 1)), Paint()..color = const Color(0xFF1B5E3A));
    // 跑道分隔線
    final linePaint = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i <= lanes; i++) {
      canvas.drawPath(_stadium(cx, cy, straight, outerR - i * laneW), linePaint);
    }
    // 起跑/終點線（下方中間，橫跨所有跑道）
    final linePaint2 = Paint()
      ..color = Colors.white
      ..strokeWidth = 3;
    canvas.drawLine(Offset(cx, cy + outerR), Offset(cx, cy + inner), linePaint2);

    // 馬：依前進比例沿著各自跑道的中線移動
    for (var i = 0; i < horses.length; i++) {
      final h = horses[i];
      final laneRadius = outerR - (i + 0.5) * laneW;
      var f = progress[h.no] ?? 0.0;
      final ft = finishTimes[h.no];
      if (f >= 1.0 && ft != null) {
        // 衝線後多滑行一小段、逐漸慢下來，才不會全部疊在終點線上
        final after = math.max(raceTime - ft, 0.0);
        f = 1.0 + 0.06 * (1 - math.exp(-after * 1.6));
      }
      final p = _pointOn(cx, cy, straight, laneRadius, f);
      final r = math.max(laneW * 0.46, 4.5);
      canvas.drawCircle(p, r + 1.5, Paint()..color = Colors.white);
      canvas.drawCircle(p, r, Paint()..color = h.color);
      final tp = TextPainter(
        text: TextSpan(text: '${h.no}', style: TextStyle(color: Colors.black87, fontSize: r * 1.15, fontWeight: FontWeight.bold)),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }
  }

  Path _stadium(double cx, double cy, double straight, double r) {
    return Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy), width: straight + 2 * r, height: 2 * r),
        Radius.circular(r),
      ));
  }

  // 沿著橢圓跑道中線走 f 圈（0~1+）後的位置：從下方中間出發，往右、上、左、下，逆時針。
  Offset _pointOn(double cx, double cy, double straight, double r, double f) {
    final perimeter = 2 * straight + 2 * math.pi * r;
    var d = (f % 1.0 == 0 && f > 0 ? 1.0 : f % 1.0) * perimeter;
    if (f > 1.0) d = (f - 1.0) * perimeter; // 衝線後繼續往前一小段
    final half = straight / 2;
    // 1) 下方直線右半段
    if (d <= half) return Offset(cx + d, cy + r);
    d -= half;
    // 2) 右側半圓（從正下方經正右方到正上方）
    final arc = math.pi * r;
    if (d <= arc) {
      final theta = math.pi / 2 - d / r;
      return Offset(cx + half + r * math.cos(theta), cy + r * math.sin(theta));
    }
    d -= arc;
    // 3) 上方直線（由右往左）
    if (d <= straight) return Offset(cx + half - d, cy - r);
    d -= straight;
    // 4) 左側半圓（從正上方經正左方到正下方）
    if (d <= arc) {
      final theta = -math.pi / 2 - d / r;
      return Offset(cx - half + r * math.cos(theta), cy + r * math.sin(theta));
    }
    d -= arc;
    // 5) 下方直線左半段，回到起跑線
    return Offset(cx - half + d, cy + r);
  }

  @override
  bool shouldRepaint(covariant _TrackPainter old) => true;
}
