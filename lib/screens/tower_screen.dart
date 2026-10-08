import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api_client.dart';
import '../widgets/hero_art.dart';
import '../widgets/monster_art.dart';

// 百層塔：勇者在走廊往右走，碰到怪就進入回合戰鬥（勇者在左、怪物在右，最多同時三隻），自動攻擊。
// 規則與戰鬥結果全由伺服器（tower_game.py）裁決：一次 fight 呼叫就把整場算完回傳紀錄，這裡只負責播放動畫。
// 勇者戰敗要等 5 分鐘復活；獎勵是裝備掉落加每場勝利的現金。

enum _Phase { loading, idle, entering, walking, waiting, battle, after, cleared, dead }

const _bandNames = ['草原', '洞窟', '墓地', '森林', '沼澤', '礦坑', '熔岩', '冰霜', '天空', '魔界'];
const _skyTop = [0xFF8FD3F4, 0xFF1B1626, 0xFF1D2340, 0xFF2E5E3A, 0xFF4B5A2A, 0xFF2A2A30, 0xFF4A1208, 0xFF9ED8F5, 0xFF5BA8F0, 0xFF1A0510];
const _skyBottom = [0xFFDFF3D0, 0xFF3A2E4A, 0xFF4A4F7A, 0xFF9CCB7A, 0xFFA6B86B, 0xFF5A5A66, 0xFFFF7A2E, 0xFFEAF8FF, 0xFFFFE4B8, 0xFF7A1630];
const _groundCol = [0xFF4C8C3A, 0xFF4A3B33, 0xFF3A3D4A, 0xFF3B6B2E, 0xFF4A5A2F, 0xFF5A5148, 0xFF3A2018, 0xFFDCEEF7, 0xFFEFE2C8, 0xFF2A1018];
const _farCol = [0xFF6BAF5B, 0xFF2B2234, 0xFF2A2E4A, 0xFF1F4A2A, 0xFF3A4A22, 0xFF3A3A44, 0xFF5A2210, 0xFFB0D4EA, 0xFFFFFFFF, 0xFF3A0C1C];

class _Mon {
  final String name;
  final int kind;
  final int band;
  final bool boss;
  final int maxHp;
  int hp;
  double flash = 0;
  double dying = 0; // 0 活著，>0 淡出中
  double shown; // 血條顯示值（平滑追上 hp）
  double ghost; // 殘影血條（被打掉的那一段，延遲後慢慢縮）
  double ghostHold = 0;
  double knock = 0; // 被打到的後仰 0~1
  _Mon(Map<String, dynamic> m)
      : name = m['name'] as String,
        kind = (m['kind'] as num).toInt(),
        band = (m['band'] as num).toInt(),
        boss = m['boss'] == true,
        maxHp = (m['max_hp'] as num).toInt(),
        hp = (m['hp'] as num).toInt(),
        shown = (m['hp'] as num).toDouble(),
        ghost = (m['hp'] as num).toDouble();
}

// 打擊特效：劈砍 / 爪擊 + 擴散環；火花粒子另外一個 list
class _Fx {
  final double x;
  final double y;
  final double size;
  final bool claw;
  final bool crit;
  final bool flip; // 勇者打怪物 = 由左上劈向右下；怪物打勇者反向
  double age = 0;
  static const dur = 0.38;
  _Fx(this.x, this.y, this.size, {this.claw = false, this.crit = false, this.flip = false});
}

class _Spark {
  double x;
  double y;
  double vx;
  double vy;
  final Color color;
  final double size;
  double age = 0;
  final double life;
  _Spark(this.x, this.y, this.vx, this.vy, this.color, this.size, this.life);
}

class _Float {
  final String text;
  final double x;
  final double y;
  final Color color;
  final double size;
  double age = 0;
  _Float(this.text, this.x, this.y, this.color, this.size);
}

class TowerScreen extends StatefulWidget {
  const TowerScreen({super.key});

  @override
  State<TowerScreen> createState() => _TowerScreenState();
}

class _TowerScreenState extends State<TowerScreen> with SingleTickerProviderStateMixin {
  final _api = ApiClient();
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  _Phase _phase = _Phase.loading;
  String? _error;
  Map<String, ({String id, int tier})> _equipped = {};
  Map<String, dynamic> _hero = {'atk': 10, 'def': 5, 'hp': 300, 'agi': 5, 'luk': 5};
  int _maxFloor = 100;
  int get _maxSelectable => math.min(_maxFloor, _bestFloor + 1); // 要先通關才能挑更高的樓層
  int _bestFloor = 0;
  int _dropsLeft = 20;
  int _goldLeft = 0;
  int _goldCap = 0;
  // 肉（體力）：每場戰鬥消耗 10，每分鐘恢復 1，上限 60（以伺服器回報為準，本機只做倒數顯示）
  double _meatBase = 60;
  DateTime _meatStamp = DateTime.now();
  int _meatMax = 60;
  int _meatCost = 10;
  int _meatRegen = 60;
  double get _meat => math.min(_meatMax.toDouble(), _meatBase + DateTime.now().difference(_meatStamp).inMilliseconds / 1000 / _meatRegen);

  void _setMeat(Map<String, dynamic> m) {
    final v = (m['meat'] as num?)?.toDouble();
    if (v == null) {
      return;
    }
    _meatBase = v;
    _meatStamp = DateTime.now();
    _meatMax = (m['meat_max'] as num?)?.toInt() ?? _meatMax;
    _meatCost = (m['meat_cost'] as num?)?.toInt() ?? _meatCost;
    _meatRegen = (m['meat_regen_seconds'] as num?)?.toInt() ?? _meatRegen;
  }
  int _floor = 1; // 選擇中的樓層
  bool _autoUp = true;
  double _speed = 2;

  // 探索狀態
  int _runFloor = 1;
  List<List<Map<String, dynamic>>> _encounters = [];
  int _index = 0;
  int _heroHp = 1;
  int _heroMax = 1;
  List<_Mon> _mons = [];

  // 動畫
  double _t = 0;
  double _scroll = 0;
  double _walkT = 0;
  static const _walkDur = 4.0;
  double _retryIn = 0;
  bool _requesting = false;

