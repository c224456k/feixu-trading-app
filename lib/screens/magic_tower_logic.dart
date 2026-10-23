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
  final int hp, atk, def;
  final bool boss;
  const MtMonster(this.name, this.kind, this.hp, this.atk, this.def, {this.boss = false});
}

const mtMonsters = <String, MtMonster>{
  '1': MtMonster('史萊姆', 0, 35, 20, 1),
  '2': MtMonster('蝙蝠', 1, 38, 32, 2),
  '3': MtMonster('哥布林', 2, 50, 42, 4),
  '4': MtMonster('骷髏兵', 3, 60, 52, 8),
  '5': MtMonster('野狼', 4, 80, 62, 10),
  '6': MtMonster('獸人', 5, 110, 72, 18),
  '7': MtMonster('石像鬼', 7, 90, 55, 30),
  '8': MtMonster('惡魔', 9, 180, 100, 28),
  'K': MtMonster('魔王', 9, 320, 90, 26, boss: true),
};

// 道具：字元 → (說明, 血, 攻, 防, 黃鑰匙, 藍鑰匙, 紅鑰匙)
class MtItem {
  final String name;
  final int hp, atk, def, ky, kb, kr;
  const MtItem(this.name, {this.hp = 0, this.atk = 0, this.def = 0, this.ky = 0, this.kb = 0, this.kr = 0});
}

const mtItems = <String, MtItem>{
  'y': MtItem('黃鑰匙', ky: 1),
  'b': MtItem('藍鑰匙', kb: 1),
  'r': MtItem('紅鑰匙', kr: 1),
  'h': MtItem('小血瓶', hp: 150),
  'H': MtItem('大血瓶', hp: 350),
  'a': MtItem('紅寶石', atk: 3),
  'd': MtItem('藍寶石', def: 3),
  'w': MtItem('魔劍', atk: 12),
  'x': MtItem('聖盾', def: 12),
};

const mtStartHp = 1000, mtStartAtk = 10, mtStartDef = 10;

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
    '#a.#...#y.#',
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
    '#x.#...#H.#',
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
    if (t == 'Y' && ky == 0) return '需要黃鑰匙';
    if (t == 'B' && kb == 0) return '需要藍鑰匙';
    if (t == 'R' && kr == 0) return '需要紅鑰匙';
    final m = mtMonsters[t];
    if (m != null && mtLoss(hp, atk, def, m) == null) return '打不贏${m.name}';
    return null;
  }

  /// 往 (dr,dc) 走一步。回傳事件：'wall'、'move'、'item:名稱'、'door'、'fight:怪物符號'（需由畫面播戰鬥，戰鬥後呼叫 [resolveFight]）、'stairs'、'win'。
  String move(int dr, int dc) {
    final nr = r + dr, nc = c + dc;
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
  void resolveFight(int nr, int nc, int heroHpAfter) {
    final t = grid[floor][nr][nc];
    grid[floor][nr][nc] = '.';
    hp = heroHpAfter;
    r = nr;
    c = nc;
    steps++;
    if (t == 'K') won = true;
  }
}
