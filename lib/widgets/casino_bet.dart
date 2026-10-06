import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../screens/baccarat_screen.dart' show CasinoChip;

final _money = NumberFormat('#,##0');

const kCasinoChips = [1000, 10000, 50000, 100000, 500000];

// 下注籌碼選擇列：圓形賭場籌碼，選中的浮起來發光
class ChipSelector extends StatelessWidget {
  final List<int> chips;
  final int selected;
  final ValueChanged<int> onSelect;
  final double size;

  const ChipSelector({super.key, this.chips = kCasinoChips, required this.selected, required this.onSelect, this.size = 52});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: chips.map((c) {
        final on = c == selected;
        return GestureDetector(
          onTap: () => onSelect(c),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            transform: Matrix4.translationValues(0, on ? -6 : 0, 0),
            child: CasinoChip(value: c, size: size, glow: on),
          ),
        );
      }).toList(),
    );
  }
}

// 把金額拆成面額疊起來（大的在下，最多 6 顆）
class ChipPile extends StatelessWidget {
  final double amount;
  final double size;
  final List<int> chips;

  const ChipPile({super.key, required this.amount, required this.size, this.chips = kCasinoChips});

  @override
  Widget build(BuildContext context) {
    final stack = <int>[];
    var left = amount.round();
    for (final v in chips.reversed) {
      while (left >= v && stack.length < 6) {
        stack.add(v);
        left -= v;
      }
    }
    if (stack.isEmpty && amount > 0) stack.add(chips.first);
    final list = stack.reversed.toList();
    const step = 5.0;
    return SizedBox(
      width: size,
      height: size * 0.5 + step * list.length + 6,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          for (var i = 0; i < list.length; i++) Positioned(bottom: i * step, child: CasinoChip(value: list[i], size: size, flat: true)),
        ],
      ),
    );
  }
}

// 賭桌上的一個下注區：標題、賠率、我押的籌碼堆；結算後贏的區域金光閃動、籌碼堆換成派彩。
class BetZone extends StatelessWidget {
  final String title;
  final String sub;
  final Color color;
  final double height;
  final double bet;
  final double payout;
  final bool settled; // 結算動畫演完
  final bool win;
  final bool canBet;
  final bool seated;
  final int chip;
  final int players;
  final String roundKey;
  final VoidCallback? onTap;

  const BetZone({
    super.key,
    required this.title,
    required this.sub,
    required this.color,
    required this.height,
    required this.bet,
    required this.payout,
    required this.settled,
    required this.win,
    required this.canBet,
    required this.seated,
    required this.chip,
    required this.players,
    required this.roundKey,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final lost = settled && bet > 0 && payout <= 0.005;
    final pulse = win ? (0.5 + 0.5 * math.sin(DateTime.now().millisecondsSinceEpoch / 180.0)) : 0.0;
    final shown = settled && payout > 0.005 ? payout : bet;
    final net = payout - bet;
    final big = height > 110;
    return GestureDetector(
      onTap: canBet ? onTap : null,
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
              top: 6,
              left: 0,
              right: 0,
              child: Column(children: [
                Text(title, style: TextStyle(fontSize: big ? 28 : 20, fontWeight: FontWeight.bold, color: color, letterSpacing: 2)),
                Text(sub, style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ]),
            ),
            if (shown > 0)
              Positioned(
                bottom: big ? 26 : 22,
                child: Opacity(
                  opacity: lost ? 0.35 : 1,
                  child: TweenAnimationBuilder<double>(
                    key: ValueKey('$roundKey-${shown.round()}-${win ? 1 : 0}'),
                    tween: Tween(begin: 0, end: 1),
                    duration: Duration(milliseconds: win ? 650 : 320),
                    curve: win ? Curves.elasticOut : Curves.bounceOut,
                    builder: (context, v, child) => Transform.translate(offset: Offset(0, -34 * (1 - v)), child: Opacity(opacity: v.clamp(0.0, 1.0), child: child)),
                    child: ChipPile(amount: shown, size: big ? 36 : 28),
                  ),
                ),
              ),
            Positioned(
              bottom: 4,
              left: 4,
              right: 4,
              child: Text(
                settled && bet > 0
                    ? (net > 0.005 ? '+${_money.format(net)}' : (net > -0.005 ? '退回' : '-${_money.format(-net)}'))
                    : (bet > 0 ? '我押 ${_money.format(bet)}' : (canBet ? '押 ${_money.format(chip)}' : (seated ? '' : '請先入座'))),
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
            Positioned(top: 3, right: 8, child: Text('$players人', style: const TextStyle(fontSize: 10, color: Colors.white38))),
          ],
        ),
      ),
    );
  }
}

// 賭桌底：綠絨加金邊，下注區放裡面
class FeltBox extends StatelessWidget {
  final Widget child;
  const FeltBox({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const RadialGradient(radius: 1.1, colors: [Color(0xFF0E7A4B), Color(0xFF06351F)]),
        border: Border.all(color: const Color(0xFF8B6B2E), width: 3),
      ),
      child: child,
    );
  }
}
