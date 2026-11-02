import 'dart:math' as math;

/// 數字門：玩家在最下面一直機槍掃射前方，往前跑，穿過數字門改人數，路上有小怪和頭目。
/// - 人數＝火力：每人每秒 ngK 點傷害，打你站的那條道上最前面的小怪（子彈到下一排門為止）
/// - 小怪在牠撞到你時還活著、而且在你這條道，就咬掉等於「剩餘血量」的人數；別條道的小怪不會咬你
/// - 兩排之間最多換一次道（點左右半邊／←→），所以眼前最大的門常常把你帶去很爛的位置
/// - 頭目：畫面停住，限時打完血條；牠會預告攻擊的道（顯示紅色），要換道閃開，被打到掉 25% 人數
/// 關卡由編號當種子固定產生，產生時用同一套模擬器驗證「有解、每排挑最大會輸、一直站同一道會輸」。
enum NgOp { add, sub, mul, div }

const int ngCap = 1000000000;
const double ngK = 3.0; // 每人每秒傷害
const double ngDt = 1 / 60;

class NgGate {
  final NgOp op;
  final int v;
  const NgGate(this.op, this.v);

  int apply(int c) {
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

  String get label => switch (op) {
        NgOp.add => '+$v',
        NgOp.sub => '−$v',
        NgOp.mul => '×$v',
        NgOp.div => '÷$v',
      };

  bool get isGood => op == NgOp.add || op == NgOp.mul;
}

class NgMon {
  final int lane;
  final double arrive; // 這一段開始後幾秒撞到玩家
  final int hp;
  final String emoji;
  const NgMon(this.lane, this.arrive, this.hp, this.emoji);
}

class NgRow {
  final List<NgGate>? gates; // 一排門（null＝頭目）
  final List<NgMon> mons; // 門前面的小怪（依 arrive 排序）
  final int bossHp;
  final double bossLimit; // 頭目停下來後的限時（秒）
  final double bossPeriod; // 頭目每隔幾秒預告一次攻擊
  final String emoji;
  final bool isFinal;
  const NgRow.seg(List<NgGate> g, this.mons)
      : gates = g,
        bossHp = 0,
        bossLimit = 0,
        bossPeriod = 0,
        emoji = '',
        isFinal = false;
  const NgRow.boss(this.bossHp, this.emoji, this.bossLimit, this.bossPeriod, {this.isFinal = false})
      : gates = null,
        mons = const [];
  bool get isBoss => gates == null;
}

class NgLevel {
  final int index;
  final int lanes;
  final double interval; // 一段（兩排門之間）的秒數
  final int start;
  final List<NgRow> rows;
  final int best; // 最佳走法的剩餘人數
  const NgLevel(this.index, this.lanes, this.interval, this.start, this.rows, this.best);
}

const ngLevels = 30;

String ngFmt(int n) {
  if (n >= 100000000) return '${(n / 1e8).toStringAsFixed(1)}億';
  if (n >= 10000) return '${(n / 1e4).toStringAsFixed(n >= 1000000 ? 0 : 1)}萬';
  return '$n';
}

// ---------------------------------------------------------------- 模擬
class NgEvt {
  final String kind; // gate bite kill boss slam hit win lose
  final int lane;
  final String text;
  final bool good;
  const NgEvt(this.kind, this.lane, this.text, this.good);
}

/// 一場跑關的模擬（畫面用，也給求解器逐段模擬用）。固定步長 ngDt。
class NgRun {
  final NgLevel lv;
  final bool perfect; // true＝求解器用：頭目的攻擊當作全部閃掉
  int row;
  double ts = 0; // 這一排（段）開始後經過的秒數
  int lane;
  int count;
  bool shifted = false;
  double shiftCd = 0;
  int result = 0; // 0 進行中 1 過關 2 失敗
  String why = '';
  List<double> mhp = [];
  List<bool> gone = [];
  double bossHp = 0;
  final List<NgEvt> events = [];
  // 頭目攻擊
  double slamAt = -1; // 預告的落下時間（頭目戰時間 bt）
  List<int> slamLanes = [];
  int slams = 0;
  int? targetMon; // 目前在打哪隻（畫面畫子彈用），null＝沒有
  bool bossFight = false; // 頭目已經停下來
  int _bossLane = 0; // 進頭目戰時站的道；打倒後陣型回到這條道（閃避換道不影響後面的路線）

