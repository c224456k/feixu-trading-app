// 弓箭肉鴿（仿弓箭傳說）：純 Dart 規則與模擬，不依賴 Flutter，可以用 dart run 跑機器人平衡測試。
// 站著不動才會自動射最近的敵人，移動時不射擊；每關 4 個戰鬥房 + 頭目房，升級三選一技能。
import 'dart:math' as math;

const int rgCols = 9;
const int rgRows = 15;
const double rgDt = 1 / 60;
const int rgChapters = 20;
const int rgRoomsPerChapter = 5; // 0~3 一般房，4 頭目房

// 20 關 = 5 種場景 × 4 階（每 5 關一輪，越後面越強；第 5、10、15、20 關是魔龍）
const rgChapterNames = [
  '翠綠草原', '幽暗洞窟', '亡者墓地', '熔岩地獄', '魔王城・城門', //
  '黃昏草原', '深淵洞窟', '腐朽墓地', '煉獄火山', '魔王城・外廷', //
  '暴風草原', '水晶洞窟', '冥王墓地', '焦土熔爐', '魔王城・迴廊', //
  '血月草原', '虛空洞窟', '死神墓地', '終焉熔岩', '魔王城・王座',
];
const rgThemeBands = [0, 1, 2, 6, 9]; // MonsterPainter 的區域配色（依場景）
// 每關怪物血量／傷害倍率（用 bot 校準過）
double rgHpMul(int c) => 1.0 + 0.75 * c + 0.16 * c * c;
double rgDmgMul(int c) => 1.0 + 0.2 * c + 0.01 * c * c;
const _mobHpMul = 1.3; // 小怪額外倍率（頭目不吃）
const _mobDmgMul = 1.25;
const _roomWaves = [0, 1, 1, 2]; // 各一般房的增援波數（剩 1 隻時從傳送門冒出來）

class RgSkillDef {
  final String id, name, icon, desc;
  final int max;
  const RgSkillDef(this.id, this.name, this.icon, this.desc, this.max);
}

const rgSkillDefs = <RgSkillDef>[
  RgSkillDef('front', '前方箭 +1', '⬆️', '正前方多一支箭，每支傷害 -18%', 2),
  RgSkillDef('multi', '連續射擊', '⏩', '每次多射一輪，傷害 -15%、攻速 -12%', 2),
  RgSkillDef('diag', '斜向箭', '↗️', '左右斜方各多一支箭', 2),
  RgSkillDef('side', '側向箭', '↔️', '左右兩側各一支箭', 1),
  RgSkillDef('back', '背後箭', '⬇️', '背後多一支箭', 1),
  RgSkillDef('pierce', '穿透', '🗡️', '箭穿過敵人，每穿一隻傷害 -33%', 1),
  RgSkillDef('rico', '彈射', '💫', '命中後彈向附近的敵人（傷害 -30%）', 2),
  RgSkillDef('wall', '反彈牆', '🧱', '箭碰到牆壁或岩石會反彈 2 次', 1),
  RgSkillDef('atk', '攻擊強化', '⚔️', '攻擊力 +22%', 12),
  RgSkillDef('spd', '攻速強化', '⚡', '攻擊速度 +20%', 6),
  RgSkillDef('crit', '暴擊強化', '🎯', '暴擊率 +10%、暴擊傷害 +30%', 6),
  RgSkillDef('hp', '生命強化', '❤️', '生命上限 +20%（同時回復這麼多）', 12),
  RgSkillDef('heal', '恢復', '💚', '立即回復 40% 生命', 99),
  RgSkillDef('vamp', '吸血', '🩸', '每擊殺一隻回復 2.5% 生命', 2),
  RgSkillDef('fire', '火焰箭', '🔥', '命中燃燒 2 秒（每秒 30% 攻擊力）', 1),
  RgSkillDef('ice', '冰凍箭', '❄️', '命中減速，15% 機率凍結 1 秒', 1),
  RgSkillDef('poison', '劇毒箭', '☠️', '命中疊毒，最多 5 層、不會消失', 1),
  RgSkillDef('orb', '旋轉刀刃', '🌀', '身邊多 2 把旋轉刀刃', 2),
  RgSkillDef('dodge', '閃避', '💨', '12% 機率閃避傷害', 3),
];

RgSkillDef rgSkill(String id) => rgSkillDefs.firstWhere((s) => s.id == id);

const double rgBaseHp = 600;
const double rgBaseAtk = 100;

class RgStats {
  Map<String, int> sk = {};
  int level = 1;
  int xp = 0;
  double hp = rgBaseHp;

  int lv(String id) => sk[id] ?? 0;
  double get maxHp => rgBaseHp * (1 + 0.2 * lv('hp'));
  double get atk => rgBaseAtk * (1 + 0.22 * lv('atk'));
  double get interval => 1 / (1.25 * (1 + 0.2 * lv('spd'))) * (1 + 0.12 * lv('multi'));
  double get critRate => 0.05 + 0.10 * lv('crit');
  double get critMul => 2.0 + 0.3 * lv('crit');
  int get xpNeed => 40 + 33 * (level - 1);

  RgStats copy() => RgStats()
    ..sk = Map.of(sk)
    ..level = level
    ..xp = xp
    ..hp = hp;

  Map<String, dynamic> toJson() => {'sk': sk, 'level': level, 'xp': xp, 'hp': hp};
  static RgStats fromJson(Map<String, dynamic> j) => RgStats()
    ..sk = (j['sk'] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()))
    ..level = (j['level'] as num).toInt()
    ..xp = (j['xp'] as num).toInt()
    ..hp = (j['hp'] as num).toDouble();
}

class RgEnemy {
  final String type;
  final bool boss;
  final int kind;
  final bool fly;
  final String name;
  double x, y, r;
  double hp, maxHp;
  double speed, contact, bdmg;
  int xp;
  double t = 0; // 目前狀態經過時間
  int st = 0; // 狀態
  int combo = 0;
  int summons = 0;
  double ang = 0; // 鎖定的方向
  double vx = 0, vy = 0;
  double sx = 0, sy = 0, tx = 0, ty = 0; // 跳躍起訖
  double wander = 0;
  double stuck = 0;
  double burnT = 0, burnDps = 0, slowT = 0, frozeT = 0;
  double frozeCd = 0; // 凍結過後一段時間不會再被凍（不然射速快會一直凍住）
  int poison = 0;
  double flash = 0;
  double orbCd = 0;
  bool airborne = false;
  bool elite = false;
  double spawnT = 0; // 出場淡入，0.5 秒內不會動
  int id = 0;
  double nx = 0, ny = 0; // 合作模式客人端：房主傳來的位置（畫面平滑追過去）
  double gx = 0, gy = 0, gvx = 0, gvy = 0, gT = -1; // 合作模式客人端：上一張畫面的位置/時間，和前後兩張算出的速度
  final double seed;
  RgEnemy(this.type, this.name, this.kind, this.boss, this.fly, this.x, this.y, this.r, this.hp, this.speed, this.contact,
      this.bdmg, this.xp, this.seed)
      : maxHp = hp;
  bool get windup => _windupStates[type]?.contains(st) ?? false;
}

// 哪些狀態要畫「蓄力」提示（瞄準線或閃爍）
const _windupStates = {
  'a': {1},
  'w': {1},
  'k': {1},
  'm': {1},
  'o': {1},
  'g': {1},
  'd': {1},
  'f': {1},
  'B1': {1},
  'B2': {1, 3},
  'B4': {3},
  'B5': {5},
};

class RgBullet {
  double x, y, vx, vy, r, dmg, life;
  final bool mine;
  int pierce, rico, wall;
  final Set<RgEnemy> hit = {};
  bool split;
  int style; // 0 箭 1 紅球 2 紫球 3 大石 4 火球
  int owner; // 箭是哪位玩家射的（合作模式）
  int id = 0; // 合作模式傳畫面時才編號，客人端用來對應同一顆子彈
  RgBullet(this.x, this.y, this.vx, this.vy, this.r, this.dmg, this.mine,
      {this.life = 6, this.pierce = 0, this.rico = 0, this.wall = 0, this.split = false, this.style = 1, this.owner = 0});
}

class RgZone {
  double x, y, r, t, total, dmg;
  RgZone(this.x, this.y, this.r, this.t, this.dmg) : total = t;
}

class RgFloat {
  double x, y, t = 0;
  final String s;
  final int color;
  final bool big;
  RgFloat(this.x, this.y, this.s, this.color, {this.big = false});
}

class RgFx {
  final int kind; // 0 火花/碎片 1 擴散圈 2 升級光柱
  double x, y, vx, vy, t = 0;
  final double life, size;
  final int color;
  RgFx(this.kind, this.x, this.y, this.vx, this.vy, this.life, this.size, this.color);
}

class RgGem {
  double x, y, vx, vy;
  RgGem(this.x, this.y, this.vx, this.vy);
}

class RgPortal {
  final double x, y;
  final String ch;
  final bool elite;
  double t;
  RgPortal(this.x, this.y, this.ch, this.elite, this.t);
}

class RgHeart {
  double x, y;
  RgHeart(this.x, this.y);
}

/// 一位玩家（合作模式有兩位）。RgGame 裡的 px/py/st… 是「目前處理中的玩家」h 的捷徑。
class RgHero {
  final int idx;
  double x = 4.5, y = 14.2, faceX = 0, faceY = -1;
  double inv = 0, shootCd = 0, hurtT = 0;
  bool moving = false;
  RgStats st = RgStats();
  RgStats snapshot = RgStats();
  final List<double> volleys = [];
  int pendingPicks = 0;
  List<String> offer = [];
  bool needAngel = false;
  bool down = false; // 合作模式：倒地，隊友站旁邊可以扶起來
  double rescue = 0;
  bool remote = false; // 位置由客人端回報（房主不幫他移動）
  RgHero(this.idx);
}

enum RgPhase { play, pick, angel, dead, chapterDone, victory }

