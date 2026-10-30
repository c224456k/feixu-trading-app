// 弓箭肉鴿（仿弓箭傳說）：純 Dart 規則與模擬，不依賴 Flutter，可以用 dart run 跑機器人平衡測試。
// 站著不動才會自動射最近的敵人，移動時不射擊；每關 4 個戰鬥房 + 頭目房，升級三選一技能。
import 'dart:math' as math;

const int rgCols = 9;
const int rgRows = 15;
const double rgDt = 1 / 60;
const int rgChapters = 5;
const int rgRoomsPerChapter = 5; // 0~3 一般房，4 頭目房

const rgChapterNames = ['翠綠草原', '幽暗洞窟', '亡者墓地', '熔岩地獄', '魔王城'];
const rgChapterBands = [0, 1, 2, 6, 9]; // MonsterPainter 的區域配色
const _hpMul = [1.0, 1.75, 2.7, 3.9, 5.3];
const _dmgMul = [1.0, 1.2, 1.42, 1.68, 1.95];

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
  RgSkillDef('atk', '攻擊強化', '⚔️', '攻擊力 +22%', 5),
  RgSkillDef('spd', '攻速強化', '⚡', '攻擊速度 +20%', 4),
  RgSkillDef('crit', '暴擊強化', '🎯', '暴擊率 +10%、暴擊傷害 +30%', 4),
  RgSkillDef('hp', '生命強化', '❤️', '生命上限 +20%（同時回復這麼多）', 5),
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
  int get xpNeed => 40 + 30 * (level - 1);

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
  int poison = 0;
  double flash = 0;
  double orbCd = 0;
  bool airborne = false;
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
  RgBullet(this.x, this.y, this.vx, this.vy, this.r, this.dmg, this.mine,
      {this.life = 6, this.pierce = 0, this.rico = 0, this.wall = 0, this.split = false, this.style = 1});
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

class RgHeart {
  double x, y;
  RgHeart(this.x, this.y);
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
  RgStats st = RgStats();
  RgStats snapshot = RgStats();
  List<String> grid = rgMaps[0][0];
  double px = 4.5, py = 14, faceX = 0, faceY = -1;
  final double pr = 0.3;
  double inv = 0, shootCd = 0;
  final List<double> _volleys = [];
  List<RgEnemy> en = [];
  List<RgBullet> bl = [];
  List<RgZone> zones = [];
  List<RgFloat> floats = [];
  List<RgHeart> hearts = [];
  bool cleared = false;
  double clearT = 0;
  int pendingPicks = 0;
  List<String> offer = [];
  RgPhase phase = RgPhase.play;
  double time = 0, roomTime = 0;
  double shake = 0;
  double orbAng = 0;
  bool angelDone = false;
  bool moving = false;
  int gemsXp = 0;
  int kills = 0;
  int hitsTaken = 0;
  String? lastHitBy;

  RgGame({int? seed}) : rng = math.Random(seed);

  /// 新的一局：從第 1 關開始，先送一次技能三選一
  void newRun() {
    st = RgStats();
    startChapter(0, st);
    pendingPicks = 1;
    _openPick();
  }

  void startChapter(int c, RgStats s) {
    chapter = c;
    st = s.copy();
    snapshot = s.copy();
    angelDone = false;
    pendingPicks = 0;
    loadRoom(0);
    phase = RgPhase.play;
  }

  void retryChapter() {
    startChapter(chapter, snapshot);
    if (chapter == 0 && st.sk.isEmpty) {
      pendingPicks = 1;
      _openPick();
    }
  }

  double get hpMul => _hpMul[chapter];
  double get dmgMul => _dmgMul[chapter];
  bool get isBossRoom => room == rgRoomsPerChapter - 1;
  RgEnemy? get boss {
    for (final e in en) {
      if (e.boss) return e;
    }
    return null;
  }

  void loadRoom(int r) {
    room = r;
    grid = [for (final row in rgMaps[chapter][r]) row.replaceAll(RegExp('[a-zA-Z]'), '.')];
    en = [];
    bl = [];
    zones = [];
    hearts = [];
    floats = [];
    _volleys.clear();
    cleared = false;
    clearT = 0;
    gemsXp = 0;
    roomTime = 0;
    px = 4.5;
    py = 14.2;
    faceX = 0;
    faceY = -1;
    inv = 1.0; // 進房短暫無敵
    shootCd = 0.4;
    final rows = rgMaps[chapter][r];
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
  }

