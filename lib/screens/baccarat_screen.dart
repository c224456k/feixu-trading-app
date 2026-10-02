import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';

final _money = NumberFormat('#,##0');

// 網頁版百家樂（六人座位制）：機制跟骰寶一樣——先入座才能下注、有人下注才開局、
// 有下注的局結果會公告到 Discord。牌局（洗牌、發牌、補牌、輸贏、派彩）全部由伺服器決定，
// 這個畫面只負責「顯示」跟「送出動作」，發牌動畫只是演出，不影響結果。
class BaccaratScreen extends StatefulWidget {
  const BaccaratScreen({super.key});

  @override
  State<BaccaratScreen> createState() => _BaccaratScreenState();
}

class _BaccaratScreenState extends State<BaccaratScreen> {
  static const _chips = [1000, 10000, 50000, 100000, 500000];
  static const _firstCardDelay = 0.4; // 開牌後多久翻第一張（秒）
  static const _cardInterval = 1.2; // 每張牌之間的間隔（秒）

  final _api = ApiClient();

  BaccaratState? _state;
  DateTime _fetchedAt = DateTime.now();
  String? _error;
  bool _busy = false;
  int _chip = 10000;

  double _displayCash = 0; // 發牌動畫沒演完前先不更新現金，避免提前劇透輸贏