  // 戰鬥播放
  List<Map<String, dynamic>> _log = [];
  int _logIdx = 0;
  double _actionT = 0;
  bool _applied = false;
  Map<String, dynamic>? _result;
  double _afterT = 0;
  bool _heroDown = false;
  double _heroFlash = 0;
  final List<_Float> _floats = [];
  final List<_Fx> _fx = [];
  final List<_Spark> _sparks = [];
  final math.Random _rnd = math.Random();
  double _shake = 0;
  double _heroShown = 1;
  double _heroGhost = 1;
  double _heroGhostHold = 0;
  double _heroKnock = 0;
  String _banner = '';
  double _bannerT = 0;
  DateTime? _deadUntil;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _load();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // ---------- 載入 ----------
  Future<void> _load() async {
    try {
      final eq = await _api.fetchHeroEquipment();
      final st = await _api.fetchTowerState();
      if (!mounted) return;
      final m = <String, ({String id, int tier})>{};
      for (final s in (eq['slots'] as List)) {
        final it = s['item'] as Map<String, dynamic>?;
        if (it != null) {
          m[s['key'] as String] = (id: it['id'] as String, tier: (it['tier'] as num).toInt());
        }
      }
      setState(() {
        _equipped = m;
        _applyState(st);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    }
  }

  void _applyState(Map<String, dynamic> st) {
    _hero = (st['hero'] as Map).cast<String, dynamic>();
    _maxFloor = (st['max_floor'] as num?)?.toInt() ?? 100;
    _setMeat(st);
    _bestFloor = (st['best_floor'] as num).toInt();
    _dropsLeft = (st['drops_left'] as num?)?.toInt() ?? 0;
    _goldLeft = (st['gold_left'] as num?)?.toInt() ?? 0;
    _goldCap = (st['gold_cap'] as num?)?.toInt() ?? 0;
    _floor = (st['selected_floor'] as num).toInt().clamp(1, _maxSelectable);
    final dead = (st['dead_seconds'] as num?)?.toInt() ?? 0;
    final run = st['run'] as Map<String, dynamic>?;
    _heroMax = (_hero['hp'] as num).toInt();
    _heroHp = _heroMax;
    _heroDown = false;
    if (dead > 0) {
      _deadUntil = DateTime.now().add(Duration(seconds: dead));
      _heroDown = true;
      _phase = _Phase.dead;
    } else if (run != null) {
      _setRun(run);
      _phase = _Phase.walking;
    } else {
      _phase = _Phase.idle;
    }
  }

  void _setRun(Map<String, dynamic> run) {
    _runFloor = (run['floor'] as num).toInt();
    _encounters = [
      for (final e in (run['encounters'] as List)) [for (final m in (e as List)) (m as Map).cast<String, dynamic>()]
    ];
    _index = (run['index'] as num).toInt();
    _heroHp = (run['hp'] as num).toInt();
    _heroMax = (run['max_hp'] as num).toInt();
    _loadMonsters();
    _walkT = 0;
    _heroDown = false;
  }

  void _loadMonsters() {
    _mons = _index < _encounters.length ? [for (final m in _encounters[_index]) _Mon(m)] : [];
  }

  // ---------- 動作 ----------
  Future<void> _enter(int floor) async {
    if (_phase == _Phase.entering) {
      return;
    }
    setState(() => _phase = _Phase.entering);
    try {
      final r = await _api.towerEnter(floor);
      if (!mounted) return;
      _setMeat(r);
      if (r['ok'] == true) {
        setState(() {
          _floor = floor;
          _setRun((r['run'] as Map).cast<String, dynamic>());
          _heroDown = false;
          _phase = _Phase.walking;
        });
      } else {
        _toast('${r['message']}');
        setState(() => _phase = _Phase.idle);
        await _refreshState();
      }
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
      setState(() => _phase = _Phase.idle);
    }
  }

  Future<void> _refreshState() async {
    try {
      final st = await _api.fetchTowerState();
      if (!mounted) return;
      setState(() => _applyState(st));
    } catch (_) {}
  }

  Future<void> _leave() async {
    try {
      await _api.towerLeave();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _mons = [];
      _heroHp = _heroMax;
    });
  }

  Future<void> _startFight() async {
    _requesting = true;
    setState(() => _phase = _Phase.waiting);
    try {
      final r = await _api.towerFight();
      if (!mounted) return;
      if (r['ok'] != true) {
        final retry = (r['retry_after'] as num?)?.toDouble();
        if (retry != null) {
          _retryIn = retry + 0.1;
          setState(() => _phase = _Phase.walking);
        } else {
          _toast('${r['message']}');
          setState(() => _phase = _Phase.idle);
          await _refreshState();
        }
        return;
      }
      setState(() {
        _result = r;
        _mons = [for (final m in (r['monsters'] as List)) _Mon((m as Map).cast<String, dynamic>())];
        _log = [for (final e in (r['log'] as List)) (e as Map).cast<String, dynamic>()];
        _logIdx = 0;
        _actionT = 0;
        _applied = false;
        _heroHp = (r['hero_hp_before'] as num).toInt();
        _heroMax = (r['max_hp'] as num).toInt();
        _phase = _Phase.battle;
      });
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
      setState(() => _phase = _Phase.idle);
    } finally {
      _requesting = false;
    }
  }

  String _fmtGold(int v) => v.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------- 每幀 ----------
  void _onTick(Duration elapsed) {
    final dt = math.min(0.1, (elapsed - _lastElapsed).inMicroseconds / 1e6);
    _lastElapsed = elapsed;
    if (!mounted) {
      return;
    }
    _t += dt;
    for (final m in _mons) {
      m.shown += (m.hp - m.shown) * math.min(1.0, dt * 14);
      m.ghost = _stepGhost(m.ghost, m.hp.toDouble(), m.maxHp.toDouble(), m.ghostHold, dt);
      m.ghostHold = math.max(0, m.ghostHold - dt);
      m.knock = math.max(0, m.knock - dt * 4.5);
      m.flash = math.max(0, m.flash - dt * 4);
      if (m.dying > 0) {
        m.dying = math.min(1, m.dying + dt * 2.2);
      }
    }
    _heroFlash = math.max(0, _heroFlash - dt * 4);
    _heroShown += (_heroHp - _heroShown) * math.min(1.0, dt * 14);
    _heroGhost = _stepGhost(_heroGhost, _heroHp.toDouble(), _heroMax.toDouble(), _heroGhostHold, dt);
    _heroGhostHold = math.max(0, _heroGhostHold - dt);
    _heroKnock = math.max(0, _heroKnock - dt * 4.5);
    _shake = math.max(0, _shake - dt * 40);
    for (final f in _fx) {
      f.age += dt;
    }
    _fx.removeWhere((f) => f.age > _Fx.dur);
    for (final sp in _sparks) {
      sp.age += dt;
      sp.x += sp.vx * dt;
      sp.y += sp.vy * dt;
      sp.vy += 700 * dt;
      sp.vx *= 1 - dt * 1.5;
    }
    _sparks.removeWhere((sp) => sp.age > sp.life);
    for (final f in _floats) {
      f.age += dt;
    }
    _floats.removeWhere((f) => f.age > 1.0);
    if (_bannerT > 0) {
      _bannerT -= dt;
    }
    switch (_phase) {
      case _Phase.walking:
        _scroll += 110 * dt;
        if (_retryIn > 0) {
          _retryIn -= dt;
        } else {
          _walkT += dt;
          if (_walkT >= _walkDur && !_requesting) {
            _startFight();
          }
        }
      case _Phase.battle:
        _stepBattle(dt * _speed);
      case _Phase.after:
        _afterT += dt * _speed;
        if (_afterT >= 1.3) {
          _finishAfter();
        }
      case _Phase.cleared:
        _afterT += dt;
        if (_afterT >= 2.2) {
          final next = _autoUp ? math.min(_maxFloor, _runFloor + 1) : _runFloor;
          _enter(next);
          _afterT = -999;
        }
      case _Phase.dead:
        if (_deadUntil != null && DateTime.now().isAfter(_deadUntil!)) {
          _deadUntil = null;
          _heroDown = false;
          _heroHp = _heroMax;
          _phase = _Phase.idle;
          _toast('勇者復活了！');
        }
      default:
        break;
    }
    setState(() {});
  }

  // 殘影血條：回血時直接跟上；扣血時先停一下再往下滑
  double _stepGhost(double ghost, double hp, double max, double hold, double dt) {
    if (hp >= ghost) return hp;
    if (hold > 0) return ghost;
    return math.max(hp, ghost - (max * 0.5 + (ghost - hp) * 3) * dt);
  }

  void _burst(double x, double y, int n, List<Color> colors, {double speed = 260, double size = 3.5}) {
    for (var i = 0; i < n; i++) {
      final a = _rnd.nextDouble() * math.pi * 2;
      final v = speed * (0.35 + _rnd.nextDouble() * 0.65);
      _sparks.add(_Spark(x, y, math.cos(a) * v, math.sin(a) * v - 90, colors[_rnd.nextInt(colors.length)], size * (0.6 + _rnd.nextDouble() * 0.8), 0.35 + _rnd.nextDouble() * 0.3));
    }
  }

  static const _actionDur = 0.6;
  static const _hitAt = 0.25;

  void _stepBattle(double dt) {
    if (_logIdx >= _log.length) {
      _endBattle();
      return;
    }
    _actionT += dt;
    final ev = _log[_logIdx];
    if (!_applied && _actionT >= _hitAt) {
      _applied = true;
      _applyEvent(ev);
    }
    if (_actionT >= _actionDur) {
      _logIdx++;
      _actionT = 0;
      _applied = false;
    }
  }

  // 舞台座標：寬 w、地面高度 gy（paint 時用同一組公式）
  void _applyEvent(Map<String, dynamic> ev) {
    final miss = ev['miss'] == true;
    final crit = ev['crit'] == true;
    final dmg = (ev['dmg'] as num).toInt();
    final hp = (ev['hp'] as num).toInt();
    final d = ev['d'];
    if (d == 'h') {
      _floats.add(_Float(miss ? 'MISS' : '-$dmg', _heroX, _groundY - 150, miss ? Colors.white70 : const Color(0xFFFF6B6B), crit ? 26 : 20));
      if (!miss) {
        _heroFlash = 1;
        _heroKnock = 1;
        _heroGhostHold = 0.45;
        final hy = _groundY - 90;
        _fx.add(_Fx(_heroX, hy, 70, claw: true, crit: crit, flip: true));
        _burst(_heroX, hy, crit ? 18 : 10, const [Color(0xFFFF5252), Color(0xFFFFB199), Colors.white]);
        _shake = math.max(_shake, crit ? 9 : 5);
      }
      _heroHp = hp;
      if (hp <= 0) {
        _heroDown = true;
      }
    } else {
      final i = (d as num).toInt();
      if (i < _mons.length) {
        final m = _mons[i];
        final pos = _monPos(i, _mons.length);
        _floats.add(_Float(miss ? 'MISS' : (crit ? '$dmg!' : '$dmg'), pos.dx, pos.dy - _monSize(m) - 16,
            miss ? Colors.white70 : (crit ? const Color(0xFFFFD93D) : Colors.white), crit ? 28 : 20));
        if (!miss) {
          m.flash = 1;
          m.knock = 1;
          m.ghostHold = 0.45;
          final cy = pos.dy - _monSize(m) * 0.5;
          _fx.add(_Fx(pos.dx, cy, _monSize(m) * 0.62, crit: crit));
          _burst(pos.dx, cy, crit ? 22 : 11,
              crit ? const [Color(0xFFFFD93D), Colors.white, Color(0xFFFF9F1C)] : const [Colors.white, Color(0xFFBFE6FF), Color(0xFFFFE9A8)],
              speed: crit ? 340 : 250);
          _shake = math.max(_shake, crit ? 9 : (m.boss ? 4 : 3));
        }
        m.hp = hp;
        if (hp <= 0) {
          m.dying = 0.01;
          _burst(pos.dx, pos.dy - _monSize(m) * 0.45, 22, const [Color(0xFFEEEEEE), Color(0xFFB0BEC5), Color(0xFFFFE082)], speed: 200, size: 5);
        }
      }
    }
  }

  void _endBattle() {
    final r = _result!;
    final won = r['won'] == true;
    _afterT = 0;
    if (won) {
      final after = (r['hero_hp_after'] as num).toInt();
      if (after > _heroHp) {
        _floats.add(_Float('+${after - _heroHp}', _heroX, _groundY - 150, const Color(0xFF7DFFA0), 20));
      }
      _heroHp = after;
      _bestFloor = (r['best_floor'] as num).toInt();
      _dropsLeft = (r['drops_left'] as num?)?.toInt() ?? _dropsLeft;
      _goldLeft = (r['gold_left'] as num?)?.toInt() ?? _goldLeft;
      final gold = (r['gold'] as num?)?.toInt() ?? 0;
      if (gold > 0) {
        _floats.add(_Float('+${_fmtGold(gold)}', _heroX, _groundY - 190, const Color(0xFFFFD93D), 22));
      }
      _banner = r['cleared'] == true ? '第 $_runFloor 層通關！' : '勝利！';
      _bannerT = 1.4;
      for (final d in (r['drops'] as List)) {
        final it = (d['item'] as Map).cast<String, dynamic>();
        _toast('🎁 獲得 ${it['name']}${it['quality'] != null ? '（品質 ${it['quality']}%）' : ''}（已放進物品欄）');
      }
      _phase = _Phase.after;
    } else {
      _heroDown = true;
      _banner = '勇者倒下了…';
      _bannerT = 2;
      _deadUntil = DateTime.now().add(Duration(seconds: (r['dead_seconds'] as num?)?.toInt() ?? 300));
      _phase = _Phase.dead;
    }
  }

  void _finishAfter() {
    final r = _result!;
    if (r['cleared'] == true) {
      _afterT = 0;
      _phase = _Phase.cleared;
      _banner = '第 $_runFloor 層通關！';
      _bannerT = 2.2;
      return;
    }
    _index = (r['index'] as num).toInt();
    _loadMonsters();
    _walkT = 0;
    _phase = _Phase.walking;
  }

  // ---------- 座標（舞台 painter 與事件共用）----------
  double _stageW = 360;
  static const double _stageH = 290;
  double get _groundY => _stageH * 0.80;
  double get _heroX => _stageW * 0.20;

  double _monSize(_Mon m) => m.boss ? 128 : (_mons.any((x) => x.boss) ? 72 : 92);

  Offset _monPos(int i, int n) {
    // 最多三隻，斜排：前（左下）→ 後（右上）
    final bossFight = _mons.any((m) => m.boss);
    final xs = n == 1 ? [0.66] : n == 2 ? [0.60, 0.80] : (bossFight ? [0.47, 0.68, 0.91] : [0.56, 0.72, 0.88]);
    final ys = n == 1 ? [0.0] : n == 2 ? [4.0, -6.0] : [6.0, -2.0, -10.0];
    var dx = 0.0;
    if (_phase == _Phase.walking || _phase == _Phase.waiting) {
      final prog = (_walkT / _walkDur).clamp(0.0, 1.0);
      dx = (1 - prog) * _stageW * 0.55;
    }
    return Offset(_stageW * xs[i] + dx, _groundY + ys[i]);
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF14110B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1710),
        title: const Text('百層塔'),
        actions: [IconButton(onPressed: _showHelp, icon: const Icon(Icons.help_outline), tooltip: '玩法說明')],
      ),
      body: _error != null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                FilledButton(
                    onPressed: () {
                      setState(() => _error = null);
                      _load();
                    },
                    child: const Text('重試')),
              ]),
            )
          : _phase == _Phase.loading
              ? const Center(child: CircularProgressIndicator())
              : _content(),
    );
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('百層塔玩法'),
        content: const SingleChildScrollView(
          child: Text(
            '・只能選「最高通關層數 + 1」以內的樓層，要先爬上去才能挑戰更高的。\n・選一個樓層出發，勇者會自動往右走，碰到怪物就進入回合戰鬥，全自動攻擊。\n'
            '・怪物最多同時三隻；每 10 層有一隻頭目（帶兩隻小怪）。\n'
            '・每層有 5 場戰鬥，打完就通關；每場勝利回復 15% 血量，通關回滿。\n'
            '・樓層越高怪物越強；裝備越好的勇者才能爬得越高。\n'
            '・每挑戰一層（出發或上樓）消耗 10 塊肉🍖，肉每分鐘恢復 1 塊、上限 60（約 60 分鐘回滿）；層內的戰鬥不另外扣，肉不夠就不能出發。\n'
            '・勇者戰敗要等 5 分鐘才能復活。\n'
            '・每場戰鬥勝利給現金：10 層約 625 元，越高越多，100 層約 2,500 元，頭目那場加倍；每天最多從塔領 125,000 元。\n'
            '・裝備掉落（頭目必掉），每天最多 20 件，樓層越高掉越好的。\n'
            '・結果由伺服器決定，中途離開頁面也算數。',
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
      ),
    );
  }

  Widget _content() {
    final running = _phase == _Phase.walking || _phase == _Phase.waiting || _phase == _Phase.battle || _phase == _Phase.after || _phase == _Phase.cleared;
    return LayoutBuilder(builder: (context, c) {
      _stageW = c.maxWidth;
      return SingleChildScrollView(
        child: Column(children: [
          SizedBox(
            height: _stageH,
            width: double.infinity,
            child: Stack(children: [
              Positioned.fill(child: ClipRect(child: CustomPaint(painter: _StagePainter(this)))),
              Positioned(
                left: 10,
                top: 8,
                child: _chip('第 ${running ? _runFloor : _floor} 層・${_bandNames[(((running ? _runFloor : _floor) - 1) ~/ 10).clamp(0, 9)]}'),
              ),
              if (running)
                Positioned(
                  right: 10,
                  top: 8,
                  child: _chip('戰鬥 ${math.min(_index + 1, _encounters.length)}/${_encounters.length}'),
                ),
              if (_bannerT > 0 && _banner.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: Opacity(
                        opacity: _bannerT.clamp(0.0, 1.0),
                        child: Text(_banner,
                            style: const TextStyle(
                                color: Color(0xFFFFE08A),
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                shadows: [Shadow(color: Colors.black, blurRadius: 8), Shadow(color: Colors.black, blurRadius: 2)])),
                      ),
                    ),
                  ),
                ),
              if (_phase == _Phase.dead) Positioned.fill(child: _deadOverlay()),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              _hpBar(),
              const SizedBox(height: 10),
              _meatBar(),
              const SizedBox(height: 12),
              _floorSelector(running),
              const SizedBox(height: 10),
              _controls(running),
              const SizedBox(height: 10),
              _infoCard(),
            ]),
          ),
        ]),
      );
    });
  }

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF6B5A2E))),
        child: Text(text, style: const TextStyle(color: Color(0xFFFFD36B), fontSize: 13, fontWeight: FontWeight.bold)),
      );

  Widget _deadOverlay() {
    final left = _deadUntil == null ? 0 : math.max(0, _deadUntil!.difference(DateTime.now()).inSeconds + 1);
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('💀', style: TextStyle(fontSize: 44)),
        const SizedBox(height: 4),
        const Text('勇者倒下了', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text('復活倒數 ${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}', style: const TextStyle(color: Color(0xFFFFD36B), fontSize: 18)),
      ]),
    );
  }

  Widget _meatBar() {
    final m = _meat;
    final full = m >= _meatMax - 1e-9;
    final secsToNext = full ? 0 : ((1 - (m - m.floorToDouble())) * _meatRegen).ceil();
    final enough = m >= _meatCost;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('🍖 肉  ${m.floor()} / $_meatMax', style: TextStyle(color: enough ? Colors.white70 : const Color(0xFFFF8A80), fontSize: 12)),
        const Spacer(),
        Text(
          !enough
              ? '肉不夠（每層 $_meatCost 塊），等待恢復…'
              : full
                  ? '已滿（每層 $_meatCost 塊）'
                  : '每層 $_meatCost 塊・下一塊 $secsToNext 秒',
          style: TextStyle(color: enough ? Colors.white38 : const Color(0xFFFF8A80), fontSize: 11),
        ),
      ]),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
            value: (m / _meatMax).clamp(0.0, 1.0), minHeight: 8, backgroundColor: Colors.white12, valueColor: AlwaysStoppedAnimation(enough ? const Color(0xFFE59A4B) : const Color(0xFFFF5252))),
      ),
    ]);
  }

  Widget _hpBar() {
    final ratio = _heroMax == 0 ? 0.0 : (_heroShown / _heroMax).clamp(0.0, 1.0);
    final ghostRatio = _heroMax == 0 ? 0.0 : (_heroGhost / _heroMax).clamp(0.0, 1.0);
    final color = ratio > 0.5 ? const Color(0xFF4CD964) : ratio > 0.25 ? const Color(0xFFFFC107) : const Color(0xFFFF5252);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('勇者 HP  $_heroHp / $_heroMax', style: const TextStyle(color: Colors.white70, fontSize: 12)),
      const SizedBox(height: 4),
      Container(
        height: 14,
        decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(7), border: Border.all(color: Colors.white24)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LayoutBuilder(builder: (context, c) {
            return Stack(children: [
              Container(width: c.maxWidth * ghostRatio, color: const Color(0xFFFFE9A8)),
              Container(
                width: c.maxWidth * ratio,
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(color, Colors.white, 0.35)!, color, Color.lerp(color, Colors.black, 0.25)!]),
                ),
              ),
            ]);
          }),
        ),
      ),
    ]);
  }

  Widget _floorSelector(bool running) {
    void set(int v) => setState(() => _floor = v.clamp(1, _maxSelectable));
    final band = _bandNames[((_floor - 1) ~/ 10).clamp(0, 9)];
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      decoration: BoxDecoration(color: const Color(0xFF1B1710), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF3D3320))),
      child: Column(children: [
        Row(children: [
          Text('樓層  $_floor', style: const TextStyle(color: Color(0xFFFFD36B), fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(width: 8),
          Text('$band${_floor % 10 == 0 ? '・頭目層' : ''}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const Spacer(),
          Text('最高通關 $_bestFloor 層・可選到 $_maxSelectable 層', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ]),
        Row(children: [
          IconButton(onPressed: () => set(_floor - 10), icon: const Icon(Icons.keyboard_double_arrow_left, color: Colors.white70), tooltip: '-10'),
          IconButton(onPressed: () => set(_floor - 1), icon: const Icon(Icons.chevron_left, color: Colors.white70)),
          Expanded(
            child: _maxSelectable <= 1
                ? const Center(child: Text('通關第 1 層後解鎖更高樓層', style: TextStyle(color: Colors.white38, fontSize: 12)))
                : Slider(
                    value: _floor.toDouble().clamp(1, _maxSelectable.toDouble()),
                    min: 1,
                    max: _maxSelectable.toDouble(),
                    divisions: _maxSelectable - 1,
                    onChanged: (v) => set(v.round()),
                  ),
          ),
          IconButton(onPressed: () => set(_floor + 1), icon: const Icon(Icons.chevron_right, color: Colors.white70)),
          IconButton(onPressed: () => set(_floor + 10), icon: const Icon(Icons.keyboard_double_arrow_right, color: Colors.white70), tooltip: '+10'),
        ]),
      ]),
    );
  }

  Widget _controls(bool running) {
    final dead = _phase == _Phase.dead;
    final busy = _phase == _Phase.entering || _phase == _Phase.waiting;
    String label;
    VoidCallback? action;
    if (dead) {
      label = '復活中…';
      action = null;
    } else if (!running) {
      label = '出發（第 $_floor 層）';
      action = busy ? null : () => _enter(_floor);
    } else if (_floor != _runFloor) {
      label = '前往第 $_floor 層';
      action = busy || _phase == _Phase.battle ? null : () => _enter(_floor);
    } else {
      label = '撤退';
      action = busy || _phase == _Phase.battle ? null : _leave;
    }
    return Column(children: [
      SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton.icon(
          onPressed: action,
          icon: Icon(running && _floor == _runFloor ? Icons.exit_to_app : Icons.play_arrow),
          label: Text(label, style: const TextStyle(fontSize: 16)),
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        const Text('通關後自動上樓', style: TextStyle(color: Colors.white70, fontSize: 13)),
        Switch(value: _autoUp, onChanged: (v) => setState(() => _autoUp = v)),
        const Spacer(),
        ChoiceChip(label: const Text('×1'), selected: _speed == 1, onSelected: (_) => setState(() => _speed = 1)),
        const SizedBox(width: 6),
        ChoiceChip(label: const Text('×2'), selected: _speed == 2, onSelected: (_) => setState(() => _speed = 2)),
      ]),
    ]);
  }

  Widget _infoCard() {
    Widget s(String k, Object v) => Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '$k ', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            TextSpan(text: '$v', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ])),
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF1B1710), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF3D3320))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(runSpacing: 4, children: [
          s('攻擊', _hero['atk']),
          s('防禦', _hero['def']),
          s('生命', _hero['hp']),
          s('敏捷', _hero['agi']),
          s('幸運', _hero['luk']),
        ]),
        const SizedBox(height: 6),
        Text('💰 今日還能領 ${_fmtGold(_goldLeft)} / ${_fmtGold(_goldCap)} 元獎金（每場勝利給錢）', style: const TextStyle(color: Color(0xFFFFD36B), fontSize: 12)),
        const SizedBox(height: 2),
        Text('今日還能掉落 $_dropsLeft 件裝備（每天上限 20 件）', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const Text('想爬更高：用 Boss 掉的裝備把勇者練強。', style: TextStyle(color: Colors.white30, fontSize: 11)),
      ]),
    );
  }
}