  RgEnemy spawn(String ch, double x, double y) {
    final t = _types[ch]!;
    final e = RgEnemy(ch, t.name, t.kind, false, t.fly, x, y, t.r, t.hp * hpMul, t.speed, t.contact * dmgMul,
        t.bdmg * dmgMul, (t.xp * (1 + 0.25 * chapter)).round(), rng.nextDouble() * 10);
    e.t = -rng.nextDouble() * 0.8; // 錯開節奏
    en.add(e);
    return e;
  }

  void _spawnBoss(double x, double y) {
    final b = _bosses[chapter];
    final e = RgEnemy(b.$1, b.$2, b.$3, true, b.$4, x, y, b.$5, b.$6 * hpMul, 1.0, 140 * dmgMul, 100 * dmgMul,
        (90 * (1 + 0.25 * chapter)).round(), 0);
    e.t = -1.2;
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
    if (phase != RgPhase.play) return;
    const dt = rgDt;
    time += dt;
    roomTime += dt;
    if (inv > 0) inv -= dt;
    if (shake > 0) shake -= dt;
    for (final f in floats) {
      f.t += dt;
      f.y -= dt * 0.8;
    }
    floats.removeWhere((f) => f.t > 0.9);

    // 玩家移動
    final ml = math.sqrt(mx * mx + my * my);
    moving = ml > 0.15;
    if (moving) {
      final k = math.min(1.0, ml) / ml;
      faceX = mx / ml;
      faceY = my / ml;
      _move(null, mx * k * 3.6 * dt, my * k * 3.6 * dt, pr, false);
    }
    // 撿愛心
    hearts.removeWhere((h) {
      if (_d2(h.x, h.y, px, py) < 0.5 * 0.5) {
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
        _volleys.add(0.12 * i);
      }
    }
    for (var i = _volleys.length - 1; i >= 0; i--) {
      _volleys[i] -= dt;
      if (_volleys[i] <= 0) {
        _volleys.removeAt(i);
        final t2 = _nearest(px, py);
        if (t2 != null) _fire(t2);
      }
    }

    // 旋轉刀刃
    final orbs = 2 * st.lv('orb');
    orbAng += dt * 3.2;
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

    // 敵人
    for (final e in List.of(en)) {
      if (e.hp <= 0) continue;
      _updateEnemy(e, dt);
    }
    // 子彈
    _updateBullets(dt);
    // 落石區
    for (final z in zones) {
      z.t -= dt;
      if (z.t <= 0 && _d2(z.x, z.y, px, py) < (z.r + pr * 0.5) * (z.r + pr * 0.5)) _hurt(z.dmg, '落石');
    }
    zones.removeWhere((z) => z.t <= 0);
    // 死亡結算
    for (final e in en) {
      if (e.hp <= 0) _onKill(e);
    }
    en.removeWhere((e) => e.hp <= 0);
    if (phase != RgPhase.play) return;

    if (!cleared && en.isEmpty) {
      cleared = true;
      clearT = 0;
      bl.removeWhere((b) => !b.mine);
      zones.clear();
      st.xp += gemsXp;
      gemsXp = 0;
      while (st.xp >= st.xpNeed) {
        st.xp -= st.xpNeed;
        st.level++;
        pendingPicks++;
      }
    }
    if (cleared) {
      clearT += dt;
      if (clearT > 0.6 && pendingPicks > 0) {
        _openPick();
        return;
      }
      // 走到上方門口
      if (py < 0.75 && (px - 4.5).abs() < 0.9) _throughDoor();
    }
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
      phase = RgPhase.angel;
      return;
    }
    loadRoom(room + 1);
  }

  /// 關卡通關後進下一關（回復 20% 生命）
  void nextChapter() {
    if (chapter >= rgChapters - 1) return;
    final s = st.copy();
    s.hp = math.min(s.maxHp, s.hp + s.maxHp * 0.2);
    startChapter(chapter + 1, s);
  }

