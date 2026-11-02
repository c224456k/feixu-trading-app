import 'dart:math' as math;

/// 數字門：自動往前跑，每一排有幾道門（+ − × ÷），穿過哪一道人數就照它變。
/// 規則重點（讓它不只是「每排挑最大」）：
/// - 兩排之間最多換一條道（換道要在這段時間內按，按完要等過了下一排才能再換）
/// - 路上的敵人／頭目要人數「大於」牠才過得去，過去後剩下 人數−敵人
/// - 所以眼前最大的門常常把你帶到下一排很爛的位置，要往前看幾排
enum NgOp { add, sub, mul, div }

const int ngCap = 1000000000;

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

class NgRow {
  final List<NgGate>? gates; // 一排門（每條道一個）
  final int enemy; // > 0：這一排是敵人，所有道都要打
  final bool boss;
  final String emoji;
  const NgRow.gates(List<NgGate> g)
      : gates = g,
        enemy = 0,
        boss = false,
        emoji = '';
  const NgRow.fight(this.enemy, this.emoji, {this.boss = false}) : gates = null;
  bool get isFight => gates == null;

  /// 過這一排後的人數；<=0 代表死了
  int pass(int count, int lane) => isFight ? (count > enemy ? count - enemy : 0) : gates![lane].apply(count);
}

class NgLevel {
  final int index; // 1 起算
  final int lanes;
  final double interval; // 兩排之間的秒數
  final int start;
  final List<NgRow> rows;
  final int best; // 最佳走法打完的剩餘人數（只拿來顯示難度，不給玩家看）
  const NgLevel(this.index, this.lanes, this.interval, this.start, this.rows, this.best);
}

const ngLevels = 30;

String ngFmt(int n) {
  if (n >= 100000000) return '${(n / 1e8).toStringAsFixed(1)}億';
  if (n >= 10000) return '${(n / 1e4).toStringAsFixed(n >= 1000000 ? 0 : 1)}萬';
  return '$n';
}

const _enemies = ['👹', '🐺', '💀', '🧌', '👺', '🦂'];
const _bosses = ['🐉', '👑', '😈'];

/// 這一關的難度參數
({int lanes, int rows, double interval, double mLo, double mHi, int fightEvery}) _params(int idx) {
  final t = (idx - 1) / (ngLevels - 1);
  final ease = idx <= 3 ? (4 - idx) * 0.1 : 0.0; // 前三關放寬一點當教學
  return (
    lanes: idx >= 16 ? 4 : 3,
    rows: 8 + (idx * 0.5).floor() + (idx >= 10 ? 2 : 0) + (idx >= 20 ? 2 : 0),
    interval: 1.7 - 0.6 * t, // 1.7 秒 → 1.1 秒
    mLo: 0.78 + 0.17 * t - ease - (idx == 1 ? 0.1 : 0), // 敵人強度＝最佳走法人數的 mLo~mHi 倍，越後面越貼著最佳解
    mHi: 0.86 + 0.13 * t - ease - (idx == 1 ? 0.1 : 0),
    fightEvery: idx >= 12 ? 3 : 4,
  );
}

/// 同一關編號永遠產生同一張（種子固定），並保證：有解、「每排挑當下最大的門」會輸
NgLevel ngLevel(int idx) {
  final p = _params(idx);
  NgLevel? last;
  for (var attempt = 0; attempt < 300; attempt++) {
    final lv = _build(idx, p, math.Random(idx * 7919 + attempt * 104729 + 13));
    last = lv;
    if (lv.best <= 0) continue;
    if (idx >= 2 && ngGreedy(lv) > 0) continue;
    if (idx >= 6 && ngStayInLane(lv) > 0) continue;
    return lv;
  }
  return last!;
}

NgLevel _build(int idx, ({int lanes, int rows, double interval, double mLo, double mHi, int fightEvery}) p, math.Random rng) {
  const start = 10;
  final lanes = p.lanes;
  final rows = <NgRow>[];
  // dp[lane]＝走到這裡、站在這條道的最大人數（0＝到不了）
  var dp = List<int>.filled(lanes, start);
  var sinceFight = 0;
  for (var r = 0; r < p.rows; r++) {
    final last = r == p.rows - 1;
    sinceFight++;
    if (last || sinceFight >= p.fightEvery && r < p.rows - 2) {
      final bestNow = dp.reduce(math.max);
      final m = last ? p.mHi : p.mLo + (p.mHi - p.mLo) * rng.nextDouble();
      final n = math.max(1, (bestNow * m).floor());
      rows.add(NgRow.fight(n, last ? _bosses[rng.nextInt(_bosses.length)] : _enemies[rng.nextInt(_enemies.length)], boss: last));
      dp = _stepFight(dp, n, lanes);
      sinceFight = 0;
      continue;
    }
    final ref = math.max(5, dp.reduce(math.max));
    final gates = <NgGate>[];
    for (var l = 0; l < lanes; l++) {
      gates.add(_gate(rng, ref, idx));
    }
    // 每排至少一道「看起來不錯」的門，不然只是在比誰比較不爛
    if (!gates.any((g) => g.isGood)) gates[rng.nextInt(lanes)] = NgGate(NgOp.mul, 2 + rng.nextInt(2));
    rows.add(NgRow.gates(gates));
    dp = _step(dp, gates, lanes);
  }
  return NgLevel(idx, lanes, p.interval, start, rows, dp.reduce(math.max));
}

