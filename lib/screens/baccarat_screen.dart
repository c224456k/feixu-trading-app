import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/casino_music.dart';

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
  static const _firstCardDelay = 0.8; // 開牌後多久翻第一張（秒）
  static const _cardInterval = 2.2; // 每張牌之間的間隔（秒）：放慢，讓大家看清楚每一張

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
    CasinoMusic.instance.enter();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _load());
    _tickTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
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
    return _since >= _firstCardDelay + _cardInterval * _dealOrder(s).length + 0.8;
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
      if (r.ok) CasinoMusic.instance.playSfx('chipdrop');
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
      appBar: AppBar(title: const Text('百家樂'), actions: const [MusicButton()]),
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
                      const SizedBox(height: 12),
                      _seats(s),
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
        TweenAnimationBuilder<double>(
          tween: Tween(end: _displayCash),
          duration: const Duration(milliseconds: 1200),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => Text('💰 現金 ${_money.format(v)} 元', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        if (s.roundId != null) Text('第 ${s.roundId} 局', style: const TextStyle(color: Colors.white54)),
      ],
    );
  }

  // 桌面只放牌、倒數與結果；座位在桌子下面一排
  Widget _table(BaccaratState s) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const RadialGradient(radius: 0.95, colors: [Color(0xFF0E7A4B), Color(0xFF07402A)]),
          border: Border.all(color: const Color(0xFF8B6B2E), width: 3),
        ),
        child: _tableCenter(s, w - 24 - 6), // 扣掉桌子內距與金色邊框
      );
    });
  }

  Widget _seats(BaccaratState s) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: s.seats.map((seat) => _seatWidget(s, seat)).toList(),
    );
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
          Text(status, style: const TextStyle(color: Colors.white70, fontSize: 14, letterSpacing: 2)),
          const SizedBox(height: 8),
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
            const SizedBox(height: 12),
            _handRow('莊', const Color(0xFFE88A82), s.bankerCards, false, shown, partial(s.bankerCards, false), width,
                highlight: _animDone && s.result == 'banker'),
            const SizedBox(height: 12),
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
    // 每手牌固定預留 3 張牌的位置（第 3 張是補牌，沒補就是空位），這樣版面不會跳動，
    // 而且發牌前也看不出「這手會不會補牌」，不會劇透。
    const labelW = 44.0;
    const gap = 8.0;
    final cardW = math.min(80.0, (width - 16 - 6 - labelW - gap * 3) / 3); // 16 = 左右內距，6 = 高亮時的邊框
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: highlight ? const Color(0x33F1C40F) : Colors.transparent,
        border: Border.all(color: highlight ? const Color(0xFFF1C40F) : Colors.white12, width: highlight ? 3 : 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: labelW,
            child: Column(
              children: [
                Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 24)),
                Text(anyShown ? '$total' : '', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(left: gap),
              child: (i < 2 || (i < cards.length && shown(isPlayer, i)))
                  ? _CardSlot(card: cards[i], visible: shown(isPlayer, i), width: cardW)
                  : SizedBox(width: cardW, height: cardW * 1.4),
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
    if (bet > 0 && net > 0.005) CasinoMusic.instance.playSfxOnce('bac-${s.roundId}', 'win');
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
      spacing: 6,
      runSpacing: 6,
      children: _chips.map((c) {
        final selected = c == _chip;
        return GestureDetector(
          onTap: () {
            CasinoMusic.instance.playSfx('chip');
            setState(() => _chip = c);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            transform: Matrix4.translationValues(0, selected ? -6 : 0, 0),
            child: CasinoChip(value: c, size: 52, glow: selected),
          ),
        );
      }).toList(),
    );
  }

  // 把金額拆成籌碼面額（由大到小），最多畫 6 顆疊起來
  List<int> _chipStack(double amount) {
    final out = <int>[];
    var left = amount.round();
    for (final v in _chips.reversed) {
      while (left >= v && out.length < 6) {
        out.add(v);
        left -= v;
      }
    }
    if (out.isEmpty && amount > 0) out.add(_chips.first);
    return out.reversed.toList(); // 大的在下面
  }

  Widget _betGrid(BaccaratState s) {
    final seated = s.mySeat != null;
    final canBet = seated && !_busy && (s.isIdle || (s.isOpen && _remaining > 0));
    BaccaratBetType? t(String k) {
      for (final b in s.betTypes) {
        if (b.key == k) return b;
      }
      return null;
    }

    Widget zone(String key, double height) {
      final bt = t(key);
      if (bt == null) return const SizedBox.shrink();
      return Expanded(child: _betZone(s, bt, height, canBet, seated));
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const RadialGradient(radius: 1.1, colors: [Color(0xFF0E7A4B), Color(0xFF06351F)]),
        border: Border.all(color: const Color(0xFF8B6B2E), width: 3),
      ),
      child: Column(
        children: [
          Row(children: [zone('player_pair', 92), const SizedBox(width: 8), zone('tie', 92), const SizedBox(width: 8), zone('banker_pair', 92)]),
          const SizedBox(height: 8),
          Row(children: [zone('player', 150), const SizedBox(width: 8), zone('banker', 150)]),
        ],
      ),
    );
  }

  Widget _betZone(BaccaratState s, BaccaratBetType t, double height, bool canBet, bool seated) {
    final color = _typeColor(t.key);
    final bet = s.myBets[t.key] ?? 0;
    final settled = s.isSettled && _animDone;
    final win = settled && _wins(t.key, s);
    final payout = s.myPayouts[t.key] ?? 0;
    final lost = settled && bet > 0 && payout <= 0.005;
    final pulse = win ? (0.5 + 0.5 * math.sin(DateTime.now().millisecondsSinceEpoch / 180.0)) : 0.0;
    // 結算後贏的區域，籌碼堆換成「派彩金額」那一疊，看起來像莊家把籌碼推過來
    final shownAmount = settled && payout > 0.005 ? payout : bet;
    final net = payout - bet;
    final bigZone = height > 120;

    return GestureDetector(
      onTap: canBet ? () => _bet(t) : null,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: color.withValues(alpha: canBet ? 0.20 : 0.10),
          border: Border.all(
            color: win ? Color.lerp(const Color(0xFFB8860B), const Color(0xFFFFE066), pulse)! : color.withValues(alpha: canBet ? 0.85 : 0.35),
            width: win ? 4 : 2,
          ),
          boxShadow: win ? [BoxShadow(color: const Color(0xFFF1C40F).withValues(alpha: 0.35 + 0.3 * pulse), blurRadius: 18, spreadRadius: 2)] : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Text(t.shortName, style: TextStyle(fontSize: bigZone ? 30 : 20, fontWeight: FontWeight.bold, color: color, letterSpacing: 2)),
                  Text(t.payout, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                ],
              ),
            ),
            if (shownAmount > 0)
              Positioned(
                bottom: bigZone ? 28 : 22,
                child: Opacity(
                  opacity: lost ? 0.35 : 1,
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey('${s.roundId}-${t.key}-${shownAmount.round()}-${win ? 1 : 0}'),
                    tween: Tween(begin: 0, end: 1),
                    duration: Duration(milliseconds: win ? 650 : 320),
                    curve: win ? Curves.elasticOut : Curves.bounceOut,
                    builder: (context, v, child) => Transform.translate(offset: Offset(0, -34 * (1 - v)), child: Opacity(opacity: v.clamp(0.0, 1.0), child: child)),
                    child: _chipPile(shownAmount, bigZone ? 38.0 : 30.0),
                  ),
                ),
              ),
            Positioned(
              bottom: 5,
              left: 4,
              right: 4,
              child: Text(
                settled && bet > 0
                    ? (net > 0.005 ? '+${_money.format(net)}' : (net > -0.005 ? '退回' : '-${_money.format(-net)}'))
                    : (bet > 0 ? '我押 ${_money.format(bet)}' : (canBet ? '押 ${_money.format(_chip)}' : (seated ? '' : '請先入座'))),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: settled && bet > 0 ? 14 : 11,
                  fontWeight: FontWeight.bold,
                  color: settled && bet > 0
                      ? (net > 0.005 ? const Color(0xFFFFE066) : (net > -0.005 ? Colors.white70 : Colors.redAccent))
                      : (bet > 0 ? Colors.white : Colors.white54),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 8,
              child: Text(
                '${s.poolPlayers[t.key] ?? 0}人',
                style: const TextStyle(fontSize: 10, color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chipPile(double amount, double size) {
    final stack = _chipStack(amount);
    const step = 5.0;
    return SizedBox(
      width: size,
      height: size * 0.5 + step * stack.length + 6,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          for (var i = 0; i < stack.length; i++)
            Positioned(bottom: i * step, child: CasinoChip(value: stack[i], size: size, flat: true)),
        ],
      ),
    );
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

// 一張牌的位置：還沒翻開時顯示牌背；翻開時做 3D 翻牌動畫（繞垂直軸轉 180 度，過半時換成正面）。
// 玩家中途才進來、牌已經翻開的話，直接顯示正面，不會重演動畫。
class _CardSlot extends StatefulWidget {
  final PlayingCard card;
  final bool visible;
  final double width;

  const _CardSlot({required this.card, required this.visible, required this.width});

  @override
  State<_CardSlot> createState() => _CardSlotState();
}

class _CardSlotState extends State<_CardSlot> with SingleTickerProviderStateMixin {
  late final AnimationController _flip;

  @override
  void initState() {
    super.initState();
    _flip = AnimationController(vsync: this, duration: const Duration(milliseconds: 700), value: widget.visible ? 1 : 0);
  }

  @override
  void didUpdateWidget(covariant _CardSlot old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible) {
      CasinoMusic.instance.playSfx('card');
      _flip.forward(from: 0);
    }
    if (!widget.visible && old.visible) _flip.value = 0;
  }

  @override
  void dispose() {
    _flip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    return SizedBox(
      width: w,
      height: w * 1.4,
      child: AnimatedBuilder(
        animation: _flip,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_flip.value);
          final angle = t * math.pi;
          final showFace = angle > math.pi / 2;
          // 翻到一半時稍微放大、浮起來，更有「翻牌」的感覺
          final pop = 1 + 0.12 * math.sin(t * math.pi);
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0014)
              ..scaleByDouble(pop, pop, 1.0, 1.0)
              ..rotateY(angle),
            child: showFace
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.rotationY(math.pi), // 正面要再翻回來，才不會左右顛倒
                    child: PlayingCardFace(card: widget.card, width: w),
                  )
                : _CardBack(width: w),
          );
        },
      ),
    );
  }
}

