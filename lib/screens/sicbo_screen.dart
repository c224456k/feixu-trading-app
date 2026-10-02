import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';

final _money = NumberFormat('#,##0');

// 網頁版骰寶（六人座位制）：桌上 6 個位置，先入座才能下注；桌子平時閒置，
// 有人下注才開始 30 秒倒數、開骰、結算。每局有下注的人，輸贏會公告到 Discord。
// 骰子點數、輸贏、派彩、座位歸屬全部由伺服器決定，這個畫面只負責「顯示」跟「送出動作」，
// 骰子翻滾只是演出動畫，沒辦法影響結果。
class SicBoScreen extends StatefulWidget {
  const SicBoScreen({super.key});

  @override
  State<SicBoScreen> createState() => _SicBoScreenState();
}

class _SicBoScreenState extends State<SicBoScreen> with SingleTickerProviderStateMixin {
  static const _chips = [1000, 10000, 50000, 100000, 500000];
  static const _rollDuration = Duration(milliseconds: 2200);

  final _api = ApiClient();

  SicBoState? _state;
  DateTime _fetchedAt = DateTime.now();
  String? _error;
  bool _busy = false;
  int _chip = 10000;

  late final AnimationController _roll;
  int? _animatedRoundId; // 已經演過（或跳過）開骰動畫的那一局，避免同一局重複播
  double _displayCash = 0; // 開骰動畫還沒演完前先不更新現金，不然會提前劇透輸贏

