import 'dart:math' as math;

// 魔塔（20 層）的規則與地圖。純邏輯、不依賴 Flutter，solver 腳本也用這份來驗證「有解」。
//
// 規則（經典魔塔）：勇者走格子，撞到怪物就戰鬥——勇者先出手，雙方每回合各打一下，
// 傷害 = 攻擊 − 對方防禦（最少 0），一直打到有一方血量歸零；撿到的道具永久加成，鑰匙開同色的門。
// 戰鬥的結果完全看數字、沒有隨機，所以走到怪物旁邊就能先算出「會掉多少血」。

const mtSize = 11;
const mtFloors = 20;

class MtMonster {
  final String name;
  final int kind; // MonsterPainter 的種類（跟百層塔共用）
  final int hp, atk, def, exp, gold;
  final bool boss;
  const MtMonster(this.name, this.kind, this.hp, this.atk, this.def, this.exp, this.gold, {this.boss = false});
}

/// 這層的怪物，沒有就是 null。
MtMonster? mtMonsterAt(int floor, String ch) => mtFloorMonsters[floor][ch];

// 道具：字元 → (說明, 血, 攻, 防, 黃鑰匙, 藍鑰匙, 紅鑰匙)
class MtItem {
  final String name;
  final int hp, atk, def, ky, kb, kr;
  const MtItem(this.name, {this.hp = 0, this.atk = 0, this.def = 0, this.ky = 0, this.kb = 0, this.kr = 0});
}

const mtItems = <String, MtItem>{
  'y': MtItem('金鑰匙', ky: 1),
  'b': MtItem('銀鑰匙', kb: 1),
  'r': MtItem('魔鑰匙', kr: 1),
  'h': MtItem('小血瓶', hp: 150),
  'H': MtItem('大血瓶', hp: 350),
  'a': MtItem('紅寶石', atk: 3),
  'd': MtItem('藍寶石', def: 3),
  'w': MtItem('魔劍', atk: 12),
  'x': MtItem('聖盾', def: 12),
};

/// 道具的血量、攻防加成會隨樓層變大（鑰匙不會）。
double mtItemMul(int floor) => 1 + floor * 0.2;
int mtScaled(int base, int floor) => (base * mtItemMul(floor)).round();

const mtStartHp = 800, mtStartAtk = 12, mtStartDef = 10;

/// 勇者等級：累積經驗到門檻就升級，每升一級 +攻 +防 +血（當場補上）。
const mtLevelAtk = 3, mtLevelDef = 3, mtLevelHp = 80;
/// 升到第 lv 級需要的累積經驗。
int mtExpNeed(int lv) => lv <= 1 ? 0 : (12 * math.pow(lv - 1, 1.9)).round();
int mtLevel(int exp) {
  var lv = 1;
  while (exp >= mtExpNeed(lv + 1)) {
    lv++;
  }
  return lv;
}

/// 商人：金幣只能在魔塔裡用。(名稱, 價格, 血, 攻, 防, 金鑰匙, 銀鑰匙)
class MtOffer {
  final String name;
  final int price, hp, atk, def, ky, kb;
  const MtOffer(this.name, this.price, {this.hp = 0, this.atk = 0, this.def = 0, this.ky = 0, this.kb = 0});
}

/// 商人賣的東西。價格隨樓層漲（金幣也越打越多）；鑰匙貴一點，因為鑰匙決定你能開幾間房。
List<MtOffer> mtShopAt(int floor) {
  final m = 1 + floor * 0.2;
  int p(int base) => (base * m).round();
  return [
    MtOffer('生命 +500', p(50), hp: 500),
    MtOffer('攻擊 +5', p(90), atk: 5),
    MtOffer('防禦 +5', p(90), def: 5),
    MtOffer('金鑰匙 ×1', p(40), ky: 1),
    MtOffer('銀鑰匙 ×1', p(70), kb: 1),
  ];
}