  NgRun(this.lv, {this.perfect = false, this.row = 0, required this.lane, required this.count}) {
    _load();
  }

  NgRow get cur => lv.rows[row];
  double get T => lv.interval;

  void _load() {
    ts = 0;
    shifted = false;
    slamAt = -1;
    slamLanes = [];
    slams = 0;
    bossFight = false;
    final r = cur;
    if (r.isBoss) {
      _bossLane = lane;
      bossHp = r.bossHp.toDouble();
      mhp = [];
      gone = [];
    } else {
      mhp = [for (final m in r.mons) m.hp.toDouble()];
      gone = [for (final _ in r.mons) false];
    }
  }

  /// 換道。回傳是否成功（兩排之間只能一次；頭目停下來之後改成有冷卻）
  bool shift(int d) {
    final n = lane + d;
    if (result != 0 || n < 0 || n >= lv.lanes) return false;
    if (bossFight) {
      if (shiftCd > 0) return false;
      shiftCd = 0.25;
    } else {
      if (shifted) return false;
      shifted = true;
    }
    lane = n;
    return true;
  }

  void _lose(String w) {
    result = 2;
    why = w;
    events.add(NgEvt('lose', lane, w, false));
  }

  void step(double dt) {
    if (result != 0) return;
    final r = cur;
    ts += dt;
    if (shiftCd > 0) shiftCd -= dt;
    final f = count * ngK * dt;
    targetMon = null;
    if (r.isBoss) {
      final was = bossFight;
      bossFight = ts >= T;
      if (bossFight && !was) _bossLane = lane; // 頭目停下來那一刻站的道
      bossHp -= f;
      if (bossHp <= 0) {
        events.add(NgEvt('boss', lane, '${r.emoji} 倒下了', true));
        if (!r.isFinal) count = math.max(1, (count * 0.6).floor()); // 打頭目折損四成人
        lane = _bossLane;
        _nextRow();
        return;
      }
      if (bossFight) {
        final bt = ts - T;
        if (bt > r.bossLimit) {
          _lose('${r.emoji} 沒在時間內打倒，被壓垮了');
          return;
        }
        if (!perfect) _slams(r, bt);
      }
      return;
    }
    // 開火：打你這條道最前面的活小怪
    for (var i = 0; i < r.mons.length; i++) {
      if (gone[i] || r.mons[i].lane != lane) continue;
      targetMon = i;
      mhp[i] -= f;
      if (mhp[i] <= 0) {
        gone[i] = true;
        targetMon = null;
        events.add(NgEvt('kill', r.mons[i].lane, r.mons[i].emoji, true));
      }
      break;
    }
    // 小怪抵達
    for (var i = 0; i < r.mons.length; i++) {
      if (gone[i] || ts < r.mons[i].arrive) continue;
      gone[i] = true;
      if (r.mons[i].lane == lane) {
        final loss = mhp[i].ceil();
        count -= loss;
        events.add(NgEvt('bite', lane, '−${ngFmt(loss)}', false));
        if (count <= 0) {
          count = 0;
          _lose('${r.mons[i].emoji} 沒打死，咬掉了 ${ngFmt(loss)} 人，全軍覆沒');
          return;
        }
      }
    }
    // 穿過門
    if (ts >= T - 1e-9) {
      final g = r.gates![lane];
      final after = g.apply(count);
      if (after <= 0) {
        _lose('穿過 ${g.label}：${ngFmt(count)} 變成 0，全軍覆沒');
        return;
      }
      events.add(NgEvt('gate', lane, g.label, after >= count));
      count = after;
      _nextRow();
    }
  }

