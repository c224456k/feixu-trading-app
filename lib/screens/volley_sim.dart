import 'dart:math' as math;

// 怪物打排球的物理與電腦對手，逐行對照伺服器的 volley_game.py（25Hz）。
// 電腦對戰完全在本機跑；連線對戰時只拿 VolleyPlayer.step 來預測自己的角色。

const double volleyTick = 0.04;
const double vW = 432, vFloor = 270;
const double vNetX = 216, vNetHalf = 5, vNetTop = 182;
const double vBallR = 20, vPlayerR = 32;
const double vStandY = vFloor - vPlayerR;
const double _grav = 1.0, _move = 6.0, _jumpV = -16.0;
const double _diveSpeed = 11.0;
const int _diveTicks = 7, _lieTicks = 10, _pointPause = 40;
const List<double> _startX = [108.0, 324.0];
const double _minHit = 15.0, _maxHit = 26.0, _maxBall = 30.0;

const evHit = 1, evSpike = 2, evBounce = 3, evGround = 4, evServe = 5, evDive = 6;

class VolleyPlayer {
  double x, y = vStandY, vx = 0, vy = 0;
  int dive = 0, lie = 0, diveDir = 0, cool = 0;
  bool hPrev = false, airH = false;
  VolleyPlayer(this.x);

  void reset(double nx) {
    x = nx;
    y = vStandY;
    vx = vy = 0;
    dive = lie = diveDir = cool = 0;
    hPrev = airH = false;
  }

  int get state {
    if (lie > 0) return 4;
    if (dive > 0) return 3;
    if (y < vStandY - 1) return airH ? 2 : 1;
    return 0;
  }

  /// side 0 = 左半場。inp = [l, r, u, h]。回傳是否撲救（供音效用）。
  bool step(int side, List<int> inp) {
    final l = inp[0], r = inp[1], u = inp[2], h = inp[3];
    final lo = side == 0 ? vPlayerR : vNetX + vNetHalf + vPlayerR;
    final hi = side == 0 ? vNetX - vNetHalf - vPlayerR : vW - vPlayerR;
    final onFloor = y >= vStandY - 1e-6;
    var dove = false;
    if (cool > 0) cool--;
    if (lie > 0) {
      lie--;
      vx = 0;
    } else if (dive > 0) {
      dive--;
      vx = diveDir * _diveSpeed;
      if (dive == 0) lie = _lieTicks;
    } else {
      final dx = (r != 0 ? 1 : 0) - (l != 0 ? 1 : 0);
      if (onFloor && h != 0 && !hPrev) {
        diveDir = dx != 0 ? dx : (side == 0 ? 1 : -1);
        dive = _diveTicks;
        vy = -4.0;
        dove = true;
      } else {
        vx = dx * _move;
        if (onFloor && u != 0) vy = _jumpV;
      }
    }
    airH = h != 0 && !onFloor;
    hPrev = h != 0;
    x = math.max(lo, math.min(hi, x + vx));
    if (y < vStandY || vy < 0) {
      vy += _grav;
      y += vy;
      if (y >= vStandY) {
        y = vStandY;
        vy = 0;
      }
    }
    return dove;
  }
}

class VolleyGame {
  final int points;
  final math.Random rng;
  List<int> score = [0, 0];
  final List<VolleyPlayer> p = [VolleyPlayer(_startX[0]), VolleyPlayer(_startX[1])];
  int server = 0, pause = 0, ticks = 0, rs = 0;
  int? winner;
  double bx = 0, by = 0, bvx = 0, bvy = 0;
  bool needReset = false, live = false;

  VolleyGame(this.points, {math.Random? rng, int? firstServer}) : rng = rng ?? math.Random() {
    server = firstServer ?? (this.rng.nextBool() ? 1 : 0);
    pause = _pointPause ~/ 2;
    _serveSetup(_pointPause);
  }

  void _serveSetup(int pa) {
    bx = server == 0 ? 56.0 : vW - 56;
    by = 40.0;
    bvx = bvy = 0;
    p[0].reset(_startX[0]);
    p[1].reset(_startX[1]);
    pause = pa;
    rs++;
    live = false;
    needReset = false;
  }

  List<int> step(List<List<int>> inputs) {
    final ev = <int>[];
    ticks++;
    for (var s = 0; s < 2; s++) {
      if (p[s].step(s, inputs[s])) ev.add(evDive);
    }
    if (pause > 0) {
      pause--;
      if (pause == 0) {
        if (needReset) {
          _serveSetup(20);
        } else {
          live = true;
          ev.add(evServe);
        }
      }
      return ev;
    }
    moveBall(ev);
    return ev;
  }

