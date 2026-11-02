import 'dart:math' as math;

/// 數字門（仿 FB 廣告那種）：沒有格子，手指左右拖動整隊人，前面一直自動掃射。
/// - 怪從前面一直來；撞到你的隊伍（隊伍寬度隨人數變寬）就咬掉人數；躲開的怪會從旁邊過去
/// - 人數＝火力（每人每秒 ngK 傷害），子彈打隊伍正前方最近的東西，打死了溢出的火力繼續打下一個
/// - 很久才出現一對加減乘除的大門；左邊那扇是「鎖住的大門」：要把裝甲血條打光才會開，開了是大獎（×3~×5），
///   沒打開就衝過去會被鎖住、人數砍半。右邊是一般的門（+ − × ÷）
/// - 中途和最後有頭目：怪停止出現，限時打血條，牠會預告攻擊的位置（紅色柱子），要閃開
/// 沒有格子所以不能像之前用演算法證明有解，難度靠 bot 實際玩來校準（見 scratchpad ng/bot.dart）。
enum NgOp { add, sub, mul, div }

const int ngCap = 1000000000;
const double ngK = 4.0; // 每人每秒傷害
const double ngH = 1.7; // 畫面深度（x 的範圍是 0~1，y 是離玩家多遠）
const double ngGateSpeed = 0.45; // 門往下走的速度
const double ngMoveSpeed = 1.9; // 玩家左右移動最大速度
const double ngBossY = 1.05; // 頭目停的位置
const double ngRange = 1.15; // 射程：再遠的怪只能看著牠走過來
const int ngLevels = 30;

String ngFmt(int n) {
  if (n >= 100000000) return '${(n / 1e8).toStringAsFixed(1)}億';
  if (n >= 10000) return '${(n / 1e4).toStringAsFixed(n >= 1000000 ? 0 : 1)}萬';
  return '$n';
}

int _apply(NgOp op, int v, int c) {
  switch (op) {
    case NgOp.add:
      return math.min(ngCap, c + v);
    case NgOp.sub:
      return c - v;
    case NgOp.mul:
      return math.min(ngCap, c * v);
    case NgOp.div:
      return c ~/ v;
  }
}

String ngOpLabel(NgOp op, int v) => switch (op) {
  NgOp.add => '+${ngFmt(v)}',
  NgOp.sub => '−${ngFmt(v)}',
  NgOp.mul => '×$v',
  NgOp.div => '÷$v',
};

bool ngOpGood(NgOp op) => op == NgOp.add || op == NgOp.mul;

/// 隊伍寬度（也是子彈掃射的寬度）
double ngCrowdW(int count) =>
    math.min(0.5, 0.14 + 0.02 * math.sqrt(count.toDouble()));

// ---------------------------------------------------------------- 關卡腳本
class NgSpawn {
  final double t; // 腳本時間
  final double x;
  final int kind; // 0 史萊姆 1 快跑 2 坦克 3 蝙蝠 4 吐彈怪
  final double frac; // 血量＝frac × 當時的參考人數 × 火力 × 出怪間隔（出現時才算，所以不會被選哪道門的運氣左右）
  const NgSpawn(this.t, this.x, this.kind, this.frac);
}

class NgGateDef {
  final double t;
  final NgOp lop; // 左邊：鎖住的大門
  final int lv;
  final double armorFrac; // 裝甲血量＝armorFrac × 參考人數 × 火力 × 門走過來的秒數
  final NgOp rop; // 右邊：一般的門
  final int rv; // × ÷ 用
  final double rfrac; // + − 用：數值＝rfrac × 參考人數
  const NgGateDef(
    this.t,
    this.lop,
    this.lv,
    this.armorFrac,
    this.rop,
    this.rv,
    this.rfrac,
  );
}

class NgBossDef {
  final double t;
  final double frac; // 血量＝frac × 參考人數 × 火力 × 限時
  final String emoji;
  final double limit;
  final double period;
  final bool isFinal;
  const NgBossDef(
    this.t,
    this.frac,
    this.emoji,
    this.limit,
    this.period,
    this.isFinal,
  );
}