/// 每層一張 11x11。# 牆　. 空地　S 起點　U 上樓　D 下樓　YBR 金銀魔門　1~5/K 怪物（強度看樓層，見 mtFloorMonsters）　P 商人　其餘見 mtItems。
/// 由 scratchpad 的產生器＋模擬器做出來並驗證過：每層中間一條路一定要打 3 隻怪才能上樓，旁邊 4 間房要開門。
const mtMaps = <List<String>>[
  [  // F1
    '###########',
    '#y.##U##H.#',
    '#.5B.3.Y..#',
    '#y.#...#d.#',
    '#####2#####',
    '#y4.....4b#',
    '#####1#####',
    '#a.#...#h.#',
    '#..Y...Y..#',
    '#a.#.S.#h.#',
    '###########',
  ],
  [  // F2
    '###########',
    '#h.#.D.#d.#',
    '#..Y...Y..#',
    '#h.#...#a.#',
    '#####1#####',
    '#b4.....4y#',
    '#####2#####',
    '#y.#...#d.#',
    '#.5B.G.Y..#',
    '#y.##U##h.#',
    '###########',
  ],
  [  // F3
    '###########',
    '#h.##U##y.#',
    '#..Y.3.B..#',
    '#d.#...#y.#',
    '#####2#####',
    '#b4.....4y#',
    '#####1#####',
    '#H.#P..#a.#',
    '#.5Y...Y..#',
    '#a.#.D.#h.#',
    '###########',
  ],
  [  // F4
    '###########',
    '#d.#.D.#h.#',
    '#..Y...Y5.#',
    '#d.#...#h.#',
    '#####1#####',
    '#y4.....4b#',
    '#####2#####',
    '#y.#...#h.#',
    '#.5B.G.Y..#',
    '#y.##U##a.#',
    '###########',
  ],
  [  // F5
    '###########',
    '#H.##U##b.#',
    '#..B.3.Y..#',
    '#w.#...#a.#',
    '#####2#####',
    '#y4.....4y#',
    '#####1#####',
    '#a.#...#d.#',
    '#..Y...B..#',
    '#b.#.D.#H.#',
    '###########',
  ],
  [  // F6
    '###########',
    '#d.#.D.#H.#',
    '#.5Y...Y..#',
    '#h.#...#a.#',
    '#####1#####',
    '#b4.....4b#',
    '#####2#####',
    '#h.#...#y.#',
    '#.5B.G.B..#',
    '#d.##U##y.#',
    '###########',
  ],
  [  // F7
    '###########',
    '#y.##U##a.#',
    '#..B.3.B..#',
    '#a.#...#y.#',
    '#####2#####',
    '#b4.....4b#',
    '#####1#####',
    '#h.#P..#H.#',
    '#.5Y...Y..#',
    '#x.#.D.#d.#',
    '###########',
  ],
  [  // F8
    '###########',
    '#a.#.D.#d.#',
    '#..B...Y..#',
    '#y.#...#H.#',
    '#####1#####',
    '#b4.....4b#',
    '#####2#####',
    '#y.#...#h.#',
    '#..B.G.Y..#',
    '#h.##U##d.#',
    '###########',
  ],
  [  // F9
    '###########',
    '#b.##U##a.#',
    '#..Y.3.Y..#',
    '#b.#...#H.#',
    '#####2#####',
    '#y4.....4y#',
    '#####1#####',
    '#d.#...#a.#',
    '#.5B...B..#',
    '#h.#.D.#h.#',
    '###########',
  ],
  [  // F10
    '###########',
    '#H.#.D.#b.#',
    '#..B...R5.#',
    '#d.#...#w.#',
    '#####1#####',
    '#r4.....4y#',
    '#####2#####',
    '#d.#...#h.#',
    '#..Y.G.B..#',
    '#b.##U##a.#',
    '###########',
  ],
  [  // F11
    '###########',
    '#H.##U##r.#',
    '#..Y.3.B..#',
    '#b.#...#a.#',
    '#####2#####',
    '#y4.....4b#',
    '#####1#####',
    '#d.#P..#a.#',
    '#.5R...B..#',
    '#H.#.D.#H.#',
    '###########',
  ],
  [  // F12
    '###########',
    '#d.#.D.#h.#',
    '#..B...B..#',
    '#r.#...#x.#',
    '#####1#####',
    '#b4.....4y#',
    '#####2#####',
    '#a.#...#d.#',
    '#..R.G.Y5.#',
    '#H.##U##b.#',
    '###########',
  ],
  [  // F13
    '###########',
    '#d.##U##H.#',
    '#..B.3.B5.#',
    '#a.#...#r.#',
    '#####2#####',
    '#b4.....4b#',
    '#####1#####',
    '#y.#...#a.#',
    '#..R...Y..#',
    '#H.#.D.#h.#',
    '###########',
  ],
  [  // F14
    '###########',
    '#H.#.D.#d.#',
    '#..R...B..#',
    '#y.#...#H.#',
    '#####1#####',
    '#b4.....4b#',
    '#####2#####',
    '#H.#...#a.#',
    '#..Y.G.B..#',
    '#d.##U##r.#',
    '###########',
  ],
  [  // F15
    '###########',
    '#H.##U##a.#',
    '#..R.3.Y..#',
    '#d.#...#a.#',
    '#####2#####',
    '#b4.....4r#',
    '#####1#####',
    '#y.#P..#h.#',
    '#..R...B..#',
    '#w.#.D.#r.#',
    '###########',
  ],
  [  // F16
    '###########',
    '#h.#.D.#H.#',
    '#..R...R..#',
    '#d.#...#d.#',
    '#####1#####',
    '#r4.....4b#',
    '#####2#####',
    '#H.#...#r.#',
    '#..B.G.Y..#',
    '#y.##U##a.#',
    '###########',
  ],
  [  // F17
    '###########',
    '#d.##U##x.#',
    '#.5R.3.B5.#',
    '#a.#...#a.#',
    '#####2#####',
    '#b4.....4y#',
    '#####1#####',
    '#h.#...#r.#',
    '#..R...Y..#',
    '#h.#.D.#r.#',
    '###########',
  ],
  [  // F18
    '###########',
    '#a.#.D.#d.#',
    '#..R...R5.#',
    '#d.#...#H.#',
    '#####1#####',
    '#H4.....4y#',
    '#####2#####',
    '#r.#...#H.#',
    '#..Y.G.B..#',
    '#b.##U##r.#',
    '###########',
  ],
  [  // F19
    '###########',
    '#d.##U##h.#',
    '#.5Y.3.R5.#',
    '#H.#...#h.#',
    '#####2#####',
    '#r4.....4r#',
    '#####1#####',
    '#a.#P..#b.#',
    '#.5B...R..#',
    '#a.#.D.#y.#',
    '###########',
  ],
  [  // F20
    '###########',
    '#r.#.D.#a.#',
    '#..B...R5.#',
    '#r.#...#d.#',
    '#####1#####',
    '#b4.....4d#',
    '#####2#####',
    '#H.#...#H.#',
    '#..Y.3.R..#',
    '#H.##K##y.#',
    '###########',
  ],
];