// ======================= 舞台繪製 =======================
class _StagePainter extends CustomPainter {
  final _TowerScreenState s;
  _StagePainter(this.s);

  @override
  void paint(Canvas canvas, Size size) {
    final band = (((s._phase == _Phase.idle || s._phase == _Phase.dead && s._encounters.isEmpty ? s._floor : s._runFloor) - 1) ~/ 10).clamp(0, 9);
    canvas.save();
    if (s._shake > 0) {
      canvas.translate(math.sin(s._t * 130) * s._shake, math.cos(s._t * 110) * s._shake * 0.6);
    }
    _background(canvas, size, band);
    final gy = s._groundY;

    // 勇者
    _drawHero(canvas, gy);

    // 怪物（後排先畫）
    final n = s._mons.length;
    final order = List.generate(n, (i) => i)..sort((a, b) => s._monPos(a, n).dy.compareTo(s._monPos(b, n).dy));
    for (final i in order) {
      final m = s._mons[i];
      if (s._phase == _Phase.idle || s._phase == _Phase.entering) {
        continue;
      }
      final pos = s._monPos(i, n);
      final sz = s._monSize(m);
      var lunge = 0.0;
      var attacking = false;
      if (s._phase == _Phase.battle && s._logIdx < s._log.length && s._log[s._logIdx]['a'] == i) {
        lunge = -_lungeCurve(s._actionT) * 60;
        attacking = true;
      }
      if (m.dying >= 1) {
        continue;
      }
      // 影子（死亡時跟著縮小）
      canvas.drawOval(Rect.fromCenter(center: Offset(pos.dx, pos.dy + 2), width: sz * 0.62 * (1 - m.dying * 0.5), height: 9), Paint()..color = Color.fromRGBO(0, 0, 0, 0.28 * (1 - m.dying)));
      // 被打：往後仰＋壓扁；出招：蓄力時前傾、撞到時拉長；死亡：縮小並往上飄
      final k = Curves.easeOut.transform(m.knock);
      final lean = attacking ? _lungeCurve(s._actionT).clamp(-1.0, 1.0) : 0.0;
      canvas.save();
      canvas.translate(pos.dx + lunge + k * 16, pos.dy - m.dying * 18);
      canvas.rotate(k * 0.12 - lean * 0.08);
      canvas.scale((1 + k * -0.10 + (attacking ? lean.abs() * 0.06 : 0)) * (1 - m.dying * 0.3), (1 + k * 0.10 - (attacking ? lean.abs() * 0.04 : 0)) * (1 - m.dying * 0.3));
      canvas.translate(-sz / 2, -sz);
      MonsterPainter(kind: m.kind, band: m.band, boss: m.boss, flash: m.flash, opacity: 1 - m.dying, t: s._t + i)
          .paint(canvas, Size(sz, sz));
      canvas.restore();
      if (m.dying == 0 && (s._phase == _Phase.battle || s._phase == _Phase.after)) {
        _hpBar(canvas, Offset(pos.dx, pos.dy - sz - 4), m.boss ? 96 : 66, m, attacking);
      } else if (m.dying == 0 && (s._phase == _Phase.walking || s._phase == _Phase.waiting)) {
        _label(canvas, Offset(pos.dx, pos.dy - sz - 2), m.name, 10, Colors.white70);
      }
    }

    // 打擊特效與火花
    for (final f in s._fx) {
      _drawFx(canvas, f);
    }
    for (final sp in s._sparks) {
      final a = (1 - sp.age / sp.life).clamp(0.0, 1.0);
      canvas.drawCircle(Offset(sp.x, sp.y), sp.size * (0.4 + 0.6 * a), Paint()..color = sp.color.withValues(alpha: a));
    }

    // 浮動數字
    for (final f in s._floats) {
      final a = (1 - f.age).clamp(0.0, 1.0);
      final pop = f.age < 0.12 ? 1 + (1 - f.age / 0.12) * 0.6 : 1.0; // 數字彈出放大再縮回
      _label(canvas, Offset(f.x, f.y - Curves.easeOut.transform(f.age.clamp(0.0, 1.0)) * 40), f.text, f.size * pop, f.color.withValues(alpha: a), bold: true, outline: true);
    }
    canvas.restore();
  }

