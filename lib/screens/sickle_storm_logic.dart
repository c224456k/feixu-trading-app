// 鐮刀風暴（試玩）：規則與 NPC AI，純 Dart、不碰畫面，方便用測試直接跑模擬。
//
// 玩法：每個人身邊繞著一圈旋轉的鐮刀（一格一格、中間有空隙）。刀碰刀會互相磨損（鐮刀多、
// 正在往前衝的一方磨得比較少）；刀尖從空隙鑽進去碰到「人」就是收割——對方全部的鐮刀瞬間
// 被吸過來。刀圈分層：每 20 把升一層換顏色（白→綠→藍→紫→橘→紅…），升層那一刻圈上
// 只剩一把更大更強的刀，再慢慢長回 20 把——大隻的也會露出空隙，小隻的才有反敗的機會。地圖有石柱、斷牆、水池擋路，草叢可以躲。
//
// 單機：被收割就結束。多人（房主的瀏覽器跑這份模擬，其他人收畫面）：被收割 3 秒後重生，
// 3 分鐘時間到鐮刀最多的人贏。
import 'dart:math' as math;

const ssArenaR = 1500.0; // 圓形場地半徑
const ssBodyR = 16.0; // 人的身體半徑
const ssPerLevel = 20; // 每 20 把升一層
const ssSilver = 21; // 第 2 層（綠）起有淡淡光暈
const ssGold = 61; // 第 4 層（紫）起變金光暴風圈
const ssRoundSec = 180.0;
const ssDt = 1 / 60;
const ssFighterTotal = 14; // 場上總人數（真人 + NPC）
const ssMaxHumans = 6;
const ssPickupCount = 100; // 地上最多幾把
const ssPickupRate = 1.8; // 每秒補幾把（限速，不然光撿就撿到爆，打架反而不划算）
const ssRespawnSec = 3.0; // 多人模式被收割後幾秒重生

/// 地上鐮刀的等級：顏色代表撿到加幾把（白 1、綠 2、藍 3、紫 5、橘 8）。
const ssPickupValue = [1, 2, 3, 5, 8];
const _pickupWeight = [66, 20, 9, 4, 1];

/// 鐮刀顏色表：0~4 是地上鐮刀的等級色，5 以後是每個人自己的本命色。
const ssBladeColors = [
  0xFFECEFF1, 0xFF69F0AE, 0xFF40C4FF, 0xFFE040FB, 0xFFFFAB40, // 白 綠 藍 紫 橘
  0xFFFF5252, 0xFFFF4081, 0xFF18FFFF, 0xFF536DFE, 0xFF90A4AE, 0xFFFF6E40, // 紅 桃 青 靛 鋼 赤銅
  0xFFEEFF41, 0xFF80D8FF, 0xFFB388FF, 0xFFF8BBD0, 0xFF64FFDA, 0xFFFFD740, // 檸檬 天藍 薰衣草 櫻 薄荷 琥珀
];
const ssSkinFirst = 5;
const ssPlayerSkin = 12; // 單機主角：天藍

/// 道具
enum SsItemType { boots, guard, magnet, rage }

const ssItemName = {
  SsItemType.boots: '跑速鞋',
  SsItemType.guard: '金鐘罩',
  SsItemType.magnet: '磁鐵',
  SsItemType.rage: '狂暴藥水',
};
const ssItemDesc = {
  SsItemType.boots: '跑速 +45%',
  SsItemType.guard: '刀槍不入，不會被磨損也不會被收割',
  SsItemType.magnet: '把附近地上的鐮刀吸過來',
  SsItemType.rage: '撞擊力量 ×1.8',
};
const ssItemDur = {SsItemType.boots: 8.0, SsItemType.guard: 5.0, SsItemType.magnet: 10.0, SsItemType.rage: 8.0};
const ssItemMax = 8; // 場上最多幾個道具
const ssItemEvery = 5.0; // 幾秒補一個

/// 第幾層（0 起算）：1~20 把是 0、21~40 是 1…
int ssLevel(int n) => n <= 0 ? 0 : (n - 1) ~/ ssPerLevel;

/// 每一層的刀色（ssBladeColors 索引）：白 綠 藍 紫 橘 紅 琥珀 桃 靛，之後都用最後一色
const ssLevelColors = [0, 1, 2, 3, 4, 5, 16, 6, 8];
int ssLevelColor(int n) => ssLevelColors[math.min(ssLevel(n), ssLevelColors.length - 1)];

/// 圈上實際有幾把刀：這一層長到第幾把（1~20），升層就從 1 把重新長。
int ssSlots(int n) => n <= 0 ? 0 : n - ssLevel(n) * ssPerLevel;

/// 鐮刀圈半徑：看圈上有幾把，層數高的稍微大一點。
double ssRingR(int n) => n <= 0 ? ssBodyR : 30 + 4.0 * math.pow(ssSlots(n), 0.8) + 4.0 * math.min(ssLevel(n), 8);

/// 單把鐮刀的大小（畫面與碰撞共用）：層數越高刀越大。
double ssBladeSize(int n) => math.min(46.0, 24 + 3.0 * ssLevel(n) + 0.2 * ssSlots(n));

/// 刀尖最外圈能碰到的距離
double ssReach(int n) => n <= 0 ? ssBodyR : ssRingR(n) + 0.45 * ssBladeSize(n);

/// 圈越大跑越慢，小隻的才有機會逃。
double ssSpeed(int n) => 250 / (1 + n * 0.004);

int ssTier(int n) => n >= ssGold ? 2 : (n >= ssSilver ? 1 : 0);

/// 轉速（弧度／秒）：刻意慢，看得到刀與刀之間的空隙；層數越高轉得稍快。
double ssSpin(int level) => math.min(2.5, 1.7 + 0.12 * level);

// 單把鐮刀的碰撞點（刀的區域座標：+x 是旋轉前進方向，-y 朝外），半徑 = 0.15 × 刀大小
const _bladePts = [0.08, -0.30, 0.30, -0.52, 0.56, -0.42, 0.76, -0.16];
const _bladePtR = 0.15;

const _botNames = [
  '割草阿伯', '鐮刀妹', '收割者', '稻田之神', '老農夫', '小紅帽', '死神學徒', '田中先生', //
  '秋收大叔', '麥田守望者', '鏽鐮刀', '月光收割', '彎月劍客', '草原狼', '風車村長', '打穀機',
  '黑袍客', '稻草人', '鐵匠之子', '夜行者',
];

const ssColors = [
  0xFFE57373, 0xFF81C784, 0xFFFFB74D, 0xFFBA68C8, 0xFF4DD0E1, 0xFFF06292, 0xFFAED581, //
  0xFFFF8A65, 0xFF9575CD, 0xFFFFD54F, 0xFF4DB6AC, 0xFF90A4AE, 0xFFDCE775, 0xFF7986CB,
];

/// 真人玩家的斗篷色（依座位）
const ssHumanColors = [0xFF64B5F6, 0xFFFF8A65, 0xFF81C784, 0xFFF06292, 0xFFFFD54F, 0xFFBA68C8];
const ssHumanSkins = [12, 5, 15, 6, 16, 13];