/// 每層的怪物：字元 1~5 代表這層的「等級」（1~3 路上的怪、4 走廊守衛、5 房間守衛），K 是魔王。
const mtFloorMonsters = <Map<String, MtMonster>>[
  {  // F1
    '1': MtMonster('史萊姆', 0, 60, 12, 2, 3, 2),
    '2': MtMonster('史萊姆', 0, 60, 12, 2, 3, 2),
    '3': MtMonster('蝙蝠', 1, 60, 12, 2, 3, 2),
    '4': MtMonster('蝙蝠', 1, 60, 12, 2, 3, 2),
    '5': MtMonster('哥布林', 2, 56, 13, 4, 4, 2),
  },
  {  // F2
    '1': MtMonster('史萊姆', 0, 108, 19, 4, 5, 2),
    '2': MtMonster('蝙蝠', 1, 108, 19, 4, 5, 2),
    '3': MtMonster('蝙蝠', 1, 108, 20, 4, 5, 2),
    '4': MtMonster('蝙蝠', 1, 108, 20, 4, 5, 2),
    '5': MtMonster('哥布林', 2, 110, 20, 6, 7, 4),
    'G': MtMonster('史萊姆王', 0, 111, 23, 10, 16, 8, boss: true),
  },
  {  // F3
    '1': MtMonster('蝙蝠', 1, 146, 32, 6, 8, 4),
    '2': MtMonster('蝙蝠', 1, 146, 32, 6, 8, 4),
    '3': MtMonster('哥布林', 2, 146, 32, 6, 8, 4),
    '4': MtMonster('哥布林', 2, 146, 32, 6, 8, 4),
    '5': MtMonster('骷髏兵', 3, 154, 33, 8, 11, 6),
  },
  {  // F4
    '1': MtMonster('哥布林', 2, 216, 41, 8, 11, 6),
    '2': MtMonster('骷髏兵', 3, 216, 41, 8, 11, 6),
    '3': MtMonster('骷髏兵', 3, 216, 41, 8, 11, 6),
    '4': MtMonster('骷髏兵', 3, 216, 41, 8, 11, 6),
    '5': MtMonster('野狼', 4, 234, 43, 10, 15, 8),
    'G': MtMonster('洞窟蝠王', 1, 280, 47, 14, 34, 17, boss: true),
  },
  {  // F5
    '1': MtMonster('骷髏兵', 3, 278, 56, 9, 15, 8),
    '2': MtMonster('骷髏兵', 3, 278, 56, 9, 15, 8),
    '3': MtMonster('野狼', 4, 278, 57, 9, 15, 8),
    '4': MtMonster('野狼', 4, 278, 57, 9, 15, 8),
    '5': MtMonster('獸人', 5, 304, 58, 11, 19, 10),
  },
  {  // F6
    '1': MtMonster('骷髏兵', 3, 504, 66, 16, 18, 9),
    '2': MtMonster('野狼', 4, 504, 66, 16, 18, 9),
    '3': MtMonster('野狼', 4, 504, 67, 16, 18, 9),
    '4': MtMonster('野狼', 4, 504, 67, 16, 18, 9),
    '5': MtMonster('獸人', 5, 564, 70, 18, 24, 12),
    'G': MtMonster('骷髏王', 3, 734, 77, 22, 56, 28, boss: true),
  },
  {  // F7
    '1': MtMonster('野狼', 4, 582, 84, 18, 23, 12),
    '2': MtMonster('野狼', 4, 582, 84, 18, 23, 12),
    '3': MtMonster('獸人', 5, 582, 85, 18, 23, 12),
    '4': MtMonster('獸人', 5, 582, 85, 18, 23, 12),
    '5': MtMonster('幽靈', 6, 652, 88, 20, 29, 14),
  },
  {  // F8
    '1': MtMonster('獸人', 5, 714, 128, 22, 27, 14),
    '2': MtMonster('幽靈', 6, 714, 128, 22, 27, 14),
    '3': MtMonster('幽靈', 6, 714, 130, 22, 27, 14),
    '4': MtMonster('幽靈', 6, 714, 130, 22, 27, 14),
    '5': MtMonster('石像鬼', 7, 802, 133, 24, 35, 18),
    'G': MtMonster('森林獸王', 5, 1064, 145, 28, 82, 41, boss: true),
  },
  {  // F9
    '1': MtMonster('幽靈', 6, 838, 151, 24, 32, 16),
    '2': MtMonster('幽靈', 6, 838, 151, 24, 32, 16),
    '3': MtMonster('石像鬼', 7, 838, 153, 24, 32, 16),
    '4': MtMonster('石像鬼', 7, 838, 153, 24, 32, 16),
    '5': MtMonster('飛龍', 8, 944, 157, 26, 42, 21),
  },
  {  // F10
    '1': MtMonster('幽靈', 6, 1004, 166, 28, 37, 18),
    '2': MtMonster('石像鬼', 7, 1004, 166, 28, 37, 18),
    '3': MtMonster('石像鬼', 7, 1004, 168, 28, 37, 18),
    '4': MtMonster('石像鬼', 7, 1004, 168, 28, 37, 18),
    '5': MtMonster('飛龍', 8, 1134, 173, 30, 49, 24),
    'G': MtMonster('沼澤魔蛇', 4, 1521, 190, 34, 112, 56, boss: true),
  },
  {  // F11
    '1': MtMonster('石像鬼', 7, 1376, 189, 37, 43, 22),
    '2': MtMonster('石像鬼', 7, 1376, 189, 37, 43, 22),
    '3': MtMonster('飛龍', 8, 1376, 192, 37, 43, 22),
    '4': MtMonster('飛龍', 8, 1376, 192, 37, 43, 22),
    '5': MtMonster('惡魔', 9, 1562, 198, 39, 56, 28),
  },
  {  // F12
    '1': MtMonster('飛龍', 8, 1608, 213, 42, 49, 24),
    '2': MtMonster('惡魔', 9, 1608, 213, 42, 49, 24),
    '3': MtMonster('惡魔', 9, 1608, 217, 42, 49, 24),
    '4': MtMonster('惡魔', 9, 1608, 217, 42, 49, 24),
    '5': MtMonster('劇毒史萊姆', 0, 1828, 223, 44, 64, 32),
    'G': MtMonster('礦坑魔像', 7, 2481, 246, 48, 147, 74, boss: true),
  },
  {  // F13
    '1': MtMonster('惡魔', 9, 1772, 279, 44, 55, 28),
    '2': MtMonster('惡魔', 9, 1772, 279, 44, 55, 28),
    '3': MtMonster('劇毒史萊姆', 0, 1772, 283, 44, 55, 28),
    '4': MtMonster('劇毒史萊姆', 0, 1772, 283, 44, 55, 28),
    '5': MtMonster('吸血蝠', 1, 2016, 290, 46, 72, 36),
  },
  {  // F14
    '1': MtMonster('惡魔', 9, 2038, 300, 50, 62, 31),
    '2': MtMonster('劇毒史萊姆', 0, 2038, 300, 50, 62, 31),
    '3': MtMonster('劇毒史萊姆', 0, 2038, 304, 50, 62, 31),
    '4': MtMonster('劇毒史萊姆', 0, 2038, 304, 50, 62, 31),
    '5': MtMonster('吸血蝠', 1, 2320, 313, 52, 81, 40),
    'G': MtMonster('熔岩飛龍', 8, 3161, 342, 56, 186, 93, boss: true),
  },
  {  // F15
    '1': MtMonster('劇毒史萊姆', 0, 2230, 330, 52, 69, 34),
    '2': MtMonster('劇毒史萊姆', 0, 2230, 330, 52, 69, 34),
    '3': MtMonster('吸血蝠', 1, 2230, 335, 52, 69, 34),
    '4': MtMonster('吸血蝠', 1, 2230, 335, 52, 69, 34),
    '5': MtMonster('哥布林王', 2, 2540, 344, 54, 90, 45),
  },
  {  // F16
    '1': MtMonster('吸血蝠', 1, 2932, 353, 67, 76, 38),
    '2': MtMonster('哥布林王', 2, 2932, 353, 67, 76, 38),
    '3': MtMonster('哥布林王', 2, 2932, 358, 67, 76, 38),
    '4': MtMonster('哥布林王', 2, 2932, 358, 67, 76, 38),
    '5': MtMonster('骷髏騎士', 3, 3348, 369, 69, 99, 50),
    'G': MtMonster('冰霜幽靈', 6, 4587, 406, 73, 230, 115, boss: true),
  },
  {  // F17
    '1': MtMonster('哥布林王', 2, 3180, 389, 71, 84, 42),
    '2': MtMonster('哥布林王', 2, 3180, 389, 71, 84, 42),
    '3': MtMonster('骷髏騎士', 3, 3180, 395, 71, 84, 42),
    '4': MtMonster('骷髏騎士', 3, 3180, 395, 71, 84, 42),
    '5': MtMonster('地獄犬', 4, 3630, 406, 73, 110, 55),
  },
  {  // F18
    '1': MtMonster('哥布林王', 2, 3574, 464, 77, 92, 46),
    '2': MtMonster('骷髏騎士', 3, 3574, 464, 77, 92, 46),
    '3': MtMonster('骷髏騎士', 3, 3574, 470, 77, 92, 46),
    '4': MtMonster('骷髏騎士', 3, 3574, 470, 77, 92, 46),
    '5': MtMonster('地獄犬', 4, 4084, 483, 79, 120, 60),
    'G': MtMonster('天空魔將', 9, 5607, 529, 83, 277, 138, boss: true),
  },
  {  // F19
    '1': MtMonster('骷髏騎士', 3, 3854, 503, 81, 101, 50),
    '2': MtMonster('骷髏騎士', 3, 3854, 503, 81, 101, 50),
    '3': MtMonster('地獄犬', 4, 3854, 510, 81, 101, 50),
    '4': MtMonster('地獄犬', 4, 3854, 510, 81, 101, 50),
    '5': MtMonster('獸人魔將', 5, 4406, 524, 83, 131, 66),
  },
  {  // F20
    '1': MtMonster('地獄犬', 4, 4340, 529, 89, 110, 55),
    '2': MtMonster('獸人魔將', 5, 4340, 529, 89, 110, 55),
    '3': MtMonster('獸人魔將', 5, 4340, 537, 89, 110, 55),
    '4': MtMonster('獸人魔將', 5, 4340, 537, 89, 110, 55),
    '5': MtMonster('獸人魔將', 5, 4962, 553, 91, 143, 72),
    'K': MtMonster('魔王', 9, 4976, 794, 133, 0, 0, boss: true),
  },
];