  void chooseAngel(bool heal) {
    if (phase != RgPhase.angel) return;
    if (heal) {
      _healPct(0.5);
      phase = RgPhase.play;
      loadRoom(room + 1);
    } else {
      pendingPicks++;
      loadRoom(room + 1);
      _openPick();
    }
  }

  void _openPick() {
    final pool = rgSkillDefs.where((s) => st.lv(s.id) < s.max && s.id != 'heal').map((s) => s.id).toList()..shuffle(rng);
    offer = pool.take(3).toList();
    if (st.hp < st.maxHp * 0.5 && offer.length == 3 && rng.nextDouble() < 0.5) offer[2] = 'heal';
    if (offer.isEmpty) offer = ['heal'];
    phase = RgPhase.pick;
  }

  void choose(String id) {
    if (phase != RgPhase.pick || !offer.contains(id)) return;
    st.sk[id] = st.lv(id) + 1;
    if (id == 'hp') st.hp += rgBaseHp * 0.2;
    if (id == 'heal') _healPct(0.4);
    pendingPicks--;
    if (pendingPicks > 0) {
      _openPick();
    } else {
      phase = RgPhase.play;
    }
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
        life: 2.5, pierce: st.lv('pierce') > 0 ? 9 : 0, rico: st.lv('rico'), wall: st.lv('wall') > 0 ? 2 : 0, style: 0));
  }

  void _hitEnemy(RgEnemy e, double dmg, {bool status = true}) {
    var d = dmg;
    final crit = rng.nextDouble() < st.critRate;
    if (crit) d *= st.critMul;
    e.hp -= d;
    e.flash = 0.12;
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
      if (!e.boss && rng.nextDouble() < 0.15) e.frozeT = 1.0;
    }
    if (st.lv('poison') > 0 && e.poison < 5) e.poison++;
  }

  void _onKill(RgEnemy e) {
    kills++;
    gemsXp += e.xp;
    if (st.lv('vamp') > 0) _healPct(0.025 * st.lv('vamp'));
    if (!e.boss && rng.nextDouble() < 0.05) hearts.add(RgHeart(e.x, e.y));
    if (e.boss) shake = 0.5;
  }

  void _hurt(double d, String by) {
    if (inv > 0 || phase != RgPhase.play) return;
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
    floats.add(RgFloat(px, py - 0.5, '-${dmg.round()}', 0xFFFF5252, big: true));
    if (st.hp <= 0) {
      st.hp = 0;
      phase = RgPhase.dead;
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
        if (_d2(px, py, b.x, b.y) < rr * rr && inv <= 0) {
          _hurt(b.dmg, '子彈');
          remove.add(b);
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
      if (_d2(x, y, px, py) < 3.5 * 3.5) continue;
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
    if (e.frozeT > 0) {
      e.frozeT -= dt;
      return;
    }
    final spd = e.slowT > 0 ? 0.6 : 1.0;
    final edt = dt * (e.slowT > 0 ? 0.75 : 1.0); // 減速時動作節奏也變慢
    e.t += edt;

    // 碰撞傷害
    if (!e.airborne) {
      final rr = e.r + pr - 0.05;
      if (_d2(e.x, e.y, px, py) < rr * rr) _hurt(e.contact, e.name);
    }

    final c = chapter;
    switch (e.type) {
      case 's':
        _chase(e, e.speed * spd, dt);
      case 'b':
        final a = _aim(e) + math.sin(time * 3 + e.seed) * 0.9;
        _move(e, math.cos(a) * e.speed * spd * dt, math.sin(a) * e.speed * spd * dt, e.r, true);
      case 'a':
        if (e.st == 0) {
          _wanderMove(e, e.speed * spd, dt);
          if (e.t > 1.3) {
            _setSt(e, 1);
            e.ang = _aim(e);
          }
        } else if (e.t > 0.6) {
          if (c >= 3) {
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
          if (e.t > 2.3) _setSt(e, 1);
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
      if (e.t > 1.0) _setSt(e, 1);
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
        if (_alive('k') < 3) _summonAt('k', e, 2);
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

  static double _d2(double ax, double ay, double bx, double by) => (ax - bx) * (ax - bx) + (ay - by) * (ay - by);
}
