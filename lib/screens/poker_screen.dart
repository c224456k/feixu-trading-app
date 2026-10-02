import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';
import 'baccarat_screen.dart' show PlayingCardFace;

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
                      _seats(s),
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

  Widget _table(PokerState s) {
    final h = s.hand;
    final board = h?.board ?? const <PlayingCard>[];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(60),
        gradient: const RadialGradient(colors: [Color(0xFF1E7A4A), Color(0xFF0F4A2C)], radius: 1.0),
        border: Border.all(color: const Color(0xFF5B3A1A), width: 6),
      ),
      child: Column(
        children: [
          Text(
            h == null
                ? '等待玩家入座（至少 2 人才會開局）'
                : (h.finished ? '第 ${h.id} 手結束' : '第 ${h.id} 手・${_streetNames[h.street]}'),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            '底池 ${h == null ? 0 : _money.format(h.pot)}',
            style: const TextStyle(color: Color(0xFFFFD54F), fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(builder: (ctx, c) {
            final w = math.min(54.0, (c.maxWidth - 4 * 6) / 5);
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < 5; i++)
                  Padding(
                    padding: EdgeInsets.only(left: i == 0 ? 0 : 6),
                    child: i < board.length ? PlayingCardFace(card: board[i], width: w) : _emptySlot(w),
                  ),
              ],
            );
          }),
          if (h != null && h.finished) ...[
            const SizedBox(height: 10),
            for (final p in h.pots)
              Text(
                '${h.pots.length > 1 ? "${_money.format(p.amount)}：" : ""}${p.winners.join("、")} 贏得 ${_money.format(p.amount)}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            if (!h.showdown) const Text('其他人都棄牌，不用亮牌', style: TextStyle(color: Colors.white54, fontSize: 11)),
          ],
        ],
      ),
    );
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

  Widget _seats(PokerState s) {
    return LayoutBuilder(builder: (ctx, c) {
      final cols = c.maxWidth >= 480 ? 3 : 2;
      final w = (c.maxWidth - (cols - 1) * 8) / cols;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [for (final seat in s.seats) SizedBox(width: w, child: _seatTile(s, seat))],
      );
    });
  }

  Widget _seatTile(PokerState s, PokerSeat seat) {
    if (!seat.occupied) {
      final canSit = s.mySeat == null;
      return InkWell(
        onTap: canSit && !_busy ? () => _sit(s, seat.seat) : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 118,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(canSit ? '${seat.seat + 1} 號位\n點我入座' : '${seat.seat + 1} 號位\n空位',
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ),
      );
    }
    final h = s.hand;
    final active = seat.isToAct && h != null && !h.finished;
    final folded = seat.status == 'folded';
    final remaining = _remaining;
    final cardW = 34.0;
    Widget cards;
    if (seat.cards != null) {
      cards = Row(mainAxisSize: MainAxisSize.min, children: [
        for (final c in seat.cards!) Padding(padding: const EdgeInsets.only(right: 3), child: PlayingCardFace(card: c, width: cardW)),
      ]);
    } else if (seat.hasCards && h != null) {
      cards = Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 2; i++) Padding(padding: const EdgeInsets.only(right: 3), child: _cardBack(cardW)),
      ]);
    } else {
      cards = SizedBox(height: cardW * 1.4);
    }
    String? tag;
    if (seat.status == 'allin') tag = '全下';
    if (folded) tag = '棄牌';
    final net = seat.net;
    return Opacity(
      opacity: folded ? 0.55 : 1,
      child: Container(
        height: 118,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: seat.isMe ? const Color(0x331E88E5) : Colors.white10,
          border: Border.all(color: active ? const Color(0xFFFFD54F) : (seat.isMe ? Colors.lightBlueAccent : Colors.white24), width: active ? 2.5 : 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (seat.isDealer)
                Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                  child: const Text('D', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              Expanded(child: Text(seat.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
              if (tag != null) Text(tag, style: TextStyle(fontSize: 11, color: tag == '全下' ? Colors.orangeAccent : Colors.white54)),
            ]),
            Text('籌碼 ${_short(seat.stack)}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 4),
            Expanded(
              child: Row(children: [
                cards,
                const Spacer(),
                Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (seat.betStreet > 0 && h != null && !h.finished)
                    Text('下注 ${_short(seat.betStreet)}', style: const TextStyle(fontSize: 12, color: Color(0xFFFFD54F))),
                  if (net != null && net != 0)
                    Text(net > 0 ? '+${_short(net)}' : _short(net),
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: net > 0 ? Colors.greenAccent : Colors.redAccent)),
                  if (seat.handName != null) Text(seat.handName!, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                  if (active && remaining != null) Text('${remaining.ceil()} 秒', style: TextStyle(fontSize: 12, color: remaining < 8 ? Colors.redAccent : Colors.white70)),
                ]),
              ]),
            ),
          ],
        ),
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

  Widget _actionPanel(PokerState s) {
    final a = s.actions;
    final pot = s.hand?.pot ?? 0;
    final canSlide = a.canRaise && a.maxRaiseTo > a.minRaiseTo;
    final raiseInt = _raiseTo.round();
    final raiseLabel = s.hand != null && s.hand!.currentBet == 0 ? '下注' : '加注到';
    void setRaise(num v) => setState(() => _raiseTo = v.clamp(a.minRaiseTo, a.maxRaiseTo).toDouble());
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: const Color(0x22FFD54F), border: Border.all(color: const Color(0xFFFFD54F))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _run(() => _api.pokerAction('fold'), toast: false),
                child: const Text('棄牌'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: _busy ? null : () => _run(() => _api.pokerAction(a.canCheck ? 'check' : 'call'), toast: false),
                child: Text(a.canCheck ? '過牌' : '跟注 ${_money.format(a.callAmount)}'),
              ),
            ),
          ]),
          if (a.canRaise) ...[
            const SizedBox(height: 10),
            if (canSlide) ...[
              Slider(
                value: _raiseTo.clamp(a.minRaiseTo.toDouble(), a.maxRaiseTo.toDouble()),
                min: a.minRaiseTo.toDouble(),
                max: a.maxRaiseTo.toDouble(),
                onChanged: _busy ? null : (v) => setState(() => _raiseTo = v),
              ),
              Wrap(spacing: 6, runSpacing: 4, alignment: WrapAlignment.center, children: [
                ActionChip(label: const Text('最小'), onPressed: () => setRaise(a.minRaiseTo)),
                ActionChip(label: const Text('半池'), onPressed: () => setRaise((s.hand?.currentBet ?? 0) + pot / 2)),
                ActionChip(label: const Text('一池'), onPressed: () => setRaise((s.hand?.currentBet ?? 0) + pot)),
                ActionChip(label: const Text('最大'), onPressed: () => setRaise(a.maxRaiseTo)),
              ]),
              const SizedBox(height: 6),
            ],
            Row(children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _busy
                      ? null
                      : () => _run(
                            () => raiseInt >= a.maxRaiseTo ? _api.pokerAction('allin') : _api.pokerAction('raise', amount: raiseInt),
                            toast: false,
                          ),
                  child: Text(raiseInt >= a.maxRaiseTo ? '全下 ${_money.format(a.maxRaiseTo)}' : '$raiseLabel ${_money.format(raiseInt)}'),
                ),
              ),
            ]),
          ] else if (!a.canCheck && a.callAmount > 0 && a.callAmount >= a.maxRaiseTo) ...[
            const SizedBox(height: 4),
            const Text('籌碼不夠完整跟注，跟注即全下', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white54)),
          ],
          if (_remaining != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
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