const _mtBandNames = ['草原', '洞窟', '墓地', '森林', '沼澤', '礦坑', '熔岩', '冰霜', '天空', '魔界'];
final mtFloorNames = [for (var f = 0; f < mtFloors; f++) '${_mtBandNames[f ~/ 2]}${f.isEven ? '外圍' : '深處'}'];
final mtBands = [for (var f = 0; f < mtFloors; f++) f ~/ 2]; // 對應百層塔的區域造型

/// 勇者打怪物會掉多少血；打不贏回傳 null。
int? mtLoss(int hp, int atk, int def, MtMonster m) {
  final dmg = atk - m.def;
  if (dmg <= 0) return null;
  final turns = (m.hp + dmg - 1) ~/ dmg;
  final per = math.max(0, m.atk - def);
  final loss = (turns - 1) * per;
  return loss >= hp ? null : loss;
}

/// 一場戰鬥的紀錄，格式跟百層塔 tower_game.fight 一樣，可以直接餵給 BattleStage。
List<Map<String, dynamic>> mtBattleLog(int hp, int atk, int def, MtMonster m) {
  final log = <Map<String, dynamic>>[];
  var mhp = m.hp, h = hp;
  final dmg = math.max(0, atk - m.def), per = math.max(0, m.atk - def);
  while (mhp > 0 && h > 0) {
    mhp = math.max(0, mhp - dmg);
    log.add({'a': 'h', 'd': 0, 'dmg': dmg, 'crit': false, 'miss': dmg == 0, 'hp': mhp});
    if (mhp <= 0) break;
    h = math.max(0, h - per);
    log.add({'a': 0, 'd': 'h', 'dmg': per, 'crit': false, 'miss': per == 0, 'hp': h});
  }
  return log;
}