  // 出招曲線：先往後蓄力一下（-0.18），再快速衝出（到 1 時正好命中），之後緩緩收回
  double _lungeCurve(double t) {
    if (t < 0.1) {
      return -0.18 * Curves.easeOut.transform(t / 0.1);
    }
    if (t < 0.25) {
      return -0.18 + 1.18 * Curves.easeIn.transform((t - 0.1) / 0.15);
    }
    return math.max(0, 1 - Curves.easeOut.transform((t - 0.25) / 0.35));
  }

  void _drawFx(Canvas canvas, _Fx f) {
    final p = (f.age / _Fx.dur).clamp(0.0, 1.0);
    final grow = Curves.easeOut.transform(math.min(1.0, p * 2.2));
    final alpha = (1 - Curves.easeIn.transform(p)).clamp(0.0, 1.0);
    final glow = f.crit ? const Color(0xFFFFD93D) : (f.claw ? const Color(0xFFFF5252) : const Color(0xFF8FD3FF));
    // 擴散環
    canvas.drawCircle(
        Offset(f.x, f.y),
        f.size * (0.3 + 0.9 * grow),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (f.crit ? 5 : 3) * (1 - p)
          ..color = glow.withValues(alpha: alpha * 0.8));
    if (f.crit) {
      // 暴擊：放射線
      final rp = Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFFFF3B0).withValues(alpha: alpha);
      for (var i = 0; i < 10; i++) {
        final a = i * math.pi / 5 + 0.3;
        canvas.drawLine(Offset(f.x + math.cos(a) * f.size * 0.45 * grow, f.y + math.sin(a) * f.size * 0.45 * grow),
            Offset(f.x + math.cos(a) * f.size * (0.6 + 0.5 * grow), f.y + math.sin(a) * f.size * (0.6 + 0.5 * grow)), rp);
      }
    }
    final slashes = f.claw ? 3 : (f.crit ? 2 : 1);
    for (var i = 0; i < slashes; i++) {
      final off = (i - (slashes - 1) / 2) * (f.claw ? 14.0 : 16.0);
      final dir = f.flip ? -1.0 : 1.0;
      final L = f.size * (f.crit ? 1.0 : 0.8);
      final a = Offset(f.x - L * 0.7 * dir + off, f.y - L * 0.85);
      final b = Offset(f.x + L * 0.7 * dir + off, f.y + L * 0.85);
      final ctrl = Offset(f.x + off + 14 * dir, f.y);
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
      for (final m in path.computeMetrics()) {
        // 前半段把線「劃出去」，後半段從尾巴開始收掉，形成劃過去的殘影
        final head = m.length * grow;
        final tail = m.length * Curves.easeIn.transform(math.max(0.0, (p - 0.35) / 0.65));
        if (head <= tail) continue;
        final seg = m.extractPath(tail, head);
        canvas.drawPath(
            seg,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = (f.crit ? 14 : 10)
              ..color = glow.withValues(alpha: 0.45 * alpha)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
        canvas.drawPath(
            seg,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = f.crit ? 5 : 3.5
              ..color = Colors.white.withValues(alpha: alpha));
      }
    }
  }