class NgLevel {
  final int index;
  final int start;
  final List<NgSpawn> spawns;
  final List<NgGateDef> gates;
  final List<NgBossDef> bosses;
  final double length; // 腳本總長（秒，不含頭目戰）
  final double spawnInt;
  final double gateInt;
  const NgLevel(
    this.index,
    this.start,
    this.spawns,
    this.gates,
    this.bosses,
    this.length,
    this.spawnInt,
    this.gateInt,
  );

  /// 預期進度的人數：順利的話每過一道門約 ×mG
  double nominal(double sc) =>
      10.0 *
      math
          .pow(
            _Cfg.mG,
            math.max(
              0.0,
              (sc - (_Cfg.firstGate + ngH / ngGateSpeed - gateInt)) / gateInt,
            ),
          )
          .toDouble();
}

/// 頭目血量倍率（校準用）
double ngBossScale = 1.3;

/// 每一關怪血量的倍率：逐關用 bot 實際玩校準，讓每一關都貼著 bot 的極限（前 3 關 bot 4/4 過、第 4~8 關 ≥3/4、之後 ≥2/4）
List<double> ngTune = [
  3.0, 3.0, 3.0, 3.0, 3.5, 2.6, 2.6, 2.0, 2.3, 2.6, //
  2.6, 2.6, 2.3, 2.3, 1.8, 2.0, 1.6, 1.4, 1.4, 1.6,
  1.4, 1.4, 1.0, 1.4, 1.0, 1.0, 1.0, 1.0, 0.85, 1.0,
];

class _Cfg {
  final int idx;
  final double t01;
  _Cfg(this.idx) : t01 = (idx - 1) / (ngLevels - 1);
  int get gates => 3 + idx ~/ 4;
  double get gateInt => 9.5 - 2.0 * t01;
  static const firstGate = 6.0;
  double get spawnInt => 0.30 - 0.14 * t01; // 平均每隻怪相隔幾秒（一直來）
  double get ease => idx <= 3 ? 0.7 : 1.0;
  double get hpF =>
      (0.30 + 0.60 * t01) * ease * ngTune[idx - 1]; // 怪流的總血量＝你火力的幾成（越高越吃緊）
  double get armorF => (0.40 + 0.75 * t01) * ease;
  double get bossF =>
      (0.30 + 0.5 * t01) /
      0.7 *
      ease *
      ngBossScale; // 頭目：全力開火要用掉限時的 (0.3~0.8) 倍，閃躲和被打掉的人數都會讓它變長
  double get bossLimit => 15 - 5 * t01;
  double get bossPeriod => 2.4 - 1.1 * t01;
  static const mG = 1.9; // 只走右邊的門的話，每過一道門人數大約 ×1.9（打開鎖住的大門會更快）
}

const _bossEmojis = ['👹', '🐉', '👑', '😈', '🦖'];