  Timer? _pollTimer;
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _roll = AnimationController(vsync: this, duration: _rollDuration)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted && _state != null) {
          setState(() => _displayCash = _state!.cash);
        }
      });
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _load());
    // 讓倒數數字平順地每 0.1 秒更新一次（資料每秒才抓一次，中間靠本機計時補）
    _tickTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tickTimer?.cancel();
    _roll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await _api.fetchSicBoState();
      if (!mounted) return;
      _fetchedAt = DateTime.now();
      switch (s.phase) {
        case SicBoPhase.idle:
        case SicBoPhase.open:
          _roll.value = 0;
          _displayCash = s.cash;
          _animatedRoundId = null;
        case SicBoPhase.settled:
          if (_animatedRoundId != s.roundId) {
            _animatedRoundId = s.roundId;
            if (s.secondsSinceSettled < 3) {
              // 剛開骰：播翻滾動畫（期間現金維持舊值，演完才更新）
              _roll.forward(from: 0);
            } else {
              // 玩家是在開骰很久之後才進來，直接顯示結果，不演動畫
              _roll.value = 1;
              _displayCash = s.cash;
            }
          } else if (_roll.isCompleted) {
            _displayCash = s.cash;
          }
      }
      setState(() {
        _state = s;
        _error = null;
      });
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

  bool get _animDone => _state != null && _state!.isSettled && _roll.isCompleted;

  Future<void> _sit(int seat) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await _api.sitSicBo(seat);
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
      await _api.leaveSicBo();
      await _load();
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bet(SicBoBetType type) async {
    final s = _state;
    if (s == null || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await _api.placeSicBoBet(type.key, _chip);
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
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  bool _wins(String key, SicBoState s) {
    if (s.triple) return key == 'triple';
    switch (key) {
      case 'big':
        return s.total >= 11 && s.total <= 17;
      case 'small':
        return s.total >= 4 && s.total <= 10;
      case 'odd':
        return s.total % 2 == 1;
      case 'even':
        return s.total % 2 == 0;
      default:
        return false;
    }
  }

  Color _typeColor(String key) {
    switch (key) {
      case 'big':
        return const Color(0xFFE74C3C);
      case 'small':
        return const Color(0xFF3498DB);
      case 'odd':
        return const Color(0xFFE67E22);
      case 'even':
        return const Color(0xFF1ABC9C);
      default:
        return const Color(0xFFF1C40F);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Scaffold(
      appBar: AppBar(title: const Text('骰寶')),
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
                      _table(s),
                      const SizedBox(height: 8),
                      _seatHint(s),
                      const SizedBox(height: 12),
                      _chipRow(),
                      const SizedBox(height: 12),
                      _betGrid(s),
                      const SizedBox(height: 16),
                      _history(s),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '規則跟 Discord 版骰寶一樣：大（11~17）/ 小（4~10）/ 單 / 雙 1 賠 1，豹子 1 賠 30；'
                        '開出豹子時大小單雙全部通殺。每局最多下注 ${_money.format(s.maxBetPerRound)} 元。'
                        '有人下注才會開局，結果會公告到 Discord。',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _cashRow(SicBoState s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('現金 ${_money.format(_displayCash)} 元', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        if (s.roundId != null) Text('第 ${s.roundId} 局', style: const TextStyle(color: Colors.white54)),
      ],
    );
  }

  // ===== 賭桌：六個座位圍著中間的骰子 =====

  static const _seatAlignments = [
    Alignment(-0.62, -1),
    Alignment(0.62, -1),
    Alignment(-1, 0),
    Alignment(1, 0),
    Alignment(-0.62, 1),
    Alignment(0.62, 1),
  ];

  Widget _table(SicBoState s) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final h = math.max(360.0, w * 0.95);
      final centerW = w - 2 * 84;
      final dieSize = math.min(64.0, (centerW - 24) / 3);
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const RadialGradient(
            radius: 0.95,
            colors: [Color(0xFF0E7A4B), Color(0xFF07402A)],
          ),
          border: Border.all(color: const Color(0xFF8B6B2E), width: 3),
        ),
        child: Stack(
          children: [
            Align(alignment: Alignment.center, child: _tableCenter(s, dieSize)),
            for (var i = 0; i < _seatAlignments.length && i < s.seats.length; i++)
              Align(alignment: _seatAlignments[i], child: _seatWidget(s, s.seats[i])),
          ],
        ),
      );
    });
  }

  Widget _tableCenter(SicBoState s, double dieSize) {
    final remaining = _remaining;
    String status;
    if (s.isIdle) {
      status = '等待下注';
    } else if (s.isOpen) {
      status = remaining > 0 ? '下注中' : '開骰中…';
    } else {
      status = _animDone ? '本局結果' : '開骰！';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(status, style: const TextStyle(color: Colors.white70, fontSize: 13, letterSpacing: 2)),
        const SizedBox(height: 6),
        if (s.isOpen) _countdown(s, remaining),
        if (s.isOpen) const SizedBox(height: 6),
        AnimatedBuilder(animation: _roll, builder: (context, _) => _diceRow(s, dieSize)),
        const SizedBox(height: 8),
        if (s.isIdle)
          const Text('入座後，第一筆下注\n就會開始 30 秒倒數', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
        if (s.isSettled && _animDone) _resultBanner(s),
        if (s.isSettled && _animDone)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${s.revealSecondsLeft.ceil().clamp(0, 99)} 秒後可開下一局',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _seatWidget(SicBoState s, SicBoSeat seat) {
    const avatar = 48.0;
    final mine = seat.isMe;
    final border = mine ? const Color(0xFFF1C40F) : Colors.white30;

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
          border: Border.all(color: border, width: mine ? 3 : 1.5),
        ),
        child: Text(
          name.characters.first,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      );
      label = mine ? '$name（我）' : name;
    }

    // 座位下方的小標籤：下注中顯示押了多少；開骰演完後顯示這局輸贏
    Widget? badge;
    if (!seat.isEmpty && seat.bet > 0) {
      if (s.isSettled && _animDone && seat.payout != null) {
        final net = seat.payout! - seat.bet;
        final color = net > 0 ? const Color(0xFF2ECC71) : (net == 0 ? Colors.white70 : Colors.redAccent);
        badge = Text(
          net > 0 ? '+${_money.format(net)}' : (net == 0 ? '平手' : '-${_money.format(-net)}'),
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
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              circle,
              const SizedBox(height: 4),
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

  Widget _seatHint(SicBoState s) {
    if (s.mySeat == null) {
      return const Text('👆 點一個空位入座，才能下注', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFF1C40F)));
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '你坐在 ${s.mySeat! + 1} 號位　',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        TextButton(onPressed: _busy ? null : _leave, child: const Text('離座')),
        Text(
          '（${s.idleTimeoutSeconds ~/ 60} 分鐘沒下注會自動離座）',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
    );
  }

  Widget _countdown(SicBoState s, double remaining) {
    final ratio = (remaining / s.betSeconds).clamp(0.0, 1.0);
    final urgent = remaining <= 5;
    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 52,
            height: 52,
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

  Widget _diceRow(SicBoState s, double size) {
    final t = _roll.value;
    final showFinal = s.isSettled && s.dice.length == 3;
    final rolling = showFinal && t < 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        int value;
        double angle = 0;
        double dy = 0;
        if (!showFinal) {
          value = 0; // 還沒開骰：顯示「？」
        } else if (rolling) {
          final eased = Curves.easeOut.transform(t);
          if (t < 0.8) {
            value = 1 + (((t * 22).floor() * (i + 3)) + i * 2) % 6; // 翻滾期間快速閃爍的點數
          } else {
            value = s.dice[i];
          }
          angle = (1 - eased) * (i.isEven ? 1 : -1) * 4 * math.pi;
          dy = -(math.sin(t * math.pi * 4)).abs() * 28 * (1 - t);
        } else {
          value = s.dice[i];
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.rotate(angle: angle, child: SicBoDie(value: value, size: size)),
          ),
        );
      }),
    );
  }

  Widget _resultBanner(SicBoState s) {
    final tags = <String>[];
    if (s.triple) {
      tags.add('豹子！通殺');
    } else {
      tags.add(s.total >= 11 ? '大' : '小');
      tags.add(s.total % 2 == 1 ? '單' : '雙');
    }
    final bet = s.myTotalBet;
    final net = s.myTotalPayout - bet;
    return Column(
      children: [
        Text(
          '${s.total}　${tags.join(' · ')}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        if (bet > 0)
          Text(
            net > 0 ? '🎉 你贏了 +${_money.format(net)}' : (net == 0 ? '平手' : '你輸了 ${_money.format(-net)}'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: net > 0 ? const Color(0xFF2ECC71) : (net == 0 ? Colors.white70 : Colors.redAccent),
            ),
          ),
      ],
    );
  }

  Widget _chipRow() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: _chips.map((c) {
        return ChoiceChip(
          label: Text(_money.format(c)),
          selected: c == _chip,
          onSelected: (_) => setState(() => _chip = c),
        );
      }).toList(),
    );
  }

  Widget _betGrid(SicBoState s) {
    final seated = s.mySeat != null;
    // 閒置時下注 = 開新局；倒數中下注 = 加注；開骰演出中不能下
    final canBet = seated && !_busy && (s.isIdle || (s.isOpen && _remaining > 0));
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 480 ? 3 : 2;
      final w = (c.maxWidth - 10 * (cols - 1)) / cols;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: s.betTypes.map((t) {
          final mine = s.myBets[t.key] ?? 0;
          final win = _animDone && _wins(t.key, s);
          final color = _typeColor(t.key);
          return SizedBox(
            width: w,
            child: Material(
              color: color.withValues(alpha: canBet || win ? 0.22 : 0.08),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: canBet ? () => _bet(t) : null,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: win ? const Color(0xFFF1C40F) : color.withValues(alpha: canBet ? 0.6 : 0.3),
                      width: win ? 3 : 1.5,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(t.shortName, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
                      Text('1 賠 ${t.payout}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                      const SizedBox(height: 6),
                      Text(
                        '全場 ${_money.format(s.poolAmount[t.key] ?? 0)}（${s.poolPlayers[t.key] ?? 0} 人）',
                        style: const TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        mine > 0
                            ? '我押 ${_money.format(mine)}'
                            : (canBet ? '點一下押 ${_money.format(_chip)}' : (seated ? '—' : '請先入座')),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: mine > 0 ? FontWeight.bold : FontWeight.normal,
                          color: mine > 0 ? Colors.white : Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      );
    });
  }

  Widget _history(SicBoState s) {
    if (s.history.isEmpty) return const SizedBox.shrink();
    // 還在演開骰動畫時，最新那局先藏起來，不要提早劇透
    final hideLatest = s.isSettled && !_roll.isCompleted;
    final items = hideLatest ? s.history.skip(1).toList() : s.history;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('近期開獎', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: items.map((h) {
            final color = h.triple
                ? const Color(0xFFF1C40F)
                : (h.total >= 11 ? const Color(0xFFE74C3C) : const Color(0xFF3498DB));
            return Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1.5),
              ),
              child: Text(
                h.triple ? '豹' : '${h.total}',
                style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: h.triple ? 15 : 14),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// 一顆骰子：白色圓角方塊 + 黑色點數。value = 0 代表「還沒開」，畫一個「？」。
class SicBoDie extends StatelessWidget {
  final int value;
  final double size;

  const SicBoDie({super.key, required this.value, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(size * 0.18),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 4))],
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFDADADA)],
        ),
      ),
      child: value == 0
          ? Center(
              child: Text('?', style: TextStyle(fontSize: size * 0.6, fontWeight: FontWeight.bold, color: Colors.black38)),
            )
          : CustomPaint(painter: _PipPainter(value)),
    );
  }
}

class _PipPainter extends CustomPainter {
  final int value;

  _PipPainter(this.value);

  // 點數在 3x3 格子上的位置（0~2, 0~2）
  static const _layout = {
    1: [(1, 1)],
    2: [(0, 0), (2, 2)],
    3: [(0, 0), (1, 1), (2, 2)],
    4: [(0, 0), (2, 0), (0, 2), (2, 2)],
    5: [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)],
    6: [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)],
  };

  @override
  void paint(Canvas canvas, Size size) {
    final pad = size.width * 0.22;
    final step = (size.width - pad * 2) / 2;
    final r = size.width * 0.085 + (value == 1 ? size.width * 0.04 : 0);
    // 一點是紅色，其他是黑色（跟實體骰子一樣）
    final paint = Paint()..color = value == 1 ? const Color(0xFFD62828) : const Color(0xFF1B1B1B);
    for (final (cx, cy) in _layout[value] ?? const <(int, int)>[]) {
      canvas.drawCircle(Offset(pad + cx * step, pad + cy * step), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PipPainter old) => old.value != value;
}