// ---------------- 地圖 ----------------
// . 地板  # 岩石（擋人擋箭）  ~ 水（擋人不擋箭）
// s 史萊姆 b 蝙蝠 a 哥布林弓手 w 野狼 k 骷髏兵 m 幽靈法師 o 獸人 g 石魔像 d 惡魔 f 小火龍 B 頭目
const rgMaps = <List<List<String>>>[
  [
    [
      '.........',
      '.........',
      '..s...s..',
      '.........',
      '..##.##..',
      '.........',
      '....a....',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.a.....a.',
      '.........',
      '...~~~...',
      '...~~~...',
      '.........',
      '.b.....b.',
      '.........',
      '.##...##.',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '..s.a.s..',
      '.........',
      '#.......#',
      '##.#.#.##',
      '.........',
      '..b...b..',
      '.........',
      '....#....',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.a..s..a.',
      '.........',
      '..~~.~~..',
      '..~~.~~..',
      '.........',
      's..b.b..s',
      '.........',
      '..#...#..',
      '..#...#..',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.........',
      '.........',
      '....B....',
      '.........',
      '.........',
      '.#.....#.',
      '.........',
      '.........',
      '.........',
      '.........',
      '.#.....#.',
      '.........',
      '.........',
      '.........',
    ],
  ],
  [
    [
      '.........',
      '..w...w..',
      '.........',
      '.##...##.',
      '.........',
      '....a....',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.a.....a.',
      '.###.###.',
      '.........',
      '..w...w..',
      '.........',
      '~~~...~~~',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.b.a.a.b.',
      '.........',
      '#..#.#..#',
      '.........',
      '..s...s..',
      '.........',
      '..#...#..',
      '.........',
      '....w....',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      'a.......a',
      '..w...w..',
      '.~~...~~.',
      '.~~...~~.',
      '....w....',
      '.........',
      '.b.....b.',
      '.........',
      '...#.#...',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.........',
      '....B....',
      '.........',
      '.........',
      '..#...#..',
      '.........',
      '.........',
      '.........',
      '..#...#..',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
  ],
  [
    [
      '.........',
      '..k...k..',
      '.........',
      '.#.....#.',
      '....m....',
      '.........',
      '..#...#..',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.m.....m.',
      '.........',
      '..#####..',
      '.........',
      '.k.....k.',
      '.........',
      '..b...b..',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      'k..a.a..k',
      '.........',
      '~~.~~~.~~',
      '.........',
      '...m.m...',
      '.........',
      '.#.....#.',
      '.........',
      '....w....',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.m..k..m.',
      '.........',
      '.#.#.#.#.',
      '.........',
      'k.......k',
      '.........',
      '..b.b.b..',
      '.........',
      '...#.#...',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.........',
      '....B....',
      '.........',
      '.........',
      '.#.....#.',
      '.........',
      '.........',
      '....#....',
      '.........',
      '.........',
      '.#.....#.',
      '.........',
      '.........',
      '.........',
    ],
  ],
  [
    [
      '.........',
      '...o.o...',
      '.........',
      '.##...##.',
      '.........',
      '..a...a..',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '....g....',
      '.........',
      '~~~...~~~',
      '.........',
      '.d.....d.',
      '.........',
      '..#...#..',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.f.....f.',
      '.........',
      '..#.#.#..',
      '.........',
      '..o...o..',
      '.........',
      '.~~...~~.',
      '.........',
      '....m....',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      'g.......g',
      '...d.d...',
      '.#.....#.',
      '.........',
      '..f...f..',
      '.........',
      'o.......o',
      '.........',
      '...#.#...',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.........',
      '....B....',
      '.........',
      '.........',
      '.........',
      '..#...#..',
      '.........',
      '.........',
      '.........',
      '..#...#..',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
  ],
  [
    [
      '.........',
      '..d...d..',
      '.........',
      '.#.#.#.#.',
      '.........',
      '..f.m.f..',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.g.....g.',
      '.........',
      '..~~~~~..',
      '.........',
      '.w.d.d.w.',
      '.........',
      '..#...#..',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      'm.f...f.m',
      '.........',
      '##.###.##',
      '.........',
      '..o...o..',
      '.........',
      '.k.....k.',
      '.........',
      '....#....',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      'd.m...m.d',
      '....g....',
      '.#.....#.',
      '.........',
      'f..o.o..f',
      '.........',
      '.~~...~~.',
      '.........',
      '..w...w..',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
    [
      '.........',
      '.........',
      '....B....',
      '.........',
      '.........',
      '.........',
      '.........',
      '.#.....#.',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
      '.........',
    ],
  ],
];

// 種類：名稱、美術 kind、會飛、半徑、血量、速度、碰撞傷害、子彈傷害、經驗
class _EType {
  final String name;
  final int kind;
  final bool fly;
  final double r, hp, speed, contact, bdmg;
  final int xp;
  const _EType(this.name, this.kind, this.fly, this.r, this.hp, this.speed, this.contact, this.bdmg, this.xp);
}

const _types = {
  's': _EType('史萊姆', 0, false, 0.34, 260, 1.4, 90, 0, 8),
  'b': _EType('蝙蝠', 1, true, 0.30, 150, 2.1, 70, 0, 7),
  'a': _EType('哥布林弓手', 2, false, 0.32, 220, 0.8, 70, 100, 10),
  'w': _EType('野狼', 4, false, 0.36, 320, 1.0, 115, 0, 11),
  'k': _EType('骷髏兵', 3, false, 0.34, 340, 1.0, 90, 90, 12),
  'm': _EType('幽靈法師', 6, true, 0.34, 280, 0.6, 80, 90, 13),
  'o': _EType('獸人', 5, false, 0.42, 620, 1.25, 130, 95, 18),
  'g': _EType('石魔像', 7, false, 0.48, 1100, 0.6, 140, 120, 24),
  'd': _EType('惡魔', 9, false, 0.38, 520, 0.9, 110, 85, 20),
  'f': _EType('小火龍', 8, true, 0.36, 450, 1.3, 100, 95, 18),
};

// 各關頭目：type、名稱、美術、會飛、半徑、血量
const _bosses = [
  ('B1', '史萊姆王', 0, false, 0.85, 4300.0),
  ('B2', '狼王', 4, false, 0.8, 4200.0),
  ('B3', '骷髏王', 3, false, 0.8, 4400.0),
  ('B4', '熔岩魔像', 7, false, 0.95, 6200.0),
  ('B5', '魔龍', 8, true, 0.95, 5600.0),
];

class RgGame {
  final math.Random rng;
  int chapter = 0;
  int room = 0;
  final List<RgHero> heroes;
  int _local = 0; // 這台裝置操作的是哪一位
  int get local => _local;
  set local(int v) {
    _local = v;
    h = heroes[v];
  }
  late RgHero h; // 目前處理中的玩家（敵人 AI 時＝牠的目標）；step 結束後都會回到 local
  RgHero get me => heroes[local];
  bool get coop => heroes.length > 1;
  int roomSeq = 0; // 每次換房間/重來 +1（客人端用來知道要跳到房主給的位置）
  double netClock = 0; // 合作模式：一直往前走的時鐘（暫停也走），客人端用來估畫面延遲多久
  int _bid = 0;
  double? _clkOff; // 客人端：房主時鐘 − 自己時鐘 的估計（取最新鮮的那幾張畫面）
  double _sinceSnap = 0;
  final Set<int> _deadB = {}; // 客人端自己判定撞牆消失的子彈，下一張畫面不要再生回來
  int _nextId = 0;
  List<String> grid = rgMaps[0][0];
  double get px => h.x;
  set px(double v) => h.x = v;
  double get py => h.y;
  set py(double v) => h.y = v;
  double get faceX => h.faceX;
  set faceX(double v) => h.faceX = v;
  double get faceY => h.faceY;
  set faceY(double v) => h.faceY = v;
  double get inv => h.inv;
  set inv(double v) => h.inv = v;
  double get shootCd => h.shootCd;
  set shootCd(double v) => h.shootCd = v;
  double get hurtT => h.hurtT;
  set hurtT(double v) => h.hurtT = v;
  bool get moving => h.moving;
  set moving(bool v) => h.moving = v;
  RgStats get st => h.st;
  set st(RgStats v) => h.st = v;
  int get pendingPicks => h.pendingPicks;
  List<String> get offer => h.offer;
  final double pr = 0.3;
  List<RgEnemy> en = [];
  List<RgBullet> bl = [];
  List<RgZone> zones = [];
  List<RgFloat> floats = [];
  List<RgHeart> hearts = [];
  List<RgFx> fx = [];
  List<RgGem> gems = [];
  List<RgPortal> portals = [];
  int wavesLeft = 0;
  bool cleared = false;
  double clearT = 0;
  RgPhase phase = RgPhase.play;
  double time = 0, roomTime = 0;
  double shake = 0;
  double orbAng = 0;
  bool angelDone = false;
  int gemsXp = 0;
  int kills = 0;
  int hitsTaken = 0;
  String? lastHitBy;

  RgGame({int? seed, int players = 1})
      : rng = math.Random(seed),
        heroes = [for (var i = 0; i < players; i++) RgHero(i)] {
    h = heroes[0];
  }

  /// 新的一局：從第 1 關開始，先送一次技能三選一
  void newRun() {
    startChapterAll(0, [for (final _ in heroes) RgStats()]);
    for (final p in heroes) {
      p.pendingPicks = 1;
    }
    _openPick();
  }

  void startChapter(int c, RgStats s) => startChapterAll(c, [for (final _ in heroes) s]);

  void startChapterAll(int c, List<RgStats> ss) {
    chapter = c;
    for (final p in heroes) {
      p.st = ss[p.idx].copy();
      p.snapshot = ss[p.idx].copy();
      p.pendingPicks = 0;
      p.offer = [];
      p.needAngel = false;
      p.down = false;
    }
    angelDone = false;
    loadRoom(0);
    phase = RgPhase.play;
  }

  void retryChapter() {
    startChapterAll(chapter, [for (final p in heroes) p.snapshot]);
    if (chapter == 0 && me.st.sk.isEmpty) {
      for (final p in heroes) {
        p.pendingPicks = 1;
      }
      _openPick();
    }
  }

  // 合作模式怪物血量 ×1.5（兩個人打，傷害各自吃）
  double get hpMul => rgHpMul(chapter) * (coop ? 1.5 : 1.0);

  /// 合作模式全滅：兩人滿血，從這一間重來（跟單人花水晶復活一樣滿血）
  void retryRoom() {
    if (phase != RgPhase.dead) return;
    for (final p in heroes) {
      p.down = false;
      p.rescue = 0;
      p.st.hp = p.st.maxHp;
    }
    loadRoom(room);
    phase = RgPhase.play;
  }
  double get dmgMul => rgDmgMul(chapter);
  int get theme => chapter % 5;
  int get tier => chapter ~/ 5;
  int revives = 0;

  /// 這一關這一間的地圖（奇數階左右鏡像）
  List<String> _rawMap(int r) {
    final m = rgMaps[theme][r];
    if (tier.isOdd) return [for (final row in m) row.split('').reversed.join()];
    return m;
  }

  /// 花寶石原地復活：滿血、清掉敵方子彈、2.5 秒無敵
  void revive() {
    if (phase != RgPhase.dead) return;
    h = me;
    h.down = false;
    revives++;
    st.hp = st.maxHp;
    inv = 2.5;
    bl.removeWhere((b) => !b.mine);
    zones.clear();
    for (final e in en) {
      if (e.boss) continue;
      final d = math.sqrt(_d2(e.x, e.y, px, py));
      if (d < 2.5) e.stuck = 0.6; // 讓貼身的怪先退開一下
    }
    floats.add(RgFloat(px, py - 0.6, '復活！', 0xFF40C4FF, big: true));
    fx.add(RgFx(2, px, py, 0, 0, 0.9, 1, 0xFF40C4FF));
    phase = RgPhase.play;
  }
  bool get isBossRoom => room == rgRoomsPerChapter - 1;
  RgEnemy? get boss {
    for (final e in en) {
      if (e.boss) return e;
    }
    return null;
  }

  void loadRoom(int r) {
    room = r;
    grid = [for (final row in _rawMap(r)) row.replaceAll(RegExp('[a-zA-Z]'), '.')];
    en = [];
    bl = [];
    zones = [];
    hearts = [];
    floats = [];
    fx = [];
    gems = [];
    portals = [];
    wavesLeft = r < _roomWaves.length ? _roomWaves[r] + (tier >= 2 && r > 0 ? 1 : 0) : 0;
    cleared = false;
    clearT = 0;
    gemsXp = 0;
    roomTime = 0;
    roomSeq++;
    for (final p in heroes) {
      p.x = coop ? 3.9 + 1.2 * p.idx : 4.5;
      p.y = 14.2;
      p.faceX = 0;
      p.faceY = -1;
      p.inv = 1.0; // 進房短暫無敵
      p.shootCd = 0.4;
      p.hurtT = 0;
      p.volleys.clear();
    }
    final rows = _rawMap(r);
    for (var y = 0; y < rgRows; y++) {
      for (var x = 0; x < rgCols; x++) {
        final ch = rows[y][x];
        if (ch == '.' || ch == '#' || ch == '~') continue;
        if (ch == 'B') {
          _spawnBoss(x + 0.5, y + 0.5);
        } else {
          spawn(ch, x + 0.5, y + 0.5);
        }
      }
    }
    // 精英怪：每間 1 隻，第 3 關起後兩間 2 隻
    // 高階關卡：每間多幾隻進階怪（位置用關卡＋房間當種子，固定）
    if (!isBossRoom && tier > 0) {
      final rr = math.Random(chapter * 31 + r);
      const adv = ['o', 'g', 'd', 'f', 'm', 'k', 'w'];
      var added = 0;
      for (var k = 0; k < 60 && added < tier + (r >= 2 ? 1 : 0); k++) {
        final x = rr.nextInt(rgCols), y = 1 + rr.nextInt(7);
        if (grid[y][x] != '.') continue;
        if (en.any((e) => _d2(e.x, e.y, x + 0.5, y + 0.5) < 1.2)) continue;
        spawn(adv[rr.nextInt(math.min(adv.length, 3 + tier * 2))], x + 0.5, y + 0.5);
        added++;
      }
    }
    if (!isBossRoom && !(chapter == 0 && r == 0)) {
      final n = (theme >= 2 && r >= 2 ? 2 : 1) + tier ~/ 2;
      final pool = List.of(en)..shuffle(rng);
      for (final e in pool.take(n)) {
        _makeElite(e);
      }
    }
  }

  void _makeElite(RgEnemy e) {
    e.elite = true;
    e.hp *= 2.2;
    e.maxHp = e.hp;
    e.r *= 1.18;
    e.contact *= 1.2;
    e.bdmg *= 1.15;
    e.xp = (e.xp * 1.5).round();
  }

  List<String> get _chapterPool {
    final set = <String>{};
    for (final m in rgMaps[theme].take(rgRoomsPerChapter - 1)) {
      for (final row in m) {
        for (final ch in row.split('')) {
          if (_types.containsKey(ch)) set.add(ch);
        }
      }
    }
    if (tier > 0) set.addAll(['o', 'g', 'd', 'f', 'm', 'k', 'w'].take(1 + tier * 2));
    return set.toList()..sort();
  }

  void _spawnWave() {
    wavesLeft--;
    final pool = _chapterPool;
    final n = 3 + (theme >= 2 ? 1 : 0) + tier;
    for (var i = 0; i < n; i++) {
      for (var k = 0; k < 40; k++) {
        final x = 0.6 + rng.nextDouble() * (rgCols - 1.2), y = 0.6 + rng.nextDouble() * 8.5;
        if (_heroNear(x, y, 3.5) || circleBlocked(x, y, 0.45)) continue;
        portals.add(RgPortal(x, y, pool[rng.nextInt(pool.length)], i == 0 && wavesLeft == 0 && chapter >= 1, 1.0 + i * 0.15));
        break;
      }
    }
  }

  RgEnemy spawn(String ch, double x, double y) {
    final t = _types[ch]!;
    final e = RgEnemy(ch, t.name, t.kind, false, t.fly, x, y, t.r, t.hp * hpMul * _mobHpMul, t.speed,
        t.contact * dmgMul * _mobDmgMul, t.bdmg * dmgMul * _mobDmgMul, (t.xp * (1 + 0.1 * chapter)).round(), rng.nextDouble() * 10);
    e.t = -rng.nextDouble() * 0.8; // 錯開節奏
    e.id = ++_nextId;
    en.add(e);
    return e;
  }

  void _spawnBoss(double x, double y) {
    final b = _bosses[theme];
    final e = RgEnemy(b.$1, b.$2, b.$3, true, b.$4, x, y, b.$5, b.$6 * hpMul, 1.0, 140 * dmgMul, 100 * dmgMul,
        (90 * (1 + 0.1 * chapter)).round(), 0);
    e.t = -1.2;
    e.id = ++_nextId;
    en.add(e);
  }

  // ---------------- 地形碰撞 ----------------
  bool tileBlocked(int c, int r, {bool fly = false, bool bullet = false}) {
    if (c < 0 || c >= rgCols || r < 0 || r >= rgRows) return true;
    final ch = grid[r].codeUnitAt(c);
    if (ch == 35) return !fly; // '#'
    if (ch == 126) return !fly && !bullet; // '~'
    return false;
  }

  bool circleBlocked(double x, double y, double r, {bool fly = false, bool bullet = false}) {
    if (x - r < 0 || x + r > rgCols || y - r < 0 || y + r > rgRows) return true;
    for (var ty = (y - r).floor(); ty <= (y + r).floor(); ty++) {
      for (var tx = (x - r).floor(); tx <= (x + r).floor(); tx++) {
        if (!tileBlocked(tx, ty, fly: fly, bullet: bullet)) continue;
        final cx = x.clamp(tx.toDouble(), tx + 1.0);
        final cy = y.clamp(ty.toDouble(), ty + 1.0);
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) < r * r) return true;
      }
    }
    return false;
  }

  /// 分軸移動；回傳是否有被擋到
  bool _move(RgEnemy? e, double dx, double dy, double r, bool fly) {
    var x = e?.x ?? px, y = e?.y ?? py;
    var hit = false;
    if (dx != 0) {
      if (!circleBlocked(x + dx, y, r, fly: fly)) {
        x += dx;
      } else {
        hit = true;
      }
    }
    if (dy != 0) {
      if (!circleBlocked(x, y + dy, r, fly: fly)) {
        y += dy;
      } else {
        hit = true;
      }
    }
    if (e != null) {
      e.x = x;
      e.y = y;
    } else {
      px = x;
      py = y;
    }
    return hit;
  }

  // ---------------- 主迴圈 ----------------
  /// mx,my：搖桿方向（長度 0~1）
  void step(double mx, double my) {
    netClock += rgDt;
    _step(mx, my);
    h = me;
  }

  void _step(double mx, double my) {
    if (phase != RgPhase.play) return;
    const dt = rgDt;
    time += dt;
    roomTime += dt;
    if (shake > 0) shake -= dt;
    for (final f in floats) {
      f.t += dt;
      f.y -= dt * 0.8;
    }
    floats.removeWhere((f) => f.t > 0.9);
    for (final f in fx) {
      f.t += dt;
      f.x += f.vx * dt;
      f.y += f.vy * dt;
      f.vx *= 0.9;
      f.vy *= 0.9;
    }
    fx.removeWhere((f) => f.t >= f.life);
    orbAng += dt * 3.2;
    for (final p in heroes) {
      h = p;
      if (p.down) continue;
      _stepHero(p.remote ? 0 : mx, p.remote ? 0 : my, dt);
    }
    if (coop) _rescue(dt);

    // 敵人
    for (final e in List.of(en)) {
      if (e.hp <= 0) continue;
      h = _targetFor(e);
      _updateEnemy(e, dt);
    }
    // 子彈
    _updateBullets(dt);
    // 落石區
    for (final z in zones) {
      z.t -= dt;
      if (z.t > 0) continue;
      for (final p in heroes) {
        if (_d2(z.x, z.y, p.x, p.y) < (z.r + pr * 0.5) * (z.r + pr * 0.5)) _hurtHero(p, z.dmg, '落石');
      }
    }
    zones.removeWhere((z) => z.t <= 0);
    // 死亡結算
    for (final e in en) {
      if (e.hp <= 0) _onKill(e);
    }
    en.removeWhere((e) => e.hp <= 0);
    if (phase != RgPhase.play) return;

    // 增援
    for (final p in portals) {
      p.t -= dt;
      if (p.t <= 0) {
        final e = spawn(p.ch, p.x, p.y);
        e.xp = (e.xp * 0.6).round(); // 增援給的經驗少，避免升太快
        if (p.elite) _makeElite(e);
        fx.add(RgFx(1, p.x, p.y, 0, 0, 0.4, 1.0, 0xFFB388FF));
      }
    }
    portals.removeWhere((p) => p.t <= 0);
    if (!cleared && wavesLeft > 0 && portals.isEmpty && en.length <= 1) _spawnWave();

    if (cleared) {
      for (final g in gems) {
        h = heroes.length == 1 ? heroes[0] : (heroes.where((p) => !p.down).firstOrNull ?? heroes[0]);
        if (coop) {
          for (final p in heroes) {
            if (_d2(g.x, g.y, p.x, p.y) < _d2(g.x, g.y, px, py)) h = p;
          }
        }
        final dx = px - g.x, dy = py - g.y;
        final d = math.sqrt(dx * dx + dy * dy) + 1e-6;
        final sp = 4 + clearT * 14;
        g.vx = g.vx * 0.85 + dx / d * sp * 0.15;
        g.vy = g.vy * 0.85 + dy / d * sp * 0.15;
        g.x += g.vx * dt;
        g.y += g.vy * dt;
      }
      gems.removeWhere((g) => heroes.any((p) => _d2(g.x, g.y, p.x, p.y) < 0.3 * 0.3));
    } else {
      for (final g in gems) {
        g.x += g.vx * dt;
        g.y += g.vy * dt;
        g.vx *= 0.88;
        g.vy *= 0.88;
      }
    }

    if (!cleared && en.isEmpty && portals.isEmpty && wavesLeft == 0) {
      cleared = true;
      clearT = 0;
      bl.removeWhere((b) => !b.mine);
      zones.clear();
      for (final p in heroes) {
        if (p.down) _standUp(p, 0.3); // 清完房間，倒地的隊友自動站起來
        final s = p.st, lvBefore = s.level;
        s.xp += gemsXp;
        while (s.xp >= s.xpNeed) {
          s.xp -= s.xpNeed;
          s.level++;
          p.pendingPicks++;
        }
        if (s.level > lvBefore) fx.add(RgFx(2, p.x, p.y, 0, 0, 0.9, 1, 0xFFFFD54F));
      }
      gemsXp = 0;
    }
    if (cleared) {
      clearT += dt;
      if (clearT > 0.9 && heroes.any((p) => p.pendingPicks > 0)) {
        _openPick();
        return;
      }
      // 走到上方門口（合作模式兩個人都要到）
      if (heroes.every((p) => p.y < 0.75 && (p.x - 4.5).abs() < 0.9)) _throughDoor();
    }
  }

  void _stepHero(double mx, double my, double dt) {
    if (inv > 0) inv -= dt;
    if (hurtT > 0) hurtT -= dt;
    // 玩家移動（客人的位置由網路設定，這裡不動）
    if (!h.remote) {
      final ml = math.sqrt(mx * mx + my * my);
      moving = ml > 0.15;
      if (moving) {
        final k = math.min(1.0, ml) / ml;
        faceX = mx / ml;
        faceY = my / ml;
        _move(null, mx * k * 3.6 * dt, my * k * 3.6 * dt, pr, false);
      }
    }
    // 撿愛心
    hearts.removeWhere((ht) {
      if (_d2(ht.x, ht.y, px, py) < 0.5 * 0.5) {
        _healPct(0.12);
        return true;
      }
      return false;
    });

    // 射擊
    if (shootCd > 0) shootCd -= dt;
    final tgt = _nearest(px, py);
    if (!moving && tgt != null && shootCd <= 0) {
      _fire(tgt);
      shootCd = st.interval;
      for (var i = 1; i <= st.lv('multi'); i++) {
        h.volleys.add(0.12 * i);
      }
    }
    for (var i = h.volleys.length - 1; i >= 0; i--) {
      h.volleys[i] -= dt;
      if (h.volleys[i] <= 0) {
        h.volleys.removeAt(i);
        final t2 = _nearest(px, py);
        if (t2 != null) _fire(t2);
      }
    }

    // 旋轉刀刃
    final orbs = 2 * st.lv('orb');
    if (orbs > 0) {
      for (var i = 0; i < orbs; i++) {
        final a = orbAng + 2 * math.pi * i / orbs;
        final ox = px + math.cos(a) * 1.15, oy = py + math.sin(a) * 1.15;
        for (final e in en) {
          if (e.orbCd > 0 || e.hp <= 0 || e.airborne) continue;
          if (_d2(e.x, e.y, ox, oy) < (e.r + 0.22) * (e.r + 0.22)) {
            _hitEnemy(e, st.atk * 0.4, status: false);
            e.orbCd = 0.35;
          }
        }
      }
    }
  }

  /// 合作模式：倒地的玩家旁邊有隊友站 2.5 秒就站起來（40% 血）
  void _rescue(double dt) {
    for (final p in heroes) {
      if (!p.down) continue;
      final helped = heroes.any((o) => !o.down && _d2(o.x, o.y, p.x, p.y) < 1.3 * 1.3);
      p.rescue = helped ? p.rescue + dt : math.max(0, p.rescue - dt * 0.5);
      if (p.rescue >= 2.5) _standUp(p, 0.4);
    }
  }

  void _standUp(RgHero p, double hpPct) {
    p.down = false;
    p.rescue = 0;
    p.st.hp = math.max(p.st.hp, p.st.maxHp * hpPct);
    p.inv = 2.0;
    floats.add(RgFloat(p.x, p.y - 0.6, '站起來了！', 0xFF69F0AE, big: true));
    fx.add(RgFx(2, p.x, p.y, 0, 0, 0.9, 1, 0xFF69F0AE));
  }

  /// 敵人追誰：最近、還沒倒地的玩家
  RgHero _targetFor(RgEnemy e) {
    if (!coop) return heroes[0];
    RgHero? best;
    var bd = double.infinity;
    for (final p in heroes) {
      if (p.down) continue;
      final d = _d2(e.x, e.y, p.x, p.y);
      if (d < bd) {
        bd = d;
        best = p;
      }
    }
    return best ?? heroes[0];
  }

  bool _heroNear(double x, double y, double r) => heroes.any((p) => !p.down && _d2(x, y, p.x, p.y) < r * r);

  void _hurtHero(RgHero p, double d, String by) {
    final keep = h;
    h = p;
    _hurt(d, by);
    h = keep;
  }

  void _throughDoor() {
    if (isBossRoom) {
      if (chapter == rgChapters - 1) {
        phase = RgPhase.victory;
      } else {
        phase = RgPhase.chapterDone;
      }
      return;
    }
    if (room == rgRoomsPerChapter - 2 && !angelDone) {
      angelDone = true;
      for (final p in heroes) {
        p.needAngel = true;
      }
      phase = RgPhase.angel;
      return;
    }
    loadRoom(room + 1);
  }

  /// 關卡通關後進下一關（回復 20% 生命）
  void nextChapter() {
    if (chapter >= rgChapters - 1) return;
    startChapterAll(chapter + 1, [for (final p in heroes) _nextStatsOf(p)]);
  }

  /// 下一關開場的狀態（回復 20% 生命），過關時回報給伺服器存起來
  RgStats nextStats() => _nextStatsOf(me);

  RgStats _nextStatsOf(RgHero p) {
    final s = p.st.copy();
    s.hp = math.min(s.maxHp, s.hp + s.maxHp * 0.2);
    return s;
  }

  void chooseAngel(bool heal) => chooseAngelFor(local, heal);

  /// 天使：每位玩家各選一次，都選完才進頭目房
  void chooseAngelFor(int i, bool heal) {
    if (phase != RgPhase.angel || i >= heroes.length || !heroes[i].needAngel) return;
    final p = heroes[i];
    p.needAngel = false;
    if (heal) {
      h = p;
      _healPct(0.5);
      h = me;
    } else {
      p.pendingPicks++;
    }
    if (heroes.any((o) => o.needAngel)) return;
    loadRoom(room + 1);
    if (heroes.any((o) => o.pendingPicks > 0)) {
      _openPick();
    } else {
      phase = RgPhase.play;
    }
  }

  void _openPick() {
    for (final p in heroes) {
      if (p.pendingPicks > 0 && p.offer.isEmpty) _genOffer(p);
    }
    phase = RgPhase.pick;
  }

  void _genOffer(RgHero p) {
    final s = p.st;
    final pool = rgSkillDefs.where((d) => s.lv(d.id) < d.max && d.id != 'heal').map((d) => d.id).toList()..shuffle(rng);
    p.offer = pool.take(3).toList();
    if (s.hp < s.maxHp * 0.5 && p.offer.length == 3 && rng.nextDouble() < 0.5) p.offer[2] = 'heal';
    if (p.offer.isEmpty) p.offer = ['heal'];
  }

  void choose(String id) => chooseFor(local, id);

  void chooseFor(int i, String id) {
    if (phase != RgPhase.pick || i >= heroes.length) return;
    final p = heroes[i];
    if (p.pendingPicks <= 0 || !p.offer.contains(id)) return;
    h = p;
    st.sk[id] = st.lv(id) + 1;
    if (id == 'hp') st.hp += rgBaseHp * 0.2;
    if (id == 'heal') _healPct(0.4);
    h = me;
    p.pendingPicks--;
    p.offer = [];
    if (p.pendingPicks > 0) _genOffer(p);
    if (heroes.every((o) => o.pendingPicks == 0)) phase = RgPhase.play;
  }

  void _healPct(double p) {
    final before = st.hp;
    st.hp = math.min(st.maxHp, st.hp + st.maxHp * p);
    final got = st.hp - before;
    if (got >= 1) floats.add(RgFloat(px, py - 0.5, '+${got.round()}', 0xFF4CFF7A));
  }

  RgEnemy? _nearest(double x, double y) {
    RgEnemy? best;
    var bd = double.infinity;
    for (final e in en) {
      if (e.hp <= 0 || e.airborne) continue;
      final d = _d2(e.x, e.y, x, y);
      if (d < bd) {
        bd = d;
        best = e;
      }
    }
    return best;
  }

  void _fire(RgEnemy t) {
    final a = math.atan2(t.y - py, t.x - px);
    faceX = math.cos(a);
    faceY = math.sin(a);
    final front = st.lv('front');
    final dmg = st.atk * math.pow(0.82, front) * math.pow(0.85, st.lv('multi'));
    final n = 1 + front;
    final nx = -math.sin(a), ny = math.cos(a);
    for (var i = 0; i < n; i++) {
      final off = (i - (n - 1) / 2) * 0.24;
      _arrow(px + nx * off, py + ny * off, a, dmg);
    }
    final diag = st.lv('diag');
    if (diag >= 1) {
      _arrow(px, py, a + 0.56, dmg);
      _arrow(px, py, a - 0.56, dmg);
    }
    if (diag >= 2) {
      _arrow(px, py, a + 0.96, dmg);
      _arrow(px, py, a - 0.96, dmg);
    }
    if (st.lv('side') > 0) {
      _arrow(px, py, a + math.pi / 2, dmg);
      _arrow(px, py, a - math.pi / 2, dmg);
    }
    if (st.lv('back') > 0) _arrow(px, py, a + math.pi, dmg);
  }

  void _arrow(double x, double y, double a, double dmg) {
    bl.add(RgBullet(x, y, math.cos(a) * 11, math.sin(a) * 11, 0.12, dmg, true,
        life: 2.5, pierce: st.lv('pierce') > 0 ? 9 : 0, rico: st.lv('rico'), wall: st.lv('wall') > 0 ? 2 : 0, style: 0, owner: h.idx));
  }

  void _hitEnemy(RgEnemy e, double dmg, {bool status = true}) {
    var d = dmg;
    final crit = rng.nextDouble() < st.critRate;
    if (crit) d *= st.critMul;
    e.hp -= d;
    e.flash = 0.12;
    if (fx.length < 160) {
      for (var i = 0; i < (crit ? 4 : 2); i++) {
        final a = rng.nextDouble() * 2 * math.pi, v = 2 + rng.nextDouble() * 3;
        fx.add(RgFx(0, e.x, e.y, math.cos(a) * v, math.sin(a) * v, 0.25, 0.06, crit ? 0xFFFFD54F : 0xFFFFFFFF));
      }
    }
    if (floats.length < 60) {
      floats.add(RgFloat(e.x + (rng.nextDouble() - 0.5) * 0.4, e.y - e.r, d.round().toString(),
          crit ? 0xFFFFD54F : 0xFFFFFFFF, big: crit));
    }
    if (!status) return;
    if (st.lv('fire') > 0) {
      e.burnT = 2;
      e.burnDps = st.atk * 0.3;
    }
    if (st.lv('ice') > 0) {
      e.slowT = 1.5;
      if (!e.boss && rng.nextDouble() < 0.15 && e.frozeCd <= 0) {
        e.frozeT = e.elite ? 0.6 : 1.0;
        e.frozeCd = e.frozeT + 3;
      }
    }
    if (st.lv('poison') > 0 && e.poison < 5) e.poison++;
  }

  void _onKill(RgEnemy e) {
    kills++;
    gemsXp += e.xp;
    for (final p in heroes) {
      if (p.down || p.st.lv('vamp') == 0) continue;
      h = p;
      _healPct(0.025 * st.lv('vamp'));
    }
    if (!e.boss && rng.nextDouble() < 0.05) hearts.add(RgHeart(e.x, e.y));
    if (e.boss) shake = 0.5;
    fx.add(RgFx(1, e.x, e.y, 0, 0, 0.35, e.r * 2.2, e.elite ? 0xFFFFD54F : 0xFFFFFFFF));
    final n = e.boss ? 24 : 8;
    for (var i = 0; i < n && fx.length < 200; i++) {
      final a = rng.nextDouble() * 2 * math.pi, v = 1.5 + rng.nextDouble() * 4;
      fx.add(RgFx(0, e.x, e.y, math.cos(a) * v, math.sin(a) * v, 0.5 + rng.nextDouble() * 0.3, 0.07 + rng.nextDouble() * 0.06,
          e.boss ? 0xFFFF7043 : 0xFFCFD8DC));
    }
    final gn = math.min(8, 1 + e.xp ~/ 6);
    for (var i = 0; i < gn; i++) {
      final a = rng.nextDouble() * 2 * math.pi, v = 1 + rng.nextDouble() * 2.5;
      gems.add(RgGem(e.x, e.y, math.cos(a) * v, math.sin(a) * v));
    }
  }

  void _hurt(double d, String by) {
    if (inv > 0 || h.down || phase != RgPhase.play) return;
    if (rng.nextDouble() < 0.12 * st.lv('dodge')) {
      floats.add(RgFloat(px, py - 0.5, '閃避', 0xFF80D8FF));
      inv = 0.25;
      return;
    }
    final dmg = d * (0.92 + rng.nextDouble() * 0.16);
    st.hp -= dmg;
    hitsTaken++;
    lastHitBy = by;
    inv = 0.6;
    shake = 0.18;
    hurtT = 0.35;
    floats.add(RgFloat(px, py - 0.5, '-${dmg.round()}', 0xFFFF5252, big: true));
    if (st.hp <= 0) {
      st.hp = 0;
      if (coop) {
        // 合作模式：先倒地，隊友來扶；兩個都倒才算死
        h.down = true;
        h.rescue = 0;
        h.volleys.clear();
        floats.add(RgFloat(px, py - 0.6, '倒地！', 0xFFFF5252, big: true));
        if (heroes.every((p) => p.down)) phase = RgPhase.dead;
      } else {
        phase = RgPhase.dead;
      }
    }
  }

  // ---------------- 子彈 ----------------
  void _shoot(RgEnemy e, double a, double speed, double dmg, {double r = 0.14, int style = 1, bool split = false, double life = 7}) {
    bl.add(RgBullet(e.x + math.cos(a) * e.r * 0.6, e.y + math.sin(a) * e.r * 0.6, math.cos(a) * speed, math.sin(a) * speed,
        r, dmg, false,
        style: style, split: split, life: life));
  }

  void _ring(RgEnemy e, int n, double speed, double dmg, {double off = 0, int style = 2}) {
    for (var i = 0; i < n; i++) {
      _shoot(e, off + 2 * math.pi * i / n, speed, dmg, style: style);
    }
  }

  void _fan(RgEnemy e, int n, double spread, double speed, double dmg, {int style = 1, double? at}) {
    final a = at ?? _aim(e);
    for (var i = 0; i < n; i++) {
      final k = n == 1 ? 0.0 : i / (n - 1) - 0.5;
      _shoot(e, a + k * spread, speed, dmg, style: style);
    }
  }

  double _aim(RgEnemy e) => math.atan2(py - e.y, px - e.x);

  void _splitAt(double x, double y, double dmg) {
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3 + 0.3;
      bl.add(RgBullet(x, y, math.cos(a) * 3.4, math.sin(a) * 3.4, 0.13, dmg * 0.6, false, style: 2, life: 5));
    }
  }

  void _updateBullets(double dt) {
    final remove = <RgBullet>{};
    for (final b in List.of(bl)) {
      b.life -= dt;
      if (b.life <= 0) {
        if (b.split) _splitAt(b.x, b.y, b.dmg);
        remove.add(b);
        continue;
      }
      final nx = b.x + b.vx * dt, ny = b.y + b.vy * dt;
      if (circleBlocked(nx, ny, b.r * 0.6, bullet: true)) {
        if (b.mine && b.wall > 0) {
          b.wall--;
          if (circleBlocked(nx, b.y, b.r * 0.6, bullet: true)) b.vx = -b.vx;
          if (circleBlocked(b.x, ny, b.r * 0.6, bullet: true)) b.vy = -b.vy;
          continue;
        }
        if (b.split) _splitAt(b.x, b.y, b.dmg);
        remove.add(b);
        continue;
      }
      b.x = nx;
      b.y = ny;
      if (b.mine) {
        for (final e in en) {
          if (e.hp <= 0 || e.airborne || b.hit.contains(e)) continue;
          final rr = e.r + b.r;
          if (_d2(e.x, e.y, b.x, b.y) > rr * rr) continue;
          h = heroes[b.owner];
          _hitEnemy(e, b.dmg);
          b.hit.add(e);
          if (b.rico > 0) {
            RgEnemy? nxt;
            var bd = 16.0;
            for (final o in en) {
              if (o == e || o.hp <= 0 || o.airborne || b.hit.contains(o)) continue;
              final d = _d2(o.x, o.y, b.x, b.y);
              if (d < bd) {
                bd = d;
                nxt = o;
              }
            }
            if (nxt != null) {
              b.rico--;
              b.dmg *= 0.7;
              final a = math.atan2(nxt.y - b.y, nxt.x - b.x);
              b.vx = math.cos(a) * 11;
              b.vy = math.sin(a) * 11;
              b.life = 2.0;
              break;
            }
          }
          if (b.pierce > 0) {
            b.pierce--;
            b.dmg *= 0.67;
          } else {
            remove.add(b);
          }
          break;
        }
      } else {
        final rr = pr + b.r - 0.04;
        for (final p in heroes) {
          if (p.down || p.inv > 0 || _d2(p.x, p.y, b.x, b.y) >= rr * rr) continue;
          _hurtHero(p, b.dmg, '子彈');
          remove.add(b);
          break;
        }
      }
    }
    bl.removeWhere(remove.contains);
  }

  // ---------------- 敵人 AI ----------------
  void _chase(RgEnemy e, double sp, double dt) {
    var a = _aim(e);
    if (e.stuck > 0) {
      e.stuck -= dt;
      a = e.ang;
    }
    final blocked = _move(e, math.cos(a) * sp * dt, math.sin(a) * sp * dt, e.r, e.fly);
    if (blocked && e.stuck <= 0) {
      e.stuck = 0.5 + rng.nextDouble() * 0.4;
      e.ang = a + (rng.nextBool() ? 1 : -1) * (math.pi / 2 + rng.nextDouble() * 0.6);
    }
  }

  void _wanderMove(RgEnemy e, double sp, double dt) {
    e.wander -= dt;
    if (e.wander <= 0) {
      e.wander = 0.8 + rng.nextDouble();
      e.ang = rng.nextDouble() * 2 * math.pi;
    }
    if (_move(e, math.cos(e.ang) * sp * dt, math.sin(e.ang) * sp * dt, e.r, e.fly)) e.wander = 0;
  }

  void _teleport(RgEnemy e) {
    for (var i = 0; i < 40; i++) {
      final x = 0.6 + rng.nextDouble() * (rgCols - 1.2), y = 0.6 + rng.nextDouble() * 9;
      if (_heroNear(x, y, 3.5)) continue;
      if (circleBlocked(x, y, e.r)) continue;
      e.x = x;
      e.y = y;
      return;
    }
  }

  void _setSt(RgEnemy e, int s) {
    e.st = s;
    e.t = 0;
  }

  void _updateEnemy(RgEnemy e, double dt) {
    if (e.flash > 0) e.flash -= dt;
    if (e.orbCd > 0) e.orbCd -= dt;
    if (e.burnT > 0) {
      e.burnT -= dt;
      e.hp -= e.burnDps * dt;
    }
    if (e.poison > 0) e.hp -= st.atk * 0.06 * e.poison * dt;
    if (e.slowT > 0) e.slowT -= dt;
    if (e.frozeCd > 0) e.frozeCd -= dt;
    if (e.frozeT > 0) {
      e.frozeT -= dt;
      return;
    }
    final spd = e.slowT > 0 ? 0.6 : 1.0;
    if (e.spawnT < 0.5) {
      e.spawnT += dt;
      return;
    }
    final edt = dt * (e.slowT > 0 ? 0.75 : 1.0) * (e.elite ? 1.3 : 1.0) * (e.boss ? 1 + 0.12 * tier : 1.0); // 減速變慢、精英與高階頭目較快
    e.t += edt;

    // 碰撞傷害
    if (!e.airborne) {
      final rr = e.r + pr - 0.05;
      for (final p in heroes) {
        if (_d2(e.x, e.y, p.x, p.y) < rr * rr) _hurtHero(p, e.contact, e.name);
      }
    }

    final c = theme + tier; // 攻擊花樣的等級
    switch (e.type) {
      case 's':
        _chase(e, e.speed * spd, dt);
      case 'b':
        final a = _aim(e) + math.sin(time * 3 + e.seed) * 0.9;
        _move(e, math.cos(a) * e.speed * spd * dt, math.sin(a) * e.speed * spd * dt, e.r, true);
      case 'a':
        if (e.st == 0) {
          _wanderMove(e, e.speed * spd, dt);
          if (e.t > 1.05) {
            _setSt(e, 1);
            e.ang = _aim(e);
          }
        } else if (e.t > 0.6) {
          if (c >= 2 || e.elite) {
            _fan(e, 3, 0.4, 6.0, e.bdmg, at: e.ang);
          } else {
            _shoot(e, e.ang, 6.0, e.bdmg);
          }
          _setSt(e, 0);
        }
      case 'w':
        if (e.st == 0) {
          _wanderMove(e, e.speed * spd, dt);
          if (e.t > 1.1) {
            _setSt(e, 1);
            e.ang = _aim(e);
          }
        } else if (e.st == 1) {
          if (e.t > 0.55) _setSt(e, 2);
        } else {
          final blocked = _move(e, math.cos(e.ang) * 8.5 * spd * dt, math.sin(e.ang) * 8.5 * spd * dt, e.r, false);
          if (blocked || e.t > 0.45) _setSt(e, 0);
        }
      case 'k':
        if (e.st == 0) {
          _chase(e, e.speed * spd, dt);
          if (e.t > 2.0) _setSt(e, 1);
        } else if (e.t > 0.4) {
          _fan(e, c >= 3 ? 5 : 3, c >= 3 ? 0.8 : 0.4, 4.5, e.bdmg);
          _setSt(e, 0);
        }
      case 'm':
        if (e.st == 0) {
          _wanderMove(e, e.speed * spd, dt);
          if (e.t > 2.4) _setSt(e, 1);
        } else if (e.t > 0.5) {
          _ring(e, c >= 3 ? 12 : 10, 3.0, e.bdmg, off: rng.nextDouble());
          _teleport(e);
          _setSt(e, 0);
        }
      case 'o':
        if (e.st == 0) {
          _chase(e, e.speed * spd, dt);
          if (e.t > 3.2) _setSt(e, 1);
        } else if (e.t > 0.7) {
          _ring(e, 14, 3.6, e.bdmg, off: rng.nextDouble());
          _setSt(e, 0);
        }
      case 'g':
        if (e.st == 0) {
          _chase(e, e.speed * spd, dt);
          if (e.t > 2.6) _setSt(e, 1);
        } else if (e.t > 0.5) {
          _shoot(e, _aim(e), 3.0, e.bdmg, r: 0.32, style: 3, split: true, life: 1.5);
          _setSt(e, 0);
        }
      case 'd':
        if (e.st == 0) {
          _wanderMove(e, e.speed * spd, dt);
          if (e.t > 2.4) _setSt(e, 1);
        } else if (e.st == 1) {
          if (e.t > 0.45) {
            _setSt(e, 2);
            e.combo = 0;
          }
        } else if (e.t > 0.22 * e.combo) {
          _fan(e, 5, 0.9, 4.2, e.bdmg, style: 2);
          e.combo++;
          if (e.combo >= 3) _setSt(e, 0);
        }
      case 'f':
        if (e.st == 0) {
          final a = _aim(e) + math.sin(time * 2 + e.seed) * 1.2;
          final far = _d2(e.x, e.y, px, py) > 9;
          final s = far ? e.speed : -e.speed * 0.5;
          _move(e, math.cos(a) * s * spd * dt, math.sin(a) * s * spd * dt, e.r, true);
          if (e.t > 2.2) {
            _setSt(e, 1);
            e.combo = 0;
          }
        } else if (e.t > 0.4 + 0.15 * e.combo) {
          _shoot(e, _aim(e), 6.5, e.bdmg, style: 4);
          e.combo++;
          if (e.combo >= 3) _setSt(e, 0);
        }
      case 'B1':
        _slimeKing(e, dt, spd);
      case 'B2':
        _wolfKing(e, dt, spd);
      case 'B3':
        _skeletonKing(e, dt, spd);
      case 'B4':
        _golemKing(e, dt, spd);
      case 'B5':
        _dragon(e, dt, spd);
    }
  }

  int _alive(String type) => en.where((o) => o.type == type && o.hp > 0).length;

  void _summonAt(String ch, RgEnemy e, int n) {
    for (var i = 0; i < n; i++) {
      final a = rng.nextDouble() * 2 * math.pi;
      var x = e.x + math.cos(a) * (e.r + 0.6), y = e.y + math.sin(a) * (e.r + 0.6);
      x = x.clamp(0.5, rgCols - 0.5);
      y = y.clamp(0.5, rgRows - 0.5);
      final s = spawn(ch, x, y);
      if (!s.fly && circleBlocked(x, y, s.r)) {
        s.x = e.x;
        s.y = e.y;
      }
      s.xp = 0;
      s.hp *= 0.7;
      s.maxHp = s.hp;
    }
  }

  // 史萊姆王：跳到玩家位置，落地噴一圈；血量 2/3、1/3 時分裂出小史萊姆
  void _slimeKing(RgEnemy e, double dt, double spd) {
    final frac = e.hp / e.maxHp;
    if (e.summons == 0 && frac < 0.66 || e.summons == 1 && frac < 0.33) {
      e.summons++;
      _summonAt('s', e, 3);
    }
    switch (e.st) {
      case 0:
        _chase(e, 0.8 * spd, dt);
        if (e.t > (frac < 0.5 ? 0.6 : 1.0)) {
          _setSt(e, 1);
          e.tx = px;
          e.ty = py;
        }
      case 1:
        if (e.t > 0.55) {
          _setSt(e, 2);
          e.sx = e.x;
          e.sy = e.y;
          e.airborne = true;
        }
      case 2:
        final k = (e.t / 0.7).clamp(0.0, 1.0);
        e.x = e.sx + (e.tx - e.sx) * k;
        e.y = e.sy + (e.ty - e.sy) * k;
        if (k >= 1) {
          e.airborne = false;
          if (circleBlocked(e.x, e.y, e.r, fly: true)) {
            e.x = e.x.clamp(e.r, rgCols - e.r);
            e.y = e.y.clamp(e.r, rgRows - e.r);
          }
          _ring(e, 16, 3.2, e.bdmg, off: e.combo * 0.2);
          if (frac < 0.5) _ring(e, 16, 2.2, e.bdmg, off: e.combo * 0.2 + 0.2);
          shake = 0.25;
          e.combo++;
          _setSt(e, 0);
        }
    }
  }

  // 狼王：連續衝刺 3 次，然後嚎叫召喚蝙蝠＋一圈子彈
  void _wolfKing(RgEnemy e, double dt, double spd) {
    final frac = e.hp / e.maxHp;
    switch (e.st) {
      case 0:
        _wanderMove(e, 0.8 * spd, dt);
        if (e.t > 0.8) {
          _setSt(e, 1);
          e.ang = _aim(e);
        }
      case 1:
        if (e.t > (frac < 0.5 ? 0.32 : 0.42)) _setSt(e, 2);
      case 2:
        final blocked = _move(e, math.cos(e.ang) * 10 * spd * dt, math.sin(e.ang) * 10 * spd * dt, e.r, false);
        if (blocked || e.t > 0.42) {
          if (blocked && frac < 0.5) _ring(e, 10, 3.0, e.bdmg, off: rng.nextDouble());
          e.combo++;
          if (e.combo % 3 == 0) {
            _setSt(e, 3);
          } else {
            _setSt(e, 1);
            e.ang = _aim(e);
          }
        }
      case 3:
        if (e.t > 0.6) {
          _ring(e, 14, 3.4, e.bdmg, off: rng.nextDouble());
          if (_alive('b') < 4) _summonAt('b', e, 2);
          _setSt(e, 0);
        }
    }
  }

  // 骷髏王：螺旋彈幕 → 瞄準扇形 → 召喚骷髏兵，輪流
  void _skeletonKing(RgEnemy e, double dt, double spd) {
    final frac = e.hp / e.maxHp;
    final p = e.combo % 3;
    if (e.st == 0) {
      _wanderMove(e, 0.6 * spd, dt);
      if (e.y > 6) e.ang = -math.pi / 2;
      if (e.t > 1.5) _setSt(e, 1); // 休息久一點，給玩家輸出空檔
      return;
    }
    if (p == 0) {
      // 螺旋 3.2 秒
      final iv = frac < 0.5 ? 0.075 : 0.1;
      final n = (e.t / iv).floor();
      if (n > e.summons) {
        e.summons = n;
        final a = e.t * 2.3;
        _shoot(e, a, 3.0, e.bdmg, style: 2);
        _shoot(e, a + math.pi, 3.0, e.bdmg, style: 2);
        if (frac < 0.5) _shoot(e, -a + math.pi / 2, 2.6, e.bdmg, style: 2);
      }
      if (e.t > 3.2) _endPattern(e);
    } else if (p == 1) {
      final n = (e.t / 0.45).floor();
      if (n > e.summons) {
        e.summons = n;
        _fan(e, 7, 1.0, 4.0, e.bdmg);
      }
      if (e.t > 0.45 * 4.5) _endPattern(e);
    } else {
      if (e.t > 0.5) {
        _ring(e, 12, 3.2, e.bdmg, off: rng.nextDouble());
        if (_alive('k') < 2 && e.sx < 3) {
          e.sx++; // 整場最多召喚 3 次，避免無限小兵擋箭
          _summonAt('k', e, 2);
        }
        _endPattern(e);
      }
    }
  }

  void _endPattern(RgEnemy e) {
    e.combo++;
    e.summons = 0;
    _setSt(e, 0);
  }

  // 熔岩魔像：分裂巨石 → 雙重震地 → 落石雨
  void _golemKing(RgEnemy e, double dt, double spd) {
    final frac = e.hp / e.maxHp;
    final p = e.combo % 3;
    if (e.st == 0) {
      _chase(e, 0.5 * spd, dt);
      if (e.t > (frac < 0.5 ? 0.7 : 1.1)) _setSt(e, p == 1 ? 3 : 1);
      return;
    }
    if (p == 0) {
      final n = (e.t / 0.7).floor();
      if (n > e.summons) {
        e.summons = n;
        _shoot(e, _aim(e) + (rng.nextDouble() - 0.5) * 0.3, 3.2, e.bdmg, r: 0.34, style: 3, split: true, life: 1.4);
      }
      if (e.t > 0.7 * 3.5) _endPattern(e);
    } else if (p == 1) {
      // st 3 = 蓄力
      if (e.st == 3 && e.t > 0.8) {
        _ring(e, 20, 3.4, e.bdmg, off: 0);
        shake = 0.2;
        _setSt(e, 4);
      } else if (e.st == 4 && e.t > 0.35) {
        _ring(e, 20, 3.0, e.bdmg, off: math.pi / 20);
        _endPattern(e);
      }
    } else {
      final cnt = frac < 0.5 ? 9 : 7;
      for (var i = 0; i < cnt; i++) {
        final near = i < 3;
        final x = near ? px + (rng.nextDouble() - 0.5) * 2.4 : 0.6 + rng.nextDouble() * (rgCols - 1.2);
        final y = near ? py + (rng.nextDouble() - 0.5) * 2.4 : 0.6 + rng.nextDouble() * (rgRows - 1.2);
        zones.add(RgZone(x.clamp(0.5, rgCols - 0.5), y.clamp(0.5, rgRows - 0.5), 0.85, 1.1 + i * 0.05, e.bdmg * 1.5));
      }
      _endPattern(e);
    }
  }

  // 魔龍：火焰扇形 → 旋轉環 → 衝刺；半血後持續噴螺旋並召喚惡魔
  void _dragon(RgEnemy e, double dt, double spd) {
    final frac = e.hp / e.maxHp;
    final rage = frac < 0.5;
    if (rage && e.summons >= 0 && e.sx == 0) {
      e.sx = 1; // 只召喚一次
      _summonAt('d', e, 1);
      _summonAt('f', e, 1);
    }
    if (rage) {
      e.tx += dt;
      if (e.tx > 0.36) {
        e.tx = 0;
        e.ty += 0.5;
        _shoot(e, e.ty, 2.4, e.bdmg * 0.8, style: 4);
        _shoot(e, e.ty + math.pi, 2.4, e.bdmg * 0.8, style: 4);
      }
    }
    final p = e.combo % 3;
    switch (e.st) {
      case 0:
        final a = _aim(e) + math.sin(time * 1.5) * 1.3;
        final far = _d2(e.x, e.y, px, py) > 16;
        _move(e, math.cos(a) * (far ? 1.2 : -0.6) * spd * dt, math.sin(a) * (far ? 1.2 : -0.6) * spd * dt, e.r, true);
        if (e.t > (rage ? 0.6 : 1.0)) {
          e.summons = 0;
          _setSt(e, p == 2 ? 5 : p + 1);
          if (p == 2) e.ang = _aim(e);
        }
      case 1: // 火焰扇形 3 輪
        final n = (e.t / 0.5).floor();
        if (n > e.summons) {
          e.summons = n;
          _fan(e, 9, 1.3, 4.2, e.bdmg, style: 4);
        }
        if (e.t > 0.5 * 3.5) _endPattern(e);
      case 2: // 旋轉環 5 波
        final n = (e.t / 0.35).floor();
        if (n > e.summons) {
          e.summons = n;
          _ring(e, 16, 3.0, e.bdmg, off: n * 0.12);
        }
        if (e.t > 0.35 * 5.5) _endPattern(e);
      case 5: // 衝刺蓄力
        if (e.t > 0.6) _setSt(e, 6);
      case 6:
        final blocked = _move(e, math.cos(e.ang) * 9 * spd * dt, math.sin(e.ang) * 9 * spd * dt, e.r, true);
        if (blocked || e.t > 0.55) {
          _ring(e, 12, 3.4, e.bdmg, off: rng.nextDouble(), style: 4);
          e.summons++;
          if (e.summons >= 2) {
            _endPattern(e);
          } else {
            _setSt(e, 5);
            e.ang = _aim(e);
          }
        }
    }
  }

  // ---------------- 合作模式連線 ----------------
  // 房主跑完整模擬，每 4 幀把畫面需要的東西打包（snap）傳給客人；客人自己移動自己的角色（guestMove），
  // 把位置回報給房主（setRemote），其他東西照房主的畫，兩次 snap 之間用 guestTick 補動畫。

  static double _r2(double v) => (v * 100).roundToDouble() / 100;

  /// 客人回報自己的位置
  void setRemote(int i, double x, double y, double fx, double fy, bool mv) {
    final p = heroes[i];
    if (p.down || phase != RgPhase.play) return;
    if (circleBlocked(x, y, pr * 0.8)) return; // 擋在牆裡的就不收
    p.x = x;
    p.y = y;
    p.faceX = fx;
    p.faceY = fy;
    p.moving = mv;
  }

  Map<String, dynamic> snap() => {
        'ph': phase.index,
        'n': _r2(netClock),
        'c': chapter,
        'r': room,
        'q': roomSeq,
        'cl': cleared ? 1 : 0,
        't': _r2(time),
        'rt': _r2(roomTime),
        'w': wavesLeft,
        'k': kills,
        'oa': _r2(orbAng),
        'h': [
          for (final p in heroes)
            [_r2(p.x), _r2(p.y), _r2(p.faceX), _r2(p.faceY), p.moving ? 1 : 0, _r2(p.inv), _r2(p.hurtT), _r2(p.shootCd),
             p.down ? 1 : 0, _r2(p.rescue), p.pendingPicks, p.needAngel ? 1 : 0, p.offer, p.st.toJson()]
        ],
        'e': [
          for (final e in en)
            [e.id, e.type, _r2(e.x), _r2(e.y), _r2(e.r), e.hp.round(), e.maxHp.round(), e.st, _r2(e.t), _r2(e.ang), _r2(e.tx),
             _r2(e.ty), (e.elite ? 1 : 0) | (e.airborne ? 2 : 0), _r2(e.flash), _r2(e.frozeT), _r2(e.slowT), _r2(e.burnT), e.poison,
             _r2(e.spawnT), _r2(e.seed)]
        ],
        'b': [
          for (final b in bl)
            [_r2(b.x), _r2(b.y), _r2(b.vx), _r2(b.vy), _r2(b.r), b.style, b.mine ? 1 : 0, _r2(b.life), b.id == 0 ? b.id = ++_bid : b.id]
        ],
        'z': [for (final z in zones) [_r2(z.x), _r2(z.y), _r2(z.r), _r2(z.t), _r2(z.total)]],
        'p': [for (final p in portals) [_r2(p.x), _r2(p.y), _r2(p.t), p.elite ? 1 : 0, p.ch]],
        'g': [for (final g in gems) [_r2(g.x), _r2(g.y), _r2(g.vx), _r2(g.vy)]],
        'hr': [for (final x in hearts) [_r2(x.x), _r2(x.y)]],
        'f': [for (final f in floats.take(40)) [_r2(f.x), _r2(f.y), f.s, f.color, f.big ? 1 : 0, _r2(f.t)]],
        'x': [
          for (final f in fx)
            if (f.kind != 0) [f.kind, _r2(f.x), _r2(f.y), _r2(f.life), _r2(f.size), f.color, _r2(f.t)]
        ],
      };

  static double _d(Object? v) => (v as num).toDouble();

  /// 客人端：套用房主傳來的畫面
  void applySnap(Map<String, dynamic> m) {
    final c = (m['c'] as num).toInt(), r = (m['r'] as num).toInt(), q = (m['q'] as num).toInt();
    final newRoom = q != roomSeq || c != chapter || r != room;
    if (newRoom) {
      chapter = c;
      room = r;
      grid = [for (final row in _rawMap(r)) row.replaceAll(RegExp('[a-zA-Z]'), '.')];
    }
    roomSeq = q;
    // 這張畫面比「現在」晚了多久：網路忽快忽慢時，晚到的畫面要多往前推一點，才不會一下前一下後
    final hostT = _d(m['n'] ?? netClock); // 舊版房主沒有時鐘
    final off = hostT - netClock;
    final prevOff = _clkOff;
    _clkOff = prevOff == null || off > prevOff || newRoom || prevOff - off > 2 ? off : prevOff + (off - prevOff) * 0.03;
    final age = (netClock + _clkOff! - hostT).clamp(0.0, 0.3);
    _sinceSnap = 0;
    phase = RgPhase.values[(m['ph'] as num).toInt()];
    cleared = m['cl'] == 1;
    time = _d(m['t']);
    roomTime = _d(m['rt']);
    wavesLeft = (m['w'] as num).toInt();
    kills = (m['k'] as num).toInt();
    orbAng = _d(m['oa']);
    final hs = m['h'] as List;
    for (var i = 0; i < hs.length && i < heroes.length; i++) {
      final a = hs[i] as List, p = heroes[i];
      final mine = i == local;
      final down = a[8] == 1;
      // 自己的位置自己算；換房間、倒地或差太多（被房主拉回）才用房主的
      if (!mine || newRoom || down || p.down || _d2(p.x, p.y, _d(a[0]), _d(a[1])) > 2.5 * 2.5) {
        p.x = _d(a[0]);
        p.y = _d(a[1]);
      }
      if (!mine) {
        p.faceX = _d(a[2]);
        p.faceY = _d(a[3]);
        p.moving = a[4] == 1;
      }
      p.inv = _d(a[5]);
      final ht = _d(a[6]);
      if (mine && ht > p.hurtT + 0.05) shake = 0.18;
      p.hurtT = ht;
      p.shootCd = _d(a[7]);
      p.down = down;
      p.rescue = _d(a[9]);
      p.pendingPicks = (a[10] as num).toInt();
      p.needAngel = a[11] == 1;
      p.offer = [for (final x in a[12] as List) x as String];
      p.st = RgStats.fromJson(Map<String, dynamic>.from(a[13] as Map));
    }
    // 敵人：用 id 對應，位置平滑追過去；血變少就噴火花、消失就爆開
    final old = {for (final e in en) e.id: e};
    final next = <RgEnemy>[];
    for (final raw in m['e'] as List) {
      final a = raw as List;
      final id = (a[0] as num).toInt();
      var e = old.remove(id);
      if (e == null || newRoom) {
        e = _netEnemy(a[1] as String, _d(a[2]), _d(a[3]), _d(a[19]));
        e.id = id;
      }
      final hp = _d(a[5]);
      if (hp < e.hp - 0.5 && fx.length < 160) {
        for (var i = 0; i < 2; i++) {
          final an = rng.nextDouble() * 2 * math.pi, v = 2 + rng.nextDouble() * 3;
          fx.add(RgFx(0, e.x, e.y, math.cos(an) * v, math.sin(an) * v, 0.25, 0.06, 0xFFFFFFFF));
        }
      }
      final sx = _d(a[2]), sy = _d(a[3]);
      final gap = hostT - e.gT;
      if (e.gT >= 0 && gap > 0.01 && gap < 0.5) {
        e.gvx = (sx - e.gx) / gap;
        e.gvy = (sy - e.gy) / gap;
        if (e.gvx * e.gvx + e.gvy * e.gvy > 14 * 14) e.gvx = e.gvy = 0; // 瞬移／衝刺結束：不要外推
      } else {
        e.gvx = e.gvy = 0;
      }
      e.gT = hostT;
      e.gx = sx;
      e.gy = sy;
      e.nx = sx + e.gvx * age;
      e.ny = sy + e.gvy * age;
      if (_d2(e.x, e.y, e.nx, e.ny) > 3 * 3) {
        e.x = e.nx;
        e.y = e.ny;
      }
      e.r = _d(a[4]);
      e.hp = hp;
      e.maxHp = _d(a[6]);
      e.st = (a[7] as num).toInt();
      e.t = _d(a[8]);
      e.ang = _d(a[9]);
      e.tx = _d(a[10]);
      e.ty = _d(a[11]);
      final fl = (a[12] as num).toInt();
      e.elite = fl & 1 != 0;
      e.airborne = fl & 2 != 0;
      e.flash = _d(a[13]);
      e.frozeT = _d(a[14]);
      e.slowT = _d(a[15]);
      e.burnT = _d(a[16]);
      e.poison = (a[17] as num).toInt();
      e.spawnT = _d(a[18]);
      next.add(e);
    }
    if (!newRoom) {
      for (final e in old.values) {
        for (var i = 0; i < (e.boss ? 24 : 8) && fx.length < 200; i++) {
          final an = rng.nextDouble() * 2 * math.pi, v = 1.5 + rng.nextDouble() * 4;
          fx.add(RgFx(0, e.x, e.y, math.cos(an) * v, math.sin(an) * v, 0.5 + rng.nextDouble() * 0.3, 0.07 + rng.nextDouble() * 0.06,
              e.boss ? 0xFFFF7043 : 0xFFCFD8DC));
        }
        if (e.boss) shake = 0.5;
      }
    }
    en = next;
    // 子彈：用編號對應同一顆，位置推到「現在」，已經在飛的只微調，不整批換掉（不然會閃）
    final oldB = {for (final b in bl) b.id: b};
    final ids = <int>{};
    final nb = <RgBullet>[];
    for (final raw in m['b'] as List) {
      final a = raw as List;
      final id = a.length > 8 ? (a[8] as num).toInt() : -nb.length - 1, vx = _d(a[2]), vy = _d(a[3]);
      ids.add(id);
      if (_deadB.contains(id)) continue;
      var tx = _d(a[0]) + vx * age, ty = _d(a[1]) + vy * age;
      if (circleBlocked(tx, ty, _d(a[4]) * 0.6, bullet: true)) {
        tx = _d(a[0]);
        ty = _d(a[1]);
      }
      var b = newRoom ? null : oldB[id];
      if (b == null) {
        b = RgBullet(tx, ty, vx, vy, _d(a[4]), 0, a[6] == 1, style: (a[5] as num).toInt(), life: _d(a[7]))..id = id;
      } else {
        b.vx = vx;
        b.vy = vy;
        b.life = _d(a[7]);
        if (_d2(b.x, b.y, tx, ty) > 1.0) {
          b.x = tx;
          b.y = ty;
        } else {
          b.x += (tx - b.x) * 0.5;
          b.y += (ty - b.y) * 0.5;
        }
      }
      nb.add(b);
    }
    _deadB.retainAll(ids);
    bl = nb;
    zones = [
      for (final raw in m['z'] as List)
        (raw as List).let((a) => RgZone(_d(a[0]), _d(a[1]), _d(a[2]), _d(a[4]), 0)..t = _d(a[3]))
    ];
    portals = [for (final raw in m['p'] as List) (raw as List).let((a) => RgPortal(_d(a[0]), _d(a[1]), a[4] as String, a[3] == 1, _d(a[2])))];
    gems = [for (final raw in m['g'] as List) (raw as List).let((a) => RgGem(_d(a[0]), _d(a[1]), _d(a[2]), _d(a[3])))];
    hearts = [for (final raw in m['hr'] as List) (raw as List).let((a) => RgHeart(_d(a[0]), _d(a[1])))];
    floats = [
      for (final raw in m['f'] as List)
        (raw as List).let((a) => RgFloat(_d(a[0]), _d(a[1]), a[2] as String, (a[3] as num).toInt(), big: a[4] == 1)..t = _d(a[5]))
    ];
    fx.removeWhere((f) => f.kind != 0);
    for (final raw in m['x'] as List) {
      final a = raw as List;
      fx.add(RgFx((a[0] as num).toInt(), _d(a[1]), _d(a[2]), 0, 0, _d(a[3]), _d(a[4]), (a[5] as num).toInt())..t = _d(a[6]));
    }
    h = me;
  }

  /// 房主重新整理網頁後：用伺服器留著的最後一張畫面接回去（技能、等級、血量都在），那一間從頭打
  void restoreFrom(Map<String, dynamic> m) {
    chapter = (m['c'] as num).toInt();
    final r = (m['r'] as num).toInt();
    final ph = RgPhase.values[(m['ph'] as num).toInt()];
    final hs = m['h'] as List;
    for (var i = 0; i < hs.length && i < heroes.length; i++) {
      final a = hs[i] as List, p = heroes[i];
      p.st = RgStats.fromJson(Map<String, dynamic>.from(a[13] as Map));
      p.snapshot = p.st.copy();
      p.down = false;
      p.rescue = 0;
      if (p.st.hp <= 0 || a[8] == 1 || ph == RgPhase.dead) p.st.hp = math.max(p.st.hp, p.st.maxHp * (ph == RgPhase.dead ? 1 : 0.3));
      p.pendingPicks = (a[10] as num).toInt();
      p.offer = [for (final x in a[12] as List) x as String];
      p.needAngel = a[11] == 1;
    }
    angelDone = r >= rgRoomsPerChapter - 2 && ph != RgPhase.play || r >= rgRoomsPerChapter - 1;
    netClock = _d(m['n']);
    roomSeq = (m['q'] as num).toInt(); // loadRoom 會 +1，客人端就知道換新畫面了
    loadRoom(r);
    phase = switch (ph) {
      RgPhase.dead => RgPhase.play,
      RgPhase.pick => RgPhase.pick,
      _ => ph,
    };
    if (phase == RgPhase.pick) _openPick();
    if (phase == RgPhase.chapterDone || phase == RgPhase.victory || phase == RgPhase.angel) {
      cleared = true; // 這間其實已經打完了
      wavesLeft = 0;
      en.clear();
    }
  }

  RgEnemy _netEnemy(String type, double x, double y, double seed) {
    final t = _types[type];
    if (t != null) return RgEnemy(type, t.name, t.kind, false, t.fly, x, y, t.r, 1, t.speed, 0, 0, 0, seed);
    final b = _bosses.firstWhere((b) => b.$1 == type, orElse: () => _bosses[0]);
    return RgEnemy(b.$1, b.$2, b.$3, true, b.$4, x, y, b.$5, 1, 1, 0, 0, 0, seed);
  }

  /// 客人端：自己移動（只做地形碰撞，傷害由房主算）
  void guestMove(double mx, double my) {
    h = me;
    if (phase != RgPhase.play || me.down) {
      me.moving = false;
      return;
    }
    final ml = math.sqrt(mx * mx + my * my);
    moving = ml > 0.15;
    if (moving) {
      final k = math.min(1.0, ml) / ml;
      faceX = mx / ml;
      faceY = my / ml;
      _move(null, mx * k * 3.6 * rgDt, my * k * 3.6 * rgDt, pr, false);
    } else {
      final t = _nearest(px, py);
      if (t != null) {
        final a = math.atan2(t.y - py, t.x - px);
        faceX = math.cos(a);
        faceY = math.sin(a);
      }
    }
  }

  /// 客人端：兩次 snap 之間補動畫（一幀 rgDt）
  void guestTick() {
    const dt = rgDt;
    netClock += dt;
    if (phase != RgPhase.play) return;
    _sinceSnap += dt;
    final extra = _sinceSnap < 0.3; // 畫面太久沒來就別再往前猜
    time += dt;
    roomTime += dt;
    orbAng += dt * 3.2;
    if (shake > 0) shake -= dt;
    for (final p in heroes) {
      if (p.inv > 0) p.inv -= dt;
      if (p.hurtT > 0) p.hurtT -= dt;
    }
    const k = 0.35;
    for (final e in en) {
      if (extra) {
        e.nx += e.gvx * dt;
        e.ny += e.gvy * dt;
      }
      e.x += (e.nx - e.x) * k;
      e.y += (e.ny - e.y) * k;
      e.t += dt;
      if (e.flash > 0) e.flash -= dt;
      if (e.spawnT < 0.5) e.spawnT += dt;
    }
    bl.removeWhere((b) {
      final nx = b.x + b.vx * dt, ny = b.y + b.vy * dt;
      if (circleBlocked(nx, ny, b.r * 0.6, bullet: true)) {
        if (b.mine) return false; // 自己的箭可能會反彈，交給房主的畫面
        _deadB.add(b.id);
        return true;
      }
      b.x = nx;
      b.y = ny;
      return false;
    });
    for (final z in zones) {
      z.t -= dt;
    }
    for (final p in portals) {
      p.t -= dt;
    }
    for (final f in floats) {
      f.t += dt;
      f.y -= dt * 0.8;
    }
    floats.removeWhere((f) => f.t > 0.9);
    for (final f in fx) {
      f.t += dt;
      f.x += f.vx * dt;
      f.y += f.vy * dt;
      f.vx *= 0.9;
      f.vy *= 0.9;
    }
    fx.removeWhere((f) => f.t >= f.life);
  }

  static double _d2(double ax, double ay, double bx, double by) => (ax - bx) * (ax - bx) + (ay - by) * (ay - by);
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