NgLevel ngLevel(int idx) {
  final c = _Cfg(idx);
  final rng = math.Random(idx * 7919 + 13);
  final spawns = <NgSpawn>[];
  final gates = <NgGateDef>[];
  final cross = ngH / ngGateSpeed; // 門從出現走到玩家要幾秒
  final length = _Cfg.firstGate + (c.gates - 1) * c.gateInt + cross + 3;
  final midT = _Cfg.firstGate + (c.gates ~/ 2) * c.gateInt + cross * 0.5;

  // 門：右邊是一般的門，左邊是鎖住的大門（裝甲血條要打光才開）
  // A 右邊還不錯（×2、×3、+）→ 左邊可挑戰可不挑戰；B 右邊是爛門（÷2、−），只能去打左邊（裝甲比較薄）；C 右邊很棒
  var lastBad = false;
  for (var g = 0; g < c.gates; g++) {
    final tg = _Cfg.firstGate + g * c.gateInt;
    final r = rng.nextDouble();
    NgOp op;
    int v = 0;
    double rf = 0;
    var armorMul = 1.0;
    if (r < 0.22 && !lastBad && g > 0) {
      lastBad = true;
      armorMul = 0.6;
      if (rng.nextBool()) {
        op = NgOp.div;
        v = 2;
      } else {
        op = NgOp.sub;
        rf = 0.4 + 0.3 * rng.nextDouble();
      }
    } else {
      lastBad = false;
      final q = rng.nextDouble();
      if (q < 0.45) {
        op = NgOp.mul;
        v = 2;
      } else if (q < 0.62) {
        op = NgOp.mul;
        v = 3;
      } else {
        op = NgOp.add;
        rf = 0.9 + 0.9 * rng.nextDouble();
      }
    }
    final lm = idx < 10 ? 3 : (idx < 20 ? 4 : 5);
    gates.add(NgGateDef(tg, NgOp.mul, lm, c.armorF * armorMul, op, v, rf));
  }

  // 怪：一直來（小殭屍成群衝過來，時不時一大波）
  var s = 1.0;
  var nextBurst = 3.5;
  double hpFor(double mul) => c.hpF * mul * (0.7 + 0.6 * rng.nextDouble());
  while (s < length) {
    if (s >= nextBurst) {
      final n = 7 + rng.nextInt(6) + idx ~/ 4;
      final cx = 0.2 + 0.6 * rng.nextDouble();
      for (var k = 0; k < n; k++) {
        spawns.add(
          NgSpawn(
            s + k * 0.05,
            (cx + (rng.nextDouble() - 0.5) * 0.3).clamp(0.05, 0.95),
            0,
            hpFor(0.8),
          ),
        );
      }
      nextBurst = s + 4.5 + 2.5 * rng.nextDouble();
      s += n * 0.05 + c.spawnInt;
      continue;
    }
    final w = rng.nextDouble();
    int kind = 0;
    if (w < 0.60) {
      kind = 0;
    } else if (w < 0.75 && idx >= 2) {
      kind = 1;
    } else if (w < 0.83 && idx >= 4) {
      kind = 3;
    } else if (w < 0.91 && idx >= 3) {
      kind = 2;
    } else if (w >= 0.95 && idx >= 8) {
      kind = 4;
    }
    final mul = switch (kind) {
      1 => 0.6,
      2 => 6.0,
      3 => 0.8,
      4 => 1.5,
      _ => 1.0,
    };
    spawns.add(NgSpawn(s, 0.06 + 0.88 * rng.nextDouble(), kind, hpFor(mul)));
    s += c.spawnInt * (0.7 + 0.6 * rng.nextDouble());
  }
  spawns.sort((a, b) => a.t.compareTo(b.t));

  // 頭目
  final bosses = <NgBossDef>[];
  if (idx >= 3) {
    bosses.add(
      NgBossDef(
        midT,
        c.bossF * 0.8,
        _bossEmojis[0],
        c.bossLimit,
        c.bossPeriod,
        false,
      ),
    );
  }
  bosses.add(
    NgBossDef(
      length,
      c.bossF,
      _bossEmojis[1 + rng.nextInt(_bossEmojis.length - 1)],
      c.bossLimit,
      c.bossPeriod,
      true,
    ),
  );
  return NgLevel(idx, 10, spawns, gates, bosses, length, c.spawnInt, c.gateInt);
}

// ---------------------------------------------------------------- 模擬
class NgMon {
  int id = 0;
  double x, y, hp, maxHp, r, speed, ph, cd = 0;
  final int kind;
  NgMon(this.x, this.y, this.hp, this.kind, this.r, this.speed, this.ph)
    : maxHp = hp;
  NgMon copy() => NgMon(x, y, hp, kind, r, speed, ph)
    ..id = id
    ..maxHp = maxHp
    ..cd = cd;
}

class NgBul {
  double x, y;
  NgBul(this.x, this.y);
}

class NgGateLive {
  final NgGateDef def;
  double y = ngH + 0.1;
  final double armorMax;
  double armor;
  int rv; // 右邊門的數值（+ − 在出現時依人數算）
  bool crossed = false;
  NgGateLive(this.def, double a, this.rv) : armor = a, armorMax = a;
  NgGateLive copy() => NgGateLive(def, armorMax, rv)
    ..y = y
    ..armor = armor
    ..crossed = crossed;
}