class MtGame {
  late List<List<List<String>>> grid; // [floor][row][col]
  int floor = 0, r = 9, c = 5;
  int hp = mtStartHp, atk = mtStartAtk, def = mtStartDef;
  int ky = 0, kb = 0, kr = 0;
  int exp = 0, gold = 0;
  int get lv => mtLevel(exp);
  int facing = 1; // 1 朝右、-1 朝左（畫面用）
  int steps = 0;
  bool won = false;

  MtGame() {
    grid = [
      for (final f in mtMaps) [for (final row in f) row.split('')]
    ];
    _place(0, 'S');
  }

  void _place(int f, String ch) {
    for (var i = 0; i < mtSize; i++) {
      for (var j = 0; j < mtSize; j++) {
        if (grid[f][i][j] == ch) {
          floor = f;
          r = i;
          c = j;
          if (ch == 'S') grid[f][i][j] = '.';
          return;
        }
      }
    }
  }

  String at(int f, int i, int j) => grid[f][i][j];

  /// 站到 (nr,nc) 會發生什麼。回傳 null = 擋住（牆、沒鑰匙的門、打不贏的怪）。
  /// 實際動作交給 [move]；這裡只做預覽，給畫面顯示傷害。
  String? blockedReason(int nr, int nc) {
    if (nr < 0 || nc < 0 || nr >= mtSize || nc >= mtSize) return '牆';
    final t = grid[floor][nr][nc];
    if (t == '#') return '牆';
    if (t == 'Y' && ky == 0) return '需要金鑰匙';
    if (t == 'B' && kb == 0) return '需要銀鑰匙';
    if (t == 'R' && kr == 0) return '需要魔鑰匙';
    final m = mtMonsterAt(floor, t);
    if (m != null && mtLoss(hp, atk, def, m) == null) return '打不贏${m.name}';
    return null;
  }