  Timer? _pollTimer;
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _load());
    _tickTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
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
      final s = await _api.fetchBaccaratState();
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

  // 開牌後經過幾秒（用伺服器給的秒數 + 本機計時），發牌動畫全靠這個推算要顯示幾張牌，
  // 所以玩家中途才進來也會看到正確的進度，不會重演也不會劇透。
  double get _since {
    final s = _state;
    if (s == null || !s.isSettled) return 0;
    return s.secondsSinceSettled + DateTime.now().difference(_fetchedAt).inMilliseconds / 1000.0;
  }

  // 發牌順序：閒1、莊1、閒2、莊2，然後（如果有）閒補牌、莊補牌
  List<(bool isPlayer, int index)> _dealOrder(BaccaratState s) {
    final order = <(bool, int)>[(true, 0), (false, 0), (true, 1), (false, 1)];
    if (s.playerCards.length > 2) order.add((true, 2));
    if (s.bankerCards.length > 2) order.add((false, 2));
    return order;
  }

  int _visibleCount(BaccaratState s) {
    final n = _dealOrder(s).length;
    final t = _since;
    if (t < _firstCardDelay) return 0;
    return math.min(n, ((t - _firstCardDelay) / _cardInterval).floor() + 1);
  }

  bool get _animDone {
    final s = _state;
    if (s == null || !s.isSettled) return false;
    return _since >= _firstCardDelay + _cardInterval * _dealOrder(s).length + 0.5;
  }

  Future<void> _sit(int seat) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await _api.sitBaccarat(seat);
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
      await _api.leaveBaccarat();
      await _load();
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bet(BaccaratBetType type) async {
    if (_state == null || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await _api.placeBaccaratBet(type.key, _chip);
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

  bool _wins(String key, BaccaratState s) {
    switch (key) {
      case 'player':
        return s.result == 'player';
      case 'banker':
        return s.result == 'banker';
      case 'tie':
        return s.result == 'tie';
      case 'player_pair':
        return s.playerPair;
      case 'banker_pair':
        return s.bankerPair;
      default:
        return false;
    }
  }

  Color _typeColor(String key) {
    switch (key) {
      case 'player':
        return const Color(0xFF3498DB);
      case 'banker':
        return const Color(0xFFE74C3C);
      case 'tie':
        return const Color(0xFF2ECC71);
      case 'player_pair':
        return const Color(0xFF7FB3E6);
      default:
        return const Color(0xFFE88A82);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Scaffold(
      appBar: AppBar(title: const Text('百家樂')),
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
                        '標準百家樂（8 副牌）：閒 1 賠 1、莊 1 賠 0.95（抽 5% 水）、和 1 賠 8、閒對 / 莊對 1 賠 11；'
                        '開和局時押閒、押莊的本金退回。每局最多下注 ${_money.format(s.maxBetPerRound)} 元。'
                        '有人下注才會發牌，結果會公告到 Discord。',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _cashRow(BaccaratState s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('現金 ${_money.format(_displayCash)} 元', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        if (s.roundId != null) Text('第 ${s.roundId} 局', style: const TextStyle(color: Colors.white54)),
      ],
    );
  }

  static const _seatAlignments = [
    Alignment(-0.62, -1),
    Alignment(0.62, -1),
    Alignment(-1, 0),
    Alignment(1, 0),
    Alignment(-0.62, 1),
    Alignment(0.62, 1),
  ];

  Widget _table(BaccaratState s) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final h = math.max(420.0, w * 1.08);
      final centerW = w - 2 * 84;
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const RadialGradient(radius: 0.95, colors: [Color(0xFF0E7A4B), Color(0xFF07402A)]),
          border: Border.all(color: const Color(0xFF8B6B2E), width: 3),
        ),
        child: Stack(
          children: [
            Align(alignment: Alignment.center, child: _tableCenter(s, centerW)),
            for (var i = 0; i < _seatAlignments.length && i < s.seats.length; i++)
              Align(alignment: _seatAlignments[i], child: _seatWidget(s, s.seats[i])),
          ],
        ),
      );
    });
  }

  Widget _tableCenter(BaccaratState s, double width) {
    final remaining = _remaining;
    String status;
    if (s.isIdle) {
      status = '等待下注';
    } else if (s.isOpen) {
      status = remaining > 0 ? '下注中' : '發牌中…';
    } else {
      status = _animDone ? '本局結果' : '開牌！';
    }
    final visible = s.isSettled ? _visibleCount(s) : 0;
    final order = s.isSettled ? _dealOrder(s) : const <(bool, int)>[];
    bool shown(bool isPlayer, int index) {
      final pos = order.indexOf((isPlayer, index));
      return pos != -1 && pos < visible;
    }

    // 目前已翻開的牌算出來的點數，隨發牌動畫一起增加（動畫演完就等於最終點數）
    int partial(List<PlayingCard> cards, bool isPlayer) {
      var sum = 0;
      for (var i = 0; i < cards.length; i++) {
        if (shown(isPlayer, i)) sum += cards[i].rank >= 10 ? 0 : cards[i].rank;
      }
      return sum % 10;
    }

    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(status, style: const TextStyle(color: Colors.white70, fontSize: 13, letterSpacing: 2)),
          const SizedBox(height: 4),
          if (s.isOpen) _countdown(s, remaining),
          if (s.isIdle)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text(
                '入座後，第一筆下注\n就會開始 30 秒倒數並發牌',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          if (s.isSettled) ...[
            _handRow('閒', const Color(0xFF7FB3E6), s.playerCards, true, shown, partial(s.playerCards, true), width,
                highlight: _animDone && s.result == 'player'),
            const SizedBox(height: 6),
            _handRow('莊', const Color(0xFFE88A82), s.bankerCards, false, shown, partial(s.bankerCards, false), width,
                highlight: _animDone && s.result == 'banker'),
            const SizedBox(height: 6),
            if (_animDone) _resultBanner(s),
            if (_animDone)
              Text(
                '${s.revealSecondsLeft.ceil().clamp(0, 99)} 秒後可開下一局',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
          ],
        ],
      ),
    );
  }

  Widget _handRow(String label, Color color, List<PlayingCard> cards, bool isPlayer, bool Function(bool, int) shown,
      int total, double width,
      {required bool highlight}) {
    final anyShown = List.generate(cards.length, (i) => shown(isPlayer, i)).any((e) => e);
    final cardW = math.min(36.0, (width - 70) / 3 - 4);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: highlight ? const Color(0xFFF1C40F) : Colors.transparent, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
                Text(anyShown ? '$total' : '', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          for (var i = 0; i < cards.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _CardSlot(card: cards[i], visible: shown(isPlayer, i), width: cardW),
            ),
        ],
      ),
    );
  }

  Widget _resultBanner(BaccaratState s) {
    final text = switch (s.result) {
      'player' => '閒贏',
      'banker' => '莊贏',
      _ => '和局',
    };
    final extra = [if (s.playerPair) '閒對', if (s.bankerPair) '莊對'];
    final bet = s.myTotalBet;
    final net = s.myTotalPayout - bet;
    return Column(
      children: [
        Text(
          '$text　${s.playerTotal} : ${s.bankerTotal}${extra.isEmpty ? '' : '　${extra.join('·')}'}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        if (bet > 0)
          Text(
            net > 0.005 ? '🎉 你贏了 +${_money.format(net)}' : (net > -0.005 ? '平手' : '你輸了 ${_money.format(-net)}'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: net > 0.005 ? const Color(0xFF2ECC71) : (net > -0.005 ? Colors.white70 : Colors.redAccent),
            ),
          ),
      ],
    );
  }

  Widget _seatWidget(BaccaratState s, SicBoSeat seat) {
    const avatar = 48.0;
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
        child: Text(name.characters.first, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
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

  Widget _seatHint(BaccaratState s) {
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

  Widget _countdown(BaccaratState s, double remaining) {
    final ratio = (remaining / s.betSeconds).clamp(0.0, 1.0);
    final urgent = remaining <= 5;
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(
              value: ratio,
              strokeWidth: 5,
              backgroundColor: Colors.white12,
              color: urgent ? Colors.redAccent : const Color(0xFFF1C40F),
            ),
          ),
          Text(
            remaining.ceil().toString(),
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: urgent ? Colors.redAccent : Colors.white),
          ),
        ],
      ),
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

  Widget _betGrid(BaccaratState s) {
    final seated = s.mySeat != null;
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
                      Text(t.payout, style: const TextStyle(fontSize: 12, color: Colors.white70)),
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

  Widget _history(BaccaratState s) {
    if (s.history.isEmpty) return const SizedBox.shrink();
    // 發牌動畫還沒演完時，最新那局先藏起來，不要提早劇透
    final hideLatest = s.isSettled && !_animDone;
    final items = hideLatest ? s.history.skip(1).toList() : s.history;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('近期開牌（新 → 舊）', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: items.map((h) {
            final (text, color) = switch (h.result) {
              'player' => ('閒', const Color(0xFF3498DB)),
              'banker' => ('莊', const Color(0xFFE74C3C)),
              _ => ('和', const Color(0xFF2ECC71)),
            };
            return Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 1.5),
              ),
              child: Text(text, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 14)),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// 一張牌的位置：還沒翻開時只佔位（顯示牌背），翻開時以淡入 + 放大的動畫出現。
class _CardSlot extends StatelessWidget {
  final PlayingCard card;
  final bool visible;
  final double width;

  const _CardSlot({required this.card, required this.visible, required this.width});

  @override
  Widget build(BuildContext context) {
    final height = width * 1.4;
    return SizedBox(
      width: width,
      height: height,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        transitionBuilder: (child, anim) => ScaleTransition(
          scale: Tween<double>(begin: 0.6, end: 1).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutBack)),
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: visible
            ? PlayingCardFace(key: const ValueKey('face'), card: card, width: width)
            : _CardBack(key: const ValueKey('back'), width: width),
      ),
    );
  }
}

class _CardBack extends StatelessWidget {
  final double width;

  const _CardBack({super.key, required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: width * 1.4,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(width * 0.12),
        color: const Color(0xFF1F3A93),
        border: Border.all(color: Colors.white, width: 1.5),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2C4DB8), Color(0xFF1B2F7A)],
        ),
      ),
      child: Center(child: Icon(Icons.diamond_outlined, color: Colors.white38, size: width * 0.5)),
    );
  }
}