class SsFighter {
  final int id;
  String name;
  bool human;
  final int color;
  final int skin; // 本命刀色（ssBladeColors 索引）
  final List<int> mix = List.filled(ssBladeColors.length, 0); // 各顏色的刀有幾把，總和 = n
  double x, y;
  double vx = 0, vy = 0;
  int n;
  double wear = 0; // 磨損累積到 1 就掉一把
  double angle;
  bool alive = true;
  bool hidden = false; // 躲在草叢裡
  int kills = 0;
  int peak;
  double shield; // 出生保護（秒）：期間不會受傷也不會傷人
  double respawnAt = 0;
  int respawns = 0; // 重生次數（連線時讓客人知道要把自己瞬移到新位置）
  int? killedBy;
  double flash = 0; // 被打到時閃白（畫面用）
  double faceX = 1, faceY = 0; // 臉朝向
  double impX = 0, impY = 0; // 連線：房主這邊推到客人的力道，下一張畫面傳過去
  // NPC 專用
  double think = 0;
  double tx = 0, ty = 0; // 想走的方向（單位向量或 0）
  final double aggr; // 積極度 0~1
  final double caution; // 謹慎度：多遠就開始逃
  int? chaseId;
  double stuck = 0, unstick = 0;
  // 連線客人端：房主傳來的位置（畫面平滑追過去）
  double sx = 0, sy = 0, sa = 0;
  // 道具效果剩餘秒數
  final buffs = <SsItemType, double>{};
  bool has(SsItemType t) => (buffs[t] ?? 0) > 0;
  // 碰撞點快取
  final List<double> _pts = [];
  int _ptsTick = -1;

  SsFighter({
    required this.id,
    required this.name,
    required this.human,
    required this.color,
    required this.skin,
    required this.x,
    required this.y,
    required this.n,
    required this.angle,
    this.shield = 1.5,
    this.aggr = 0.5,
    this.caution = 1,
  }) : peak = n {
    mix[skin] = n;
  }

  double get ringR => ssRingR(n);
  double get reach => ssReach(n);
  double get bladeSize => ssBladeSize(n);
  int get slots => ssSlots(n);
  int get tier => ssTier(n);
  int get level => ssLevel(n);
  int get levelColor => ssLevelColor(n);
  double get spin => ssSpin(level);

  void addBlades(int color, int k) {
    mix[color] += k;
    n += k;
    if (n > peak) peak = n;
  }

  /// 掉一把：照比例隨機挑一個顏色扣掉，回傳那把的顏色
  int dropOne(math.Random rng) {
    if (n <= 0) return skin;
    var r = rng.nextInt(n);
    for (var i = 0; i < mix.length; i++) {
      if (r < mix[i]) {
        mix[i]--;
        n--;
        return i;
      }
      r -= mix[i];
    }
    n--;
    return skin;
  }

  void clearBlades() {
    for (var i = 0; i < mix.length; i++) {
      mix[i] = 0;
    }
    n = 0;
  }

  /// 圈上刀的顏色：看在第幾層（同一層全部同色）。
  int slotColor(int k, int m, [int layer = 0]) => levelColor;

  /// 每一格刀的碰撞點（世界座標，x,y 交錯），同一幀只算一次。
  List<double> bladePoints(int tick) {
    if (_ptsTick == tick) return _pts;
    _ptsTick = tick;
    _pts.clear();
    final m = slots;
    if (m <= 0) return _pts;
    final bs = bladeSize;
    final rb = ringR - bs * 0.15;
    final gap = math.pi * 2 / m;
    for (var k = 0; k < m; k++) {
      final a = angle + k * gap;
      final ca = math.cos(a), sa = math.sin(a);
      for (var j = 0; j < _bladePts.length; j += 2) {
        final lx = _bladePts[j] * bs, out = rb - _bladePts[j + 1] * bs;
        _pts.add(x + ca * out - sa * lx);
        _pts.add(y + sa * out + ca * lx);
      }
    }
    return _pts;
  }
}

class SsPickup {
  final int id;
  double x, y;
  final double phase;
  final int grade; // 0~4
  SsPickup(this.id, this.x, this.y, this.phase, this.grade);
  int get value => ssPickupValue[grade];
}

class SsItem {
  final double x, y;
  final SsItemType type;
  final double phase;
  SsItem(this.x, this.y, this.type, this.phase);
}

const ssItemReach = ssBodyR + 30; // 道具要用身體去碰（不是鐮刀圈）

/// 地圖障礙物：0 石塊、1 石柱、2 水池、3 斷牆（x,y→x2,y2 的膠囊形）
class SsObstacle {
  final int kind;
  final double x, y, r, x2, y2;
  final int seed; // 畫面用的外形亂數
  const SsObstacle(this.kind, this.x, this.y, this.r, {this.x2 = 0, this.y2 = 0, this.seed = 0});
  bool get wall => kind == 3;
}

/// 草叢：走進去別人看不到你（NPC 也找不到你，除非貼很近）
class SsBush {
  final double x, y, r;
  final int seed;
  const SsBush(this.x, this.y, this.r, this.seed);
}

enum SsEvType { kill, clash, gold, silver, pickup, item, over }

class SsEvent {
  final SsEvType type;
  final double x, y;
  final int a; // 主要的人（擊殺者 / 撿到的人）
  final int b; // 次要的人（被收割的人）
  final int count;
  final double x2, y2;
  SsEvent(this.type, this.x, this.y, {this.a = -1, this.b = -1, this.count = 0, this.x2 = 0, this.y2 = 0});
}

class SsGame {
  final math.Random rng;
  final bool multi;
  final List<SsFighter> fighters = [];
  final List<SsPickup> pickups = [];
  final List<SsItem> items = [];
  final List<SsObstacle> obstacles = [];
  final List<SsBush> bushes = [];
  final List<double> _avoid = []; // NPC 避障用的圓（x,y,r 三個一組，牆拆成好幾顆）
  final List<SsEvent> events = []; // 畫面每幀取走，做特效用
  final Map<int, double> _pairCd = {};
  final Map<int, (double, double)> inputs = {}; // 真人的搖桿方向
  double time = 0;
  int tick = 0;
  bool over = false;
  String overReason = '';
  int? killedBy; // 單機：主角被誰收割
  int _nextId = 0;
  int _nextPickup = 0;
  int _nameIdx = 0;
  int? introId; // 單機開場那個也拿一把鐮刀的路人甲
  double _pickupAcc = 0;
  double _itemAcc = 0;
  // 連線（房主）：地上鐮刀的增減，下一張畫面傳給客人
  bool trackPickups = false;
  final List<SsPickup> pickupAdded = [];
  final List<int> pickupRemoved = [];