  void _slams(NgRow r, double bt) {
    if (slamAt < 0) {
      // 下一次預告：每 period 秒一次，預告後 0.9 秒落下，瞄準你現在站的道
      if (bt >= slams * r.bossPeriod + 0.5) {
        slamAt = bt + 0.9;
        final lanes = <int>{lane};
        if (lv.index >= 10) lanes.add(lane > 0 ? lane - 1 : lane + 1); // 後期一次打兩道
        if (lv.index >= 22 && lv.lanes >= 4) lanes.add(lane < lv.lanes - 1 ? lane + 1 : lane - 1);
        slamLanes = lanes.toList();
        events.add(NgEvt('slam', lane, '預告', false));
      }
    } else if (bt >= slamAt) {
      if (slamLanes.contains(lane)) {
        final loss = math.max(1, (count * 0.25).ceil());
        count -= loss;
        events.add(NgEvt('hit', lane, '−${ngFmt(loss)}', false));
        if (count <= 0) {
          count = 0;
          _lose('被 ${r.emoji} 的攻擊打垮了');
        }
      }
      slamAt = -1;
      slams++;
    }
  }

  void _nextRow() {
    row++;
    if (row >= lv.rows.length) {
      result = 1;
      events.add(const NgEvt('win', 0, '過關', true));
      return;
    }
    _load();
  }
}

/// 從第 i 排開頭（站在 lane、人數 count）整段模擬到穿過這一排，回傳剩餘人數（0＝死）
int ngSegment(NgLevel lv, int i, int lane, int count) {
  final run = NgRun(lv, perfect: true, row: i, lane: lane, count: count);
  while (run.result == 0 && run.row == i) {
    run.step(ngDt);
  }
  return run.result == 2 ? 0 : run.count;
}

// ---------------------------------------------------------------- 求解／驗證
const _monEmojis = ['👾', '🐛', '🦇', '🕷️', '👻', '🐀'];
const _bossEmojis = ['👹', '🐉', '👑', '😈', '🦖'];

typedef _P = ({int lanes, int rows, double interval, double mon, double boss, double limit, double period});

_P _params(int idx) {
  final t = (idx - 1) / (ngLevels - 1);
  final ease = idx <= 3 ? (4 - idx) * 0.1 : 0.0;
  return (
    lanes: idx >= 16 ? 4 : 3,
    rows: 8 + (idx * 0.5).floor() + (idx >= 10 ? 2 : 0) + (idx >= 20 ? 2 : 0),
    interval: 2.0 - 0.7 * t,
    mon: 0.45 + 0.5 * t - ease, // 小怪血量＝這一段火力的幾成
    boss: 0.72 + 0.27 * t - ease, // 頭目血量＝最佳走法火力的幾成（越後面越貼著最佳解）
    limit: 9 - 3 * t,
    period: 2.4 - 1.0 * t,
  );
}

NgLevel ngLevel(int idx) {
  final p = _params(idx);
  NgLevel? last;
  for (var attempt = 0; attempt < 400; attempt++) {
    final lv = _build(idx, p, math.Random(idx * 7919 + attempt * 104729 + 13));
    last = lv;
    if (lv.best <= 0) continue;
    if (idx >= 2 && ngGreedy(lv) > 0) continue;
    if (idx >= 6 && ngStayInLane(lv) > 0) continue;
    return lv;
  }
  return last!;
}

NgLevel _one(NgLevel lv, NgRow r) => NgLevel(lv.index, lv.lanes, lv.interval, lv.start, [r], 0);

/// 從上一排的 dp（每條道的最大人數）走一排，回傳這一排後每條道的最大人數
List<int> _dpRow(NgLevel proto, NgRow r, List<int> dp) {
  final lanes = proto.lanes;
  final one = _one(proto, r);
  final out = List<int>.filled(lanes, 0);
  for (var l = 0; l < lanes; l++) {
    var from = 0;
    for (var d = -1; d <= 1; d++) {
      final k = l + d;
      if (k >= 0 && k < lanes) from = math.max(from, dp[k]);
    }
    if (from <= 0) continue;
    out[l] = ngSegment(one, 0, l, from);
  }
  return out;
}

NgLevel _build(int idx, _P p, math.Random rng) {
  const start = 10;
  final lanes = p.lanes;
  final proto = NgLevel(idx, lanes, p.interval, start, const [], 0);
  final rows = <NgRow>[];
  var dp = List<int>.filled(lanes, start);
  final midBoss = idx >= 3 ? p.rows ~/ 2 : -1;
  for (var r = 0; r < p.rows; r++) {
    final last = r == p.rows - 1;
    if (last || r == midBoss) {
      final best = dp.reduce(math.max);
      final m = p.boss * (last ? 1.0 : 0.9);
      final hp = math.max(10, (best * ngK * (p.interval + p.limit) * m).floor());
      final row = NgRow.boss(hp, _bossEmojis[last ? 1 + rng.nextInt(_bossEmojis.length - 1) : 0], p.limit, p.period, isFinal: last);
      rows.add(row);
      dp = _dpRow(proto, row, dp);
      continue;
    }
    NgRow? ok;
    List<int>? okDp;
    for (var tries = 0; tries < 30; tries++) {
      final row = _segRow(rng, idx, p, dp);
      final nd = _dpRow(proto, row, dp);
      if (nd.any((c) => c > 0)) {
        ok = row;
        okDp = nd;
        break;
      }
    }
    if (ok == null) return NgLevel(idx, lanes, p.interval, start, rows, 0);
    rows.add(ok);
    dp = okDp!;
  }
  return NgLevel(idx, lanes, p.interval, start, rows, dp.reduce(math.max));
}

NgRow _segRow(math.Random rng, int idx, _P p, List<int> dp) {
  final lanes = p.lanes;
  final ref = math.max(5, dp.reduce(math.max));
  final gates = <NgGate>[for (var l = 0; l < lanes; l++) _gate(rng, ref, idx)];
  if (!gates.any((g) => g.isGood)) gates[rng.nextInt(lanes)] = NgGate(NgOp.add, math.max(2, (ref * 0.3).round()));
  final mons = <NgMon>[];
  final T = p.interval;
  final monP = (0.42 + 0.25 * (idx / ngLevels)).clamp(0.0, 0.8);
  for (var l = 0; l < lanes; l++) {
    if (rng.nextDouble() > monP) continue;
    final n = rng.nextDouble() < 0.35 + 0.3 * (idx / ngLevels) ? 2 : 1;
    var prev = 0.0;
    for (var k = 0; k < n; k++) {
      final a = k == 0 ? T * (0.3 + 0.25 * rng.nextDouble()) : math.min(T * 0.95, prev + T * (0.25 + 0.2 * rng.nextDouble()));
      if (a <= prev + 0.05) break;
      final hp = math.max(3, (ref * ngK * (a - prev) * p.mon * (0.6 + 0.4 * rng.nextDouble())).round());
      mons.add(NgMon(l, a, hp, _monEmojis[rng.nextInt(_monEmojis.length)]));
      prev = a;
    }
  }
  mons.sort((a, b) => a.arrive.compareTo(b.arrive));
  return NgRow.seg(gates, mons);
}

NgGate _gate(math.Random rng, int ref, int idx) {
  final hard = idx / ngLevels;
  final x = rng.nextDouble();
  var subP = 0.18 + 0.1 * hard, divP = 0.1 + 0.08 * hard, mulP = 0.28;
  if (ref > 150 * (1 + idx)) {
    // 人數已經太多：多出扣人的門，少出乘法，不然只是數字膨脹不是難
    subP = 0.38;
    divP = 0.3;
    mulP = 0.04;
  }
  if (x < subP) return NgGate(NgOp.sub, math.max(1, (ref * (0.08 + (ref > 150 * (1 + idx) ? 0.55 : 0.4) * rng.nextDouble())).round()));
  if (x < subP + divP) return NgGate(NgOp.div, 2 + rng.nextInt(idx >= 14 ? 3 : 2));
  if (x < subP + divP + mulP) return NgGate(NgOp.mul, 2 + (rng.nextDouble() < 0.18 ? 2 : rng.nextInt(2)));
  return NgGate(NgOp.add, math.max(2, (ref * (0.1 + 0.7 * rng.nextDouble())).round()));
}

/// 最佳解（每段最多換一道，換完在這一段全程待在新的道）的剩餘人數；0＝無解
int ngSolve(NgLevel lv) {
  var dp = List<int>.filled(lv.lanes, lv.start);
  for (final r in lv.rows) {
    dp = _dpRow(lv, r, dp);
  }
  return dp.reduce(math.max);
}

/// 最佳解路線（每一排站哪條道，頭目那排＝前一排的道）；無解回傳 null
List<int>? ngSolvePath(NgLevel lv) {
  final n = lv.rows.length, lanes = lv.lanes;
  final dp = [for (var i = 0; i <= n; i++) List<int>.filled(lanes, 0)];
  final par = [for (var i = 0; i <= n; i++) List<int>.filled(lanes, 0)];
  dp[0] = List<int>.filled(lanes, lv.start);
  for (var i = 0; i < n; i++) {
    for (var l = 0; l < lanes; l++) {
      var from = 0, fk = l;
      for (var d = -1; d <= 1; d++) {
        final k = l + d;
        if (k >= 0 && k < lanes && dp[i][k] > from) {
          from = dp[i][k];
          fk = k;
        }
      }
      par[i + 1][l] = fk;
      if (from > 0) dp[i + 1][l] = ngSegment(lv, i, l, from);
    }
  }
  var bl = 0;
  for (var l = 1; l < lanes; l++) {
    if (dp[n][l] > dp[n][bl]) bl = l;
  }
  if (dp[n][bl] <= 0) return null;
  final path = List<int>.filled(n, 0);
  var l = bl;
  for (var i = n - 1; i >= 0; i--) {
    path[i] = l;
    l = par[i + 1][l];
  }
  return path;
}

/// 照一條路線（每排站哪條道）完美執行的結果；0＝死
int ngReplay(NgLevel lv, List<int> path) {
  var c = lv.start;
  for (var i = 0; i < lv.rows.length; i++) {
    c = ngSegment(lv, i, path[i], c);
    if (c <= 0) return 0;
  }
  return c;
}

/// 「每一段挑模擬結果人數最多的那道（只能換一道）」的結果；0＝輸
int ngGreedy(NgLevel lv) {
  var lane = lv.lanes ~/ 2, c = lv.start;
  for (var i = 0; i < lv.rows.length; i++) {
    var bl = lane, bc = -1;
    for (var d = -1; d <= 1; d++) {
      final k = lane + d;
      if (k < 0 || k >= lv.lanes) continue;
      final v = ngSegment(lv, i, k, c);
      if (v > bc) {
        bc = v;
        bl = k;
      }
    }
    lane = bl;
    c = bc;
    if (c <= 0) return 0;
  }
  return c;
}

/// 一直站同一條道最好的那條
int ngStayInLane(NgLevel lv) {
  var best = 0;
  for (var lane = 0; lane < lv.lanes; lane++) {
    var c = lv.start;
    for (var i = 0; i < lv.rows.length; i++) {
      c = ngSegment(lv, i, lane, c);
      if (c <= 0) break;
    }
    if (c > best) best = c;
  }
  return best;
}

/// 每段隨機換道（−1/0/+1）的過關機率
double ngRandomWinRate(NgLevel lv, {int n = 600, int seed = 1}) {
  final rng = math.Random(seed);
  var win = 0;
  for (var i = 0; i < n; i++) {
    var lane = rng.nextInt(lv.lanes), c = lv.start;
    for (var r = 0; r < lv.rows.length; r++) {
      lane = (lane + rng.nextInt(3) - 1).clamp(0, lv.lanes - 1);
      c = ngSegment(lv, r, lane, c);
      if (c <= 0) break;
    }
    if (c > 0) win++;
  }
  return win / n;
}