  void _drawHero(Canvas canvas, double gy) {
    const hh = 178.0;
    const hw = hh * 0.45;
    var x = s._heroX;
    var y = gy + 6;
    if (s._phase == _Phase.walking) {
      y -= (math.sin(s._t * 12)).abs() * 5;
    }
    if (s._phase == _Phase.battle && s._logIdx < s._log.length && s._log[s._logIdx]['a'] == 'h') {
      final tIdx = s._log[s._logIdx]['d'];
      final tx = tIdx is int && tIdx < s._mons.length ? s._monPos(tIdx, s._mons.length).dx : s._stageW * 0.6;
      x += _lungeCurve(s._actionT) * math.max(30.0, (tx - x) - 70);
    }
    final hk = Curves.easeOut.transform(s._heroKnock);
    x -= hk * 14;
    canvas.save();
    canvas.translate(x, y);
    if (hk > 0 && !s._heroDown) {
      canvas.rotate(-hk * 0.1);
    }
    if (s._heroDown) {
      canvas.rotate(math.pi / 2 * 0.9);
      canvas.translate(0, -hh * 0.2);
    }
    canvas.translate(-hw / 2, -hh);
    if (s._heroFlash > 0) {
      canvas.saveLayer(const Rect.fromLTWH(-40, -40, 200, 260), Paint());
    }
    HeroPaperDoll(s._equipped).paint(canvas, const Size(hw, hh));
    if (s._heroFlash > 0) {
      canvas.drawRect(const Rect.fromLTWH(-40, -40, 200, 260), Paint()
        ..color = Colors.white.withValues(alpha: s._heroFlash * 0.7)
        ..blendMode = BlendMode.srcATop);
      canvas.restore();
    }
    canvas.restore();
    // 影子
    canvas.drawOval(Rect.fromCenter(center: Offset(x, gy + 8), width: 56, height: 10), Paint()..color = const Color(0x44000000));
  }