  /// 球的一步（電腦預測軌跡也用這個，所以 players 要可略過）。
  void moveBall(List<int> ev, {bool players = true}) {
    bvy += _grav;
    final sp = math.sqrt(bvx * bvx + bvy * bvy);
    if (sp > _maxBall) {
      bvx = bvx * _maxBall / sp;
      bvy = bvy * _maxBall / sp;
    }
    bx += bvx;
    by += bvy;
    if (bx < vBallR) {
      bx = vBallR;
      bvx = bvx.abs();
      ev.add(evBounce);
    } else if (bx > vW - vBallR) {
      bx = vW - vBallR;
      bvx = -bvx.abs();
      ev.add(evBounce);
    }
    final cx = math.max(vNetX - vNetHalf, math.min(vNetX + vNetHalf, bx));
    final cy = math.max(vNetTop, by);
    final dx = bx - cx, dy = by - cy;
    final d2 = dx * dx + dy * dy;
    if (d2 < vBallR * vBallR) {
      var d = math.sqrt(d2);
      double nx, ny;
      if (d < 1e-6) {
        nx = bvx > 0 ? -1.0 : 1.0;
        ny = 0;
        d = 0;
      } else {
        nx = dx / d;
        ny = dy / d;
      }
      bx += nx * (vBallR - d);
      by += ny * (vBallR - d);
      final vn = bvx * nx + bvy * ny;
      if (vn < 0) {
        bvx -= 2 * vn * nx;
        bvy -= 2 * vn * ny;
        ev.add(evBounce);
      }
    }
    if (players) {
      for (var s = 0; s < 2; s++) {
        _hitPlayer(s, ev);
      }
    }
    if (by >= vFloor - vBallR) {
      by = vFloor - vBallR;
      ev.add(evGround);
      final scorer = bx < vNetX ? 1 : 0;
      score[scorer]++;
      server = scorer;
      if (score[scorer] >= points) winner = scorer;
      live = false;
      pause = _pointPause;
      needReset = true;
    }
  }

  void _hitPlayer(int side, List<int> ev) {
    final q = p[side];
    if (q.cool > 0) return;
    final dx = bx - q.x, dy = by - q.y;
    final d2 = dx * dx + dy * dy;
    const rr = vBallR + vPlayerR;
    if (d2 >= rr * rr) return;
    var d = math.sqrt(d2);
    if (d == 0) d = 1e-6;
    final nx = dx / d, ny = dy / d;
    bx = q.x + nx * rr;
    by = q.y + ny * rr;
    q.cool = 3;
    final inAir = q.y < vStandY - 4;
    if (q.airH && inAir) {
      final dir = side == 0 ? 1 : -1;
      bvx = dir * (13.0 + 9.0 * nx.abs());
      bvy = 9.0 + 5.0 * math.max(0.0, -ny);
      ev.add(evSpike);
      return;
    }
    final rvx = bvx - q.vx, rvy = bvy - q.vy;
    final speed = math.min(_maxHit, math.max(_minHit, math.sqrt(rvx * rvx + rvy * rvy) * 0.9 + 2.0));
    bvx = nx * speed + q.vx * 0.7;
    bvy = ny * speed + q.vy * 0.4;
    if (bvy > -6 && ny < 0.2) bvy -= 4;
    ev.add(evHit);
  }

  /// 跟伺服器 frame() 同格式，畫面程式可以共用。
  Map<String, dynamic> frame(List<int> ev) => {
        't': 's',
        'p': [
          for (final q in p) [q.x.round(), q.y.round(), q.state]
        ],
        'b': [bx.round(), by.round(), (bvx * 10).round() / 10],
        'sc': List<int>.from(score),
        'sv': server,
        'ph': live ? 0 : 1,
        'ev': ev,
        'rs': rs,
      };
}

// ---------------------------------------------------------------- 電腦對手
class VolleyBotCfg {
  final String name;
  final int lag;
  final double err, miss, spike;
  const VolleyBotCfg(this.name, this.lag, this.err, this.miss, this.spike);
}

const _botLevels = [
  VolleyBotCfg('電腦（新手）', 12, 60.0, 0.62, 0.0),
  VolleyBotCfg('電腦（普通）', 6, 40.0, 0.35, 0.5),
  VolleyBotCfg('電腦（高手）', 3, 25.0, 0.12, 1.0),
];
String volleyBotName(int level) => _botLevels[level].name;

bool _mineBall(VolleyGame g, int side) => side == 0 ? g.bx < vNetX + 20 : g.bx > vNetX - 20;

