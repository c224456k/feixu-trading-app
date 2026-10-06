import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';
import 'baccarat_screen.dart' show PlayingCardFace, CasinoChip;

final _money = NumberFormat('#,##0');

// 籌碼數字太長，座位卡上用「萬／億」縮寫；對話框、結果則顯示完整數字。
String _short(num n) {
  final v = n.abs();
  final sign = n < 0 ? '-' : '';
  if (v >= 100000000) return '$sign${_trim(v / 100000000)}億';
  if (v >= 10000) return '$sign${_trim(v / 10000)}萬';
  return '$sign${v.toInt()}';
}

String _trim(double x) {
  final s = x.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

// 網頁版德州撲克（六人桌、無限注、固定盲注、不抽水）：玩家對玩家。
// 洗牌、發牌、輪到誰、下注是否合法、邊池、比牌、派彩全部由伺服器決定，這個畫面只負責「顯示」跟「送出動作」。
// 別人的底牌伺服器根本不會傳過來，只有攤牌時還沒棄牌的人才會公開。
class PokerScreen extends StatefulWidget {
  const PokerScreen({super.key});

  @override
  State<PokerScreen> createState() => _PokerScreenState();
}

class _PokerScreenState extends State<PokerScreen> {
  final _api = ApiClient();

  PokerState? _state;
  DateTime _fetchedAt = DateTime.now();
  String? _error;
  bool _busy = false;

  double _raiseTo = 0;
  String _raiseKey = '';

  Timer? _pollTimer;
  Timer? _tickTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _load());
    _tickTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
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
      final s = await _api.fetchPokerState();
      if (!mounted) return;
      _fetchedAt = DateTime.now();
      _state = s;
      // 輪到我、或是下注額改變（有人加注）時，把加注滑桿重設成最小加注額；其他時候保留玩家自己拉的位置。
      final key = '${s.hand?.id}-${s.hand?.street}-${s.hand?.currentBet}-${s.actions.canAct}';
      if (key != _raiseKey) {
        _raiseKey = key;
        _raiseTo = s.actions.minRaiseTo.toDouble();
      }
      _raiseTo = _raiseTo.clamp(s.actions.minRaiseTo.toDouble(), math.max(s.actions.minRaiseTo, s.actions.maxRaiseTo).toDouble());
      setState(() => _error = null);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  double? get _remaining {
    final left = _state?.hand?.secondsLeft;
    if (left == null) return null;
    final elapsed = DateTime.now().difference(_fetchedAt).inMilliseconds / 1000.0;
    return math.max(0, left - elapsed);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  Future<void> _run(Future<SicBoBetResult> Function() call, {bool toast = true}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await call();
      if (toast || !r.ok) _snack(r.message);
      await _load();
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sit(PokerState s, int seat) async {
    final buyin = await showDialog<int>(
      context: context,
      builder: (_) => _BuyinDialog(min: s.minBuyin, max: s.maxBuyin, cash: s.cash, bigBlind: s.bigBlind),
    );
    if (buyin == null) return;
    await _run(() => _api.sitPoker(seat, buyin));
  }

  Future<void> _leave(PokerState s) async {
    final me = s.mySeat == null ? null : s.seats[s.mySeat!];
    final inHand = me != null && me.inHand && me.status == 'active' && s.hand?.finished == false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('離開牌桌？'),
        content: Text(inHand ? '這手牌你還沒棄牌，離座會自動棄牌，已經投進底池的籌碼拿不回來。剩下的籌碼會換回現金。' : '桌上的籌碼會換回現金。離座後要等一下才能再入座。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('離座')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => _api.leavePoker());
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('德州撲克'),
        actions: [
          if (s?.mySeat != null)
            TextButton.icon(
              onPressed: _busy ? null : () => _leave(s!),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('離座'),
            ),
        ],
      ),
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
              padding: const EdgeInsets.all(12),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(s),
                      const SizedBox(height: 10),
                      _table(s),
                      const SizedBox(height: 10),
                      if (s.actions.canAct) _actionPanel(s) else _hint(s),
                      const SizedBox(height: 14),
                      _history(s),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12), textAlign: TextAlign.center),
                        ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _header(PokerState s) {
    return Row(
      children: [
        const Icon(Icons.account_balance_wallet, size: 18),
        const SizedBox(width: 6),
        Text('現金 ${_money.format(s.cash)}', style: const TextStyle(fontWeight: FontWeight.bold)),
        const Spacer(),
        Text('盲注 ${_short(s.smallBlind)}/${_short(s.bigBlind)}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }

  static const _streetNames = ['翻牌前', '翻牌', '轉牌', '河牌'];

  // 籌碼面額（對應盲注 5 萬 / 10 萬）與顏色
  static const _denoms = <(int, Color)>[
    (50000000, Color(0xFFF9A825)),
    (10000000, Color(0xFFE65100)),
    (5000000, Color(0xFF00838F)),
    (1000000, Color(0xFF7B1FA2)),
    (500000, Color(0xFF212121)),
    (100000, Color(0xFF2E7D32)),
    (50000, Color(0xFFC62828)),
    (0, Color(0xFF546E7A)),
  ];

  // 把金額拆成籌碼（大面額在下），最多疊 7 顆
  Widget _pile(num amount, double size) {
    if (amount <= 0) return const SizedBox.shrink();
    final chips = <(int, Color)>[];
    var left = amount.round();
    for (final d in _denoms) {
      if (d.$1 == 0) continue;
      while (left >= d.$1 && chips.length < 7) {
        chips.add(d);
        left -= d.$1;
      }
    }
    if (chips.isEmpty) chips.add(_denoms.last);
    const step = 4.0;
    return SizedBox(
      width: size,
      height: size * 0.5 + step * chips.length + 4,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          for (var i = 0; i < chips.length; i++)
            Positioned(
              bottom: i * step,
              child: CasinoChip(value: chips[i].$1, size: size, flat: true, color: chips[i].$2, text: chips[i].$1 == 0 ? '' : _short(chips[i].$1)),
            ),
        ],
      ),
    );
  }

  // 六個座位在橢圓桌邊的位置（中心點佔桌面比例），由「自己」在最下面開始順時針排
  static const _slots = <Offset>[
    Offset(0.5, 0.87),
    Offset(0.14, 0.68),
    Offset(0.14, 0.30),
    Offset(0.5, 0.13),
    Offset(0.86, 0.30),
    Offset(0.86, 0.68),
  ];

  Widget _table(PokerState s) {
    final h = s.hand;
    final board = h?.board ?? const <PlayingCard>[];
    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      final height = w > 500 ? w * 0.85 : w * 1.22;
      final base = s.mySeat ?? 0;
      final center = Offset(w / 2, height / 2);
      final seatW = math.min(104.0, w * 0.27);
      const seatH = 112.0;
      final cardW = math.min(52.0, (w * 0.7 - 24) / 5);

      Offset seatPos(int seat) {
        final slot = _slots[(seat - base + 6) % 6];
        return Offset(slot.dx * w, slot.dy * height);
      }

      final children = <Widget>[
        // 桌子：木頭邊 + 金線 + 綠絨
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.all(Radius.elliptical(w / 2, height / 2)),
              gradient: const LinearGradient(colors: [Color(0xFF6D4C2B), Color(0xFF3E2814)], begin: Alignment.topLeft, end: Alignment.bottomRight),
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 6))],
            ),
          ),
        ),
        Positioned.fill(
          child: Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.all(Radius.elliptical(w / 2, height / 2)),
              gradient: const RadialGradient(colors: [Color(0xFF1E8A55), Color(0xFF0B3D25)], radius: 0.85),
              border: Border.all(color: const Color(0xFFC9A24B), width: 2),
            ),
          ),
        ),
        // 中央資訊：局數、底池籌碼、公牌
        Positioned(
          left: 0,
          right: 0,
          top: height * 0.5 - cardW * 0.7 - 74,
          child: Column(
            children: [
              Text(
                h == null ? '等待玩家入座（2 人以上開局）' : (h.finished ? '第 ${h.id} 手結束' : '第 ${h.id} 手・${_streetNames[h.street]}'),
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(height: 2),
              if (h != null && h.pot > 0)
                TweenAnimationBuilder<double>(
                  key: ValueKey('pot-${h.id}-${h.pot}'),
                  tween: Tween(begin: 0.85, end: 1),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.elasticOut,
                  builder: (context, v, child) => Transform.scale(scale: v, child: child),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _pile(h.pot, 26),
                      const SizedBox(width: 8),
                      Text('底池 ${_money.format(h.pot)}', style: const TextStyle(color: Color(0xFFFFD54F), fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                )
              else
                const Text('底池 0', style: TextStyle(color: Color(0xFFFFD54F), fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: height * 0.5 - cardW * 0.7 + 4,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 5; i++)
                Padding(
                  padding: EdgeInsets.only(left: i == 0 ? 0 : 5),
                  child: i < board.length
                      ? TweenAnimationBuilder<double>(
                          key: ValueKey('b-${h?.id}-$i'),
                          tween: Tween(begin: 0, end: 1),
                          duration: const Duration(milliseconds: 450),
                          curve: Curves.easeOut,
                          builder: (context, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, -16 * (1 - v)), child: child)),
                          child: PlayingCardFace(card: board[i], width: cardW),
                        )
                      : _emptySlot(cardW),
                ),
            ],
          ),
        ),
        if (h != null && h.finished) ...[
          Positioned(
            left: 12,
            right: 12,
            top: height * 0.5 + cardW * 0.7 + 12,
            child: Column(
              children: [
                for (final p in h.pots)
                  Text(
                    '${p.winners.join("、")} 贏得 ${_money.format(p.amount)}',
                    style: const TextStyle(color: Color(0xFFFFE066), fontWeight: FontWeight.bold, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                if (!h.showdown) const Text('其他人都棄牌', style: TextStyle(color: Colors.white54, fontSize: 10)),
              ],
            ),
          ),
        ],
      ];

      // 每個座位的下注籌碼（往桌中央推）、贏家的籌碼（從底池滑回座位）
      for (final seat in s.seats) {
        if (!seat.occupied) continue;
        final sp = seatPos(seat.seat);
        final betPos = Offset.lerp(sp, center, 0.42)!;
        if (seat.betStreet > 0 && h != null && !h.finished) {
          children.add(Positioned(
            left: betPos.dx - 40,
            top: betPos.dy - 24,
            width: 80,
            child: TweenAnimationBuilder<double>(
              key: ValueKey('bet-${h.id}-${seat.seat}-${seat.betStreet}'),
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutBack,
              builder: (context, v, child) {
                final from = sp - betPos;
                return Transform.translate(offset: Offset(from.dx * (1 - v) * 0.6, from.dy * (1 - v) * 0.6), child: Opacity(opacity: v.clamp(0.0, 1.0), child: child));
              },
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _pile(seat.betStreet, 22),
                Text(_short(seat.betStreet), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ]),
            ),
          ));
        }
        final net = seat.net;
        if (h != null && h.finished && net != null && net > 0) {
          children.add(TweenAnimationBuilder<double>(
            key: ValueKey('win-${h.id}-${seat.seat}'),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 1100),
            curve: Curves.easeInOutCubic,
            builder: (context, v, child) {
              final pos = Offset.lerp(center, betPos, v)!;
              return Positioned(left: pos.dx - 40, top: pos.dy - 24, width: 80, child: child!);
            },
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _pile(net, 24),
              Text('+${_short(net)}', style: const TextStyle(color: Color(0xFFFFE066), fontSize: 13, fontWeight: FontWeight.bold)),
            ]),
          ));
        }
      }

      for (final seat in s.seats) {
        final sp = seatPos(seat.seat);
        children.add(Positioned(
          left: sp.dx - seatW / 2,
          top: sp.dy - seatH / 2,
          width: seatW,
          height: seatH,
          child: _seatSpot(s, seat, seatW),
        ));
      }

      return SizedBox(width: w, height: height, child: Stack(clipBehavior: Clip.none, children: children));
    });
  }

  Widget _emptySlot(double w) => Container(
        width: w,
        height: w * 1.4,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(w * 0.1),
          border: Border.all(color: Colors.white24, width: 1),
          color: Colors.black12,
        ),
      );

  Widget _seatSpot(PokerState s, PokerSeat seat, double seatW) {
    if (!seat.occupied) {
      final canSit = s.mySeat == null;
      return GestureDetector(
        onTap: canSit && !_busy ? () => _sit(s, seat.seat) : null,
        child: Center(
          child: Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black26,
              border: Border.all(color: canSit ? const Color(0xFFFFD54F) : Colors.white24, width: 1.5),
            ),
            child: Text(canSit ? '${seat.seat + 1}\n入座' : '${seat.seat + 1}\n空位',
                textAlign: TextAlign.center, style: TextStyle(color: canSit ? const Color(0xFFFFD54F) : Colors.white38, fontSize: 12, height: 1.2)),
          ),
        ),
      );
    }
    final h = s.hand;
    final live = h != null && !h.finished;
    final active = seat.isToAct && live;
    final folded = seat.status == 'folded';
    final win = h != null && h.finished && (seat.net ?? 0) > 0;
    final remaining = _remaining;
    final pulse = (active || win) ? (0.5 + 0.5 * math.sin(DateTime.now().millisecondsSinceEpoch / 200.0)) : 0.0;
    final cw = seat.isMe ? 38.0 : 28.0;

    Widget cards;
    if (seat.cards != null) {
      cards = Row(mainAxisSize: MainAxisSize.min, children: [
        for (final c in seat.cards!) Padding(padding: const EdgeInsets.symmetric(horizontal: 1.5), child: PlayingCardFace(card: c, width: cw)),
      ]);
    } else if (seat.hasCards && h != null) {
      cards = Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 2; i++) Padding(padding: const EdgeInsets.symmetric(horizontal: 1.5), child: _cardBack(cw)),
      ]);
    } else {
      cards = SizedBox(height: cw * 1.4);
    }

    String? tag;
    if (seat.status == 'allin') tag = '全下';
    if (folded) tag = '棄牌';
    final ringColor = win
        ? Color.lerp(const Color(0xFFB8860B), const Color(0xFFFFE066), pulse)!
        : active
            ? Color.lerp(const Color(0xFFFFB300), const Color(0xFFFFF176), pulse)!
            : (seat.isMe ? Colors.lightBlueAccent : Colors.white30);

    return Opacity(
      opacity: folded ? 0.5 : 1,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: cw * 1.4, child: Align(alignment: Alignment.bottomCenter, child: cards)),
              const SizedBox(height: 3),
              Container(
                width: seatW,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: const Color(0xDD14202B),
                  border: Border.all(color: ringColor, width: (active || win) ? 2.5 : 1.5),
                  boxShadow: (active || win) ? [BoxShadow(color: ringColor.withValues(alpha: 0.6), blurRadius: 10)] : null,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      seat.isMe ? '${seat.name ?? ''}（我）' : (seat.name ?? ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const CasinoChip(value: 0, size: 12, flat: true, color: Color(0xFFC62828), text: ''),
                      const SizedBox(width: 4),
                      Text(_short(seat.stack), style: const TextStyle(fontSize: 12, color: Color(0xFFFFD54F), fontWeight: FontWeight.bold)),
                    ]),
                    SizedBox(
                      height: 13,
                      child: Text(
                        active && remaining != null
                            ? '${remaining.ceil()} 秒'
                            : (tag ?? seat.handName ?? ''),
                        style: TextStyle(
                          fontSize: 10,
                          color: active && remaining != null && remaining < 8
                              ? Colors.redAccent
                              : (tag == '全下' ? Colors.orangeAccent : Colors.white60),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (seat.isDealer)
            Positioned(
              right: 0,
              bottom: 22,
              child: Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: Colors.black45), boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)]),
                child: const Text('D', style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ),
          if (h != null && h.finished && (seat.net ?? 0) < 0)
            Positioned(
              top: 0,
              child: Text(_short(seat.net!), style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _cardBack(double w) => Container(
        width: w,
        height: w * 1.4,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(w * 0.12),
          border: Border.all(color: Colors.white, width: 1.2),
          gradient: const LinearGradient(colors: [Color(0xFF2C4DB8), Color(0xFF1B2F7A)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
      );

  Widget _hint(PokerState s) {
    String text;
    if (s.mySeat == null) {
      text = '點一個空位入座（買入 ${_money.format(s.minBuyin)} ~ ${_money.format(s.maxBuyin)}），2 人以上就會自動開局。';
    } else if (s.hand == null || s.hand!.finished) {
      final seated = s.seats.where((e) => e.occupied && e.stack > 0).length;
      text = seated < 2 ? '等其他玩家入座…' : '下一手牌馬上開始…';
    } else {
      final me = s.seats[s.mySeat!];
      if (!me.inHand) {
        text = '這手牌你還沒加入，下一手開始就會發牌給你。';
      } else if (me.status == 'folded') {
        text = '你已棄牌，等這手牌結束。';
      } else if (me.status == 'allin') {
        text = '你已全下，等開牌。';
      } else {
        text = '等其他玩家行動…';
      }
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.white10),
      child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
    );
  }

  // 圓形籌碼按鈕：上面是動作文字，下面小字補充金額
  Widget _chipButton(String label, Color color, VoidCallback? onTap, {double size = 58, String? caption, bool glow = false}) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CasinoChip(value: 0, size: size, color: color, text: label, glow: glow && enabled),
            SizedBox(
              height: 16,
              child: Text(caption ?? '', style: const TextStyle(fontSize: 11, color: Colors.white70), maxLines: 1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionPanel(PokerState s) {
    final a = s.actions;
    final pot = s.hand?.pot ?? 0;
    final canSlide = a.canRaise && a.maxRaiseTo > a.minRaiseTo;
    final raiseInt = _raiseTo.round();
    final raiseLabel = s.hand != null && s.hand!.currentBet == 0 ? '下注' : '加注';
    final allIn = raiseInt >= a.maxRaiseTo;
    void setRaise(num v) => setState(() => _raiseTo = v.clamp(a.minRaiseTo, a.maxRaiseTo).toDouble());
    final enabled = !_busy;
    final bet = s.hand?.currentBet ?? 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(colors: [Color(0xFF14202B), Color(0xFF0B141B)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        border: Border.all(color: const Color(0xFFC9A24B), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _chipButton('棄牌', const Color(0xFFC62828), enabled ? () => _run(() => _api.pokerAction('fold'), toast: false) : null),
              _chipButton(
                a.canCheck ? '過牌' : '跟注',
                const Color(0xFF2E7D32),
                enabled ? () => _run(() => _api.pokerAction(a.canCheck ? 'check' : 'call'), toast: false) : null,
                size: 72,
                caption: a.canCheck ? '' : _money.format(a.callAmount),
                glow: true,
              ),
              if (a.canRaise)
                _chipButton(
                  allIn ? '全下' : raiseLabel,
                  const Color(0xFFF9A825),
                  enabled
                      ? () => _run(() => allIn ? _api.pokerAction('allin') : _api.pokerAction('raise', amount: raiseInt), toast: false)
                      : null,
                  size: 72,
                  caption: _money.format(allIn ? a.maxRaiseTo : raiseInt),
                  glow: true,
                ),
            ],
          ),
          if (a.canRaise && canSlide) ...[
            const SizedBox(height: 8),
            Slider(
              value: _raiseTo.clamp(a.minRaiseTo.toDouble(), a.maxRaiseTo.toDouble()),
              min: a.minRaiseTo.toDouble(),
              max: a.maxRaiseTo.toDouble(),
              onChanged: enabled ? (v) => setState(() => _raiseTo = v) : null,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _chipButton('最小', const Color(0xFF546E7A), () => setRaise(a.minRaiseTo), size: 46),
                _chipButton('半池', const Color(0xFF00838F), () => setRaise(bet + pot / 2), size: 46),
                _chipButton('一池', const Color(0xFF7B1FA2), () => setRaise(bet + pot), size: 46),
                _chipButton('最大', const Color(0xFF212121), () => setRaise(a.maxRaiseTo), size: 46),
              ],
            ),
          ] else if (!a.canRaise && !a.canCheck && a.callAmount > 0 && a.callAmount >= a.maxRaiseTo) ...[
            const SizedBox(height: 4),
            const Text('籌碼不夠完整跟注，跟注即全下', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white54)),
          ],
          if (_remaining != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('剩 ${_remaining!.ceil()} 秒，逾時會自動${a.canCheck ? "過牌" : "棄牌"}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ),
        ],
      ),
    );
  }

  Widget _history(PokerState s) {
    if (s.history.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('最近牌局', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        for (final e in s.history)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '#${e.id}　${e.winner} 贏 ${_short(e.winnerNet)}${e.hand != null ? "（${e.hand}）" : ""}　底池 ${_short(e.pot)}',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
      ],
    );
  }
}

class _BuyinDialog extends StatefulWidget {
  final int min;
  final int max;
  final double cash;
  final int bigBlind;

  const _BuyinDialog({required this.min, required this.max, required this.cash, required this.bigBlind});

  @override
  State<_BuyinDialog> createState() => _BuyinDialogState();
}

class _BuyinDialogState extends State<_BuyinDialog> {
  late double _v;

  @override
  void initState() {
    super.initState();
    _v = math.min(widget.min * 2.5, widget.max.toDouble());
    _v = (_v / widget.bigBlind).roundToDouble() * widget.bigBlind;
  }

  @override
  Widget build(BuildContext context) {
    final buy = _v.round();
    final enough = widget.cash >= buy;
    return AlertDialog(
      title: const Text('買入籌碼'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_money.format(buy), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text('= ${(buy / widget.bigBlind).round()} 個大盲', style: const TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, alignment: WrapAlignment.center, children: [
            for (final bb in <int>{widget.min ~/ widget.bigBlind, 60, 100, 150, widget.max ~/ widget.bigBlind})
              if (bb * widget.bigBlind >= widget.min && bb * widget.bigBlind <= widget.max)
                GestureDetector(
                  onTap: () => setState(() => _v = (bb * widget.bigBlind).toDouble()),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CasinoChip(
                      value: 0,
                      size: 50,
                      color: bb >= 150 ? const Color(0xFF7B1FA2) : (bb >= 100 ? const Color(0xFF212121) : (bb >= 60 ? const Color(0xFF2E7D32) : const Color(0xFFC62828))),
                      text: '${bb}BB',
                      glow: buy == bb * widget.bigBlind,
                    ),
                    Text(_short(bb * widget.bigBlind), style: const TextStyle(fontSize: 11, color: Colors.white60)),
                  ]),
                ),
          ]),
          Slider(
            value: _v,
            min: widget.min.toDouble(),
            max: widget.max.toDouble(),
            divisions: (widget.max - widget.min) ~/ widget.bigBlind,
            onChanged: (v) => setState(() => _v = v),
          ),
          Text('可買入 ${_money.format(widget.min)} ~ ${_money.format(widget.max)}\n你的現金 ${_money.format(widget.cash)}',
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          if (!enough) const Text('現金不夠', style: TextStyle(color: Colors.redAccent)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: enough ? () => Navigator.pop(context, buy) : null, child: const Text('入座')),
      ],
    );
  }
}