  void _hpBar(Canvas canvas, Offset bottomCenter, double w, _Mon m, bool active) {
    final h = m.boss ? 10.0 : 8.0;
    final r = Rect.fromLTWH(bottomCenter.dx - w / 2, bottomCenter.dy - h - 1, w, h);
    final rr = RRect.fromRectAndRadius(r, Radius.circular(h / 2));
    final ratio = (m.shown / m.maxHp).clamp(0.0, 1.0);
    final ghostRatio = (m.ghost / m.maxHp).clamp(0.0, 1.0);
    canvas.drawRRect(rr.inflate(1.5), Paint()..color = active ? const Color(0xFFFFD93D) : Colors.black87);
    canvas.drawRRect(rr, Paint()..color = const Color(0xFF1A1A1A));
    canvas.save();
    canvas.clipRRect(rr);
    // 殘影（剛被打掉的那一段）
    canvas.drawRect(Rect.fromLTWH(r.left, r.top, w * ghostRatio, h), Paint()..color = const Color(0xFFFFE9A8));
    final base = m.boss ? const Color(0xFFFF5252) : (ratio > 0.5 ? const Color(0xFF4CD964) : ratio > 0.25 ? const Color(0xFFFFC107) : const Color(0xFFFF5252));
    final fillRect = Rect.fromLTWH(r.left, r.top, w * ratio, h);
    canvas.drawRect(
        fillRect,
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(base, Colors.white, 0.35)!, base, Color.lerp(base, Colors.black, 0.25)!])
              .createShader(r));
    // 上緣高光
    canvas.drawRect(Rect.fromLTWH(r.left, r.top + 1, w * ratio, h * 0.28), Paint()..color = Colors.white.withValues(alpha: 0.25));
    canvas.restore();
    _label(canvas, Offset(bottomCenter.dx, r.top - 2), m.boss ? '👑 ${m.name}' : m.name, m.boss ? 12 : 10, Colors.white);
    if (m.boss) {
      _label(canvas, Offset(bottomCenter.dx, r.bottom + 12), '${m.hp} / ${m.maxHp}', 9, Colors.white70);
    }
  }

  void _label(Canvas canvas, Offset bottomCenter, String text, double size, Color color, {bool bold = false, bool outline = false}) {
    void draw(Color col, {Paint? fg}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: TextStyle(color: fg == null ? col : null, foreground: fg, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(bottomCenter.dx - tp.width / 2, bottomCenter.dy - tp.height));
    }

    if (outline) {
      draw(Colors.black, fg: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = Colors.black.withValues(alpha: color.a));
    } else {
      draw(Colors.black54, fg: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.black54);
    }
    draw(color);
  }

  // ---------- 背景 ----------
  void _background(Canvas canvas, Size size, int band) {
    final w = size.width;
    final gy = s._groundY;
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, size.height),
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(_skyTop[band]), Color(_skyBottom[band])])
              .createShader(Rect.fromLTWH(0, 0, w, gy)));
    // 遠景山丘（慢速捲動）
    final far = Path()..moveTo(0, gy);
    for (var x = 0.0; x <= w + 20; x += 20) {
      final wx = x + s._scroll * 0.25;
      far.lineTo(x, gy - 40 - math.sin(wx / 53) * 18 - math.sin(wx / 23) * 8);
    }
    far.lineTo(w + 20, gy);
    far.close();
    canvas.drawPath(far, Paint()..color = Color(_farCol[band]).withValues(alpha: band == 8 ? 0.55 : 0.85));
    // 中景裝飾
    final period = 150.0;
    final off = s._scroll * 0.6 % period;
    for (var i = -1; i * period - off < w + 80; i++) {
      final x = i * period - off + 40;
      final seed = ((i + (s._scroll * 0.6 / period).floor()) * 7919) & 0xFF;
      _deco(canvas, band, x + (seed % 40), gy, 0.8 + (seed % 5) * 0.08);
    }
    // 地面
    canvas.drawRect(Rect.fromLTWH(0, gy, w, size.height - gy), Paint()..color = Color(_groundCol[band]));
    canvas.drawRect(Rect.fromLTWH(0, gy, w, 3), Paint()..color = Colors.white.withValues(alpha: 0.18));
    final dash = Paint()
      ..color = Colors.black.withValues(alpha: 0.18)
      ..strokeWidth = 2;
    final doff = s._scroll % 60;
    for (var x = -60.0 - doff; x < w + 60; x += 60) {
      canvas.drawLine(Offset(x, gy + 22), Offset(x + 30, gy + 22), dash);
      canvas.drawLine(Offset(x + 18, gy + 44), Offset(x + 52, gy + 44), dash);
    }
    // 魔界血月 / 熔岩光
    if (band == 9) {
      canvas.drawCircle(Offset(w * 0.78, 50), 28, Paint()..color = const Color(0xFFFF4D4D).withValues(alpha: 0.85));
    }
    if (band == 6) {
      canvas.drawRect(Rect.fromLTWH(0, gy - 6, w, 8), Paint()..color = const Color(0x55FF8A2E));
    }
  }

  void _deco(Canvas c, int band, double x, double gy, double k) {
    final p = Paint();
    switch (band) {
      case 0:
        p.color = const Color(0xFF2E7D32);
        for (var i = -1; i <= 1; i++) {
          c.drawPath(Path()..moveTo(x + i * 6, gy)..lineTo(x + i * 6 - 3, gy - 14 * k)..lineTo(x + i * 6 + 3, gy)..close(), p);
        }
        c.drawCircle(Offset(x + 10, gy - 6 * k), 3, Paint()..color = const Color(0xFFFF8FA3));
      case 1:
        c.drawPath(Path()..moveTo(x, gy)..lineTo(x + 10, gy - 38 * k)..lineTo(x + 22, gy)..close(), p..color = const Color(0xFF5C4B66));
      case 2:
        c.drawRRect(RRect.fromRectAndCorners(Rect.fromLTWH(x, gy - 30 * k, 20, 30 * k), topLeft: const Radius.circular(10), topRight: const Radius.circular(10)), p..color = const Color(0xFF8A8FA8));
        c.drawLine(Offset(x + 10, gy - 24 * k), Offset(x + 10, gy - 12 * k), Paint()
          ..color = Colors.black38
          ..strokeWidth = 2);
        c.drawLine(Offset(x + 5, gy - 19 * k), Offset(x + 15, gy - 19 * k), Paint()
          ..color = Colors.black38
          ..strokeWidth = 2);
      case 3:
        c.drawRect(Rect.fromLTWH(x + 8, gy - 30 * k, 8, 30 * k), p..color = const Color(0xFF5D4037));
        c.drawCircle(Offset(x + 12, gy - 40 * k), 20 * k, p..color = const Color(0xFF1F6B34));
        c.drawCircle(Offset(x + 2, gy - 32 * k), 12 * k, p..color = const Color(0xFF2E8B45));
      case 4:
        for (var i = 0; i < 3; i++) {
          c.drawLine(Offset(x + i * 6, gy), Offset(x + i * 6 + (i - 1) * 3, gy - 30 * k), Paint()
            ..color = const Color(0xFF55692A)
            ..strokeWidth = 2.4);
        }
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x + 3, gy - 38 * k, 5, 12 * k), const Radius.circular(2)), p..color = const Color(0xFF6D4C41));
      case 5:
        c.drawPath(Path()..moveTo(x, gy)..lineTo(x + 8, gy - 30 * k)..lineTo(x + 16, gy - 8)..lineTo(x + 22, gy)..close(), p..color = const Color(0xFF4DD0E1));
        c.drawPath(Path()..moveTo(x + 8, gy - 30 * k)..lineTo(x + 12, gy - 6)..lineTo(x + 4, gy - 6)..close(), p..color = Colors.white30);
      case 6:
        c.drawPath(Path()..moveTo(x, gy)..quadraticBezierTo(x + 10, gy - 34 * k, x + 28, gy)..close(), p..color = const Color(0xFF2A1410));
        c.drawCircle(Offset(x + 14, gy - 8), 4, Paint()..color = const Color(0xFFFF8A2E));
      case 7:
        c.drawPath(Path()..moveTo(x, gy)..lineTo(x + 8, gy - 42 * k)..lineTo(x + 18, gy)..close(), p..color = const Color(0xFF9AD6F2));
        c.drawPath(Path()..moveTo(x + 14, gy)..lineTo(x + 20, gy - 24 * k)..lineTo(x + 28, gy)..close(), p..color = const Color(0xFFBFE6F8));
      case 8:
        p.color = Colors.white.withValues(alpha: 0.8);
        c.drawCircle(Offset(x, gy - 50 * k), 14, p);
        c.drawCircle(Offset(x + 14, gy - 54 * k), 18, p);
        c.drawCircle(Offset(x + 30, gy - 50 * k), 13, p);
        c.drawRect(Rect.fromLTWH(x + 10, gy - 36 * k, 10, 36 * k), Paint()..color = const Color(0xFFD7C9A8));
      case 9:
        c.drawPath(Path()..moveTo(x, gy)..lineTo(x + 10, gy - 58 * k)..lineTo(x + 20, gy)..close(), p..color = const Color(0xFF1A0A12));
        c.drawRect(Rect.fromLTWH(x + 8, gy - 26 * k, 4, 6), Paint()..color = const Color(0xFFFFB300));
    }
  }

  @override
  bool shouldRepaint(covariant _StagePainter old) => true;
}