NgGate _gate(math.Random rng, int ref, int idx) {
  final hard = (idx / ngLevels);
  final x = rng.nextDouble();
  // 越後面扣人的門越多
  final subP = 0.22 + 0.12 * hard, divP = 0.14 + 0.08 * hard, mulP = 0.26;
  if (x < subP) return NgGate(NgOp.sub, math.max(1, (ref * (0.08 + 0.45 * rng.nextDouble())).round()));
  if (x < subP + divP) return NgGate(NgOp.div, 2 + rng.nextInt(idx >= 14 ? 3 : 2));
  if (x < subP + divP + mulP) return NgGate(NgOp.mul, 2 + (rng.nextDouble() < 0.18 ? 2 : rng.nextInt(2)));
  return NgGate(NgOp.add, math.max(2, (ref * (0.1 + 0.7 * rng.nextDouble())).round()));
}

/// 一排敵人：前面也可以換一格道，過去後每道剩 人數−敵人
List<int> _stepFight(List<int> dp, int enemy, int lanes) {
  final out = List<int>.filled(lanes, 0);
  for (var l = 0; l < lanes; l++) {
    var from = 0;
    for (var d = -1; d <= 1; d++) {
      final k = l + d;
      if (k >= 0 && k < lanes) from = math.max(from, dp[k]);
    }
    out[l] = from > enemy ? from - enemy : 0;
  }
  return out;
}

/// 一排門：換道最多一格
List<int> _step(List<int> dp, List<NgGate> gates, int lanes) {
  final out = List<int>.filled(lanes, 0);
  for (var l = 0; l < lanes; l++) {
    var from = 0;
    for (var d = -1; d <= 1; d++) {
      final k = l + d;
      if (k < 0 || k >= lanes) continue;
      from = math.max(from, dp[k]);
    }
    if (from <= 0) continue;
    final c = gates[l].apply(from);
    out[l] = c > 0 ? c : 0;
  }
  return out;
}

/// 最佳解（以「每排最多換一格」計），回傳最後剩餘人數；0＝無解
int ngSolve(NgLevel lv) {
  var dp = List<int>.filled(lv.lanes, lv.start);
  for (final r in lv.rows) {
    dp = r.isFight ? _stepFight(dp, r.enemy, lv.lanes) : _step(dp, r.gates!, lv.lanes);
  }
  return dp.reduce(math.max);
}

/// 最佳解的路線（每一排要站哪條道），給「解法提示」用；無解回傳 null
List<int>? ngSolvePath(NgLevel lv) {
  final n = lv.rows.length, lanes = lv.lanes;
  final dp = [for (var i = 0; i <= n; i++) List<int>.filled(lanes, 0)];
  final par = [for (var i = 0; i <= n; i++) List<int>.filled(lanes, 0)];
  dp[0] = List<int>.filled(lanes, lv.start);
  for (var i = 0; i < n; i++) {
    final r = lv.rows[i];
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
      if (from <= 0) continue;
      final c = r.pass(from, l);
      dp[i + 1][l] = c > 0 ? c : 0;
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

/// 「每排挑當下人數最多的那道（只能換一格）」的結果，0＝輸
int ngGreedy(NgLevel lv) {
  var lane = lv.lanes ~/ 2, c = lv.start;
  for (final r in lv.rows) {
    if (r.isFight) {
      c = r.pass(c, lane);
    } else {
      var bl = lane, bc = -1 << 30;
      for (var d = -1; d <= 1; d++) {
        final k = lane + d;
        if (k < 0 || k >= lv.lanes) continue;
        final v = r.gates![k].apply(c);
        if (v > bc) {
          bc = v;
          bl = k;
        }
      }
      lane = bl;
      c = bc;
    }
    if (c <= 0) return 0;
  }
  return c;
}

/// 一直站在同一條道最好的那條
int ngStayInLane(NgLevel lv) {
  var best = 0;
  for (var lane = 0; lane < lv.lanes; lane++) {
    var c = lv.start;
    for (final r in lv.rows) {
      c = r.pass(c, lane);
      if (c <= 0) break;
    }
    if (c > best) best = c;
  }
  return best;
}

/// 隨機亂走（每排隨機 −1/0/+1）活到最後的機率，拿來看難度
double ngRandomWinRate(NgLevel lv, {int n = 4000, int seed = 1}) {
  final rng = math.Random(seed);
  var win = 0;
  for (var i = 0; i < n; i++) {
    var lane = rng.nextInt(lv.lanes), c = lv.start;
    for (final r in lv.rows) {
      lane = (lane + rng.nextInt(3) - 1).clamp(0, lv.lanes - 1);
      c = r.pass(c, lane);
      if (c <= 0) break;
    }
    if (c > 0) win++;
  }
  return win / n;
}

/// 玩家走過的路線（每排站哪條道）能不能過、剩多少人；0＝死
int ngReplay(NgLevel lv, List<int> path) {
  var c = lv.start;
  for (var i = 0; i < lv.rows.length; i++) {
    c = lv.rows[i].pass(c, path[i]);
    if (c <= 0) return 0;
  }
  return c;
}