// 一張撲克牌的正面：白底、左上角點數、中央大花色，紅心/方塊紅色、黑桃/梅花黑色。
class PlayingCardFace extends StatelessWidget {
  final PlayingCard card;
  final double width;

  const PlayingCardFace({super.key, required this.card, required this.width});

  static const _suits = ['♠', '♥', '♦', '♣'];

  static String rankLabel(int rank) {
    switch (rank) {
      case 1:
        return 'A';
      case 11:
        return 'J';
      case 12:
        return 'Q';
      case 13:
        return 'K';
      default:
        return '$rank';
    }
  }

  @override
  Widget build(BuildContext context) {
    final red = card.suit == 1 || card.suit == 2;
    final color = red ? const Color(0xFFD62828) : const Color(0xFF1B1B1B);
    return Container(
      width: width,
      height: width * 1.4,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(width * 0.12),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: Stack(
        children: [
          Positioned(
            left: width * 0.1,
            top: width * 0.04,
            child: Text(
              rankLabel(card.rank),
              style: TextStyle(fontSize: width * 0.42, fontWeight: FontWeight.bold, color: color, height: 1.0),
            ),
          ),
          Center(
            child: Padding(
              padding: EdgeInsets.only(top: width * 0.22),
              child: Text(_suits[card.suit], style: TextStyle(fontSize: width * 0.62, color: color, height: 1.0)),
            ),
          ),
        ],
      ),
    );
  }
}