  /// [humans] 為 null 是單機（主角＋路人甲開場）；否則是多人，依序建立真人（id 0..）。
  SsGame({int? seed, List<String>? humans})
      : rng = math.Random(seed),
        multi = humans != null {
    _buildMap(math.Random((seed ?? 0) ^ 0x5eed));
    if (humans == null) {
      final p = _spawnHuman('你', 0, shield: 2);
      _nameIdx = rng.nextInt(_botNames.length);
      // 開場：附近就有一個一樣只拿一把小鐮刀的人，衝過來找你單挑
      double ix = 0, iy = 0;
      for (var t = 0; t < 40; t++) {
        final b = rng.nextDouble() * math.pi * 2;
        ix = p.x + math.cos(b) * 330;
        iy = p.y + math.sin(b) * 330;
        if (_free(ix, iy, 40)) break;
      }
      final intro = _spawnBot(n: 1, x: ix, y: iy, name: '路人甲', aggr: 1, shield: 0);
      introId = intro.id;
    } else {
      _nameIdx = rng.nextInt(_botNames.length);
      for (var i = 0; i < humans.length; i++) {
        _spawnHuman(humans[i], i, shield: 3);
      }
    }
    final bots = math.max(6, ssFighterTotal - fighters.length);
    for (var i = 0; i < bots; i++) {
      // 場上一開始就有幾隻已經長大的，讓玩家知道目標在哪
      final n = i < 2 ? 18 + rng.nextInt(10) : (i < 5 ? 5 + rng.nextInt(6) : 1 + rng.nextInt(4));
      _spawnBot(n: n, awayFrom: fighters.first, shield: 0);
    }
    while (pickups.length < ssPickupCount) {
      _spawnPickup();
    }
    for (var i = 0; i < 4; i++) {
      _spawnItem();
    }
  }

  SsFighter get player => fighters.first;

  SsFighter? byId(int id) {
    for (final f in fighters) {
      if (f.id == id) return f;
    }
    return null;
  }