class _CardBack extends StatelessWidget {
  final double width;

  const _CardBack({required this.width});

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

// 一張撲克牌的正面：白底、左上與右下角（倒過來）各有點數與小花色，中央大花色；紅心/方塊紅色、黑桃/梅花黑色。
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

  Widget _corner(Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(rankLabel(card.rank), style: TextStyle(fontSize: width * 0.3, fontWeight: FontWeight.bold, color: color, height: 1.0)),
        Text(_suits[card.suit], style: TextStyle(fontSize: width * 0.26, color: color, height: 1.0)),
      ],
    );
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
        borderRadius: BorderRadius.circular(width * 0.1),
        border: Border.all(color: Colors.black12, width: 1),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 3))],
      ),
      child: Stack(
        children: [
          Positioned(left: width * 0.08, top: width * 0.06, child: _corner(color)),
          Positioned(right: width * 0.08, bottom: width * 0.06, child: Transform.rotate(angle: math.pi, child: _corner(color))),
          Center(child: Text(_suits[card.suit], style: TextStyle(fontSize: width * 0.6, color: color, height: 1.0))),
        ],
      ),
    );
  }
}


// 賭場籌碼：圓形、外圈白色缺口條紋、內圈細線、中間寫面額。flat = 疊在一起時用（不加大陰影）。
class CasinoChip extends StatelessWidget {
  final int value;
  final double size;
  final bool glow;
  final bool flat;
  final Color? color; // 指定的話就不用面額換顏色（德州撲克用）
  final String? text;