class NgBoss {
  final NgBossDef def;
  final double maxHp;
  double hp;
  double y = ngH + 0.3;
  double fight = 0; // 停下來之後的秒數
  double slamAt = -1; // 預告落下的 fight 時間
  List<double> slamX = [];
  int slams = 0;
  NgBoss(this.def, this.hp) : maxHp = hp;
  NgBoss copy() => NgBoss(def, maxHp)
    ..hp = hp
    ..y = y
    ..fight = fight
    ..slamAt = slamAt
    ..slamX = List.of(slamX)
    ..slams = slams;
  bool get stopped => y <= ngBossY + 1e-6;
}

class NgEvt {
  final String kind; // gate lock bite kill boss slam hit armor win lose
  final double x;
  final double y;
  final String text;
  final bool good;
  const NgEvt(this.kind, this.x, this.y, this.text, this.good);
}

class NgSim {
  final NgLevel lv;
  double sc = 0; // 腳本時間（頭目戰時暫停）
  double t = 0; // 真實經過時間
  double px = 0.5;
  int count;
  int result = 0; // 0 進行中 1 過關 2 失敗
  String why = '';
  List<NgMon> mons = [];
  List<NgBul> buls = [];
  List<NgGateLive> gates = [];
  NgBoss? boss;
  int _ns = 0, _ng = 0, _nb = 0, _id = 0;
  final List<NgEvt> events = [];
  // 畫面用
  double fireTargetY = -1; // 子彈打到哪（畫面 y 值，<0＝沒目標打到頂）
  int kills = 0;
  int bites = 0;

  NgSim(this.lv) : count = lv.start;

  NgSim._copy(NgSim o)
    : lv = o.lv,
      sc = o.sc,
      t = o.t,
      px = o.px,
      count = o.count,
      result = o.result,
      mons = [for (final m in o.mons) m.copy()],
      buls = [for (final b in o.buls) NgBul(b.x, b.y)],
      gates = [for (final g in o.gates) g.copy()],
      boss = o.boss?.copy(),
      _ns = o._ns,
      _ng = o._ng,
      _nb = o._nb,
      _id = o._id;

  NgSim copy() => NgSim._copy(this);

  /// 參考人數：現在的人數，但限制在預期進度的 0.4~3 倍（人太少不會變簡單，太多也不會無限變難）
  double get ref {
    final nom = lv.nominal(sc);
    return math.max(nom * 0.4, math.min(count.toDouble(), nom * 3));
  }

  double get crowdW => ngCrowdW(count);
  bool get bossActive => boss != null;

  void _lose(String w) {
    result = 2;
    why = w;
    events.add(NgEvt('lose', px, 0, w, false));
  }

  double _speedOf(int kind) => switch (kind) {
    1 => 0.45,
    2 => 0.14,
    3 => 0.3,
    4 => 0.26,
    _ => 0.23,
  };
  double _radiusOf(int kind) => switch (kind) {
    1 => 0.03,
    2 => 0.07,
    3 => 0.035,
    4 => 0.045,
    _ => 0.034,
  };