  // ---------------- 地圖 ----------------
  void _buildMap(math.Random r) {
    // 中央廣場：一圈六根石柱
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3 + math.pi / 6;
      obstacles.add(SsObstacle(1, math.cos(a) * 185, math.sin(a) * 185, 24, seed: r.nextInt(1 << 20)));
    }
    // 中圈：六座 L 形斷牆，開口方向亂轉
    final rot = r.nextDouble() * math.pi * 2;
    for (var i = 0; i < 6; i++) {
      final a = rot + i * math.pi / 3 + (r.nextDouble() - 0.5) * 0.3;
      final rr = 650 + r.nextDouble() * 120;
      final cx = math.cos(a) * rr, cy = math.sin(a) * rr;
      final face = a + math.pi + (r.nextBool() ? 0.8 : -0.8);
      final l1 = 150 + r.nextDouble() * 70, l2 = 110 + r.nextDouble() * 70;
      final a1 = face, a2 = face + math.pi / 2;
      obstacles.add(SsObstacle(3, cx, cy, 15, x2: cx + math.cos(a1) * l1, y2: cy + math.sin(a1) * l1, seed: r.nextInt(1 << 20)));
      obstacles.add(SsObstacle(3, cx, cy, 15, x2: cx + math.cos(a2) * l2, y2: cy + math.sin(a2) * l2, seed: r.nextInt(1 << 20)));
    }
    // 外圈：四個水池
    final rot2 = r.nextDouble() * math.pi * 2;
    for (var i = 0; i < 4; i++) {
      final a = rot2 + i * math.pi / 2 + (r.nextDouble() - 0.5) * 0.5;
      final rr = 1080 + r.nextDouble() * 120;
      obstacles.add(SsObstacle(2, math.cos(a) * rr, math.sin(a) * rr, 95 + r.nextDouble() * 45, seed: r.nextInt(1 << 20)));
    }
    // 散落的石塊
    for (var k = 0, tries = 0; k < 16 && tries < 400; tries++) {
      final a = r.nextDouble() * math.pi * 2;
      final rr = 320 + r.nextDouble() * 1100;
      final x = math.cos(a) * rr, y = math.sin(a) * rr;
      final rad = 22 + r.nextDouble() * 20;
      if (!_free(x, y, rad + 90)) continue;
      obstacles.add(SsObstacle(0, x, y, rad, seed: r.nextInt(1 << 20)));
      k++;
    }
    // 草叢
    for (var k = 0, tries = 0; k < 10 && tries < 400; tries++) {
      final a = r.nextDouble() * math.pi * 2;
      final rr = 380 + r.nextDouble() * 1000;
      final x = math.cos(a) * rr, y = math.sin(a) * rr;
      final rad = 70 + r.nextDouble() * 35;
      if (!_free(x, y, rad + 30)) continue;
      if (bushes.any((b) => _dist(b.x, b.y, x, y) < b.r + rad + 120)) continue;
      bushes.add(SsBush(x, y, rad, r.nextInt(1 << 20)));
      k++;
    }
    for (final o in obstacles) {
      if (!o.wall) {
        _avoid.addAll([o.x, o.y, o.r]);
      } else {
        final len = _dist(o.x, o.y, o.x2, o.y2);
        final steps = math.max(1, (len / 30).ceil());
        for (var i = 0; i <= steps; i++) {
          final t = i / steps;
          _avoid.addAll([o.x + (o.x2 - o.x) * t, o.y + (o.y2 - o.y) * t, o.r]);
        }
      }
    }
  }

  /// 這個點離所有障礙物至少 margin 遠
  bool _free(double x, double y, double margin) {
    if (math.sqrt(x * x + y * y) > ssArenaR - margin * 0.5 - 20) return false;
    for (final o in obstacles) {
      if (_obsDist(o, x, y) < o.r + margin) return false;
    }
    return true;
  }

  static double _obsDist(SsObstacle o, double x, double y) {
    if (!o.wall) return _dist(o.x, o.y, x, y);
    final (px, py) = _closestOnSeg(o, x, y);
    return _dist(px, py, x, y);
  }

  static (double, double) _closestOnSeg(SsObstacle o, double x, double y) {
    final dx = o.x2 - o.x, dy = o.y2 - o.y;
    final l2 = dx * dx + dy * dy;
    final t = l2 <= 0 ? 0.0 : (((x - o.x) * dx + (y - o.y) * dy) / l2).clamp(0.0, 1.0);
    return (o.x + dx * t, o.y + dy * t);
  }

  bool inBush(double x, double y) {
    for (final b in bushes) {
      final dx = b.x - x, dy = b.y - y;
      if (dx * dx + dy * dy < b.r * b.r * 0.8) return true;
    }
    return false;
  }

  (double, double) _randomFree(double margin, {SsFighter? awayFrom, double away = 700, double maxR = 0.9}) {
    var x = 0.0, y = 0.0;
    for (var tries = 0; tries < 60; tries++) {
      final a = rng.nextDouble() * math.pi * 2;
      final r = math.sqrt(rng.nextDouble()) * ssArenaR * maxR;
      x = math.cos(a) * r;
      y = math.sin(a) * r;
      if (!_free(x, y, margin)) continue;
      if (awayFrom != null && _dist(x, y, awayFrom.x, awayFrom.y) < away && tries < 40) continue;
      break;
    }
    return (x, y);
  }

  // ---------------- 生成 ----------------
  SsFighter _spawnHuman(String name, int seat, {double shield = 2}) {
    double x, y;
    if (!multi) {
      final (fx, fy) = _ringSpot(ssArenaR * 0.35);
      x = fx;
      y = fy;
    } else {
      // 真人散開出生，不要一開場就撞在一起
      final (fx, fy) = _ringSpot(ssArenaR * 0.55, angle: seat * math.pi * 2 / ssMaxHumans + 0.3);
      x = fx;
      y = fy;
    }
    final f = SsFighter(
      id: _nextId++,
      name: name,
      human: true,
      color: multi ? ssHumanColors[seat % ssHumanColors.length] : 0xFF64B5F6,
      skin: multi ? ssHumanSkins[seat % ssHumanSkins.length] : ssPlayerSkin,
      x: x,
      y: y,
      n: 1,
      angle: 0,
      shield: shield,
    );
    fighters.add(f);
    return f;
  }

  (double, double) _ringSpot(double r, {double? angle}) {
    var a = angle ?? rng.nextDouble() * math.pi * 2;
    for (var t = 0; t < 40; t++) {
      final x = math.cos(a) * r, y = math.sin(a) * r;
      if (_free(x, y, 50)) return (x, y);
      a += 0.13;
    }
    return (math.cos(a) * r, math.sin(a) * r);
  }

  /// 多人模式中途有人加入
  SsFighter addHuman(String name, int seat) {
    final f = _spawnHuman(name, seat, shield: 3);
    final (x, y) = _randomFree(60, awayFrom: _biggest(), away: 600, maxR: 0.85);
    f.x = x;
    f.y = y;
    // 補位：踢掉一個小隻的 NPC，總人數不要越來越多
    final bots = fighters.where((o) => !o.human && o.alive).toList()..sort((a, b) => a.n.compareTo(b.n));
    if (fighters.length > ssFighterTotal && bots.length > 6) fighters.remove(bots.first);
    return f;
  }

  /// 真人離開：交給電腦接手
  void dropHuman(int id) {
    final f = byId(id);
    if (f == null) return;
    f.human = false;
    f.name = '${f.name}(電腦)';
    inputs.remove(id);
  }

  SsFighter? _biggest() {
    SsFighter? b;
    for (final f in fighters) {
      if (f.alive && (b == null || f.n > b.n)) b = f;
    }
    return b;
  }

  SsFighter _spawnBot({required int n, double? x, double? y, SsFighter? awayFrom, String? name, double? aggr, double shield = 1.2}) {
    if (x == null || y == null) {
      final (fx, fy) = _randomFree(40, awayFrom: awayFrom);
      x = fx;
      y = fy;
    }
    final f = SsFighter(
      id: _nextId++,
      name: name ?? _botNames[_nameIdx++ % _botNames.length],
      human: false,
      color: ssColors[rng.nextInt(ssColors.length)],
      skin: ssSkinFirst + rng.nextInt(ssBladeColors.length - ssSkinFirst),
      x: x,
      y: y,
      n: n,
      angle: rng.nextDouble() * math.pi * 2,
      shield: shield,
      aggr: aggr ?? (0.25 + rng.nextDouble() * 0.7),
      caution: 0.6 + rng.nextDouble() * 0.8,
    );
    // 長大的 NPC 身上本來就混了一些撿來的彩色刀
    for (var i = 0; i < n ~/ 3; i++) {
      final g = rng.nextInt(4);
      f.mix[f.skin]--;
      f.mix[g]++;
    }
    fighters.add(f);
    return f;
  }

  void _spawnPickup({double? x, double? y, int? grade}) {
    if (x == null || y == null) {
      final (fx, fy) = _randomFree(18, maxR: 0.96);
      x = fx;
      y = fy;
    }
    if (grade == null) {
      var roll = rng.nextInt(100);
      grade = 0;
      while (roll >= _pickupWeight[grade!]) {
        roll -= _pickupWeight[grade];
        grade++;
      }
    }
    final p = SsPickup(_nextPickup++, x, y, rng.nextDouble() * math.pi * 2, grade);
    pickups.add(p);
    if (trackPickups) pickupAdded.add(p);
  }

  void _spawnItem() {
    final (x, y) = _randomFree(40, maxR: 0.88);
    final t = SsItemType.values[rng.nextInt(SsItemType.values.length)];
    items.add(SsItem(x, y, t, rng.nextDouble() * math.pi * 2));
  }

  static double _dist(double ax, double ay, double bx, double by) {
    final dx = ax - bx, dy = ay - by;
    return math.sqrt(dx * dx + dy * dy);
  }

  // ---------------- 移動 ----------------
  /// 一個人往 (wx,wy) 走一步：慣性、障礙物、場地邊界、轉刀。客人端自己的角色也用這個。
  void moveFighter(SsFighter f, double wx, double wy, double dt) {
    final sp = ssSpeed(f.n) * (f.human ? 1 : 0.93) * (f.has(SsItemType.boots) ? 1.45 : 1);
    // 加速度：起步、轉向有一點點慣性，撞開時的反彈才看得出來
    final k = 1 - math.exp(-9 * dt);
    f.vx += (wx * sp - f.vx) * k;
    f.vy += (wy * sp - f.vy) * k;
    f.x += f.vx * dt;
    f.y += f.vy * dt;
    final sv = f.vx * f.vx + f.vy * f.vy;
    if (sv > 400) {
      final l = math.sqrt(sv);
      f.faceX = f.vx / l;
      f.faceY = f.vy / l;
    }
    collide(f);
    f.angle += f.spin * dt;
  }

  /// 把人推出障礙物與場地外
  void collide(SsFighter f) {
    for (final o in obstacles) {
      double cx, cy;
      if (o.wall) {
        (cx, cy) = _closestOnSeg(o, f.x, f.y);
      } else {
        cx = o.x;
        cy = o.y;
      }
      final dx = f.x - cx, dy = f.y - cy;
      final lim = o.r + ssBodyR;
      final d2 = dx * dx + dy * dy;
      if (d2 >= lim * lim) continue;
      final d = math.sqrt(d2);
      final nx = d < 1e-6 ? 1.0 : dx / d, ny = d < 1e-6 ? 0.0 : dy / d;
      f.x = cx + nx * lim;
      f.y = cy + ny * lim;
      final vn = f.vx * nx + f.vy * ny;
      if (vn < 0) {
        // 沿著障礙物滑過去，不要黏住
        f.vx -= vn * nx;
        f.vy -= vn * ny;
      }
    }
    final d = math.sqrt(f.x * f.x + f.y * f.y);
    final lim = ssArenaR - ssBodyR;
    if (d > lim) {
      f.x *= lim / d;
      f.y *= lim / d;
      final nx = f.x / d, ny = f.y / d;
      final vn = f.vx * nx + f.vy * ny;
      if (vn > 0) {
        f.vx -= vn * nx * 1.5;
        f.vy -= vn * ny * 1.5;
      }
    }
  }

  /// 前進一個固定步長。單機：ix/iy 是主角的搖桿方向（長度 0~1）。
  void step([double ix = 0, double iy = 0]) {
    if (!multi) inputs[player.id] = (ix, iy);
    if (over) return;
    const dt = ssDt;
    time += dt;
    tick++;

    for (final f in fighters) {
      if (!f.alive) continue;
      if (f.shield > 0) f.shield -= dt;
      if (f.flash > 0) f.flash -= dt;
      if (f.buffs.isNotEmpty) {
        for (final t in f.buffs.keys.toList()) {
          final v = f.buffs[t]! - dt;
          if (v <= 0) {
            f.buffs.remove(t);
          } else {
            f.buffs[t] = v;
          }
        }
      }
      double wx, wy;
      if (f.human) {
        (wx, wy) = inputs[f.id] ?? (0.0, 0.0);
      } else {
        f.think -= dt;
        if (f.think <= 0) _think(f);
        wx = f.tx;
        wy = f.ty;
        // 卡住（想走卻幾乎沒動）就隨便換個方向走一下
        if (f.unstick > 0) {
          f.unstick -= dt;
        } else if ((wx != 0 || wy != 0) && f.vx * f.vx + f.vy * f.vy < 40 * 40) {
          f.stuck += dt;
          if (f.stuck > 0.5) {
            f.stuck = 0;
            f.unstick = 0.6;
            final a = rng.nextDouble() * math.pi * 2;
            f.tx = math.cos(a);
            f.ty = math.sin(a);
          }
        } else {
          f.stuck = 0;
        }
      }
      moveFighter(f, wx, wy, dt);
      f.hidden = inBush(f.x, f.y);
    }

    _collectPickups();
    _combat(dt);

    // 重生：NPC 換一個新的（後期重生的帶比較多鐮刀，不然金圈沒東西吃）；多人模式的真人原地復活
    for (final f in fighters.toList()) {
      if (f.alive || f.respawnAt <= 0 || time < f.respawnAt) continue;
      f.respawnAt = 0;
      if (f.human) {
        _reviveHuman(f);
      } else {
        final extra = (time / 30).floor();
        _spawnBot(n: 1 + rng.nextInt(3 + extra * 2), awayFrom: fighters.first);
      }
    }
    fighters.removeWhere((f) => !f.alive && !f.human && f.respawnAt == 0);
    _itemAcc += dt;
    if (_itemAcc >= ssItemEvery) {
      _itemAcc = 0;
      if (items.length < ssItemMax) _spawnItem();
    }
    _pickupAcc += ssPickupRate * dt;
    while (_pickupAcc >= 1) {
      _pickupAcc -= 1;
      if (pickups.length < ssPickupCount) _spawnPickup();
    }

    if (time >= ssRoundSec) {
      over = true;
      overReason = 'time';
      events.add(SsEvent(SsEvType.over, 0, 0));
    }
  }

  void _reviveHuman(SsFighter f) {
    final (x, y) = _randomFree(60, awayFrom: _biggest(), away: 600, maxR: 0.85);
    f
      ..x = x
      ..y = y
      ..vx = 0
      ..vy = 0
      ..alive = true
      ..shield = 2.5
      ..wear = 0
      ..killedBy = null
      ..respawns += 1;
    f.buffs.clear();
    f.clearBlades();
    f.addBlades(f.skin, 1);
  }

  void _removePickupAt(int i) {
    final p = pickups.removeAt(i);
    if (trackPickups) pickupRemoved.add(p.id);
  }

  void _collectPickups() {
    for (final f in fighters) {
      if (!f.alive) continue;
      final r = f.ringR + 10;
      final r2 = r * r;
      // 磁鐵：大範圍內的鐮刀往自己飛過來
      final mag = f.has(SsItemType.magnet);
      final mr = r * 2 + 260;
      final mr2 = mr * mr;
      for (var i = pickups.length - 1; i >= 0; i--) {
        final p = pickups[i];
        final dx = p.x - f.x, dy = p.y - f.y;
        final d2 = dx * dx + dy * dy;
        if (d2 < r2) {
          _removePickupAt(i);
          _gain(f, p.value, p.grade);
          if (f.human) events.add(SsEvent(SsEvType.pickup, p.x, p.y, a: f.id, count: p.value, b: p.grade));
        } else if (mag && d2 < mr2) {
          final d = math.sqrt(d2);
          final pull = math.min(d, 520 * ssDt);
          p.x -= dx / d * pull;
          p.y -= dy / d * pull;
          if (trackPickups) pickupAdded.add(p); // 位置變了，客人那邊也要跟著動
        }
      }
      for (var i = items.length - 1; i >= 0; i--) {
        final it = items[i];
        if (_dist(it.x, it.y, f.x, f.y) < ssItemReach) {
          items.removeAt(i);
          f.buffs[it.type] = ssItemDur[it.type]!;
          events.add(SsEvent(SsEvType.item, it.x, it.y, a: f.id, count: it.type.index));
        }
      }
    }
  }

  void _gain(SsFighter f, int k, int color) {
    final before = f.level;
    f.addBlades(color, k);
    _levelUp(f, before);
  }

  /// 升層了：發事件（count = 新的層數，0 起算）
  void _levelUp(SsFighter f, int before) {
    final after = f.level;
    if (after > before) {
      events.add(SsEvent(f.n >= ssGold ? SsEvType.gold : SsEvType.silver, f.x, f.y, a: f.id, count: after));
    }
  }

  double _power(SsFighter a, double nx, double ny) {
    // nx,ny：a → 對方 的單位向量。正在衝向對方的一方佔便宜。
    final sp = ssSpeed(a.n);
    final approach = ((a.vx * nx + a.vy * ny) / sp).clamp(0.0, 1.0);
    // 開場路人甲的鐮刀是生鏽的（前 15 秒力量 ×0.3），主角第一戰一定打得贏
    final rusty = a.id == introId && time < 15 ? 0.3 : 1.0;
    final rage = a.has(SsItemType.rage) ? 1.8 : 1.0;
    return a.n * (1 + 0.6 * approach) * (a.human ? 1.1 : 1.0) * rusty * rage;
  }

  bool _dull(SsFighter a, SsFighter b) => a.id == introId && b.human && time < 15;

  /// a 的刀尖有沒有碰到 b 的身體
  bool _bladeHitsBody(SsFighter a, SsFighter b) {
    final pts = a.bladePoints(tick);
    final lim = ssBodyR + a.bladeSize * _bladePtR * 0.8;
    final l2 = lim * lim;
    for (var i = 0; i < pts.length; i += 2) {
      final dx = pts[i] - b.x, dy = pts[i + 1] - b.y;
      if (dx * dx + dy * dy < l2) return true;
    }
    return false;
  }

  /// 兩圈刀有沒有真的碰在一起，有的話回傳碰撞點
  (double, double)? _bladeClash(SsFighter a, SsFighter b) {
    final pa = a.bladePoints(tick), pb = b.bladePoints(tick);
    final lim = (a.bladeSize + b.bladeSize) * _bladePtR;
    final l2 = lim * lim;
    // 先挑出靠近對方刀圈的點，省得兩兩全比
    final ra = b.reach + a.bladeSize * _bladePtR, rb = a.reach + b.bladeSize * _bladePtR;
    final innerA = math.max(0.0, b.ringR - b.bladeSize * 0.9), innerB = math.max(0.0, a.ringR - a.bladeSize * 0.9);
    for (var i = 0; i < pa.length; i += 2) {
      final ax = pa[i], ay = pa[i + 1];
      final da = _dist(ax, ay, b.x, b.y);
      if (da > ra || da < innerA) continue;
      for (var j = 0; j < pb.length; j += 2) {
        final bx = pb[j], by = pb[j + 1];
        final dx = ax - bx, dy = ay - by;
        if (dx * dx + dy * dy < l2) {
          final db = _dist(bx, by, a.x, a.y);
          if (db > rb || db < innerB) continue;
          return ((ax + bx) / 2, (ay + by) / 2);
        }
      }
    }
    return null;
  }

  void _combat(double dt) {
    for (final k in _pairCd.keys.toList()) {
      final v = _pairCd[k]! - dt;
      if (v <= 0) {
        _pairCd.remove(k);
      } else {
        _pairCd[k] = v;
      }
    }
    final list = fighters.where((f) => f.alive).toList();
    for (var i = 0; i < list.length; i++) {
      final a = list[i];
      if (!a.alive) continue;
      for (var j = i + 1; j < list.length; j++) {
        final b = list[j];
        if (!b.alive || !a.alive) continue;
        final dx = b.x - a.x, dy = b.y - a.y;
        final reach = a.reach + b.reach;
        if (dx.abs() > reach + 20 || dy.abs() > reach + 20) continue;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d > reach + 4 || d < 1e-6) continue;
        final nx = dx / d, ny = dy / d;
        // 身體不會重疊
        if (d < ssBodyR * 2) _push(a, b, nx, ny, 160);
        if (a.shield > 0 || b.shield > 0) {
          // 保護中：只會被輕輕推開
          if (d < reach * 0.8) _push(a, b, nx, ny, 120);
          continue;
        }
        final ga = a.has(SsItemType.guard), gb = b.has(SsItemType.guard);
        // 刀尖碰到身體 = 收割（金鐘罩擋得住）
        // 開場路人甲的刀是鈍的：前 15 秒收割不了主角
        final aHits = a.n > 0 && !gb && !_dull(a, b) && d < a.reach + ssBodyR && _bladeHitsBody(a, b);
        final bHits = b.n > 0 && !ga && !_dull(b, a) && d < b.reach + ssBodyR && _bladeHitsBody(b, a);
        if (aHits || bHits) {
          if (aHits && bHits) {
            final pa = _power(a, nx, ny), pb = _power(b, -nx, -ny);
            pa >= pb ? _kill(a, b) : _kill(b, a);
          } else {
            aHits ? _kill(a, b) : _kill(b, a);
          }
          continue;
        }
        // 刀碰刀 = 互相磨損、彈開
        if (a.n > 0 && b.n > 0 && d < reach) {
          final key = a.id * 100000 + b.id;
          if (_pairCd.containsKey(key)) continue;
          final hit = _bladeClash(a, b);
          if (hit == null) continue;
          _pairCd[key] = 0.12;
          final pa = _power(a, nx, ny), pb = _power(b, -nx, -ny);
          // 每次碰撞的磨損：雙方平均力量決定打多兇，力量比決定誰吃虧（比例 1.5 次方，
          // 多一點點就明顯佔上風；40 把撞 5 把幾乎一次就把對方磨光）
          final base = 0.3 + (pa + pb) * 0.025;
          final ratio = (pa / pb).clamp(0.1, 10.0);
          if (!ga) a.wear += base * math.pow(1 / ratio, 1.5);
          if (!gb) b.wear += base * math.pow(ratio, 1.5);
          final (cx, cy) = hit;
          final lostA = _wearOff(a, cx, cy), lostB = _wearOff(b, cx, cy);
          if (lostA > 0) a.flash = 0.12;
          if (lostB > 0) b.flash = 0.12;
          _push(a, b, nx, ny, 260);
          // 刀被擋一下：兩圈都往回彈一點點
          a.angle -= 0.12;
          b.angle -= 0.12;
          events.add(SsEvent(SsEvType.clash, cx, cy, a: a.id, b: b.id, count: lostA + lostB));
        }
      }
    }
  }

  int _wearOff(SsFighter f, double cx, double cy) {
    var lost = 0;
    while (f.wear >= 1 && f.n > 0) {
      f.wear -= 1;
      final col = f.dropOne(rng);
      lost++;
      // 斷掉的鐮刀有一半掉在地上，誰都能撿（彩色的掉下去還是彩色）
      if (rng.nextDouble() < 0.5) {
        final a = rng.nextDouble() * math.pi * 2;
        final r = 30 + rng.nextDouble() * 50;
        final px = cx + math.cos(a) * r, py = cy + math.sin(a) * r;
        if (_free(px, py, 10)) _spawnPickup(x: px, y: py, grade: col < ssSkinFirst ? math.min(col, 1) : 0);
      }
    }
    if (f.n == 0) f.wear = 0;
    return lost;
  }

  void _push(SsFighter a, SsFighter b, double nx, double ny, double imp) {
    // 大隻的比較推不動
    final wa = 1 / (1 + a.n * 0.03), wb = 1 / (1 + b.n * 0.03);
    final ka = imp * wa / (wa + wb) * 2, kb = imp * wb / (wa + wb) * 2;
    a.vx -= nx * ka;
    a.vy -= ny * ka;
    b.vx += nx * kb;
    b.vy += ny * kb;
    if (a.human) {
      a.impX -= nx * ka;
      a.impY -= ny * ka;
    }
    if (b.human) {
      b.impX += nx * kb;
      b.impY += ny * kb;
    }
  }

  void _kill(SsFighter killer, SsFighter victim) {
    final got = math.max(1, victim.n); // 空手的人也至少吸到他身上那把柄
    final before = killer.level;
    if (victim.n == 0) {
      killer.addBlades(victim.skin, 1);
    } else {
      for (var i = 0; i < victim.mix.length; i++) {
        if (victim.mix[i] > 0) killer.addBlades(i, victim.mix[i]);
      }
    }
    victim.alive = false;
    victim.clearBlades();
    victim.killedBy = killer.id;
    victim.buffs.clear();
    killer.kills++;
    _levelUp(killer, before);
    events.add(SsEvent(SsEvType.kill, victim.x, victim.y, a: killer.id, b: victim.id, count: got, x2: killer.x, y2: killer.y));
    if (victim.human && !multi) {
      over = true;
      overReason = 'dead';
      killedBy = killer.id;
      events.add(SsEvent(SsEvType.over, victim.x, victim.y));
    } else {
      victim.respawnAt = time + ssRespawnSec;
    }
  }

  // ---------------- NPC ----------------
  void _think(SsFighter b) {
    b.think = 0.15 + rng.nextDouble() * 0.2;
    // 開場路人甲：前 10 秒直直衝向玩家
    if (b.id == introId && time < 10 && player.alive) {
      _aim(b, player.x + player.vx * 0.2, player.y + player.vy * 0.2);
      return;
    }
    var fx = 0.0, fy = 0.0;
    var flee = false;
    SsFighter? prey;
    var best = double.infinity;
    for (final o in fighters) {
      if (!o.alive || o.id == b.id) continue;
      final dx = o.x - b.x, dy = o.y - b.y;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < 1) continue;
      if (o.hidden && d > 170) continue; // 躲在草叢裡的看不到
      final danger = o.reach + b.reach + 200 * b.caution;
      if (o.n > b.n * 1.15 + 1 && d < danger && o.shield <= 0) {
        final w = (danger - d) / danger;
        fx -= dx / d * w;
        fy -= dy / d * w;
        flee = true;
      } else if (b.n >= o.n * 1.25 + 1 || (b.n >= o.n && b.aggr > 0.75)) {
        if (o.human && time < 10) continue; // 開場 10 秒除了路人甲，其他人先不找玩家麻煩
        if (d < 420 + b.aggr * 300 && o.shield <= 0) {
          final score = d - (b.n - o.n) * 4 - (o.human ? 60 : 0); // 稍微偏愛追玩家
          if (score < best) {
            best = score;
            prey = o;
          }
        }
      }
    }
    if (flee) {
      final l = math.sqrt(fx * fx + fy * fy);
      // 逃的時候往場中央偏，不要自己卡在牆角
      final cx = -b.x / ssArenaR * 0.5, cy = -b.y / ssArenaR * 0.5;
      _setDir(b, fx / l + cx, fy / l + cy);
      b.chaseId = null;
      return;
    }
    if (prey != null && (b.chaseId == prey.id || rng.nextDouble() < b.aggr)) {
      b.chaseId = prey.id;
      _aim(b, prey.x + prey.vx * 0.35, prey.y + prey.vy * 0.35);
      return;
    }
    b.chaseId = null;
    SsItem? item;
    var id = 380.0;
    for (final it in items) {
      final d = _dist(it.x, it.y, b.x, b.y);
      if (d < id) {
        id = d;
        item = it;
      }
    }
    if (item != null) {
      _aim(b, item.x, item.y);
      return;
    }
    SsPickup? near;
    var nd = 650.0;
    for (final p in pickups) {
      // 高等級的鐮刀比較值得繞路
      final d = _dist(p.x, p.y, b.x, b.y) - p.grade * 70;
      if (d < nd) {
        nd = d;
        near = p;
      }
    }
    if (near != null) {
      _aim(b, near.x, near.y);
    } else {
      final a = rng.nextDouble() * math.pi * 2;
      _aim(b, math.cos(a) * ssArenaR * 0.5, math.sin(a) * ssArenaR * 0.5);
    }
  }

  void _aim(SsFighter b, double x, double y) => _setDir(b, x - b.x, y - b.y);

  void _setDir(SsFighter b, double dx, double dy) {
    // 靠牆時加一點往內的力
    final d0 = math.sqrt(b.x * b.x + b.y * b.y);
    if (d0 > ssArenaR - 220) {
      final w = (d0 - (ssArenaR - 220)) / 220;
      final l = math.sqrt(dx * dx + dy * dy);
      if (l > 0) {
        dx = dx / l - b.x / d0 * w * 1.5;
        dy = dy / l - b.y / d0 * w * 1.5;
      }
    }
    var l = math.sqrt(dx * dx + dy * dy);
    if (l < 1e-6) {
      b.tx = b.ty = 0;
      return;
    }
    var ux = dx / l, uy = dy / l;
    // 避開前方的障礙物：往側邊偏
    var sx = 0.0, sy = 0.0;
    for (var i = 0; i < _avoid.length; i += 3) {
      final ox = _avoid[i] - b.x, oy = _avoid[i + 1] - b.y;
      final t = ox * ux + oy * uy;
      if (t < 0 || t > 150) continue;
      final cross = ux * oy - uy * ox; // >0：障礙物在左邊
      final clear = _avoid[i + 2] + ssBodyR + 14;
      if (cross.abs() > clear) continue;
      final w = (1 - t / 150) * (1 - cross.abs() / clear) + 0.3;
      final side = cross > 0 ? -1.0 : 1.0;
      sx += -uy * side * w;
      sy += ux * side * w;
    }
    if (sx != 0 || sy != 0) {
      ux += sx * 1.6;
      uy += sy * 1.6;
      l = math.sqrt(ux * ux + uy * uy);
      ux /= l;
      uy /= l;
    }
    b.tx = ux;
    b.ty = uy;
  }

  /// 目前排名（活著的 + 真人），依鐮刀數。
  List<SsFighter> ranking() {
    final l = fighters.where((f) => f.alive || f.human).toList();
    l.sort((a, b) => b.n != a.n ? b.n.compareTo(a.n) : a.id.compareTo(b.id));
    return l;
  }

  int rankOf(SsFighter p) {
    if (!p.alive && !multi) {
      // 單機死掉時用死前最大值跟現在活著的比
      return 1 + fighters.where((f) => f.alive && f.n > p.peak).length;
    }
    final r = ranking().indexOf(p);
    return r < 0 ? fighters.length : r + 1;
  }

  int playerRank() => rankOf(player);

  // ---------------- 連線 ----------------
  // 房主每隔幾幀呼叫 snap() 傳給客人；客人用 applySnap() 更新自己的鏡像，再用 mirrorTick() 補動畫。

  /// [fullPickups]：連地上全部鐮刀都附上（剛加入的人、或每隔幾秒對一次帳）。
  Map<String, dynamic> snap({bool fullPickups = false, List<SsEvent>? evs}) {
    final m = <String, dynamic>{
      'k': 's',
      't': (time * 1000).round(),
      if (over) 'ov': 1,
      'f': [
        for (final f in fighters)
          [
            f.id, f.x.round(), f.y.round(), f.vx.round(), f.vy.round(), f.n, //
            ((f.angle % (math.pi * 2)) * 1000).round(),
            (f.alive ? 1 : 0) | (f.hidden ? 2 : 0) | (f.flash > 0 ? 4 : 0) | (f.human ? 8 : 0),
            f.kills, f.peak, f.color, f.skin, f.respawns,
            (f.shield * 10).round(),
            [for (final t in SsItemType.values) ((f.buffs[t] ?? 0) * 10).round()],
            [for (var i = 0; i < f.mix.length; i++) if (f.mix[i] > 0) ...[i, f.mix[i]]],
            f.name,
            f.alive ? 0 : ((f.respawnAt - time) * 10).round(),
            f.killedBy ?? -1,
            f.impX.round(), f.impY.round(),
          ],
      ],
      'it': [for (final it in items) [it.x.round(), it.y.round(), it.type.index]],
      'ev': [
        for (final e in evs ?? events) [e.type.index, e.x.round(), e.y.round(), e.a, e.b, e.count, e.x2.round(), e.y2.round()],
      ],
    };
    for (final f in fighters) {
      f.impX = f.impY = 0;
    }
    if (fullPickups) {
      m['pf'] = [for (final p in pickups) [p.id, p.x.round(), p.y.round(), p.grade]];
    } else {
      final seen = <int>{};
      m['pa'] = [
        for (final p in pickupAdded.reversed)
          if (seen.add(p.id)) [p.id, p.x.round(), p.y.round(), p.grade],
      ];
      m['pd'] = List<int>.of(pickupRemoved);
    }
    pickupAdded.clear();
    pickupRemoved.clear();
    return m;
  }

  /// 客人：套用房主的畫面。[meId] 是自己的角色，位置由自己算（除非差太多或剛重生）。
  /// 回傳房主推了自己多少（要加到自己的速度上）。
  (double, double) applySnap(Map<String, dynamic> m, int meId) {
    time = (m['t'] as num) / 1000;
    over = m['ov'] == 1;
    if (over) overReason = 'time';
    var impX = 0.0, impY = 0.0;
    final keep = <int>{};
    final old = {for (final f in fighters) f.id: f};
    final list = <SsFighter>[];
    for (final raw in m['f'] as List) {
      final r = raw as List;
      final id = r[0] as int;
      keep.add(id);
      final flags = r[7] as int;
      var f = old[id];
      final x = (r[1] as num).toDouble(), y = (r[2] as num).toDouble();
      if (f == null) {
        f = SsFighter(
          id: id,
          name: r[16] as String,
          human: flags & 8 != 0,
          color: r[10] as int,
          skin: r[11] as int,
          x: x,
          y: y,
          n: 0,
          angle: (r[6] as num) / 1000,
        );
        f.respawns = r[12] as int;
      }
      f.name = r[16] as String;
      f.human = flags & 8 != 0;
      f.sx = x;
      f.sy = y;
      f.sa = (r[6] as num) / 1000;
      final wasAlive = f.alive;
      f.alive = flags & 1 != 0;
      f.hidden = flags & 2 != 0;
      if (flags & 4 != 0) f.flash = 0.12;
      f.kills = r[8] as int;
      f.peak = r[9] as int;
      f.shield = (r[13] as num) / 10;
      final bl = r[14] as List;
      f.buffs.clear();
      for (var i = 0; i < SsItemType.values.length && i < bl.length; i++) {
        final v = (bl[i] as num) / 10;
        if (v > 0) f.buffs[SsItemType.values[i]] = v;
      }
      for (var i = 0; i < f.mix.length; i++) {
        f.mix[i] = 0;
      }
      final mx = r[15] as List;
      for (var i = 0; i + 1 < mx.length; i += 2) {
        final c = mx[i] as int;
        if (c >= 0 && c < f.mix.length) f.mix[c] = mx[i + 1] as int;
      }
      f.n = r[5] as int;
      f.respawnAt = f.alive ? 0 : time + (r[17] as num) / 10;
      final kb = r[18] as int;
      f.killedBy = kb < 0 ? null : kb;
      final rs = r[12] as int;
      if (id == meId) {
        impX = (r[19] as num).toDouble();
        impY = (r[20] as num).toDouble();
        // 自己：剛重生、剛出現或跟房主差太遠才瞬移
        final far = _dist(f.x, f.y, x, y) > 160;
        if (rs != f.respawns || far || (!wasAlive && f.alive) || !old.containsKey(id)) {
          f.x = x;
          f.y = y;
          f.vx = 0;
          f.vy = 0;
        }
      } else {
        f.vx = (r[3] as num).toDouble();
        f.vy = (r[4] as num).toDouble();
        if (!old.containsKey(id) || rs != f.respawns || _dist(f.x, f.y, x, y) > 250) {
          f.x = x;
          f.y = y;
          f.angle = f.sa;
        }
      }
      f.respawns = rs;
      list.add(f);
    }
    fighters
      ..clear()
      ..addAll(list);
    items
      ..clear()
      ..addAll([
        for (final raw in m['it'] as List)
          SsItem(((raw as List)[0] as num).toDouble(), (raw[1] as num).toDouble(), SsItemType.values[raw[2] as int], (raw[0] as num) * 0.37),
      ]);
    if (m['pf'] != null) {
      pickups
        ..clear()
        ..addAll([for (final raw in m['pf'] as List) _pickFrom(raw as List)]);
    } else {
      final del = {for (final id in (m['pd'] as List? ?? const [])) id as int};
      final add = {for (final raw in (m['pa'] as List? ?? const [])) (raw as List)[0] as int: raw};
      pickups.removeWhere((p) => del.contains(p.id) || add.containsKey(p.id));
      for (final raw in add.values) {
        if (!del.contains(raw[0])) pickups.add(_pickFrom(raw));
      }
    }
    for (final raw in m['ev'] as List) {
      final e = raw as List;
      events.add(SsEvent(SsEvType.values[e[0] as int], (e[1] as num).toDouble(), (e[2] as num).toDouble(),
          a: e[3] as int, b: e[4] as int, count: e[5] as int, x2: (e[6] as num).toDouble(), y2: (e[7] as num).toDouble()));
    }
    return (impX, impY);
  }

  SsPickup _pickFrom(List r) =>
      SsPickup(r[0] as int, (r[1] as num).toDouble(), (r[2] as num).toDouble(), (r[0] as int) * 0.618 % (math.pi * 2), r[3] as int);

  /// 客人端每幀：別人照速度往前推、慢慢修正到房主的位置；自己用本機的搖桿移動。
  void mirrorTick(double dt, int meId, double ix, double iy) {
    if (!over) time += dt;
    final k = 1 - math.exp(-10 * dt);
    for (final f in fighters) {
      if (f.flash > 0) f.flash -= dt;
      if (!f.alive) continue;
      if (f.id == meId) {
        moveFighter(f, ix, iy, dt);
        continue;
      }
      f.sx += f.vx * dt;
      f.sy += f.vy * dt;
      f.x += f.vx * dt + (f.sx - f.x) * k;
      f.y += f.vy * dt + (f.sy - f.y) * k;
      f.sa += f.spin * dt;
      var da = (f.sa - f.angle) % (math.pi * 2);
      if (da > math.pi) da -= math.pi * 2;
      f.angle += f.spin * dt + da * k;
      final sv = f.vx * f.vx + f.vy * f.vy;
      if (sv > 400) {
        final l = math.sqrt(sv);
        f.faceX = f.vx / l;
        f.faceY = f.vy / l;
      }
    }
  }

  /// 房主：收到客人回報的位置與搖桿
  void setRemote(int id, double x, double y, double vx, double vy, double ix, double iy) {
    final f = byId(id);
    if (f == null || !f.human) return;
    inputs[id] = (ix.clamp(-1.0, 1.0), iy.clamp(-1.0, 1.0));
    if (!f.alive) return;
    // 信任客人的位置，但不能一次瞬移太遠（防亂傳）
    if (_dist(f.x, f.y, x, y) > 220) return;
    f.x = x;
    f.y = y;
    f.vx = vx.clamp(-600.0, 600.0);
    f.vy = vy.clamp(-600.0, 600.0);
    collide(f);
  }
}
