import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/casino_music.dart';
import '../widgets/casino_bet.dart';

final _money = NumberFormat('#,##0');

// 網頁版賭馬（六人座位制）：機制跟骰寶、百家樂一樣——先入座才能下注、有人下注才開跑、
// 有下注的場次結果會公告到 Discord（等比賽跑完才公告）。名次、賠率、派彩全部由伺服器決定，
// 這個畫面只負責「顯示」跟「送出動作」；跑道上的奔跑動畫是播放伺服器給的軌跡，不影響結果。
//
// 版面（為了「一邊看比賽一邊下注、不用上下滑」）：
// - 手機（窄螢幕）：跑道跟座位固定在上方，下面的下注區自己捲動；每匹馬一行，左邊壓冠軍、右邊壓亞軍
// - 平板/電腦（寬螢幕）：左邊跑道跟座位，右邊下注區，一左一右
class HorseScreen extends StatefulWidget {
  const HorseScreen({super.key});

  @override
  State<HorseScreen> createState() => _HorseScreenState();
}

class _HorseScreenState extends State<HorseScreen> {

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
    CasinoMusic.instance.enter();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _load());
    // 跑道動畫要順，用 50ms 重畫一次（資料每秒才抓一次，中間靠本機計時推算馬的位置）
    _tickTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    CasinoMusic.instance.leave();
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
      appBar: AppBar(title: const Text('賭馬'), toolbarHeight: 48, actions: const [MusicButton()]),
      body: s == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                    )
                  : const CircularProgressIndicator(),
            )
          : LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth >= 760;
              if (wide) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [_topBar(s), const SizedBox(height: 6), _trackCard(s, 0.56), const SizedBox(height: 8), _seatStrip(s)],
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(width: 420, child: SingleChildScrollView(child: _betPanel(s))),
                    ],
                  ),
                );
              }
              // 窄螢幕：上面固定（金額、跑道、座位），下面下注區自己捲動，不用為了看馬往上滑
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _topBar(s),
                    const SizedBox(height: 4),
                    _trackCard(s, 0.56),
                    const SizedBox(height: 6),
                    _seatStrip(s),
                    const SizedBox(height: 4),
                    Expanded(child: SingleChildScrollView(child: _betPanel(s))),
                  ],
                ),
              );
            }),
    );
  }

  Widget _topBar(HorseState s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(end: _displayCash),
          duration: const Duration(milliseconds: 1200),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => Text('💰 現金 ${_money.format(v)} 元', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ),
        if (s.roundId != null) Text('第 ${s.roundId} 場', style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }

  // ===== 跑道 =====

  Widget _trackCard(HorseState s, double aspect) {
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
    var finished = 0;
    if (s.isSettled && s.race != null) {
      s.race!.finishTimes.forEach((no, ft) {
        if (t >= ft) finished++;
      });
    }

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final h = (w * aspect).clamp(190.0, 360.0);
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF8B6B2E), width: 2.5),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15.5),
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
              // 內場（草地中間）放狀態、倒數、比賽結果
              Align(alignment: Alignment.center, child: _infield(s, status, remaining, finished)),
            ],
          ),
        ),
      );
    });
  }

  Widget _infield(HorseState s, String status, double remaining, int finished) {
    const labelStyle = TextStyle(color: Colors.white, fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.bold, shadows: [Shadow(color: Colors.black87, blurRadius: 3)]);
    if (s.isSettled && _animDone && s.race != null) {
      final order = s.race!.order;
      const medals = ['🥇', '🥈', '🥉'];
      final bet = s.myTotalBet;
      final net = s.myTotalPayout - bet;
      final names = [for (var i = 0; i < 3; i++) '${medals[i]}${order[i]} ${s.horse(order[i]).name}'].join('  ');
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(names, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, shadows: [Shadow(color: Colors.black87, blurRadius: 3)])),
          if (bet > 0)
            Text(
              net > 0.005 ? '🎉 你贏了 +${_money.format(net)}' : (net > -0.005 ? '平手' : '你輸了 ${_money.format(-net)}'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: net > 0.005 ? const Color(0xFF7CFFB0) : (net > -0.005 ? Colors.white70 : const Color(0xFFFF8A8A)),
                shadows: const [Shadow(color: Colors.black87, blurRadius: 3)],
              ),
            )
          else
            const Text('這場你沒有下注', style: TextStyle(color: Colors.white70, fontSize: 11)),
          Text(
            '${s.revealSecondsLeft.ceil().clamp(0, 99)} 秒後可開下一場',
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.isSettled ? '$status  $finished/${s.horses.length}' : status,
          style: labelStyle,
        ),
        if (s.isOpen) ...[
          const SizedBox(width: 10),
          _countdown(s, remaining),
        ],
        if (s.isIdle)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Text('入座後第一筆下注即開跑', style: TextStyle(color: Colors.white70, fontSize: 11)),
          ),
      ],
    );
  }

  Widget _countdown(HorseState s, double remaining) {
    final ratio = (remaining / s.betSeconds).clamp(0.0, 1.0);
    final urgent = remaining <= 5;
    return SizedBox(
      width: 38,
      height: 38,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 38,
            height: 38,
            child: CircularProgressIndicator(
              value: ratio,
              strokeWidth: 4,
              backgroundColor: Colors.black38,
              color: urgent ? Colors.redAccent : const Color(0xFFF1C40F),
            ),
          ),
          Text(
            remaining.ceil().toString(),
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: urgent ? Colors.redAccent : Colors.white),
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

  // ===== 座位（一排小頭像，固定在跑道下面）=====

  Widget _seatStrip(HorseState s) {
    return Column(
      children: [
        Row(
          children: s.seats.map((seat) => Expanded(child: _seatItem(s, seat))).toList(),
        ),
        _seatHint(s),
      ],
    );
  }

  Widget _seatItem(HorseState s, SicBoSeat seat) {
    const avatar = 30.0;
    final mine = seat.isMe;
    Widget circle;
    String label;
    if (seat.isEmpty) {
      circle = Container(
        width: avatar,
        height: avatar,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white38, width: 1.2)),
        child: const Icon(Icons.add, color: Colors.white54, size: 16),
      );
      label = '${seat.seat + 1}';
    } else {
      final name = seat.name ?? '玩家';
      circle = Container(
        width: avatar,
        height: avatar,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: mine ? const Color(0xFF8B6B2E) : const Color(0xFF2C3E50),
          border: Border.all(color: mine ? const Color(0xFFF1C40F) : Colors.white30, width: mine ? 2.5 : 1.2),
        ),
        child: Text(name.characters.first, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white)),
      );
      label = mine ? '$name(我)' : name;
    }
    Widget? badge;
    if (!seat.isEmpty && seat.bet > 0) {
      if (s.isSettled && _animDone && seat.payout != null) {
        final net = seat.payout! - seat.bet;
        final color = net > 0.005 ? const Color(0xFF2ECC71) : (net > -0.005 ? Colors.white70 : Colors.redAccent);
        badge = Text(
          net > 0.005 ? '+${_compact(net)}' : (net > -0.005 ? '平' : '-${_compact(-net)}'),
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color),
        );
      } else {
        badge = Text(_compact(seat.bet), style: const TextStyle(fontSize: 10, color: Color(0xFFF1C40F)));
      }
    }
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: seat.isEmpty && !_busy ? () => _sit(seat.seat) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            circle,
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: seat.isEmpty ? Colors.white38 : Colors.white)),
            SizedBox(height: 13, child: badge),
          ],
        ),
      ),
    );
  }

  // 金額縮寫：12,000 → 1.2萬、1,500,000 → 150萬（座位小標籤放不下完整數字）
  String _compact(double v) {
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}億';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(v >= 1000000 ? 0 : 1).replaceAll(RegExp(r'\.0$'), '')}萬';
    return v.toStringAsFixed(0);
  }

  Widget _seatHint(HorseState s) {
    if (s.mySeat == null) {
      return const Text('👆 點一個空位入座，才能下注', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFF1C40F), fontSize: 12));
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('你坐 ${s.mySeat! + 1} 號位', style: const TextStyle(color: Colors.white70, fontSize: 12)),
        TextButton(
          onPressed: _busy ? null : _leave,
          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 24), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          child: const Text('離座', style: TextStyle(fontSize: 12)),
        ),
        Text('（${s.idleTimeoutSeconds ~/ 60} 分鐘沒下注自動離座）', style: const TextStyle(color: Colors.white38, fontSize: 10)),
      ],
    );
  }

  // ===== 下注區 =====

  Widget _betPanel(HorseState s) {
    final seated = s.mySeat != null;
    final canBet = seated && !_busy && (s.isIdle || (s.isOpen && _remaining > 0));
    final order = s.race?.order;
    final done = s.isSettled && _animDone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _chipRow(),
        const SizedBox(height: 6),
        for (final h in s.horses)
          _horseRow(
            s,
            h,
            canBet: canBet,
            winHighlight: done && order != null && order[0] == h.no,
            secondHighlight: done && order != null && order[1] == h.no,
          ),
        const SizedBox(height: 6),
        _history(s),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 11))),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 16),
          child: Text(
            '6 匹馬繞跑道一圈：左邊按鈕壓「冠軍」（第一名），右邊壓「亞軍」（第二名）。賠率下注當下固定、賭場抽 ${(s.houseEdge * 100).round()}%，'
            '每場最多下注 ${_money.format(s.maxBetPerRound)} 元。有人下注才開跑，等馬跑完結果才會公告到 Discord。',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _chipRow() => ChipSelector(selected: _chip, size: 46, onSelect: (c) => setState(() => _chip = c));

  // 一匹馬一行：左邊馬號與名字，然後「冠軍」按鈕在左、「亞軍」按鈕在右
  Widget _horseRow(HorseState s, Horse h, {required bool canBet, required bool winHighlight, required bool secondHighlight}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: h.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: h.color.withValues(alpha: 0.45), width: 1),
      ),
      child: Row(
        children: [
          _numberDot(h, 26),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                Text('奪冠率 ${(h.winProb * 100).round()}%', style: const TextStyle(fontSize: 10, color: Colors.white54)),
              ],
            ),
          ),
          _betButton('冠軍', h.winOdds, 'win:${h.no}', s, canBet, h.color, winHighlight),
          const SizedBox(width: 6),
          _betButton('亞軍', h.secondOdds, 'second:${h.no}', s, canBet, h.color, secondHighlight),
        ],
      ),
    );
  }

  Widget _betButton(String label, double odds, String betKey, HorseState s, bool canBet, Color color, bool highlight) {
    final mine = s.myBets[betKey] ?? 0;
    final pool = s.poolAmount[betKey] ?? 0;
    final payout = s.myPayouts[betKey] ?? 0;
    final settled = s.isSettled && _animDone;
    final pulse = highlight ? (0.5 + 0.5 * math.sin(DateTime.now().millisecondsSinceEpoch / 180.0)) : 0.0;
    final shown = settled && payout > 0.005 ? payout : mine;
    final net = payout - mine;
    final lost = settled && mine > 0 && payout <= 0.005;
    return SizedBox(
      width: 104,
      child: GestureDetector(
        onTap: canBet ? () => _bet(betKey) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: canBet || highlight ? 0.22 : 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: highlight ? Color.lerp(const Color(0xFFB8860B), const Color(0xFFFFE066), pulse)! : color.withValues(alpha: canBet ? 0.8 : 0.3),
              width: highlight ? 3 : 1.5,
            ),
            boxShadow: highlight ? [BoxShadow(color: const Color(0xFFF1C40F).withValues(alpha: 0.3 + 0.3 * pulse), blurRadius: 10)] : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: shown > 0
                    ? Opacity(
                        opacity: lost ? 0.35 : 1,
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey('${s.roundId}-$betKey-${shown.round()}'),
                          tween: Tween(begin: 0, end: 1),
                          duration: const Duration(milliseconds: 380),
                          curve: Curves.bounceOut,
                          builder: (context, v, child) => Transform.translate(offset: Offset(0, -18 * (1 - v)), child: Opacity(opacity: v.clamp(0.0, 1.0), child: child)),
                          child: ChipPile(amount: shown, size: 22),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '$label ', style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
                        TextSpan(text: odds.toStringAsFixed(2), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                    Text(
                      settled && mine > 0
                          ? (net > 0.005 ? '+${_compact(net)}' : (net > -0.005 ? '退回' : '-${_compact(-net)}'))
                          : (mine > 0 ? '我押 ${_compact(mine)}' : (pool > 0 ? '全場 ${_compact(pool)}' : (canBet ? '押 ${_compact(_chip.toDouble())}' : '—'))),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: settled && mine > 0 ? FontWeight.bold : FontWeight.normal,
                        color: settled && mine > 0
                            ? (net > 0.005 ? const Color(0xFFFFE066) : (net > -0.005 ? Colors.white70 : Colors.redAccent))
                            : (mine > 0 ? const Color(0xFFF1C40F) : Colors.white38),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _history(HorseState s) {
    if (s.history.isEmpty) return const SizedBox.shrink();
    // 比賽動畫沒演完時，最新那場先藏起來，不要提早劇透
    final hideLatest = s.isSettled && !_animDone;
    final items = (hideLatest ? s.history.skip(1) : s.history).take(3).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('近期賽果', style: TextStyle(color: Colors.white54, fontSize: 11)),
        for (final h in items)
          Text('第 ${h.id} 場　🥇 ${h.first} ${h.firstName}　🥈 ${h.second} ${h.secondName}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    );
  }
}

// 橢圓形跑道（兩端半圓 + 上下直線），一圈從下方中間的起跑線出發，逆時針跑一圈回到同一條線。
// 6 匹馬各佔一條跑道（內圈到外圈）。畫了：草地、外圍白色圍欄（含柱子）、沙地跑道（漸層 + 耙痕）、
// 分隔線、內場草坪（割草條紋）與內欄、1/4 圈距離標示、黑白格子的起跑/終點線。
class _TrackPainter extends CustomPainter {
  final List<Horse> horses;
  final Map<int, double> progress; // 馬號 -> 前進比例（0~1）
  final double raceTime;
  final Map<int, double> finishTimes;

  _TrackPainter({required this.horses, required this.progress, required this.raceTime, required this.finishTimes});

  @override
  void paint(Canvas canvas, Size size) {
    const margin = 13.0;
    final outerH = size.height - margin * 2;
    final outerR = outerH / 2;
    final halfW = (size.width - margin * 2) / 2;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final straight = math.max(halfW - outerR, 0.0) * 2;
    final lanes = horses.length;
    final laneW = math.min(outerR * 0.115, 17.0);
    final inner = outerR - lanes * laneW;

    // 1) 外圍草地 + 割草條紋
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1E5233));
    final stripe = Paint()..color = const Color(0x14FFFFFF);
    for (var x = 0.0; x < size.width; x += 28) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 14, size.height), stripe);
    }

    // 2) 外圍白色圍欄：先畫一圈陰影，再畫白色欄杆，每隔一段加一根柱子
    final railPath = _stadium(cx, cy, straight, outerR + 5);
    canvas.drawPath(
      railPath,
      Paint()
        ..color = Colors.black45
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawPath(railPath, Paint()..color = const Color(0xFFF2F2F2)..style = PaintingStyle.stroke..strokeWidth = 2.6);
    for (final m in railPath.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 24) {
        final tan = m.getTangentForOffset(d);
        if (tan != null) canvas.drawCircle(tan.position, 2.2, Paint()..color = Colors.white);
      }
    }

    // 3) 沙地跑道（由外往內做漸層，看起來有明暗）+ 耙痕
    final trackPath = _stadium(cx, cy, straight, outerR);
    canvas.drawPath(
      trackPath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFD2A972), Color(0xFFB98B55), Color(0xFFA77A47)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
    // 跑道分隔線（淡白）+ 每條跑道中間再畫一條更淡的耙痕
    final laneLine = Paint()
      ..color = Colors.white.withValues(alpha: 0.38)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rake = Paint()
      ..color = Colors.brown.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (var i = 0; i <= lanes; i++) {
      canvas.drawPath(_stadium(cx, cy, straight, outerR - i * laneW), laneLine);
      if (i < lanes) canvas.drawPath(_stadium(cx, cy, straight, outerR - (i + 0.5) * laneW), rake);
    }

    // 4) 內場草坪：用同心圈畫出割草條紋，再加內欄
    final infieldR = math.max(inner, 2.0);
    canvas.drawPath(_stadium(cx, cy, straight, infieldR), Paint()..color = const Color(0xFF2A7A47));
    for (var k = 0; k < 6; k++) {
      final rr = infieldR - k * (infieldR / 6.5);
      if (rr <= 1) break;
      canvas.drawPath(_stadium(cx, cy, straight, rr), Paint()..color = (k.isEven ? const Color(0x1AFFFFFF) : const Color(0x14000000)));
    }
    final innerRail = _stadium(cx, cy, straight, infieldR);
    canvas.drawPath(innerRail, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2.2);

    // 5) 1/4、1/2、3/4 圈距離標示（內欄邊上的小紅白標竿）
    for (final f in [0.25, 0.5, 0.75]) {
      final p = _pointOn(cx, cy, straight, infieldR - 4, f);
      canvas.drawCircle(p, 3.4, Paint()..color = Colors.white);
      canvas.drawCircle(p, 2.2, Paint()..color = const Color(0xFFD62828));
    }

    // 6) 起跑 / 終點線：黑白格子橫跨所有跑道
    final cell = 4.0;
    final y0 = cy + inner;
    final y1 = cy + outerR;
    var row = 0;
    for (var y = y0; y < y1; y += cell) {
      for (var col = 0; col < 2; col++) {
        final dark = (row + col).isEven;
        canvas.drawRect(Rect.fromLTWH(cx - cell + col * cell, y, cell, math.min(cell, y1 - y)), Paint()..color = dark ? Colors.black87 : Colors.white);
      }
      row++;
    }

    // 7) 馬：依前進比例沿著各自跑道的中線移動，朝著前進方向奔跑
    final horseSize = math.max(laneW * 3.3, 30.0);
    final placed = <(Offset, double, Horse, double, bool)>[];
    for (var i = 0; i < horses.length; i++) {
      final h = horses[i];
      final laneRadius = outerR - (i + 0.5) * laneW;
      var f = progress[h.no] ?? 0.0;
      final ft = finishTimes[h.no];
      var running = f > 0 && f < 1.0;
      var speed = 1.0;
      if (f >= 1.0 && ft != null) {
        final after = math.max(raceTime - ft, 0.0);
        f = 1.0 + 0.06 * (1 - math.exp(-after * 1.6));
        speed = math.exp(-after * 1.6);
        running = speed > 0.08;
      }
      final p = _pointOn(cx, cy, straight, laneRadius, f);
      final ahead = _pointOn(cx, cy, straight, laneRadius, f + 0.004);
      var heading = math.atan2(ahead.dy - p.dy, ahead.dx - p.dx);
      if (f <= 0) heading = 0;
      final phase = running ? raceTime * 15 * speed + h.no * 0.9 : 0.0;
      placed.add((p, heading, h, phase, running));
    }
    placed.sort((a, b) => a.$1.dy.compareTo(b.$1.dy));
    for (final (p, heading, h, phase, running) in placed) {
      drawHorseSprite(canvas, p, heading, horseSize, horseBodyColors[(h.no - 1) % horseBodyColors.length], h.color, phase, running);
      final badgeC = p + Offset(0, -horseSize * 0.62);
      canvas.drawCircle(badgeC, 6.5, Paint()..color = Colors.white);
      canvas.drawCircle(badgeC, 5.3, Paint()..color = h.color);
      final tp = TextPainter(
        text: TextSpan(text: '${h.no}', style: const TextStyle(color: Colors.black87, fontSize: 8, fontWeight: FontWeight.bold)),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, badgeC - Offset(tp.width / 2, tp.height / 2));
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
    if (d <= half) return Offset(cx + d, cy + r);
    d -= half;
    final arc = math.pi * r;
    if (d <= arc) {
      final theta = math.pi / 2 - d / r;
      return Offset(cx + half + r * math.cos(theta), cy + r * math.sin(theta));
    }
    d -= arc;
    if (d <= straight) return Offset(cx + half - d, cy - r);
    d -= straight;
    if (d <= arc) {
      final theta = -math.pi / 2 - d / r;
      return Offset(cx - half + r * math.cos(theta), cy + r * math.sin(theta));
    }
    d -= arc;
    return Offset(cx - half + d, cy + r);
  }

  @override
  bool shouldRepaint(covariant _TrackPainter old) => true;
}

// 每匹馬的毛色（自然的馬色），騎師的賽衣顏色才是這匹馬的代表色，方便辨認
const horseBodyColors = [
  Color(0xFF8B4A24), // 栗色
  Color(0xFF2E2E33), // 黑
  Color(0xFFEDE6DA), // 白
  Color(0xFFA9622D), // 棗色
  Color(0xFF8F9296), // 灰
  Color(0xFFD7A24B), // 淡金
];

// 畫一匹側面的馬（朝右、腳朝下），再依 heading 旋轉到前進方向。size = 馬的全長（像素）。
// 座標用「以馬身中心為原點、全長 = 1」的單位，所以線條粗細也會跟著放大縮小。
void drawHorseSprite(Canvas canvas, Offset center, double heading, double size, Color body, Color silk, double phase, bool running) {
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(heading);
  canvas.scale(size, size);

  final dark = Color.lerp(body, Colors.black, 0.5)!;
  final fill = Paint()..color = body;
  Paint stroke(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  // 地面陰影
  canvas.drawOval(Rect.fromCenter(center: const Offset(0, 0.30), width: 0.78, height: 0.1), Paint()..color = Colors.black26);

  // 尾巴：從臀部往後甩，奔跑時上下擺動
  final tailSwing = running ? math.sin(phase * 1.3) * 0.05 : 0.0;
  canvas.drawPath(
    Path()
      ..moveTo(-0.31, -0.07)
      ..quadraticBezierTo(-0.52, -0.08 + tailSwing, -0.55, 0.14 + tailSwing),
    stroke(dark, 0.07),
  );

  // 四條腿：奔跑時前腿與後腿反向擺動（大腿 + 小腿兩節）
  void leg(double x, double ph, Color color) {
    final a = running ? math.sin(ph) * 0.75 : 0.0;
    final hip = Offset(x, 0.09);
    final knee = hip + Offset(math.sin(a) * 0.15, math.cos(a) * 0.14);
    final bend = running ? math.sin(ph - 0.9) * 0.55 : 0.0;
    final foot = knee + Offset(math.sin(a - bend) * 0.15 - 0.03, math.cos(a - bend) * 0.15);
    canvas.drawPath(
      Path()
        ..moveTo(hip.dx, hip.dy)
        ..lineTo(knee.dx, knee.dy)
        ..lineTo(foot.dx, foot.dy),
      stroke(color, 0.065),
    );
  }

  leg(-0.2, phase + math.pi, dark); // 遠側的後腿
  leg(0.16, phase + 0.5, dark); // 遠側的前腿
  leg(-0.14, phase + math.pi + 0.55, dark.withValues(alpha: 1.0));
  leg(0.22, phase, dark.withValues(alpha: 1.0));

  // 身體
  canvas.drawOval(Rect.fromCenter(center: const Offset(0, 0), width: 0.68, height: 0.34), fill);
  // 脖子 + 頭
  canvas.drawPath(
    Path()
      ..moveTo(0.18, -0.12)
      ..lineTo(0.33, -0.37)
      ..lineTo(0.44, -0.31)
      ..lineTo(0.32, 0.0)
      ..close(),
    fill,
  );
  canvas.save();
  canvas.translate(0.49, -0.33);
  canvas.rotate(0.55);
  canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 0.27, height: 0.12), fill);
  canvas.restore();
  // 耳朵
  canvas.drawPath(
    Path()
      ..moveTo(0.38, -0.40)
      ..lineTo(0.40, -0.49)
      ..lineTo(0.44, -0.39)
      ..close(),
    Paint()..color = dark,
  );
  // 鬃毛
  canvas.drawPath(
    Path()
      ..moveTo(0.20, -0.14)
      ..quadraticBezierTo(0.22, -0.30, 0.33, -0.40),
    stroke(dark, 0.06),
  );

  // 騎師：賽衣顏色 = 這匹馬的代表色；馬背上有一塊同色馬衣
  canvas.drawRRect(
    RRect.fromRectAndRadius(Rect.fromLTWH(-0.08, -0.17, 0.2, 0.15), const Radius.circular(0.03)),
    Paint()..color = silk,
  );
  final lean = running ? 0.02 : 0.0; // 奔跑時身體前傾
  canvas.drawPath(
    Path()
      ..moveTo(-0.01, -0.15)
      ..lineTo(0.08 + lean, -0.30),
    stroke(silk, 0.1),
  );
  canvas.drawCircle(Offset(0.11 + lean, -0.35), 0.055, Paint()..color = const Color(0xFFF2C9A0)); // 臉
  canvas.drawArc(Rect.fromCircle(center: Offset(0.11 + lean, -0.35), radius: 0.06), math.pi, math.pi, true, Paint()..color = silk); // 帽子
  // 韁繩
  canvas.drawLine(Offset(0.13 + lean, -0.30), const Offset(0.44, -0.30), stroke(Colors.black54, 0.012));

  canvas.restore();
}