  void step(double dt, double targetX) {
    if (result != 0) return;
    t += dt;
    // 移動
    final tx = targetX.clamp(0.04, 0.96);
    final d = (tx - px).clamp(-ngMoveSpeed * dt, ngMoveSpeed * dt);
    px = (px + d).clamp(0.04, 0.96);

    // 腳本推進（頭目戰時停住）
    if (!bossActive) {
      sc += dt;
      while (_ns < lv.spawns.length && lv.spawns[_ns].t <= sc) {
        final s = lv.spawns[_ns++];
        final m = NgMon(
          s.x,
          ngH + 0.05,
          math.max(3.0, s.frac * ref * ngK * lv.spawnInt),
          s.kind,
          _radiusOf(s.kind),
          _speedOf(s.kind) * (1 + 0.012 * lv.index),
          (s.x * 37 + s.t) % 6.28,
        )..id = ++_id;
        mons.add(m);
      }
      while (_ng < lv.gates.length && lv.gates[_ng].t <= sc) {
        final d = lv.gates[_ng++];
        final rf = ref;
        final rv = (d.rop == NgOp.add || d.rop == NgOp.sub)
            ? math.max(3, (d.rfrac * rf).round())
            : d.rv;
        gates.add(
          NgGateLive(
            d,
            d.armorFrac * rf * ngK * (ngRange / ngGateSpeed) * 0.85,
            rv,
          ),
        );
      }
      if (_nb < lv.bosses.length &&
          lv.bosses[_nb].t <= sc &&
          mons.length < 3 + 1000) {
        final d = lv.bosses[_nb++];
        boss = NgBoss(d, d.frac * ref * ngK * d.limit * 0.7);
      }
    }

    // 怪移動
    for (final m in mons) {
      if (m.kind == 4 && m.y <= 1.0) {
        // 吐彈怪停在前面，定時往下吐
        m.cd -= dt;
        if (m.cd <= 0) {
          m.cd = 1.7;
          buls.add(NgBul(m.x, m.y - 0.04));
        }
      } else {
        m.y -= m.speed * dt;
      }
      if (m.kind == 3) {
        m.x = (m.x + math.cos(t * 2.2 + m.ph) * 0.22 * dt).clamp(0.04, 0.96);
      }
      if (m.kind == 1) {
        m.x = (m.x + math.sin(t * 3.0 + m.ph) * 0.16 * dt).clamp(0.04, 0.96);
      }
      if (m.kind == 0 || m.kind == 2) {
        // 殭屍會慢慢往你的隊伍靠攏
        final dx = px - m.x;
        m.x += dx.clamp(-0.1 * dt, 0.1 * dt);
      }
    }
    for (final b in buls) {
      b.y -= 0.7 * dt;
    }
    for (final g in gates) {
      g.y -= ngGateSpeed * dt;
    }
    final bs = boss;
    if (bs != null && !bs.stopped) bs.y = math.max(ngBossY, bs.y - 0.7 * dt);

    // 開火：隊伍正前方（寬度＝隊伍寬）最近的東西先吃，打死了溢出的火力繼續打
    final bw = crowdW / 2;
    var power = count * ngK * dt;
    fireTargetY = -1;
    final targets = <({double y, int kind, int i})>[]; // kind 0 怪 1 鎖住的門 2 頭目
    for (var i = 0; i < mons.length; i++) {
      final m = mons[i];
      if (m.y > 0.02 && m.y <= ngRange && (m.x - px).abs() <= bw + m.r) {
        targets.add((y: m.y, kind: 0, i: i));
      }
    }
    if (px < 0.5) {
      for (var i = 0; i < gates.length; i++) {
        final g = gates[i];
        if (!g.crossed && g.armor > 0 && g.y > 0.02 && g.y <= ngRange) {
          targets.add((y: g.y, kind: 1, i: i));
        }
      }
    }
    if (bs != null && (bs.hp > 0) && (px - 0.5).abs() <= bw + 0.3) {
      targets.add((y: bs.y, kind: 2, i: 0));
    }
    targets.sort((a, b) => a.y.compareTo(b.y));
    for (final tg in targets) {
      if (power <= 0) break;
      fireTargetY = tg.y;
      if (tg.kind == 0) {
        final m = mons[tg.i];
        final use = math.min(power, m.hp);
        m.hp -= use;
        power -= use;
      } else if (tg.kind == 1) {
        final g = gates[tg.i];
        final use = math.min(power, g.armor);
        g.armor -= use;
        power -= use;
        if (g.armor <= 0) events.add(NgEvt('armor', 0.25, g.y, '解鎖！', true));
      } else {
        final use = math.min(power, bs!.hp);
        bs.hp -= use;
        power -= use;
      }
    }
    // 死掉的怪
    for (final m in mons) {
      if (m.hp <= 0) {
        kills++;
        events.add(NgEvt('kill', m.x, m.y, '${m.kind}', true));
      }
    }
    mons.removeWhere((m) => m.hp <= 0);

    // 撞到隊伍
    final front = 0.045;
    for (var i = mons.length - 1; i >= 0; i--) {
      final m = mons[i];
      if (m.y <= front) {
        if ((m.x - px).abs() <= bw + m.r) {
          final loss = math.max(
            2,
            math.min(
              math.max((m.hp * 0.6).ceil(), (count * 0.05).ceil()),
              (count * 0.45).ceil(),
            ),
          );
          count -= loss;
          bites++;
          events.add(NgEvt('bite', px, 0, '−${ngFmt(loss)}', false));
          mons.removeAt(i);
          if (count <= 0) {
            count = 0;
            _lose('被怪物淹沒了');
            return;
          }
        } else if (m.y < -0.15) {
          mons.removeAt(i);
        }
      }
    }
    // 吐的彈
    for (var i = buls.length - 1; i >= 0; i--) {
      final b = buls[i];
      if (b.y <= front) {
        if ((b.x - px).abs() <= bw + 0.025) {
          final loss = math.max(1, (count * 0.06).ceil());
          count -= loss;
          events.add(NgEvt('hit', px, 0, '−${ngFmt(loss)}', false));
          if (count <= 0) {
            count = 0;
            _lose('被子彈打垮了');
            return;
          }
        }
        buls.removeAt(i);
      }
    }

    // 穿過門
    for (final g in gates) {
      if (g.crossed || g.y > 0.02) continue;
      g.crossed = true;
      if (px < 0.5) {
        if (g.armor > 0) {
          count = math.max(1, (count * 0.5).ceil());
          events.add(NgEvt('lock', px, 0, '鎖住了！−50%', false));
        } else {
          count = _apply(g.def.lop, g.def.lv, count);
          events.add(
            NgEvt('gate', px, 0, ngOpLabel(g.def.lop, g.def.lv), true),
          );
        }
      } else {
        final after = _apply(g.def.rop, g.rv, count);
        events.add(
          NgEvt('gate', px, 0, ngOpLabel(g.def.rop, g.rv), after >= count),
        );
        count = after;
      }
      if (count <= 0) {
        count = 0;
        _lose('人數歸零');
        return;
      }
    }
    gates.removeWhere((g) => g.y < -0.3);

    // 頭目
    if (bs != null) {
      if (bs.hp <= 0) {
        events.add(NgEvt('boss', 0.5, bs.y, '${bs.def.emoji} 倒下了', true));
        boss = null;
        if (bs.def.isFinal) {
          result = 1;
          events.add(const NgEvt('win', 0.5, 0, '過關', true));
        }
        return;
      }
      if (bs.stopped) {
        bs.fight += dt;
        if (bs.fight > bs.def.limit) {
          _lose('${bs.def.emoji} 沒在時間內打倒，被壓垮了');
          return;
        }
        if (bs.slamAt < 0) {
          if (bs.fight >= bs.slams * bs.def.period + 0.6) {
            bs.slamAt = bs.fight + 0.9;
            bs.slamX = [px];
            if (lv.index >= 10) {
              bs.slamX.add((px + (px > 0.5 ? -0.3 : 0.3)).clamp(0.1, 0.9));
            }
            events.add(NgEvt('slam', px, 0, '', false));
          }
        } else if (bs.fight >= bs.slamAt) {
          for (final sx in bs.slamX) {
            if ((sx - px).abs() <= 0.1 + bw * 0.6) {
              final loss = math.max(1, (count * 0.25).ceil());
              count -= loss;
              events.add(NgEvt('hit', px, 0, '−${ngFmt(loss)}', false));
              break;
            }
          }
          if (count <= 0) {
            count = 0;
            _lose('被 ${bs.def.emoji} 的攻擊打垮了');
            return;
          }
          bs.slamAt = -1;
          bs.slams++;
        }
      }
    }
  }
}
