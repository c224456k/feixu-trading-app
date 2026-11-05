// 鐮刀風暴（試玩）：規則與 NPC AI，純 Dart、不碰畫面，方便用測試直接跑模擬。
//
// 玩法：每個人身邊繞著一圈旋轉的鐮刀。兩圈鐮刀撞在一起會互相磨損（鐮刀多、正在往前衝
// 的一方磨得比較少），撞到「人」就是收割——對方全部的鐮刀瞬間被吸過來，圈越轉越大，
// 30 把以上變成金光暴風圈。地上散落的鐮刀碰到就撿。3 分鐘結束時鐮刀最多的人贏，
// 中途被收割就結束。
import 'dart:math' as math;

const ssArenaR = 1500.0; // 圓形場地半徑
const ssBodyR = 16.0; // 人的身體半徑
const ssSilver = 12; // 12 把起變銀圈
const ssGold = 30; // 30 把起變金光暴風圈
const ssRoundSec = 180.0;
const ssDt = 1 / 60;
const ssBotCount = 13;
const ssPickupCount = 100; // 地上最多幾把
const ssPickupRate = 1.8; // 每秒補幾把（限速，不然光撿就撿到爆，打架反而不划算）

/// 地上鐮刀的等級：顏色代表撿到加幾把（白 1、綠 2、藍 3、紫 5、橘 8）。
const ssPickupValue = [1, 2, 3, 5, 8];
const _pickupWeight = [66, 20, 9, 4, 1];

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

/// 鐮刀圈半徑：一把也要比身體大一圈，之後隨數量變大（開根號左右，不會大到失控）。
double ssRingR(int n) => n <= 0 ? ssBodyR : 28 + 4.2 * math.pow(n, 0.65);

/// 圈越大跑越慢，小隻的才有機會逃。
double ssSpeed(int n) => 250 / (1 + n * 0.004);

int ssTier(int n) => n >= ssGold ? 2 : (n >= ssSilver ? 1 : 0);

const _botNames = [
  '割草阿伯', '鐮刀妹', '收割者', '稻田之神', '老農夫', '小紅帽', '死神學徒', '田中先生', //
  '秋收大叔', '麥田守望者', '鏽鐮刀', '月光收割', '彎月劍客', '草原狼', '風車村長', '打穀機',
  '黑袍客', '稻草人', '鐵匠之子', '夜行者',
];

const ssColors = [
  0xFFE57373, 0xFF81C784, 0xFFFFB74D, 0xFFBA68C8, 0xFF4DD0E1, 0xFFF06292, 0xFFAED581, //
  0xFFFF8A65, 0xFF9575CD, 0xFFFFD54F, 0xFF4DB6AC, 0xFF90A4AE, 0xFFDCE775, 0xFF7986CB,
];

class SsFighter {
  final int id;
  final String name;
  final bool player;
  final int color;
  double x, y;
  double vx = 0, vy = 0;
  int n;
  double wear = 0; // 磨損累積到 1 就掉一把
  double angle;
  bool alive = true;
  int kills = 0;
  int peak;
  double shield; // 出生保護（秒）：期間不會受傷也不會傷人
  double respawnAt = 0;
  double flash = 0; // 被打到時閃白（畫面用）
  double faceX = 1, faceY = 0; // 臉朝向
  // NPC 專用
  double think = 0;
  double tx = 0, ty = 0; // 想走的方向（單位向量或 0）
  final double aggr; // 積極度 0~1
  final double caution; // 謹慎度：多遠就開始逃
  int? chaseId;
  // 道具效果剩餘秒數
  final buffs = <SsItemType, double>{};
  bool has(SsItemType t) => (buffs[t] ?? 0) > 0;

  SsFighter({
    required this.id,
    required this.name,
    required this.player,
    required this.color,
    required this.x,
    required this.y,
    required this.n,
    required this.angle,
    this.shield = 1.5,
    this.aggr = 0.5,
    this.caution = 1,
  }) : peak = n;

  double get ringR => ssRingR(n);
  int get tier => ssTier(n);
  double get spin => const [3.4, 4.4, 5.8][tier];
}

class SsPickup {
  double x, y;
  final double phase;
  final int grade; // 0~4
  SsPickup(this.x, this.y, this.phase, this.grade);
  int get value => ssPickupValue[grade];
}