  /// 往 (dr,dc) 走一步。回傳事件：'wall'、'move'、'item:名稱'、'door'、'fight:怪物符號'（需由畫面播戰鬥，戰鬥後呼叫 [resolveFight]）、'stairs'、'win'。
  String move(int dr, int dc) {
    final nr = r + dr, nc = c + dc;
    if (dc != 0) facing = dc;
    if (nr >= 0 && nc >= 0 && nr < mtSize && nc < mtSize && grid[floor][nr][nc] == 'P') return 'shop';
    final why = blockedReason(nr, nc);
    if (why != null) return 'blocked:$why';
    final t = grid[floor][nr][nc];
    if (mtMonsterAt(floor, t) != null) return 'fight:$t:$nr:$nc';
    switch (t) {
      case 'Y':
        ky--;
        grid[floor][nr][nc] = '.';
        steps++;
        return 'door';
      case 'B':
        kb--;
        grid[floor][nr][nc] = '.';
        steps++;
        return 'door';
      case 'R':
        kr--;
        grid[floor][nr][nc] = '.';
        steps++;
        return 'door';
    }
    r = nr;
    c = nc;
    steps++;
    if (t == 'U' && floor < mtFloors - 1) {
      floor++;
      _place(floor, 'D');
      return 'stairs';
    }
    if (t == 'D' && floor > 0) {
      floor--;
      _place(floor, 'U');
      return 'stairs';
    }
    final it = mtItems[t];
    if (it != null) {
      hp += mtScaled(it.hp, floor);
      atk += mtScaled(it.atk, floor);
      def += mtScaled(it.def, floor);
      ky += it.ky;
      kb += it.kb;
      kr += it.kr;
      grid[floor][nr][nc] = '.';
      return 'item:${it.name}';
    }
    return 'move';
  }

