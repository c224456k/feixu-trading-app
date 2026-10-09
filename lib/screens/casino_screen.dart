import 'package:flutter/material.dart';

import 'baccarat_screen.dart';
import 'horse_screen.dart';
import 'poker_screen.dart';
import 'sicbo_screen.dart';
import 'slot_screen.dart';

class _CasinoGame {
  final String name;
  final String desc;
  final IconData icon;
  final Color color;
  final Widget Function() builder;

  const _CasinoGame(this.name, this.desc, this.icon, this.color, this.builder);
}

/// 娛樂城大廳：把所有博奕遊戲收在同一個入口。
class CasinoScreen extends StatelessWidget {
  const CasinoScreen({super.key});

  static final _games = <_CasinoGame>[
    _CasinoGame('老虎機', '1024 種連線、鑽石必中、全服累積彩池', Icons.stars,
        const Color(0xFFE5B800), () => const SlotScreen()),
    _CasinoGame('德州撲克', '六人桌真人對戰，不抽水', Icons.filter_vintage,
        const Color(0xFF2E8B57), () => const PokerScreen()),
    _CasinoGame('百家樂', '莊閒和，六人座位制', Icons.style,
        const Color(0xFFC0392B), () => const BaccaratScreen()),
    _CasinoGame('骰寶', '三顆骰子，大小與點數', Icons.casino,
        const Color(0xFF8E44AD), () => const SicBoScreen()),
    _CasinoGame('賭馬', '押注賽馬名次', Icons.emoji_events,
        const Color(0xFF2980B9), () => const HorseScreen()),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('娛樂城')),
      body: LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth >= 900 ? 3 : (c.maxWidth >= 560 ? 2 : 1);
        return GridView.count(
          padding: const EdgeInsets.all(16),
          crossAxisCount: cols,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: cols == 1 ? 3.6 : 2.6,
          children: [for (final g in _games) _tile(context, g)],
        );
      }),
    );
  }

  Widget _tile(BuildContext context, _CasinoGame g) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => g.builder())),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: g.color.withValues(alpha: 0.2),
                child: Icon(g.icon, color: g.color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    const SizedBox(height: 4),
                    Text(g.desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.grey, fontSize: 13)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
