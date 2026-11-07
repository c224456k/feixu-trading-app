import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../web_reload.dart';
import 'archer_rogue_screen.dart';
import 'hero_screen.dart';
import 'magic_tower_screen.dart';
import 'sickle_storm_screen.dart';
import 'td_screen.dart';
import 'volley_screen.dart';

class _Game {
  final String name;
  final String desc;
  final IconData icon;
  final Color color;
  final Widget Function()? builder; // 站內畫面
  final String? url; // 外部網址（開新分頁）

  const _Game(this.name, this.desc, this.icon, this.color, {this.builder, this.url});
}

/// 遊戲區大廳：把非博奕的小遊戲收在同一個入口（版面同娛樂城）。
class GamesScreen extends StatelessWidget {
  const GamesScreen({super.key});

  static final _games = <_Game>[
    _Game('勇者裝備', '穿裝備、看屬性、逛勇者商店', Icons.shield, const Color(0xFFB8860B),
        builder: () => const HeroScreen()),
    _Game('塔防', '蓋塔擋怪', Icons.castle, const Color(0xFF6D4C41), builder: () => const TdScreen()),
    _Game('怪物打排球', '連線雙人對戰、每晚排球大賽', Icons.sports_volleyball, const Color(0xFFE67E22),
        builder: () => const VolleyScreen()),
    _Game('魔塔（試玩）', '20 層格子解謎', Icons.domain, const Color(0xFF5E35B1),
        builder: () => const MagicTowerScreen()),
    _Game('弓箭肉鴿', '20 關、每天一局、可雙人合作', Icons.gps_fixed, const Color(0xFF00897B),
        builder: () => const ArcherRogueScreen()),
    _Game('鐮刀風暴（試玩）', '轉刀收割 .io，單人或多人連線', Icons.cyclone, const Color(0xFFD81B60),
        builder: () => const SickleStormScreen()),
    _Game('萌獸大冒險（試玩）', '復古掌機風抓怪 RPG：抓萌獸、練功、打道館（開新分頁）', Icons.pets,
        const Color(0xFF43A047),
        url: 'https://c224456k.github.io/monster-rpg/'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('遊戲區')),
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

  void _open(BuildContext context, _Game g) {
    if (g.builder != null) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => g.builder!()));
      return;
    }
    if (openInNewTab(g.url!)) return;
    // 非網頁版：顯示網址讓玩家自己用瀏覽器開
    Clipboard.setData(ClipboardData(text: g.url!));
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(g.name),
        content: SelectableText('請用瀏覽器開啟（網址已複製）：\n${g.url}'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('好'))],
      ),
    );
  }

  Widget _tile(BuildContext context, _Game g) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context, g),
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
              Icon(g.url != null ? Icons.open_in_new : Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
