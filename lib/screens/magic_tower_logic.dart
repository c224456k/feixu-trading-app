import 'dart:math' as math;

// 魔塔（5 層試玩版）的規則與地圖。純邏輯、不依賴 Flutter，solver 腳本也用這份來驗證「有解」。
//
// 規則（經典魔塔）：勇者走格子，撞到怪物就戰鬥——勇者先出手，雙方每回合各打一下，
// 傷害 = 攻擊 − 對方防禦（最少 0），一直打到有一方血量歸零；撿到的道具永久加成，鑰匙開同色的門。
// 戰鬥的結果完全看數字、沒有隨機，所以走到怪物旁邊就能先算出「會掉多少血」。

const mtSize = 11;
const mtFloors = 5;

class MtMonster {
  final String name;
  final int kind; // MonsterPainter 的種類（跟百層塔共用）
  final int hp, atk, def, exp, gold;
  final bool boss;
  const MtMonster(this.name, this.kind, this.hp, this.atk, this.def, this.exp, this.gold, {this.boss = false});
}

const mtMonsters = <String, MtMonster>{
  '1': MtMonster('史萊姆', 0, 35, 24, 1, 3, 3),
  '2': MtMonster('蝙蝠', 1, 38, 37, 2, 5, 5),
  '3': MtMonster('哥布林', 2, 50, 50, 4, 8, 8),
  '4': MtMonster('骷髏兵', 3, 60, 61, 8, 12, 12),
  '5': MtMonster('野狼', 4, 80, 72, 10, 18, 18),
  '6': MtMonster('獸人', 5, 110, 83, 18, 26, 26),
  '7': MtMonster('石像鬼', 7, 90, 64, 30, 30, 40),
  '8': MtMonster('惡魔', 9, 180, 112, 28, 60, 80),
  'K': MtMonster('魔王', 9, 320, 150, 26, 0, 0, boss: true),
};

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

const mtStartHp = 800, mtStartAtk = 12, mtStartDef = 10;

/// 勇者等級：累積經驗到門檻就升級，每升一級 +攻 +防 +血（當場補上）。
const mtExpAt = [0, 20, 50, 100, 170, 260, 370, 500, 650, 820]; // 第 i+1 級需要的累積經驗
const mtLevelAtk = 3, mtLevelDef = 3, mtLevelHp = 80;
int mtLevel(int exp) {
  var lv = 1;
  for (var i = 1; i < mtExpAt.length; i++) {
    if (exp >= mtExpAt[i]) lv = i + 1;
  }
  return lv;
}

/// 商人：金幣只能在魔塔裡用。(名稱, 價格, 血, 攻, 防, 金鑰匙, 銀鑰匙)
class MtOffer {
  final String name;
  final int price, hp, atk, def, ky, kb;
  const MtOffer(this.name, this.price, {this.hp = 0, this.atk = 0, this.def = 0, this.ky = 0, this.kb = 0});
}

const mtShop = <MtOffer>[
  MtOffer('生命 +400', 40, hp: 400),
  MtOffer('攻擊 +4', 60, atk: 4),
  MtOffer('防禦 +4', 60, def: 4),
  MtOffer('金鑰匙 ×1', 25, ky: 1),
  MtOffer('銀鑰匙 ×1', 45, kb: 1),
];

/// 每層一張 11x11。# 牆　. 空地　S 起點　U 上樓　D 下樓　YBR 黃藍紅門　數字/K 怪物　其餘見 mtItems。
/// 上下樓的位置固定在中間欄（c5）的最上/最下，奇偶層交替。
const mtMaps = <List<String>>[
  [
    '###########',
    '#y.#.U.#a.#',
    '#..Y.1.Y..#',
    '#d.#...#h.#',
    '####.2.####',
    '#y1.....1y#',
    '####.3.####',
    '#d.#...#a.#',
    '#..Y...Y..#',
    '#h.#.S.#hy#',
    '###########',
  ],
  [
    '###########',
    '#h.#.D.#d.#',
    '#..B.4.Y..#',
    '#a.#P..#y.#',
    '####.2.####',
    '#y2.....2b#',
    '####.3.####',
    '#b.#...#h.#',
    '#..Y...B..#',
    '#H.#.U.#a.#',
    '###########',
  ],
  [
    '###########',
    '#b.#.U.#a.#',
    '#..B.5.Y..#',
    '#d.#...#d.#',
    '####.4.####',
    '#y4.....4b#',
    '####.5.####',
    '#r.#...#H.#',
    '#..Y...B.y#',
    '#h.#.D.#7a#',
    '###########',
  ],
  [
    '###########',
    '#h.#.D.#d.#',
    '#..R.6.Y..#',
    '#w.#...#y.#',
    '####.5.####',
    '#y6.....6b#',
    '####.8.####',
    '#x.#P..#H.#',
    '#..Y...B..#',
    '#a.#.U.#a.#',
    '###########',
  ],
  [
    '###########',
    '#H.#.K.#H.#',
    '#..B.6.Y..#',
    '#a.#...#d.#',
    '####.7.####',
    '#y6.....6b#',
    '####.6.####',
    '#y.#...#y.#',
    '#..Y...Y..#',
    '#h.#.D.#H.#',
    '###########',
  ],
];

const mtFloorNames = ['草原', '洞窟', '墓地', '森林', '魔界'];
const mtBands = [0, 1, 2, 3, 9]; // 對應百層塔的區域造型

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
    final m = mtMonsters[t];
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
    if (mtMonsters.containsKey(t)) return 'fight:$t:$nr:$nc';
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
      hp += it.hp;
      atk += it.atk;
      def += it.def;
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
    final m = mtMonsters[t]!;
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
