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
    '#a.##U##y.#',
    '#.5B.3.Y..#',
    '#a.#...#d.#',
    '#####2#####',
    '#d4.....4h#',
    '#####1#####',
    '#h.#...#b.#',
    '#..Y...Y..#',
    '#y.#.S.#H.#',
    '###########',
  ],
  [  // F2
    '###########',
    '#h.#.D.#y.#',
    '#..Y...Y..#',
    '#d.#...#y.#',
    '#####1#####',
    '#d4.....4a#',
    '#####2#####',
    '#H.#...#h.#',
    '#..B.3.Y..#',
    '#a.##U##b.#',
    '###########',
  ],
  [  // F3
    '###########',
    '#y.##U##a.#',
    '#..B.3.Y5.#',
    '#h.#...#d.#',
    '#####2#####',
    '#H4.....4h#',
    '#####1#####',
    '#d.#P..#y.#',
    '#.5Y...Y..#',
    '#a.#.D.#b.#',
    '###########',
  ],
  [  // F4
    '###########',
    '#h.#.D.#b.#',
    '#..Y...Y..#',
    '#y.#...#H.#',
    '#####1#####',
    '#a4.....4d#',
    '#####2#####',
    '#h.#...#a.#',
    '#..B.3.Y5.#',
    '#y.##U##d.#',
    '###########',
  ],
  [  // F5
    '###########',
    '#b.##U##w.#',
    '#..B.3.Y5.#',
    '#y.#...#a.#',
    '#####2#####',
    '#y4.....4h#',
    '#####1#####',
    '#h.#...#h.#',
    '#.5B...Y5.#',
    '#d.#.D.#a.#',
    '###########',
  ],
  [  // F6
    '###########',
    '#y.#.D.#a.#',
    '#..B...Y..#',
    '#y.#...#b.#',
    '#####1#####',
    '#a4.....4d#',
    '#####2#####',
    '#H.#...#H.#',
    '#.5Y.3.B..#',
    '#d.##U##h.#',
    '###########',
  ],
  [  // F7
    '###########',
    '#x.##U##b.#',
    '#.5B.3.Y..#',
    '#a.#...#y.#',
    '#####2#####',
    '#d4.....4H#',
    '#####1#####',
    '#y.#P..#h.#',
    '#..Y...B..#',
    '#h.#.D.#d.#',
    '###########',
  ],
  [  // F8
    '###########',
    '#a.#.D.#h.#',
    '#..Y...Y..#',
    '#y.#...#H.#',
    '#####1#####',
    '#H4.....4a#',
    '#####2#####',
    '#y.#...#d.#',
    '#..B.3.B5.#',
    '#b.##U##d.#',
    '###########',
  ],
  [  // F9
    '###########',
    '#y.##U##d.#',
    '#..Y.3.Y5.#',
    '#b.#...#a.#',
    '#####2#####',
    '#a4.....4d#',
    '#####1#####',
    '#H.#...#b.#',
    '#..B...B..#',
    '#h.#.D.#H.#',
    '###########',
  ],
  [  // F10
    '###########',
    '#a.#.D.#b.#',
    '#.5B...Y..#',
    '#w.#...#y.#',
    '#####1#####',
    '#a4.....4d#',
    '#####2#####',
    '#H.#...#d.#',
    '#..R.3.B..#',
    '#h.##U##b.#',
    '###########',
  ],
  [  // F11
    '###########',
    '#h.##U##r.#',
    '#..B.3.Y..#',
    '#b.#...#h.#',
    '#####2#####',
    '#a4.....4d#',
    '#####1#####',
    '#b.#P..#a.#',
    '#..R...B5.#',
    '#d.#.D.#H.#',
    '###########',
  ],
  [  // F12
    '###########',
    '#x.#.D.#b.#',
    '#.5Y...B..#',
    '#a.#...#r.#',
    '#####1#####',
    '#H4.....4H#',
    '#####2#####',
    '#d.#...#h.#',
    '#.5B.3.R..#',
    '#d.##U##y.#',
    '###########',
  ],
  [  // F13
    '###########',
    '#y.##U##d.#',
    '#.5Y.3.R5.#',
    '#h.#...#a.#',
    '#####2#####',
    '#h4.....4b#',
    '#####1#####',
    '#r.#...#a.#',
    '#..B...B5.#',
    '#h.#.D.#d.#',
    '###########',
  ],
  [  // F14
    '###########',
    '#H.#.D.#h.#',
    '#..Y...B..#',
    '#d.#...#y.#',
    '#####1#####',
    '#H4.....4a#',
    '#####2#####',
    '#a.#...#b.#',
    '#..R.3.B..#',
    '#d.##U##b.#',
    '###########',
  ],
  [  // F15
    '###########',
    '#r.##U##d.#',
    '#..R.3.R..#',
    '#r.#...#h.#',
    '#####2#####',
    '#w4.....4a#',
    '#####1#####',
    '#h.#P..#y.#',
    '#..B...Y..#',
    '#d.#.D.#H.#',
    '###########',
  ],
  [  // F16
    '###########',
    '#y.#.D.#h.#',
    '#..Y...R..#',
    '#h.#...#h.#',
    '#####1#####',
    '#a4.....4d#',
    '#####2#####',
    '#a.#...#r.#',
    '#..R.3.B..#',
    '#b.##U##d.#',
    '###########',
  ],
  [  // F17
    '###########',
    '#r.##U##y.#',
    '#..R.3.B..#',
    '#d.#...#h.#',
    '#####2#####',
    '#a4.....4x#',
    '#####1#####',
    '#h.#...#a.#',
    '#..Y...R..#',
    '#h.#.D.#r.#',
    '###########',
  ],
  [  // F18
    '###########',
    '#H.#.D.#r.#',
    '#..R...B..#',
    '#b.#...#h.#',
    '#####1#####',
    '#d4.....4a#',
    '#####2#####',
    '#r.#...#d.#',
    '#..Y.3.R..#',
    '#h.##U##a.#',
    '###########',
  ],
  [  // F19
    '###########',
    '#d.##U##a.#',
    '#.5Y.3.R..#',
    '#d.#...#y.#',
    '#####2#####',
    '#a4.....4H#',
    '#####1#####',
    '#r.#P..#H.#',
    '#..R...B..#',
    '#h.#.D.#b.#',
    '###########',
  ],
  [  // F20
    '###########',
    '#r.#.D.#h.#',
    '#..Y...R..#',
    '#y.#...#H.#',
    '#####1#####',
    '#a4.....4H#',
    '#####2#####',
    '#d.#...#a.#',
    '#..B.3.R5.#',
    '#r.##K##d.#',
    '###########',
  ],
];