class SsItem {
  final double x, y;
  final SsItemType type;
  final double phase;
  SsItem(this.x, this.y, this.type, this.phase);
}

const ssItemReach = ssBodyR + 30; // 道具要用身體去碰（不是鐮刀圈）

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
  final List<SsFighter> fighters = [];
  final List<SsPickup> pickups = [];
  final List<SsItem> items = [];
  final List<SsEvent> events = []; // 畫面每幀取走，做特效用
  final Map<int, double> _pairCd = {};
  double time = 0;
  bool over = false;
  String overReason = '';
  int? killedBy;
  int _nextId = 0;
  int _nameIdx = 0;
  int? introId; // 開場那個也拿一把鐮刀的路人甲
  double _pickupAcc = 0;
  double _itemAcc = 0;

  SsGame({int? seed}) : rng = math.Random(seed) {
    final a = rng.nextDouble() * math.pi * 2;
    final r = ssArenaR * 0.35;
    fighters.add(SsFighter(
      id: _nextId++,
      name: '你',
      player: true,
      color: 0xFF64B5F6,
      x: math.cos(a) * r,
      y: math.sin(a) * r,
      n: 1,
      angle: 0,
      shield: 2,
    ));
    _nameIdx = rng.nextInt(_botNames.length);
    // 開場：附近就有一個一樣只拿一把小鐮刀的人，衝過來找你單挑
    final p = player;
    final b = rng.nextDouble() * math.pi * 2;
    final intro = _spawnBot(n: 1, x: p.x + math.cos(b) * 330, y: p.y + math.sin(b) * 330, name: '路人甲', aggr: 1, shield: 0);
    introId = intro.id;
    for (var i = 1; i < ssBotCount; i++) {
      // 場上一開始就有幾隻已經長大的，讓玩家知道目標在哪
      final n = i <= 2 ? 18 + rng.nextInt(10) : (i <= 5 ? 5 + rng.nextInt(6) : 1 + rng.nextInt(4));
      _spawnBot(n: n, awayFrom: p, shield: 0);
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

  SsFighter _spawnBot({required int n, double? x, double? y, SsFighter? awayFrom, String? name, double? aggr, double shield = 1.2}) {
    if (x == null || y == null) {
      for (var tries = 0; tries < 30; tries++) {
        final a = rng.nextDouble() * math.pi * 2;
        final r = math.sqrt(rng.nextDouble()) * ssArenaR * 0.9;
        x = math.cos(a) * r;
        y = math.sin(a) * r;
        if (awayFrom == null || _dist(x, y, awayFrom.x, awayFrom.y) > 700) break;
      }
    }
    final f = SsFighter(
      id: _nextId++,
      name: name ?? _botNames[_nameIdx++ % _botNames.length],
      player: false,
      color: ssColors[rng.nextInt(ssColors.length)],
      x: x!,
      y: y!,
      n: n,
      angle: rng.nextDouble() * math.pi * 2,
      shield: shield,
      aggr: aggr ?? (0.25 + rng.nextDouble() * 0.7),
      caution: 0.6 + rng.nextDouble() * 0.8,
    );
    fighters.add(f);
    return f;
  }

  void _spawnPickup({double? x, double? y, int? grade}) {
    if (x == null || y == null) {
      final a = rng.nextDouble() * math.pi * 2;
      final r = math.sqrt(rng.nextDouble()) * (ssArenaR - 60);
      x = math.cos(a) * r;
      y = math.sin(a) * r;
    }
    if (grade == null) {
      var roll = rng.nextInt(100);
      grade = 0;
      while (roll >= _pickupWeight[grade!]) {
        roll -= _pickupWeight[grade];
        grade++;
      }
    }
    pickups.add(SsPickup(x, y, rng.nextDouble() * math.pi * 2, grade));
  }

  void _spawnItem() {
    final a = rng.nextDouble() * math.pi * 2;
    final r = math.sqrt(rng.nextDouble()) * (ssArenaR - 150);
    final t = SsItemType.values[rng.nextInt(SsItemType.values.length)];
    items.add(SsItem(math.cos(a) * r, math.sin(a) * r, t, rng.nextDouble() * math.pi * 2));
  }

  static double _dist(double ax, double ay, double bx, double by) {
    final dx = ax - bx, dy = ay - by;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// 前進一個固定步長。ix/iy 是玩家的搖桿方向（長度 0~1）。
  void step(double ix, double iy) {
    if (over) return;
    const dt = ssDt;
    time += dt;

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
      if (f.player) {
        wx = ix;
        wy = iy;
      } else {
        f.think -= dt;
        if (f.think <= 0) _think(f);
        wx = f.tx;
        wy = f.ty;
      }
      final sp = ssSpeed(f.n) * (f.player ? 1 : 0.93) * (f.has(SsItemType.boots) ? 1.45 : 1);
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
      // 場地邊界
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
      f.angle += f.spin * dt;
    }

    _collectPickups();
    _combat(dt);

    // NPC 重生，維持場上熱鬧；後期重生的會帶比較多鐮刀，不然金圈沒東西吃
    for (final f in fighters.toList()) {
      if (!f.alive && !f.player && f.respawnAt > 0 && time >= f.respawnAt) {
        f.respawnAt = 0;
        final extra = (time / 30).floor();
        final b = _spawnBot(n: 1 + rng.nextInt(3 + extra * 2), awayFrom: player);
        b.chaseId = null;
      }
    }
    fighters.removeWhere((f) => !f.alive && !f.player && f.respawnAt == 0);
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
      events.add(SsEvent(SsEvType.over, player.x, player.y));
    }
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
          pickups.removeAt(i);
          _gain(f, p.value);
          if (f.player) events.add(SsEvent(SsEvType.pickup, p.x, p.y, a: f.id, count: p.value, b: p.grade));
        } else if (mag && d2 < mr2) {
          final d = math.sqrt(d2);
          final pull = math.min(d, 520 * ssDt);
          p.x -= dx / d * pull;
          p.y -= dy / d * pull;
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

  void _gain(SsFighter f, int k) {
    final before = f.tier;
    f.n += k;
    if (f.n > f.peak) f.peak = f.n;
    final after = f.tier;
    if (after > before) {
      events.add(SsEvent(after == 2 ? SsEvType.gold : SsEvType.silver, f.x, f.y, a: f.id));
    }
  }

  double _power(SsFighter a, SsFighter b, double nx, double ny) {
    // nx,ny：a → b 的單位向量。正在衝向對方的一方佔便宜。
    final sp = ssSpeed(a.n);
    final approach = ((a.vx * nx + a.vy * ny) / sp).clamp(0.0, 1.0);
    // 開場路人甲的鐮刀是生鏽的（前 15 秒力量 ×0.3），主角第一戰一定打得贏
    final rusty = a.id == introId && time < 15 ? 0.3 : 1.0;
    final rage = a.has(SsItemType.rage) ? 1.8 : 1.0;
    return a.n * (1 + 0.6 * approach) * (a.player ? 1.1 : 1.0) * rusty * rage;
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
        final reach = a.ringR + b.ringR;
        if (dx.abs() > reach + 20 || dy.abs() > reach + 20) continue;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d > reach + 4 || d < 1e-6) continue;
        final nx = dx / d, ny = dy / d;
        if (a.shield > 0 || b.shield > 0) {
          // 保護中：只會被輕輕推開
          if (d < reach) _push(a, b, nx, ny, 120);
          continue;
        }
        final pa = _power(a, b, nx, ny), pb = _power(b, a, -nx, -ny);
        final ga = a.has(SsItemType.guard), gb = b.has(SsItemType.guard);
        final aHits = a.n > 0 && !gb && d < a.ringR + ssBodyR * 0.7; // a 的鐮刀掃到 b 的身體（金鐘罩擋得住）
        final bHits = b.n > 0 && !ga && d < b.ringR + ssBodyR * 0.7;
        if (aHits || bHits) {
          if (aHits && (!bHits || pa >= pb)) {
            _kill(a, b);
          } else {
            _kill(b, a);
          }
          continue;
        }
        if (a.n > 0 && b.n > 0 && d < reach) {
          final key = a.id * 100000 + b.id;
          if (_pairCd.containsKey(key)) continue;
          _pairCd[key] = 0.09;
          // 每次碰撞的磨損：雙方平均力量決定打多兇，力量比決定誰吃虧（比例 1.5 次方，
          // 多一點點就明顯佔上風；40 把撞 5 把幾乎一次就把對方磨光）
          final base = 0.3 + (pa + pb) * 0.025;
          final ratio = (pa / pb).clamp(0.1, 10.0);
          if (!ga) a.wear += base * math.pow(1 / ratio, 1.5);
          if (!gb) b.wear += base * math.pow(ratio, 1.5);
          final cx = a.x + nx * (d * a.ringR / reach), cy = a.y + ny * (d * a.ringR / reach);
          final lostA = _wearOff(a, cx, cy), lostB = _wearOff(b, cx, cy);
          if (lostA > 0) a.flash = 0.12;
          if (lostB > 0) b.flash = 0.12;
          _push(a, b, nx, ny, 260);
          events.add(SsEvent(SsEvType.clash, cx, cy, a: a.id, b: b.id, count: lostA + lostB));
        }
      }
    }
  }

  int _wearOff(SsFighter f, double cx, double cy) {
    var lost = 0;
    while (f.wear >= 1 && f.n > 0) {
      f.wear -= 1;
      f.n--;
      lost++;
      // 斷掉的鐮刀有一半掉在地上，誰都能撿
      if (rng.nextDouble() < 0.5) {
        final a = rng.nextDouble() * math.pi * 2;
        final r = 30 + rng.nextDouble() * 50;
        _spawnPickup(x: cx + math.cos(a) * r, y: cy + math.sin(a) * r, grade: 0);
      }
    }
    if (f.n == 0) f.wear = 0;
    return lost;
  }

  void _push(SsFighter a, SsFighter b, double nx, double ny, double imp) {
    // 大隻的比較推不動
    final wa = 1 / (1 + a.n * 0.03), wb = 1 / (1 + b.n * 0.03);
    a.vx -= nx * imp * wa / (wa + wb) * 2;
    a.vy -= ny * imp * wa / (wa + wb) * 2;
    b.vx += nx * imp * wb / (wa + wb) * 2;
    b.vy += ny * imp * wb / (wa + wb) * 2;
  }

  void _kill(SsFighter killer, SsFighter victim) {
    final got = math.max(1, victim.n); // 空手的人也至少吸到他身上那把柄
    victim.alive = false;
    victim.n = 0;
    killer.kills++;
    _gain(killer, got);
    events.add(SsEvent(SsEvType.kill, victim.x, victim.y, a: killer.id, b: victim.id, count: got, x2: killer.x, y2: killer.y));
    if (victim.player) {
      over = true;
      overReason = 'dead';
      killedBy = killer.id;
      events.add(SsEvent(SsEvType.over, victim.x, victim.y));
    } else {
      victim.respawnAt = time + 3;
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
      final danger = o.ringR + b.ringR + 200 * b.caution;
      if (o.n > b.n * 1.15 + 1 && d < danger && o.shield <= 0) {
        final w = (danger - d) / danger;
        fx -= dx / d * w;
        fy -= dy / d * w;
        flee = true;
      } else if (b.n >= o.n * 1.25 + 1 || (b.n >= o.n && b.aggr > 0.75)) {
        if (o.player && time < 10) continue; // 開場 10 秒除了路人甲，其他人先不找玩家麻煩
        if (d < 420 + b.aggr * 300 && o.shield <= 0) {
          final score = d - (b.n - o.n) * 4 - (o.player ? 60 : 0); // 稍微偏愛追玩家
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
    final l = math.sqrt(dx * dx + dy * dy);
    if (l < 1e-6) {
      b.tx = b.ty = 0;
    } else {
      b.tx = dx / l;
      b.ty = dy / l;
    }
  }

  /// 目前排名（活著的 + 玩家），依鐮刀數。
  List<SsFighter> ranking() {
    final l = fighters.where((f) => f.alive || f.player).toList();
    l.sort((a, b) => b.n != a.n ? b.n.compareTo(a.n) : a.id.compareTo(b.id));
    return l;
  }

  int playerRank() {
    final p = player;
    if (!p.alive) {
      // 死掉時用死前最大值跟現在活著的比
      return 1 + fighters.where((f) => f.alive && f.n > p.peak).length;
    }
    return ranking().indexOf(p) + 1;
  }
}