  /// 戰鬥動畫播完後套用結果：扣血、怪物消失、勇者站到怪物的格子。
  /// 回傳升了幾級。
  int resolveFight(int nr, int nc, int heroHpAfter) {
    final t = grid[floor][nr][nc];
    final m = mtMonsterAt(floor, t)!;
    grid[floor][nr][nc] = '.';
    hp = heroHpAfter;
    final before = lv;
    exp += m.exp;
    gold += m.gold;
    final up = lv - before;
    if (up > 0) {
      atk += mtLevelAtk * up;
      def += mtLevelDef * up;
      hp += mtLevelHp * up;
    }
    r = nr;
    c = nc;
    steps++;
    if (t == 'K') won = true;
    return up;
  }

  /// 存檔用：整個狀態轉成 JSON（網頁重新整理、版本更新後可以接著玩）。
  Map<String, dynamic> toJson() => {
        'v': 5,
        'grid': [for (final f in grid) [for (final row in f) row.join()]],
        'floor': floor, 'r': r, 'c': c, 'hp': hp, 'atk': atk, 'def': def,
        'ky': ky, 'kb': kb, 'kr': kr, 'exp': exp, 'gold': gold, 'facing': facing, 'steps': steps, 'won': won,
      };

  /// 讀檔；格式不對（例如地圖改版）回傳 null。
  static MtGame? fromJson(Map<String, dynamic> j) {
    try {
      final rows = j['grid'] as List;
      if (j['v'] != 5 || rows.length != mtFloors) return null;
      final g = MtGame();
      for (var f = 0; f < mtFloors; f++) {
        final fr = rows[f] as List;
        if (fr.length != mtSize) return null;
        for (var i = 0; i < mtSize; i++) {
          final line = fr[i] as String;
          if (line.length != mtSize) return null;
          g.grid[f][i] = line.split('');
        }
      }
      g.floor = j['floor'] as int;
      g.r = j['r'] as int;
      g.c = j['c'] as int;
      g.hp = j['hp'] as int;
      g.atk = j['atk'] as int;
      g.def = j['def'] as int;
      g.ky = j['ky'] as int;
      g.kb = j['kb'] as int;
      g.kr = j['kr'] as int;
      g.exp = j['exp'] as int;
      g.gold = j['gold'] as int;
      g.facing = j['facing'] as int;
      g.steps = j['steps'] as int;
      g.won = j['won'] as bool;
      return g;
    } catch (_) {
      return null;
    }
  }

  bool buy(MtOffer o) {
    if (gold < o.price) return false;
    gold -= o.price;
    hp += o.hp;
    atk += o.atk;
    def += o.def;
    ky += o.ky;
    kb += o.kb;
    // 每位商人只賣一樣，買完就走人
    for (var i = 0; i < mtSize; i++) {
      for (var j = 0; j < mtSize; j++) {
        if (grid[floor][i][j] == 'P') grid[floor][i][j] = '.';
      }
    }
    return true;
  }
}