/// 每層的怪物：字元 1~5 代表這層的「等級」（1~3 路上的怪、4 走廊守衛、5 房間守衛），K 是魔王。
const mtFloorMonsters = <Map<String, MtMonster>>[
  {  // F1
    '1': MtMonster('史萊姆', 0, 30, 15, 2, 3, 2),
    '2': MtMonster('史萊姆', 0, 30, 15, 2, 3, 2),
    '3': MtMonster('蝙蝠', 1, 30, 16, 2, 3, 2),
    '4': MtMonster('蝙蝠', 1, 30, 16, 2, 3, 2),
    '5': MtMonster('哥布林', 2, 28, 16, 4, 4, 2),
  },
  {  // F2
    '1': MtMonster('史萊姆', 0, 38, 23, 3, 5, 2),
    '2': MtMonster('蝙蝠', 1, 38, 23, 3, 5, 2),
    '3': MtMonster('蝙蝠', 1, 38, 24, 3, 5, 2),
    '4': MtMonster('蝙蝠', 1, 38, 24, 3, 5, 2),
    '5': MtMonster('哥布林', 2, 36, 25, 5, 7, 4),
  },
  {  // F3
    '1': MtMonster('蝙蝠', 1, 50, 29, 4, 8, 4),
    '2': MtMonster('蝙蝠', 1, 50, 29, 4, 8, 4),
    '3': MtMonster('哥布林', 2, 50, 30, 4, 8, 4),
    '4': MtMonster('哥布林', 2, 50, 30, 4, 8, 4),
    '5': MtMonster('骷髏兵', 3, 50, 32, 6, 11, 6),
  },
  {  // F4
    '1': MtMonster('哥布林', 2, 63, 35, 4, 11, 6),
    '2': MtMonster('骷髏兵', 3, 63, 35, 4, 11, 6),
    '3': MtMonster('骷髏兵', 3, 63, 36, 4, 11, 6),
    '4': MtMonster('骷髏兵', 3, 63, 36, 4, 11, 6),
    '5': MtMonster('野狼', 4, 64, 38, 6, 15, 8),
  },
  {  // F5
    '1': MtMonster('骷髏兵', 3, 88, 45, 6, 15, 8),
    '2': MtMonster('骷髏兵', 3, 88, 45, 6, 15, 8),
    '3': MtMonster('野狼', 4, 88, 46, 6, 15, 8),
    '4': MtMonster('野狼', 4, 88, 46, 6, 15, 8),
    '5': MtMonster('獸人', 5, 93, 49, 8, 19, 10),
  },
  {  // F6
    '1': MtMonster('骷髏兵', 3, 152, 50, 10, 18, 9),
    '2': MtMonster('野狼', 4, 152, 50, 10, 18, 9),
    '3': MtMonster('野狼', 4, 152, 52, 10, 18, 9),
    '4': MtMonster('野狼', 4, 152, 52, 10, 18, 9),
    '5': MtMonster('獸人', 5, 166, 55, 12, 24, 12),
  },
  {  // F7
    '1': MtMonster('野狼', 4, 186, 61, 12, 23, 12),
    '2': MtMonster('野狼', 4, 186, 61, 12, 23, 12),
    '3': MtMonster('獸人', 5, 186, 63, 12, 23, 12),
    '4': MtMonster('獸人', 5, 186, 63, 12, 23, 12),
    '5': MtMonster('幽靈', 6, 205, 67, 14, 29, 14),
  },
  {  // F8
    '1': MtMonster('獸人', 5, 207, 73, 12, 27, 14),
    '2': MtMonster('幽靈', 6, 207, 73, 12, 27, 14),
    '3': MtMonster('幽靈', 6, 207, 75, 12, 27, 14),
    '4': MtMonster('幽靈', 6, 207, 75, 12, 27, 14),
    '5': MtMonster('石像鬼', 7, 228, 80, 14, 35, 18),
  },
  {  // F9
    '1': MtMonster('幽靈', 6, 249, 79, 14, 32, 16),
    '2': MtMonster('幽靈', 6, 249, 79, 14, 32, 16),
    '3': MtMonster('石像鬼', 7, 249, 81, 14, 32, 16),
    '4': MtMonster('石像鬼', 7, 249, 81, 14, 32, 16),
    '5': MtMonster('飛龍', 8, 277, 85, 16, 42, 21),
  },
  {  // F10
    '1': MtMonster('幽靈', 6, 295, 92, 17, 37, 18),
    '2': MtMonster('石像鬼', 7, 295, 92, 17, 37, 18),
    '3': MtMonster('石像鬼', 7, 295, 94, 17, 37, 18),
    '4': MtMonster('石像鬼', 7, 295, 94, 17, 37, 18),
    '5': MtMonster('飛龍', 8, 329, 99, 19, 49, 24),
  },
  {  // F11
    '1': MtMonster('石像鬼', 7, 348, 105, 19, 43, 22),
    '2': MtMonster('石像鬼', 7, 348, 105, 19, 43, 22),
    '3': MtMonster('飛龍', 8, 348, 108, 19, 43, 22),
    '4': MtMonster('飛龍', 8, 348, 108, 19, 43, 22),
    '5': MtMonster('惡魔', 9, 389, 113, 21, 56, 28),
  },
  {  // F12
    '1': MtMonster('飛龍', 8, 408, 119, 21, 49, 24),
    '2': MtMonster('惡魔', 9, 408, 119, 21, 49, 24),
    '3': MtMonster('惡魔', 9, 408, 122, 21, 49, 24),
    '4': MtMonster('惡魔', 9, 408, 122, 21, 49, 24),
    '5': MtMonster('劇毒史萊姆', 0, 458, 128, 23, 64, 32),
  },
  {  // F13
    '1': MtMonster('惡魔', 9, 447, 127, 22, 55, 28),
    '2': MtMonster('惡魔', 9, 447, 127, 22, 55, 28),
    '3': MtMonster('劇毒史萊姆', 0, 447, 131, 22, 55, 28),
    '4': MtMonster('劇毒史萊姆', 0, 447, 131, 22, 55, 28),
    '5': MtMonster('吸血蝠', 1, 502, 137, 24, 72, 36),
  },
  {  // F14
    '1': MtMonster('惡魔', 9, 513, 143, 25, 62, 31),
    '2': MtMonster('劇毒史萊姆', 0, 513, 143, 25, 62, 31),
    '3': MtMonster('劇毒史萊姆', 0, 513, 146, 25, 62, 31),
    '4': MtMonster('劇毒史萊姆', 0, 513, 146, 25, 62, 31),
    '5': MtMonster('吸血蝠', 1, 578, 153, 27, 81, 40),
  },
  {  // F15
    '1': MtMonster('劇毒史萊姆', 0, 588, 148, 28, 69, 34),
    '2': MtMonster('劇毒史萊姆', 0, 588, 148, 28, 69, 34),
    '3': MtMonster('吸血蝠', 1, 588, 151, 28, 69, 34),
    '4': MtMonster('吸血蝠', 1, 588, 151, 28, 69, 34),
    '5': MtMonster('哥布林王', 2, 664, 159, 30, 90, 45),
  },
  {  // F16
    '1': MtMonster('吸血蝠', 1, 885, 156, 40, 76, 38),
    '2': MtMonster('哥布林王', 2, 885, 156, 40, 76, 38),
    '3': MtMonster('哥布林王', 2, 885, 160, 40, 76, 38),
    '4': MtMonster('哥布林王', 2, 885, 160, 40, 76, 38),
    '5': MtMonster('骷髏騎士', 3, 1006, 167, 42, 99, 50),
  },
  {  // F17
    '1': MtMonster('哥布林王', 2, 980, 173, 43, 84, 42),
    '2': MtMonster('哥布林王', 2, 980, 173, 43, 84, 42),
    '3': MtMonster('骷髏騎士', 3, 980, 177, 43, 84, 42),
    '4': MtMonster('骷髏騎士', 3, 980, 177, 43, 84, 42),
    '5': MtMonster('地獄犬', 4, 1114, 185, 45, 110, 55),
  },
  {  // F18
    '1': MtMonster('哥布林王', 2, 1078, 228, 47, 92, 46),
    '2': MtMonster('骷髏騎士', 3, 1078, 228, 47, 92, 46),
    '3': MtMonster('骷髏騎士', 3, 1078, 233, 47, 92, 46),
    '4': MtMonster('骷髏騎士', 3, 1078, 233, 47, 92, 46),
    '5': MtMonster('地獄犬', 4, 1227, 241, 49, 120, 60),
  },
  {  // F19
    '1': MtMonster('骷髏騎士', 3, 1204, 250, 50, 101, 50),
    '2': MtMonster('骷髏騎士', 3, 1204, 250, 50, 101, 50),
    '3': MtMonster('地獄犬', 4, 1204, 254, 50, 101, 50),
    '4': MtMonster('地獄犬', 4, 1204, 254, 50, 101, 50),
    '5': MtMonster('獸人魔將', 5, 1371, 263, 52, 131, 66),
  },
  {  // F20
    '1': MtMonster('地獄犬', 4, 1317, 255, 54, 110, 55),
    '2': MtMonster('獸人魔將', 5, 1317, 255, 54, 110, 55),
    '3': MtMonster('獸人魔將', 5, 1317, 259, 54, 110, 55),
    '4': MtMonster('獸人魔將', 5, 1317, 259, 54, 110, 55),
    '5': MtMonster('獸人魔將', 5, 1501, 269, 56, 143, 72),
    'K': MtMonster('魔王', 9, 2090, 507, 90, 0, 0, boss: true),
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

  bool buy(MtOffer o) {
    if (gold < o.price) return false;
    gold -= o.price;
    hp += o.hp;
    atk += o.atk;
    def += o.def;
    ky += o.ky;
    kb += o.kb;
    return true;
  }
}