  const CasinoChip({super.key, required this.value, required this.size, this.glow = false, this.flat = false, this.color, this.text});

  static Color colorFor(int v) {
    if (v >= 500000) return const Color(0xFF7B1FA2);
    if (v >= 100000) return const Color(0xFF212121);
    if (v >= 50000) return const Color(0xFF2E7D32);
    if (v >= 10000) return const Color(0xFFC62828);
    if (v >= 5000) return const Color(0xFF1565C0);
    if (v >= 1000) return const Color(0xFF546E7A);
    return const Color(0xFF8D6E63);
  }

  static String label(int v) => v >= 1000 ? '${v ~/ 1000}K' : '$v';

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: glow ? const Color(0xFFF1C40F).withValues(alpha: 0.8) : Colors.black54,
            blurRadius: glow ? 12 : (flat ? 2 : 5),
            offset: glow ? Offset.zero : const Offset(0, 2),
          ),
        ],
      ),
      child: CustomPaint(
        painter: ChipPainter(color ?? colorFor(value)),
        child: Center(
          child: Text(text ?? label(value), style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size * (text != null && text!.length > 3 ? 0.21 : 0.26))),
        ),
      ),
    );
  }
}

class ChipPainter extends CustomPainter {
  final Color color;
  ChipPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = color);
    // 外圈 8 段白色條紋
    final stripe = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.22;
    final rect = Rect.fromCircle(center: c, radius: r * 0.89);
    for (var i = 0; i < 8; i++) {
      canvas.drawArc(rect, i * math.pi / 4 - 0.2, 0.4, false, stripe);
    }
    canvas.drawCircle(c, r * 0.68, Paint()
      ..color = Colors.white70
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
    canvas.drawCircle(c, r - 0.5, Paint()
      ..color = Colors.black26
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant ChipPainter old) => old.color != color;
}