/// 只剩球的簡化遊戲，用來預測軌跡 / 試扣球。
VolleyGame _ballOnly(double bx, double by, double bvx, double bvy) {
  final s = VolleyGame(99);
  s.bx = bx;
  s.by = by;
  s.bvx = bvx;
  s.bvy = bvy;
  s.score = [0, 0];
  s.winner = null;
  s.live = true;
  s.pause = 0;
  s.needReset = false;
  return s;
}

class VolleyBot {
  final int side;
  final VolleyBotCfg cfg;
  final math.Random rng = math.Random();
  final List<List<double>> hist = []; // bx, by, bvx, bvy, live
  double err = 0, off = 20;
  bool lastLive = false;

  VolleyBot(this.side, int level) : cfg = _botLevels[level];

  List<(double, double)> _predict(double bx, double by, double bvx, double bvy) {
    final s = _ballOnly(bx, by, bvx, bvy);
    final out = <(double, double)>[];
    for (var i = 0; i < 90; i++) {
      s.moveBall([], players: false);
      out.add((s.bx, s.by));
      if (!s.live) break;
    }
    return out;
  }

  bool _spikeOk(VolleyGame g, VolleyPlayer p) {
    final dir = side == 0 ? 1 : -1;
    var d = math.sqrt((g.bx - p.x) * (g.bx - p.x) + (g.by - p.y) * (g.by - p.y));
    if (d == 0) d = 1.0;
    final nx = (g.bx - p.x) / d, ny = (g.by - p.y) / d;
    final s = _ballOnly(g.bx, g.by, dir * (13.0 + 9.0 * nx.abs()), 9.0 + 5.0 * math.max(0.0, -ny));
    for (var i = 0; i < 60; i++) {
      s.moveBall([], players: false);
      if (!s.live) return side == 0 ? s.bx > vNetX : s.bx < vNetX;
    }
    return false;
  }

  List<int> act(VolleyGame g) {
    final c = cfg;
    final p = g.p[side];
    final dirn = side == 0 ? 1 : -1;
    hist.add([g.bx, g.by, g.bvx, g.bvy, g.live ? 1 : 0]);
    if (hist.length > c.lag + 1) hist.removeAt(0);
    final h0 = hist[0];
    final bx = h0[0], by = h0[1], bvx = h0[2], bvy = h0[3];
    final live = h0[4] != 0;
    if (g.live && !lastLive) {
      err = (rng.nextDouble() * 2 - 1) * c.err;
      off = c.spike > 0 ? 8.0 + rng.nextDouble() * 32.0 : 20.0;
    }
    lastLive = g.live;
    var l = 0, r = 0, u = 0, h = 0;
    var tx = _startX[side];
    if (live) {
      final traj = _predict(bx, by, bvx, bvy);
      bool mine(double x) => side == 0 ? x < vNetX : x > vNetX;
      const reachY = vStandY - 55;
      (int, double, double)? hit;
      for (var i = 0; i < traj.length; i++) {
        final (x, y) = traj[i];
        if (y >= reachY && mine(x)) {
          hit = (i, x, y);
          break;
        }
      }
      if (hit == null && mine(bx) && traj.isNotEmpty) hit = (traj.length - 1, traj.last.$1, traj.last.$2);
      if (hit != null) tx = hit.$2 - dirn * off + err;
    }
    final dx = tx - p.x;
    if (dx.abs() > 5 && rng.nextDouble() >= c.miss) {
      if (dx > 0) {
        r = 1;
      } else {
        l = 1;
      }
    }
    final grounded = p.y >= vStandY - 1e-6 && p.lie == 0 && p.dive == 0;
    if (live && grounded && _mineBall(g, side)) {
      final rx = g.bx - p.x;
      if (c.spike > 0 && rx.abs() < 46 && g.by > 70 && g.by < vStandY - 70 && g.bvy > 0 && rng.nextDouble() < c.spike) u = 1;
    }
    if (p.y < vStandY - 1 && live) {
      final dd = math.sqrt((g.bx - p.x) * (g.bx - p.x) + (g.by - p.y) * (g.by - p.y));
      if (dd < vBallR + vPlayerR + 30 && c.spike > 0 && _spikeOk(g, p)) h = 1;
    }
    if (live && grounded && _mineBall(g, side) && c.spike >= 1.0) {
      if (g.by > vStandY - 40 && (g.bx - p.x).abs() > 50 && (g.bx - p.x).abs() < 110 && g.bvx.abs() < 22) {
        h = 1;
        if (g.bx < p.x) {
          l = 1;
          r = 0;
        } else {
          l = 0;
          r = 1;
        }
      }
    }
    return [l, r, u, h];
  }
}
