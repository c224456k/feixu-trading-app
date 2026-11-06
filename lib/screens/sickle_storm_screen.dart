// 鐮刀風暴（試玩）畫面：全部用 Canvas 自己畫（地圖、鐮刀、人、金光暴風、粒子），
// 規則在 sickle_storm_logic.dart。單機不連伺服器；多人連線時房主的瀏覽器跑模擬，
// 伺服器（/ws/sickle）只負責開房與轉送。都沒有獎金。
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_client.dart';
import 'sickle_storm_logic.dart';

const _gold = Color(0xFFFFD54F);
const _goldDeep = Color(0xFFFF8F00);
const _bgDark = Color(0xFF0E1A10);

class SickleStormScreen extends StatefulWidget {
  final int? seed; // 測試用
  final bool autoStart; // 測試用：跳過開始畫面
  const SickleStormScreen({super.key, this.seed, this.autoStart = false});

  @visibleForTesting
  static SsGame? debugGame; // 測試截圖時用來直接改局面

  @override
  State<SickleStormScreen> createState() => _SickleStormScreenState();
}

enum _Phase { menu, lobby, room, play, over }

enum _Mode { single, host, guest }

// ---------------- 特效 ----------------
class _Particle {
  double x, y, vx, vy, life, maxLife, size, rot, vr;
  final int kind; // 0 火花 1 金粉 2 塵土 3 碎片
  final Color color;
  _Particle(this.x, this.y, this.vx, this.vy, this.life, this.size, this.color, this.kind, {this.rot = 0, this.vr = 0}) : maxLife = life;
}

class _FlyBlade {
  // 收割時從死者身上飛向擊殺者的鐮刀
  final double sx, sy;
  final int target;
  final double delay, dur, spin, arc;
  double t = 0;
  final int color;
  _FlyBlade(this.sx, this.sy, this.target, this.delay, this.dur, this.spin, this.arc, this.color);
}

class _Wave {
  final double x, y, maxR;
  final Color color;
  double t = 0;
  final double dur;
  _Wave(this.x, this.y, this.maxR, this.color, this.dur);
}

class _FloatText {
  final double x, y;
  final String text;
  final Color color;
  final double size;
  double t = 0;
  _FloatText(this.x, this.y, this.text, this.color, this.size);
}

class _Feed {
  final String text;
  final Color color;
  double t = 0;
  _Feed(this.text, this.color);
}

class _Fx {
  final parts = <_Particle>[];
  final flies = <_FlyBlade>[];
  final waves = <_Wave>[];
  final texts = <_FloatText>[];
  double shake = 0;
  void clear() {
    parts.clear();
    flies.clear();
    waves.clear();
    texts.clear();
    shake = 0;
  }
}

class _SickleStormScreenState extends State<SickleStormScreen> with SingleTickerProviderStateMixin {
  late SsGame _g;
  late final Ticker _ticker;
  final _repaint = ValueNotifier<int>(0);
  final _focus = FocusNode();
  final _fx = _Fx();
  final _rng = math.Random();
  final _feed = <_Feed>[];
  _Phase _phase = _Phase.menu;
  _Mode _mode = _Mode.single;
  Duration _last = Duration.zero;
  double _acc = 0;
  double _hudAcc = 0;
  Offset? _joyOrigin, _joyNow;
  // 鏡頭
  double _camX = 0, _camY = 0, _zoom = 1;
  String? _banner;
  Color _bannerColor = _gold;
  double _bannerT = 0;
  double _bannerDur = 2.2;
  bool _introHint = true;
  int _seedBase = 0;
  // 地圖底圖（每局畫一次存起來）
  ui.Picture? _mapPic;
  SsGame? _mapFor;
  // 連線
  _SsNet? _net;
  int _meId = 0;
  int _mySide = 0;
  String? _roomId;
  List<(int, String)> _members = []; // (座位, 名字)
  final Map<int, int> _sideFid = {}; // 房主：座位 → 角色 id
  final List<SsEvent> _pendingEv = []; // 房主：還沒傳出去的事件
  bool _fullDue = true;
  bool _gotSnap = false;
  double _inAcc = 0;
  int _snapCnt = 0;
  String? _lobbyMsg;

  SsFighter? get _meOrNull => _g.byId(_meId);
  bool get _online => _mode != _Mode.single;

  @override
  void initState() {
    super.initState();
    _seedBase = widget.seed ?? DateTime.now().millisecondsSinceEpoch;
    _g = SsGame(seed: _seedBase);
    SickleStormScreen.debugGame = _g;
    _snapCamera();
    _ticker = createTicker(_onTick)..start();
    if (widget.autoStart) _phase = _Phase.play;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    _focus.dispose();
    _net?.close();
    _mapPic?.dispose();
    super.dispose();
  }

  void _resetFx() {
    _fx.clear();
    _feed.clear();
    _banner = null;
    _introHint = true;
    _acc = 0;
  }

  void _startSingle() {
    _net?.close();
    _net = null;
    setState(() {
      _mode = _Mode.single;
      _g = SsGame(seed: ++_seedBase);
      _meId = _g.player.id;
      SickleStormScreen.debugGame = _g;
      _resetFx();
      _phase = _Phase.play;
      _snapCamera();
    });
    _focus.requestFocus();
  }

  void _snapCamera() {
    final me = _meOrNull;
    if (me == null) return;
    _camX = me.x;
    _camY = me.y;
    _zoom = _targetZoom();
  }

  double _targetZoom() {
    final me = _meOrNull;
    final r = me == null || !me.alive ? 40.0 : me.ringR;
    return 1 / math.max(1.0, r / 105); // 拉遠得慢一點，大圈才看起來真的「超巨大」
  }

  (double, double) _input() {
    var mx = 0.0, my = 0.0;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    if (keys.contains(LogicalKeyboardKey.keyA) || keys.contains(LogicalKeyboardKey.arrowLeft)) mx -= 1;
    if (keys.contains(LogicalKeyboardKey.keyD) || keys.contains(LogicalKeyboardKey.arrowRight)) mx += 1;
    if (keys.contains(LogicalKeyboardKey.keyW) || keys.contains(LogicalKeyboardKey.arrowUp)) my -= 1;
    if (keys.contains(LogicalKeyboardKey.keyS) || keys.contains(LogicalKeyboardKey.arrowDown)) my += 1;
    if (mx != 0 || my != 0) {
      final l = math.sqrt(mx * mx + my * my);
      return (mx / l, my / l);
    }
    final o = _joyOrigin, n = _joyNow;
    if (o == null || n == null) return (0, 0);
    final d = n - o;
    final l = d.distance;
    if (l < 6) return (0, 0);
    final k = math.min(1.0, l / 50) / l;
    return (d.dx * k, d.dy * k);
  }

  void _onTick(Duration now) {
    var dt = _last == Duration.zero ? 0.0 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (dt > 0.1) dt = 0.1; // 分頁切走再回來不要一次補太多
    final playing = _phase == _Phase.play;
    if (playing || (_phase == _Phase.over && _mode == _Mode.guest)) {
      final (ix, iy) = playing ? _input() : (0.0, 0.0);
      switch (_mode) {
        case _Mode.single:
          _acc += dt;
          while (_acc >= ssDt) {
            _acc -= ssDt;
            _g.step(ix, iy);
          }
        case _Mode.host:
          _g.inputs[_meId] = (ix, iy);
          _acc += dt;
          while (_acc >= ssDt && !_g.over) {
            _acc -= ssDt;
            final before = _g.events.length;
            _g.step();
            _pendingEv.addAll(_g.events.sublist(before));
            if (_g.tick % 180 == 0) _fullDue = true;
            if (++_snapCnt % 3 == 0 || _g.over) _sendSnap();
          }
        case _Mode.guest:
          if (_gotSnap) {
            _g.mirrorTick(dt, _meId, ix, iy);
            _inAcc += dt;
            final me = _meOrNull;
            if (_inAcc >= 0.05 && me != null && playing) {
              _inAcc = 0;
              _net?.relay({
                'k': 'in',
                'x': me.x.round(),
                'y': me.y.round(),
                'vx': me.vx.round(),
                'vy': me.vy.round(),
                'ix': (ix * 100).round(),
                'iy': (iy * 100).round(),
              });
            }
          }
      }
      _consumeEvents();
      if (_g.over && playing) {
        _phase = _Phase.over;
        setState(() {});
      }
    }
    _updateFx(dt);
    // 鏡頭跟著自己（死掉時看著兇手）
    final me = _meOrNull;
    if (me != null) {
      var fx = me.x, fy = me.y;
      final kid = _online ? me.killedBy : _g.killedBy;
      if (!me.alive && kid != null) {
        final k = _g.byId(kid);
        if (k != null && k.alive) {
          fx = k.x;
          fy = k.y;
        }
      }
      final ck = 1 - math.exp(-8 * dt);
      _camX += (fx - _camX) * ck;
      _camY += (fy - _camY) * ck;
    }
    _zoom += (_targetZoom() - _zoom) * (1 - math.exp(-2.5 * dt));
    _repaint.value++;
    _hudAcc += dt;
    if (_hudAcc > 0.1) {
      _hudAcc = 0;
      if (mounted) setState(() {});
    }
  }

  // ---------------- 連線 ----------------
  void _openLobby() {
    _net?.close();
    setState(() {
      _phase = _Phase.lobby;
      _lobbyMsg = null;
      _net = _SsNet(ApiClient(), onMsg: _onNet, onChanged: () {
        if (mounted) setState(() {});
      });
    });
    _net!.connect();
  }

  void _leaveRoom() {
    _net?.send({'t': 'leave'});
    setState(() {
      _phase = _Phase.lobby;
      _mode = _Mode.single;
      _roomId = null;
      _members = [];
    });
  }

  void _sendSnap() {
    final evs = List<SsEvent>.of(_pendingEv);
    _pendingEv.clear();
    if (_members.length <= 1) {
      _fullDue = true;
      return; // 沒有客人就不用傳
    }
    final m = _g.snap(fullPickups: _fullDue, evs: evs);
    _fullDue = false;
    m['sm'] = [for (final e in _sideFid.entries) [e.key, e.value]];
    _net?.relay(m);
  }

  List<(int, String)> _parseMembers(dynamic raw) {
    final l = [for (final m in (raw as List? ?? const [])) ((m as Map)['side'] as int, '${m['name']}')];
    l.sort((a, b) => a.$1.compareTo(b.$1));
    return l;
  }

  void _onNet(Map<String, dynamic> m) {
    if (!mounted) return;
    switch (m['t']) {
      case 'room':
        setState(() {
          _roomId = '${m['room']}';
          _mySide = m['side'] as int;
          _members = _parseMembers(m['members']);
          _mode = _mySide == 0 ? _Mode.host : _Mode.guest;
          _phase = _Phase.room;
          _lobbyMsg = null;
        });
      case 'err':
        setState(() => _lobbyMsg = '${m['msg'] ?? '發生錯誤'}');
      case 'members':
        setState(() => _members = _parseMembers(m['members']));
      case 'start':
        _members = _parseMembers(m['members']);
        _beginOnline(m['seed'] as int);
      case 'joined':
        if (_mode == _Mode.host && (_phase == _Phase.play)) {
          final side = m['side'] as int;
          final f = _g.addHuman('${m['name']}', side);
          _sideFid[side] = f.id;
          _fullDue = true;
          _pushFeed('${m['name']} 加入了戰局', const Color(0xFF80D8FF));
        }
      case 'left':
        final side = m['side'] as int;
        if (_mode == _Mode.host) {
          final fid = _sideFid.remove(side);
          if (fid != null && _phase == _Phase.play) {
            final f = _g.byId(fid);
            _g.dropHuman(fid);
            if (f != null) _pushFeed('${m['name'] ?? f.name} 離開了，電腦接手', Colors.white60);
          }
        }
      case 'gone':
        setState(() {
          _phase = _Phase.lobby;
          _mode = _Mode.single;
          _roomId = null;
          _members = [];
          _lobbyMsg = '${m['msg'] ?? '房間關閉了'}';
        });
      case 'r':
        final d = m['d'];
        if (d is! Map) return;
        final dm = Map<String, dynamic>.from(d);
        if (_mode == _Mode.host && dm['k'] == 'in') {
          final fid = _sideFid[m['s']];
          if (fid == null || _phase != _Phase.play) return;
          double n(String k) => ((dm[k] as num?) ?? 0).toDouble();
          _g.setRemote(fid, n('x'), n('y'), n('vx'), n('vy'), n('ix') / 100, n('iy') / 100);
        } else if (_mode == _Mode.guest && dm['k'] == 's') {
          for (final p in (dm['sm'] as List? ?? const [])) {
            final l = p as List;
            if (l[0] == _mySide) _meId = l[1] as int;
          }
          final first = !_gotSnap;
          final (ix, iy) = _g.applySnap(dm, _meId);
          _gotSnap = true;
          final me = _meOrNull;
          if (me != null) {
            me.vx += ix;
            me.vy += iy;
          }
          if (first) _snapCamera();
        }
      case 'drop':
        if (_phase == _Phase.play || _phase == _Phase.over) {
          setState(() {
            _phase = _Phase.lobby;
            _mode = _Mode.single;
            _lobbyMsg = '連線中斷了，請重新加入';
          });
        }
    }
  }

  void _beginOnline(int seed) {
    final names = [for (final m in _members) m.$2];
    setState(() {
      _g = SsGame(seed: seed, humans: names);
      SickleStormScreen.debugGame = _g;
      _sideFid.clear();
      for (var i = 0; i < _members.length; i++) {
        _sideFid[_members[i].$1] = _g.fighters[i].id;
      }
      _meId = _sideFid[_mySide] ?? -1;
      _pendingEv.clear();
      _fullDue = true;
      _gotSnap = false;
      _snapCnt = 0;
      if (_mode == _Mode.host) _g.trackPickups = true;
      _resetFx();
      _phase = _Phase.play;
      _snapCamera();
    });
    _focus.requestFocus();
  }

  // ---------------- 事件 → 特效 ----------------
  String _nameOf(SsFighter? f) {
    if (f == null) return '?';
    return f.id == _meId ? '你' : f.name;
  }

  void _consumeEvents() {
    final meId = _meId;
    for (final e in _g.events) {
      switch (e.type) {
        case SsEvType.clash:
          final mine = e.a == meId || e.b == meId;
          final n = math.min(14, 4 + e.count * 2);
          for (var i = 0; i < n; i++) {
            final a = _rng.nextDouble() * math.pi * 2;
            final s = 150 + _rng.nextDouble() * 380;
            _fx.parts.add(_Particle(e.x, e.y, math.cos(a) * s, math.sin(a) * s, 0.18 + _rng.nextDouble() * 0.25, 1.5 + _rng.nextDouble() * 2,
                i.isEven ? const Color(0xFFFFF59D) : Colors.white, 0));
          }
          for (var i = 0; i < math.min(e.count, 6); i++) {
            final a = _rng.nextDouble() * math.pi * 2;
            final s = 80 + _rng.nextDouble() * 160;
            _fx.parts.add(_Particle(e.x, e.y, math.cos(a) * s, math.sin(a) * s, 0.6, 10, const Color(0xFFB0BEC5), 3,
                rot: _rng.nextDouble() * 6, vr: (_rng.nextDouble() - 0.5) * 20));
          }
          if (mine) _fx.shake = math.max(_fx.shake, 4 + e.count * 1.5);
        case SsEvType.kill:
          final killer = _g.byId(e.a);
          final victim = _g.byId(e.b);
          final k = math.min(e.count, 40);
          for (var i = 0; i < k; i++) {
            final col = killer == null ? 0 : killer.slotColor(i % 12, 12, i ~/ 12);
            _fx.flies.add(_FlyBlade(e.x + (_rng.nextDouble() - 0.5) * 30, e.y + (_rng.nextDouble() - 0.5) * 30, e.a, i * 0.012,
                0.42 + _rng.nextDouble() * 0.2, (_rng.nextDouble() - 0.5) * 30, (_rng.nextDouble() - 0.5) * 1.6, col));
          }
          _fx.waves.add(_Wave(e.x, e.y, 120, Colors.white, 0.35));
          for (var i = 0; i < 26; i++) {
            final a = _rng.nextDouble() * math.pi * 2;
            final s = 60 + _rng.nextDouble() * 260;
            _fx.parts.add(_Particle(e.x, e.y, math.cos(a) * s, math.sin(a) * s, 0.5 + _rng.nextDouble() * 0.4, 3 + _rng.nextDouble() * 4,
                Color(victim?.color ?? 0xFFFFFFFF), 2));
          }
          if (e.a == meId) {
            _fx.shake = math.max(_fx.shake, 10);
            _fx.texts.add(_FloatText(e.x2, e.y2 - 40, '+${e.count}', _gold, 30));
            _introHint = false;
            _pushFeed('你 收割了 ${_nameOf(victim)}（+${e.count}）', _gold);
          } else if (e.b == meId) {
            _fx.shake = 16;
            _pushFeed('${_nameOf(killer)} 收割了 你', const Color(0xFFFF5252));
          } else if (e.count >= 15 || (killer?.n ?? 0) >= ssGold || (killer?.human ?? false) || (victim?.human ?? false)) {
            _pushFeed('${_nameOf(killer)} 收割了 ${_nameOf(victim)}（${e.count} 把）', Colors.white70);
          }
        case SsEvType.gold:
          final f = _g.byId(e.a);
          final lc = Color(ssBladeColors[ssLevelColors[math.min(e.count, ssLevelColors.length - 1)]]);
          if (e.a == meId && f != null) {
            _showBanner('⚡ 第 ${e.count + 1} 層・${_levelName(e.count)}刀 ⚡', lc);
            _fx.shake = 14;
            _fx.waves.add(_Wave(f.x, f.y, 420, _gold, 0.8));
            _fx.waves.add(_Wave(f.x, f.y, 260, Colors.white, 0.5));
            for (var i = 0; i < 60; i++) {
              final a = _rng.nextDouble() * math.pi * 2;
              final s = 200 + _rng.nextDouble() * 400;
              _fx.parts.add(_Particle(f.x, f.y, math.cos(a) * s, math.sin(a) * s, 0.8 + _rng.nextDouble() * 0.6, 2 + _rng.nextDouble() * 3, _gold, 1));
            }
          } else if (f != null) {
            _pushFeed('${f.name} 升到第 ${e.count + 1} 層・${_levelName(e.count)}刀！', lc);
          }
        case SsEvType.silver:
          final f = _g.byId(e.a);
          final lc = Color(ssBladeColors[ssLevelColors[math.min(e.count, ssLevelColors.length - 1)]]);
          if (e.a == meId && f != null) {
            _showBanner('第 ${e.count + 1} 層・${_levelName(e.count)}刀', lc);
            _fx.waves.add(_Wave(f.x, f.y, 220, lc, 0.6));
          }
        case SsEvType.pickup:
          if (e.a != meId) break;
          final gc = _gradeColors[e.b.clamp(0, 4)];
          for (var i = 0; i < 2 + e.b * 3; i++) {
            final a = _rng.nextDouble() * math.pi * 2;
            final sp = 40 + _rng.nextDouble() * 120;
            _fx.parts.add(_Particle(e.x, e.y, math.cos(a) * sp, math.sin(a) * sp - 40, 0.4 + _rng.nextDouble() * 0.3, 2.5, gc, 1));
          }
          if (e.b >= 1) _fx.texts.add(_FloatText(e.x, e.y - 20, '+${e.count}', gc, 16 + e.b * 3.0));
        case SsEvType.item:
          final t = SsItemType.values[e.count];
          final col = _itemColors[t]!;
          _fx.waves.add(_Wave(e.x, e.y, 90, col, 0.4));
          for (var i = 0; i < 18; i++) {
            final a = _rng.nextDouble() * math.pi * 2;
            final sp = 80 + _rng.nextDouble() * 220;
            _fx.parts.add(_Particle(e.x, e.y, math.cos(a) * sp, math.sin(a) * sp, 0.5 + _rng.nextDouble() * 0.3, 3, col, 1));
          }
          if (e.a == meId) {
            _showBanner('${_itemEmoji[t]} ${ssItemName[t]}', col, dur: 1.4); // 道具橫幅短一點
            _pushFeed('撿到 ${ssItemName[t]}：${ssItemDesc[t]}', col);
          }
        case SsEvType.over:
          break;
      }
    }
    _g.events.clear();
  }

  void _pushFeed(String t, Color c) {
    _feed.insert(0, _Feed(t, c));
    if (_feed.length > 5) _feed.removeLast();
  }

  void _showBanner(String t, Color c, {double dur = 2.2}) {
    _banner = t;
    _bannerColor = c;
    _bannerT = 0;
    _bannerDur = dur;
  }

  void _updateFx(double dt) {
    for (final p in _fx.parts) {
      p.life -= dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      final drag = p.kind == 1 ? 2.5 : 4.0;
      p.vx *= math.exp(-drag * dt);
      p.vy *= math.exp(-drag * dt);
      p.rot += p.vr * dt;
    }
    _fx.parts.removeWhere((p) => p.life <= 0);
    if (_fx.parts.length > 900) _fx.parts.removeRange(0, _fx.parts.length - 900);
    for (final f in _fx.flies) {
      f.t += dt;
    }
    _fx.flies.removeWhere((f) => f.t > f.delay + f.dur);
    for (final w in _fx.waves) {
      w.t += dt;
    }
    _fx.waves.removeWhere((w) => w.t > w.dur);
    for (final t in _fx.texts) {
      t.t += dt;
    }
    _fx.texts.removeWhere((t) => t.t > 1.2);
    for (final f in _feed) {
      f.t += dt;
    }
    _feed.removeWhere((f) => f.t > 5);
    _fx.shake *= math.exp(-9 * dt);
    if (_banner != null) {
      _bannerT += dt;
      if (_bannerT > _bannerDur) _banner = null;
    }
    if (_phase == _Phase.menu || _phase == _Phase.lobby || _phase == _Phase.room) return;
    for (final f in _g.fighters) {
      if (!f.alive) continue;
      // 跑速鞋：腳下噴風
      if (f.has(SsItemType.boots) && (f.vx * f.vx + f.vy * f.vy) > 900 && _rng.nextDouble() < 0.7) {
        _fx.parts.add(_Particle(f.x + (_rng.nextDouble() - 0.5) * 16, f.y + 10, -f.vx * 0.3 + (_rng.nextDouble() - 0.5) * 60,
            -f.vy * 0.3 + (_rng.nextDouble() - 0.5) * 60, 0.35, 4, const Color(0xFFB2EBF2), 2));
      }
      // 金圈持續噴金粉
      if (f.tier >= 2 && !(f.hidden && f.id != _meId) && _rng.nextDouble() < 0.6) {
        final a = _rng.nextDouble() * math.pi * 2;
        final r = f.ringR * (0.9 + _rng.nextDouble() * 0.4);
        final tx = -math.sin(a), ty = math.cos(a);
        _fx.parts.add(_Particle(f.x + math.cos(a) * r, f.y + math.sin(a) * r, tx * 120 + f.vx * 0.5, ty * 120 + f.vy * 0.5,
            0.5 + _rng.nextDouble() * 0.5, 1.5 + _rng.nextDouble() * 2, _rng.nextBool() ? _gold : Colors.white, 1));
      }
    }
  }

  // ---------------- 畫面 ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        title: Text(_online && _roomId != null ? '鐮刀風暴・房間 $_roomId' : '鐮刀風暴（試玩）'),
        backgroundColor: const Color(0xFF13241A),
        foregroundColor: Colors.white,
      ),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (n, e) {
          if (e.logicalKey == LogicalKeyboardKey.space && e is KeyDownEvent && _phase == _Phase.over && _mode == _Mode.single) {
            _startSingle();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: LayoutBuilder(builder: (context, c) {
          final inGame = _phase == _Phase.play || _phase == _Phase.over;
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) => _joyOrigin = _joyNow = d.localPosition,
                  onPanUpdate: (d) => _joyNow = d.localPosition,
                  onPanEnd: (_) => _joyOrigin = _joyNow = null,
                  onPanCancel: () => _joyOrigin = _joyNow = null,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _WorldPainter(this),
                      size: Size(c.maxWidth, c.maxHeight),
                    ),
                  ),
                ),
              ),
              if (inGame) ..._hud(c),
              if (_banner != null && inGame) _bannerWidget(),
              if (_phase == _Phase.play && _online) ..._onlineOverlay(),
              if (_phase == _Phase.menu) Positioned.fill(child: _menu()),
              if (_phase == _Phase.lobby) Positioned.fill(child: _lobby()),
              if (_phase == _Phase.room) Positioned.fill(child: _room()),
              if (_phase == _Phase.over) Positioned.fill(child: _online ? _overOnline() : _overPanel()),
            ],
          );
        }),
      ),
    );
  }

  List<Widget> _onlineOverlay() {
    final me = _meOrNull;
    String? msg;
    if (_mode == _Mode.guest && !_gotSnap) {
      msg = '連線中…等房主的畫面';
    } else if (me != null && !me.alive) {
      final k = me.killedBy == null ? null : _g.byId(me.killedBy!);
      final left = math.max(0.0, me.respawnAt - _g.time);
      msg = '被 ${k?.name ?? '?'} 收割了…${left.ceil()} 秒後重生';
    }
    if (msg == null) return const [];
    return [
      Positioned(
        left: 0,
        right: 0,
        top: 140,
        child: IgnorePointer(
          child: Center(
            child: _glass(Text(msg, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800))),
          ),
        ),
      ),
    ];
  }

  List<Widget> _hud(BoxConstraints c) {
    final p = _meOrNull;
    if (p == null) return const [];
    final left = math.max(0.0, ssRoundSec - _g.time);
    final mm = left ~/ 60, ss = (left % 60).floor();
    final rank = _g.ranking();
    final narrow = c.maxWidth < 520;
    return [
      Positioned(
        left: 10,
        top: 10,
        child: _glass(Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 26, height: 26, child: CustomPaint(painter: _IconSickle(p.tier))),
          const SizedBox(width: 6),
          Text('${p.n}', style: TextStyle(color: Color(ssBladeColors[p.levelColor]), fontSize: 24, fontWeight: FontWeight.w900, height: 1)),
          Text(' 第${p.level + 1}層', style: TextStyle(color: Color(ssBladeColors[p.levelColor]).withValues(alpha: 0.8), fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          const Icon(Icons.dangerous, size: 16, color: Colors.white54),
          Text(' ${p.kills}', style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w700)),
          if (p.hidden) ...[
            const SizedBox(width: 10),
            const Icon(Icons.grass, size: 16, color: Color(0xFF81C784)),
            const Text(' 躲藏中', style: TextStyle(color: Color(0xFF81C784), fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ])),
      ),
      Positioned(
        top: 10,
        left: 0,
        right: 0,
        child: Center(
          child: _glass(Text('$mm:${ss.toString().padLeft(2, '0')}',
              style: TextStyle(
                  color: left < 20 ? const Color(0xFFFF5252) : Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()]))),
        ),
      ),
      Positioned(
        right: 10,
        top: 10,
        child: _glass(
          SizedBox(
            width: narrow ? 128 : 170,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('排行', style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w700)),
              for (var i = 0; i < math.min(5, rank.length); i++) _rankRow(i + 1, rank[i]),
              if (!rank.take(5).contains(p)) ...[
                const Divider(height: 6, color: Colors.white24),
                _rankRow(_g.rankOf(p), p),
              ],
            ]),
          ),
        ),
      ),
      Positioned(
        left: 10,
        top: 56,
        child: IgnorePointer(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final f in _feed)
              Opacity(
                opacity: (1 - (f.t - 4).clamp(0.0, 1.0)),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(6)),
                  child: Text(f.text, style: TextStyle(color: f.color, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
        ),
      ),
      Positioned(
        right: 10,
        bottom: 10,
        child: IgnorePointer(
          child: Container(
            width: narrow ? 104 : 140,
            height: narrow ? 104 : 140,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.45),
              border: Border.all(color: Colors.white24),
            ),
            child: CustomPaint(painter: _MiniMap(_g, _meId)),
          ),
        ),
      ),
      if (p.buffs.isNotEmpty)
        Positioned(
          left: 10,
          bottom: 10,
          child: IgnorePointer(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final e in p.buffs.entries) _buffChip(e.key, e.value),
            ]),
          ),
        ),
      if (_introHint && _g.time < 12 && _phase == _Phase.play)
        Positioned(
          left: 0,
          right: 0,
          bottom: 28,
          child: IgnorePointer(
            child: Center(
              child: _glass(Text(
                  _online ? '刀與刀之間有空隙，看準時機讓刀尖鑽進去叉到人就能收割 ⚔️' : '前面有個也拿鐮刀的傢伙衝過來了！看準刀的空隙，用刀尖叉到他的身體就能收割 ⚔️',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600))),
            ),
          ),
        ),
    ];
  }

  Widget _buffChip(SsItemType t, double left) {
    final col = _itemColors[t]!;
    final k = (left / ssItemDur[t]!).clamp(0.0, 1.0);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(6, 5, 10, 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: col.withValues(alpha: 0.8), width: 1.5),
        boxShadow: [BoxShadow(color: col.withValues(alpha: 0.35), blurRadius: 10)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 26, height: 26, child: CustomPaint(painter: _ItemIconPainter(t, k))),
        const SizedBox(width: 6),
        Text(ssItemName[t]!, style: TextStyle(color: col, fontSize: 13, fontWeight: FontWeight.w800)),
        const SizedBox(width: 6),
        Text('${left.ceil()}s', style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Color _nameColor(SsFighter f) {
    if (f.id == _meId) return const Color(0xFF80D8FF);
    if (f.human && _online) return Color(f.color);
    return f.tier == 2 ? _gold : Colors.white;
  }

  Widget _rankRow(int i, SsFighter f) {
    final me = f.id == _meId;
    final c = _nameColor(f);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        SizedBox(width: 18, child: Text('$i', style: TextStyle(color: c.withValues(alpha: 0.7), fontSize: 12, fontWeight: FontWeight.w800))),
        if (f.human && _online && !me) Icon(Icons.person, size: 12, color: c),
        Expanded(
            child: Text(me ? '你' : f.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c, fontSize: 12.5, fontWeight: me ? FontWeight.w900 : FontWeight.w600))),
        Text('${f.n}', style: TextStyle(color: c, fontSize: 12.5, fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _glass(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: child,
      );

  Widget _bannerWidget() {
    final t = _bannerT;
    final scale = t < 0.25 ? 0.6 + Curves.easeOutBack.transform(t / 0.25) * 0.4 : 1.0;
    final op = t > _bannerDur - 0.5 ? (1 - (t - _bannerDur + 0.5) / 0.5).clamp(0.0, 1.0) : 1.0;
    return Positioned(
      left: 0,
      right: 0,
      top: 90,
      child: IgnorePointer(
        child: Center(
          child: Opacity(
            opacity: op,
            child: Transform.scale(
              scale: scale,
              child: Text(_banner!,
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                    color: _bannerColor,
                    shadows: [
                      Shadow(color: _bannerColor.withValues(alpha: 0.9), blurRadius: 24),
                      const Shadow(color: Colors.black, blurRadius: 4, offset: Offset(0, 2)),
                    ],
                  )),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title() => ShaderMask(
        shaderCallback: (r) =>
            const LinearGradient(colors: [Color(0xFFFFF8E1), _gold, _goldDeep], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(r),
        child: const Text('鐮刀風暴',
            style: TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 6, shadows: [
              Shadow(color: Color(0xAAFF8F00), blurRadius: 30),
            ])),
      );

  Widget _panel({required Widget child, double maxWidth = 440}) => Container(
        color: Colors.black.withValues(alpha: 0.55),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
        ),
      );

  Widget _menu() {
    return _panel(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _title(),
        const SizedBox(height: 4),
        const Text('試玩版・沒有獎金', style: TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 18),
        _glass(const Text(
          '你身邊繞著一圈鐮刀，刀與刀之間有空隙。\n'
          '刀碰刀：同顏色的兩把一起碎掉；高等的刀撞低等的刀，低等的那把被撞掉。\n'
          '刀圈一定有縫——刀尖鑽過縫進到對方圈裡就是「收割」：他全部的鐮刀瞬間歸你！\n'
          '刀圈每 20 把升一層換顏色（白→綠→藍→紫→橘→紅…），升層時圈上只剩一把更大的刀，再慢慢長回 20 把。\n'
          '3 分鐘後鐮刀最多的人獲勝。地上鐮刀看顏色：白 +1、綠 +2、藍 +3、紫 +5、橘 +8。\n'
          '石柱、斷牆、水池會擋路；走進草叢別人就看不到你。\n'
          '道具：👟跑速鞋、🛡️金鐘罩、🧲磁鐵、🔥狂暴藥水（用身體去碰才撿得到）',
          style: TextStyle(color: Colors.white, fontSize: 14, height: 1.6),
        )),
        const SizedBox(height: 10),
        const Text('操作：手指在畫面任一處拖曳（虛擬搖桿）／ WASD、方向鍵', style: TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 18),
        Wrap(spacing: 12, runSpacing: 10, alignment: WrapAlignment.center, children: [
          _bigButton('單人遊戲', _startSingle),
          _bigButton('多人連線', _openLobby, color: const Color(0xFF1E88E5)),
        ]),
        const SizedBox(height: 8),
        const Text('單人：被收割就結束　多人：最多 6 人同場，被收割 3 秒後重生', style: TextStyle(color: Colors.white38, fontSize: 11)),
      ]),
    );
  }

  Widget _bigButton(String t, VoidCallback? onTap, {Color color = _goldDeep, bool small = false}) => FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.white12,
          padding: small ? const EdgeInsets.symmetric(horizontal: 22, vertical: 12) : const EdgeInsets.symmetric(horizontal: 36, vertical: 16),
          textStyle: TextStyle(fontSize: small ? 15 : 19, fontWeight: FontWeight.w900, letterSpacing: small ? 1 : 3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(t),
      );

  Widget _lobby() {
    final net = _net;
    final rooms = net?.rooms ?? const [];
    return _panel(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('多人連線', textAlign: TextAlign.center, style: TextStyle(color: _gold, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 4)),
        const SizedBox(height: 4),
        const Text('開一間房找朋友，或加入別人的房間（最多 6 人，其餘位置由電腦補上）',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontSize: 12.5)),
        const SizedBox(height: 14),
        if (_lobbyMsg != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_lobbyMsg!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFFAB91), fontSize: 13)),
          ),
        if (net == null || !net.connected)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              if (net?.error == null) const CircularProgressIndicator(color: _gold),
              if (net?.error != null) Text(net!.error!, style: const TextStyle(color: Color(0xFFFF8A80))),
              if (net?.error != null) ...[
                const SizedBox(height: 10),
                _bigButton('重新連線', _openLobby, small: true, color: const Color(0xFF1E88E5)),
              ],
            ]),
          )
        else ...[
          _glass(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('等待中的房間', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (rooms.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('目前沒有房間，開一間吧！', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
              ),
            for (final r in rooms)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  const Icon(Icons.cyclone, size: 18, color: _gold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('${r['host']} 的房間',
                        overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                  Text('${r['n']}/$ssMaxHumans${r['playing'] == true ? '・對戰中' : ''}',
                      style: TextStyle(color: r['playing'] == true ? const Color(0xFFFFAB40) : Colors.white60, fontSize: 12.5)),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: (r['n'] as int? ?? 0) >= ssMaxHumans ? null : () => _net?.send({'t': 'join', 'room': r['id']}),
                    child: const Text('加入'),
                  ),
                ]),
              ),
          ])),
          const SizedBox(height: 14),
          Center(child: _bigButton('開新房間', () => _net?.send({'t': 'create'}), color: const Color(0xFF1E88E5))),
        ],
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: () {
              _net?.close();
              setState(() {
                _net = null;
                _phase = _Phase.menu;
              });
            },
            child: const Text('← 返回', style: TextStyle(color: Colors.white60)),
          ),
        ),
      ]),
    );
  }

  Widget _room() {
    final host = _mode == _Mode.host;
    return _panel(
      maxWidth: 380,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('房間 $_roomId', textAlign: TextAlign.center, style: const TextStyle(color: _gold, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 3)),
        const SizedBox(height: 12),
        _glass(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('玩家 ${_members.length}/$ssMaxHumans', style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          for (final m in _members)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Color(ssHumanColors[m.$1 % ssHumanColors.length])),
                ),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(m.$2,
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: m.$1 == _mySide ? FontWeight.w900 : FontWeight.w600))),
                if (m.$1 == 0) const Text('房主', style: TextStyle(color: _gold, fontSize: 12, fontWeight: FontWeight.w800)),
                if (m.$1 == _mySide && m.$1 != 0) const Text('你', style: TextStyle(color: Color(0xFF80D8FF), fontSize: 12, fontWeight: FontWeight.w800)),
              ]),
            ),
        ])),
        const SizedBox(height: 10),
        Text(host ? '人到齊就按開始；沒人加入也可以自己開打，空位由電腦補上。\n開打後還可以中途加入。' : '等房主按開始…',
            textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60, fontSize: 12.5, height: 1.5)),
        const SizedBox(height: 14),
        if (host) Center(child: _bigButton('開始', () => _net?.send({'t': 'start'}))),
        const SizedBox(height: 6),
        Center(child: TextButton(onPressed: _leaveRoom, child: const Text('離開房間', style: TextStyle(color: Colors.white60)))),
      ]),
    );
  }

  Widget _overPanel() {
    final p = _g.player;
    final dead = _g.overReason == 'dead';
    final killer = _g.killedBy == null ? null : _g.byId(_g.killedBy!);
    final rank = _g.playerRank();
    final title = dead ? '你被收割了' : (rank == 1 ? '🏆 收割之王' : '時間到');
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title,
              style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  color: dead ? const Color(0xFFFF5252) : _gold,
                  shadows: [Shadow(color: (dead ? Colors.red : _goldDeep).withValues(alpha: 0.8), blurRadius: 20)])),
          if (dead && killer != null) ...[
            const SizedBox(height: 4),
            Text('兇手：${killer.name}（${killer.n} 把）', style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ],
          const SizedBox(height: 16),
          _glass(Column(children: [
            _statRow('名次', '第 $rank 名'),
            _statRow('最多鐮刀', '${p.peak} 把'),
            _statRow('收割人數', '${p.kills} 人'),
            _statRow('存活時間', '${_g.time.floor()} 秒'),
          ])),
          const SizedBox(height: 18),
          Wrap(spacing: 10, runSpacing: 8, alignment: WrapAlignment.center, children: [
            _bigButton('再來一局', _startSingle),
            _bigButton('回選單', () => setState(() => _phase = _Phase.menu), color: Colors.white24, small: true),
          ]),
          const SizedBox(height: 6),
          const Text('空白鍵也可以重來', style: TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
      ),
    );
  }

  Widget _overOnline() {
    final me = _meOrNull;
    final rank = _g.ranking();
    final myRank = me == null ? 0 : _g.rankOf(me);
    final host = _mode == _Mode.host;
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(myRank == 1 ? '🏆 收割之王' : '時間到',
                style: TextStyle(
                    fontSize: 36, fontWeight: FontWeight.w900, color: _gold, shadows: [Shadow(color: _goldDeep.withValues(alpha: 0.8), blurRadius: 20)])),
            if (me != null) Text('你是第 $myRank 名・最多 ${me.peak} 把・收割 ${me.kills} 人', style: const TextStyle(color: Colors.white70, fontSize: 14)),
            const SizedBox(height: 14),
            _glass(Column(children: [
              for (var i = 0; i < math.min(8, rank.length); i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(width: 26, child: Text('${i + 1}', style: TextStyle(color: _nameColor(rank[i]), fontWeight: FontWeight.w900))),
                    if (rank[i].human) Icon(Icons.person, size: 14, color: _nameColor(rank[i])),
                    Expanded(
                      child: Text(rank[i].id == _meId ? '你' : rank[i].name,
                          overflow: TextOverflow.ellipsis, style: TextStyle(color: _nameColor(rank[i]), fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                    Text('${rank[i].n} 把', style: TextStyle(color: _nameColor(rank[i]), fontWeight: FontWeight.w800)),
                    SizedBox(
                        width: 52,
                        child: Text('⚔${rank[i].kills}', textAlign: TextAlign.right, style: const TextStyle(color: Colors.white54, fontSize: 12))),
                  ]),
                ),
            ])),
            const SizedBox(height: 16),
            if (host) _bigButton('再來一局', () => _net?.send({'t': 'start'})),
            if (!host) const Text('等房主開下一局…', style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 6),
            TextButton(onPressed: _leaveRoom, child: const Text('離開房間', style: TextStyle(color: Colors.white60))),
          ]),
        ),
      ),
    );
  }

  Widget _statRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(k, style: const TextStyle(color: Colors.white60, fontSize: 15)),
          const Spacer(),
          Text(v, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
        ]),
      );
}

/// 多人連線的 WebSocket（/ws/sickle）：大廳、開房，之後房主跟客人互傳 {t:r, d}
class _SsNet {
  final ApiClient api;
  final void Function(Map<String, dynamic>) onMsg;
  final VoidCallback onChanged;
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  bool connected = false;
  bool _closed = false;
  String? error;
  List<Map<String, dynamic>> rooms = [];
  _SsNet(this.api, {required this.onMsg, required this.onChanged});

  Future<void> connect() async {
    error = null;
    onChanged();
    try {
      final (url, key, token) = await api.sickleConnectInfo();
      final ch = WebSocketChannel.connect(Uri.parse(url));
      await ch.ready;
      if (_closed) {
        ch.sink.close();
        return;
      }
      _ch = ch;
      _sub = ch.stream.listen(_onRaw, onDone: _onDone, onError: (_) => _onDone());
      send({'t': 'auth', 'key': key, 'token': token});
      connected = true;
    } on ApiException catch (e) {
      error = e.message;
    } catch (e) {
      error = '連不上伺服器';
    }
    onChanged();
  }

  void _onDone() {
    if (_closed) return;
    connected = false;
    _ch = null;
    error = '連線中斷了';
    onMsg({'t': 'drop'});
    onChanged();
  }

  void _onRaw(dynamic raw) {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['t']) {
      case 'lobby':
        rooms = [for (final r in m['rooms'] as List) Map<String, dynamic>.from(r as Map)];
        onChanged();
      case 'err':
        error = m['msg'] as String?;
        onChanged();
    }
    onMsg(m);
  }

  void send(Map<String, dynamic> m) {
    try {
      _ch?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  void relay(Map<String, dynamic> d) => send({'t': 'r', 'd': d});

  void close() {
    _closed = true;
    _sub?.cancel();
    _ch?.sink.close();
  }
}

const _levelNames = ['白', '綠', '藍', '紫', '橘', '紅', '琥珀', '桃', '靛'];
String _levelName(int level) => _levelNames[math.min(level, _levelNames.length - 1)];

Color _tierColor(int tier) => const [Color(0xFFE0E0E0), Color(0xFFB3E5FC), _gold][tier];

// ---------------- 鐮刀形狀（單位座標：-y 朝外、+x 是旋轉前進方向） ----------------
final Path _bladePath = () {
  final p = Path();
  p.moveTo(-0.05, -0.08);
  p.cubicTo(-0.10, -0.62, 0.52, -0.86, 0.80, -0.10); // 外緣（刀背）
  p.cubicTo(0.58, -0.52, 0.12, -0.50, 0.06, -0.06); // 內緣（刀刃）
  p.close();
  return p;
}();

final Path _edgePath = () {
  final p = Path();
  p.moveTo(0.06, -0.06);
  p.cubicTo(0.12, -0.50, 0.58, -0.52, 0.80, -0.10);
  return p;
}();

final List<Paint> _bladeFill = [
  // 鐵
  Paint()
    ..shader = ui.Gradient.linear(const Offset(0, -0.8), const Offset(0.6, 0),
        [const Color(0xFFF5F5F5), const Color(0xFFB0BEC5), const Color(0xFF546E7A)], [0, 0.5, 1]),
  // 銀
  Paint()
    ..shader = ui.Gradient.linear(const Offset(0, -0.8), const Offset(0.6, 0),
        [Colors.white, const Color(0xFFB3E5FC), const Color(0xFF4FC3F7)], [0, 0.45, 1]),
  // 金
  Paint()
    ..shader = ui.Gradient.linear(const Offset(0, -0.8), const Offset(0.6, 0),
        [const Color(0xFFFFFDE7), _gold, _goldDeep], [0, 0.45, 1]),
];

void _drawSickle(Canvas c, double x, double y, double ang, double size, int tier, {double alpha = 1, bool handle = true, Paint? fill}) {
  c.save();
  c.translate(x, y);
  c.rotate(ang);
  c.scale(size);
  if (handle) _drawHandle(c, alpha);
  if (alpha >= 1) {
    c.drawPath(_bladePath, fill ?? _bladeFill[tier]);
  } else {
    c.drawPath(_bladePath, Paint()..color = _tierColor(tier).withValues(alpha: alpha));
  }
  c.drawPath(
      _edgePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.035
        ..color = Colors.white.withValues(alpha: 0.85 * alpha));
  c.restore();
}

void _drawHandle(Canvas c, double alpha) {
  final handle = Paint()
    ..color = Color.fromRGBO(121, 85, 72, alpha)
    ..strokeWidth = 0.11
    ..strokeCap = StrokeCap.round;
  c.drawLine(const Offset(0, 0.42), const Offset(0, -0.08), handle);
  c.drawLine(const Offset(0, 0.42), const Offset(0, 0.30),
      handle..color = Color.fromRGBO(62, 39, 35, alpha)); // 柄尾
}

// 地上鐮刀等級的顏色：白 / 綠 / 藍 / 紫 / 橘
const _gradeColors = [Color(0xFFECEFF1), Color(0xFF69F0AE), Color(0xFF40C4FF), Color(0xFFE040FB), Color(0xFFFFAB40)];
final List<Paint> _gradeFill = [
  for (final c in _gradeColors)
    Paint()
      ..shader = ui.Gradient.linear(const Offset(0, -0.8), const Offset(0.6, 0), [
        Colors.white,
        c,
        HSLColor.fromColor(c).withLightness((HSLColor.fromColor(c).lightness * 0.55).clamp(0, 1)).toColor(),
      ], [
        0,
        0.45,
        1
      ]),
];

const _itemColors = {
  SsItemType.boots: Color(0xFF4DD0E1),
  SsItemType.guard: Color(0xFFFFCA28),
  SsItemType.magnet: Color(0xFF7C4DFF),
  SsItemType.rage: Color(0xFFFF3D3D),
};
const _itemEmoji = {SsItemType.boots: '👟', SsItemType.guard: '🛡️', SsItemType.magnet: '🧲', SsItemType.rage: '🔥'};

/// 道具圖示，畫在原點、大小約 ±size。
void _drawItemIcon(Canvas c, SsItemType t, double size) {
  c.save();
  c.scale(size);
  switch (t) {
    case SsItemType.boots:
      // 翅膀
      final wing = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.1
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 3; i++) {
        final y = -0.55 + i * 0.22;
        c.drawLine(Offset(-0.38, y + 0.05), Offset(-0.85 + i * 0.12, y - 0.12), wing);
      }
      final boot = Path()
        ..moveTo(-0.38, -0.75)
        ..lineTo(0.12, -0.75)
        ..lineTo(0.14, 0.08)
        ..lineTo(0.62, 0.2)
        ..quadraticBezierTo(0.85, 0.3, 0.75, 0.52)
        ..lineTo(-0.42, 0.52)
        ..close();
      c.drawPath(
          boot,
          Paint()
            ..shader = ui.Gradient.linear(const Offset(0, -0.8), const Offset(0, 0.5), [const Color(0xFFE0F7FA), const Color(0xFF00ACC1)]));
      c.drawLine(const Offset(-0.44, 0.58), const Offset(0.8, 0.58),
          Paint()
            ..color = const Color(0xFF263238)
            ..strokeWidth = 0.14
            ..strokeCap = StrokeCap.round);
      c.drawLine(const Offset(-0.3, -0.62), const Offset(0.02, -0.62), Paint()..color = Colors.white..strokeWidth = 0.08);
    case SsItemType.guard:
      Path shield(double k) => Path()
        ..moveTo(0, -0.82 * k)
        ..lineTo(0.68 * k, -0.56 * k)
        ..lineTo(0.62 * k, 0.1 * k)
        ..quadraticBezierTo(0.46 * k, 0.62 * k, 0, 0.86 * k)
        ..quadraticBezierTo(-0.46 * k, 0.62 * k, -0.62 * k, 0.1 * k)
        ..lineTo(-0.68 * k, -0.56 * k)
        ..close();
      c.drawPath(shield(1), Paint()..shader = ui.Gradient.linear(const Offset(-0.6, -0.8), const Offset(0.6, 0.8), [const Color(0xFFFFF8E1), const Color(0xFFFFB300)]));
      c.drawPath(shield(0.68), Paint()..shader = ui.Gradient.linear(const Offset(0, -0.6), const Offset(0, 0.6), [const Color(0xFFD32F2F), const Color(0xFF7F0000)]));
      final star = Path();
      for (var i = 0; i < 10; i++) {
        final a = -math.pi / 2 + i * math.pi / 5;
        final r = i.isEven ? 0.34 : 0.14;
        final o = Offset(math.cos(a) * r, math.sin(a) * r + 0.02);
        i == 0 ? star.moveTo(o.dx, o.dy) : star.lineTo(o.dx, o.dy);
      }
      c.drawPath(star..close(), Paint()..color = const Color(0xFFFFE082));
    case SsItemType.magnet:
      final red = Paint()
        ..color = const Color(0xFFE53935)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.34;
      c.drawArc(const Rect.fromLTRB(-0.55, -0.3, 0.55, 0.8), 0, math.pi, false, red);
      c.drawLine(const Offset(-0.55, 0.25), const Offset(-0.55, -0.4), red);
      c.drawLine(const Offset(0.55, 0.25), const Offset(0.55, -0.4), red);
      final tip = Paint()
        ..color = const Color(0xFFECEFF1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.34;
      c.drawLine(const Offset(-0.55, -0.4), const Offset(-0.55, -0.78), tip);
      c.drawLine(const Offset(0.55, -0.4), const Offset(0.55, -0.78), tip);
      final spark = Paint()
        ..color = const Color(0xFFFFF59D)
        ..strokeWidth = 0.07
        ..strokeCap = StrokeCap.round;
      c.drawLine(const Offset(-0.15, -0.75), const Offset(0, -0.5), spark);
      c.drawLine(const Offset(0, -0.5), const Offset(0.15, -0.75), spark);
    case SsItemType.rage:
      c.drawRect(const Rect.fromLTRB(-0.17, -0.82, 0.17, -0.32), Paint()..color = const Color(0xCCE1F5FE));
      c.drawRRect(RRect.fromLTRBR(-0.22, -0.95, 0.22, -0.74, const Radius.circular(0.05)), Paint()..color = const Color(0xFF8D6E63));
      c.drawCircle(const Offset(0, 0.2), 0.6, Paint()..color = const Color(0x99E1F5FE));
      c.save();
      c.clipPath(Path()..addOval(Rect.fromCircle(center: const Offset(0, 0.2), radius: 0.56)));
      c.drawRect(const Rect.fromLTRB(-0.6, 0.0, 0.6, 0.8),
          Paint()..shader = ui.Gradient.linear(const Offset(0, 0), const Offset(0, 0.8), [const Color(0xFFFF5252), const Color(0xFFB71C1C)]));
      c.restore();
      final b = Paint()..color = Colors.white.withValues(alpha: 0.85);
      c.drawCircle(const Offset(-0.18, 0.3), 0.08, b);
      c.drawCircle(const Offset(0.12, 0.45), 0.06, b);
      c.drawCircle(const Offset(0.2, 0.15), 0.05, b);
      c.drawArc(const Rect.fromLTRB(-0.45, -0.25, 0.1, 0.4), math.pi * 1.1, 0.6, false,
          Paint()
            ..color = Colors.white70
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.07);
  }
  c.restore();
}

// 每種刀色一支漸層筆刷（刀背亮、刀刃深）
final List<Paint> _colorFill = [
  for (final v in ssBladeColors)
    Paint()
      ..shader = ui.Gradient.linear(const Offset(0, -0.8), const Offset(0.6, 0), [
        Colors.white,
        Color(v),
        HSLColor.fromColor(Color(v)).withLightness((HSLColor.fromColor(Color(v)).lightness * 0.5).clamp(0, 1)).toColor(),
      ], [
        0,
        0.42,
        1
      ]),
];

final _edgeTier = [
  Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.035
    ..color = const Color(0xD9FFFFFF),
  Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.05
    ..color = const Color(0xFFE1F5FE),
  Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.065
    ..color = _gold,
];
final _outlineTier = [
  Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.03
    ..color = const Color(0x66000000),
  Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.05
    ..color = const Color(0xCC81D4FA),
  Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.12
    ..color = const Color(0xB3FFB300),
];

/// 圈上的一把彩色鐮刀：刀身用自己的顏色，外框代表等級（鐵 / 銀 / 金）
void _drawBlade(Canvas c, double x, double y, double ang, double size, int color, int tier, {bool handle = true}) {
  c.save();
  c.translate(x, y);
  c.rotate(ang);
  c.scale(size);
  if (handle) _drawHandle(c, 1);
  c.drawPath(_bladePath, _outlineTier[tier]);
  c.drawPath(_bladePath, _colorFill[color]);
  c.drawPath(_edgePath, _edgeTier[tier]);
  c.restore();
}

// ---------------- 地圖底圖 ----------------
Path _blob(double x, double y, double r, int seed, {int pts = 10, double wobble = 0.16}) {
  final rnd = math.Random(seed);
  final ks = [for (var i = 0; i < pts; i++) 1 - wobble + rnd.nextDouble() * wobble * 2];
  final p = Path();
  Offset at(int i) {
    final a = i * math.pi * 2 / pts;
    final k = ks[i % pts];
    return Offset(x + math.cos(a) * r * k, y + math.sin(a) * r * k);
  }

  final first = Offset.lerp(at(0), at(1), 0.5)!;
  p.moveTo(first.dx, first.dy);
  for (var i = 1; i <= pts; i++) {
    final c = at(i);
    final n = Offset.lerp(at(i), at(i + 1), 0.5)!;
    p.quadraticBezierTo(c.dx, c.dy, n.dx, n.dy);
  }
  return p..close();
}

ui.Picture _buildMapPicture(SsGame g) {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  const R = ssArenaR;
  // 地面：乾淨的草地漸層 + 幾塊很淡的大色塊（不要碎花碎草）
  c.drawCircle(
      Offset.zero,
      R,
      Paint()
        ..shader = ui.Gradient.radial(Offset.zero, R, [const Color(0xFF5E9150), const Color(0xFF4F8244), const Color(0xFF3D6B36)], [0, 0.6, 1]));
  final rnd = math.Random(11);
  c.save();
  c.clipPath(Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: R)));
  for (var i = 0; i < 22; i++) {
    final a = rnd.nextDouble() * math.pi * 2, rr = math.sqrt(rnd.nextDouble()) * R;
    final o = Offset(math.cos(a) * rr, math.sin(a) * rr);
    final r = 140 + rnd.nextDouble() * 220;
    final col = i.isEven ? const Color(0xFF79AA62) : const Color(0xFF3B6A34);
    c.drawCircle(o, r, Paint()..shader = ui.Gradient.radial(o, r, [col.withValues(alpha: 0.22), col.withValues(alpha: 0)]));
  }
  // 土路：一圈環道 + 六條通往廣場的小路
  final path = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..color = const Color(0x40B39B6B);
  final pathEdge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..color = const Color(0x1FB39B6B);
  c.drawCircle(Offset.zero, 460, pathEdge..strokeWidth = 64);
  c.drawCircle(Offset.zero, 460, path..strokeWidth = 40);
  c.drawCircle(Offset.zero, 980, pathEdge..strokeWidth = 50);
  c.drawCircle(Offset.zero, 980, path..strokeWidth = 30);
  for (var i = 0; i < 6; i++) {
    final a = i * math.pi / 3;
    final p0 = Offset(math.cos(a) * 250, math.sin(a) * 250), p1 = Offset(math.cos(a) * 460, math.sin(a) * 460);
    c.drawLine(p0, p1, pathEdge..strokeWidth = 50);
    c.drawLine(p0, p1, path..strokeWidth = 30);
    final a2 = a + math.pi / 6;
    final q0 = Offset(math.cos(a2) * 460, math.sin(a2) * 460), q1 = Offset(math.cos(a2) * 980, math.sin(a2) * 980);
    c.drawLine(q0, q1, pathEdge..strokeWidth = 40);
    c.drawLine(q0, q1, path..strokeWidth = 22);
  }
  c.restore();

  // 中央廣場：石板圓環
  c.drawCircle(const Offset(6, 10), 262, Paint()..color = const Color(0x33000000));
  c.drawCircle(
      Offset.zero,
      258,
      Paint()
        ..shader = ui.Gradient.radial(const Offset(-60, -80), 360, [const Color(0xFFD7CCB4), const Color(0xFFB3A68A), const Color(0xFF928465)], [0, 0.6, 1]));
  final seam = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..color = const Color(0x40000000);
  final seamHi = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..color = const Color(0x22FFFFFF);
  const rings = [56.0, 110.0, 160.0, 210.0, 258.0];
  for (var i = 0; i < rings.length; i++) {
    c.drawCircle(Offset.zero, rings[i], seam);
    c.drawCircle(Offset.zero, rings[i] - 2, seamHi);
    if (i == 0) continue;
    final cnt = 8 + i * 6;
    for (var j = 0; j < cnt; j++) {
      final a = (j + (i.isOdd ? 0.5 : 0)) * math.pi * 2 / cnt;
      c.drawLine(Offset(math.cos(a) * rings[i - 1], math.sin(a) * rings[i - 1]), Offset(math.cos(a) * rings[i], math.sin(a) * rings[i]), seam);
    }
  }
  c.drawCircle(Offset.zero, 258, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6
    ..color = const Color(0xFF7A6C50));
  // 中心徽記：金色鐮刀
  c.drawCircle(Offset.zero, 54, Paint()..color = const Color(0xFF6D5F45));
  c.drawCircle(Offset.zero, 46, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..color = const Color(0x99FFD54F));
  _drawSickle(c, -14, 18, -0.5, 62, 2);

  // 水池
  for (final o in g.obstacles.where((o) => o.kind == 2)) {
    c.drawPath(_blob(o.x, o.y, o.r + 18, o.seed), Paint()..color = const Color(0xFFCDBB8A));
    c.drawPath(_blob(o.x, o.y, o.r + 6, o.seed + 1), Paint()..color = const Color(0xFF8D7B55));
    c.drawPath(
        _blob(o.x, o.y, o.r, o.seed + 2),
        Paint()
          ..shader = ui.Gradient.radial(Offset(o.x - o.r * 0.3, o.y - o.r * 0.3), o.r * 1.4,
              [const Color(0xFF81D4FA), const Color(0xFF29B6F6), const Color(0xFF01579B)], [0, 0.45, 1]));
    final pr = math.Random(o.seed);
    for (var i = 0; i < 4; i++) {
      final a = pr.nextDouble() * math.pi * 2, rr = o.r * (0.35 + pr.nextDouble() * 0.45);
      final p = Offset(o.x + math.cos(a) * rr, o.y + math.sin(a) * rr);
      final s = 9 + pr.nextDouble() * 7;
      c.drawArc(Rect.fromCircle(center: p, radius: s), a, math.pi * 1.75, true, Paint()..color = const Color(0xFF43A047));
      if (i.isEven) c.drawCircle(p.translate(s * 0.3, -s * 0.2), 3, Paint()..color = const Color(0xFFF8BBD0));
    }
    c.drawOval(Rect.fromCenter(center: Offset(o.x - o.r * 0.25, o.y - o.r * 0.4), width: o.r * 0.7, height: o.r * 0.16),
        Paint()..color = const Color(0x55FFFFFF));
  }
  // 斷牆：影子、牆身、頂面、磚縫
  for (final o in g.obstacles.where((o) => o.wall)) {
    final a = Offset(o.x, o.y), b = Offset(o.x2, o.y2);
    final w = o.r * 2;
    c.drawLine(a.translate(7, 10), b.translate(7, 10), Paint()
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x55000000));
    c.drawLine(a.translate(0, 5), b.translate(0, 5), Paint()
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF6B6153));
    c.drawLine(a, b, Paint()
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFA89C86));
    c.drawLine(a.translate(-1.5, -2.5), b.translate(-1.5, -2.5), Paint()
      ..strokeWidth = w * 0.45
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFC9BEA6));
    final len = (b - a).distance;
    final ux = (b.dx - a.dx) / len, uy = (b.dy - a.dy) / len;
    final brick = Paint()
      ..strokeWidth = 1.4
      ..color = const Color(0x55000000);
    for (var t = 24.0; t < len - 6; t += 24) {
      final p = Offset(a.dx + ux * t, a.dy + uy * t);
      c.drawLine(p.translate(-uy * o.r * 0.9, ux * o.r * 0.9), p.translate(uy * o.r * 0.9, -ux * o.r * 0.9), brick);
    }
    // 牆頭長一點青苔
    final mr = math.Random(o.seed);
    for (var i = 0; i < 3; i++) {
      final t = mr.nextDouble() * len;
      c.drawCircle(Offset(a.dx + ux * t, a.dy + uy * t), 4 + mr.nextDouble() * 4, Paint()..color = const Color(0xAA558B2F));
    }
  }
  // 石柱
  for (final o in g.obstacles.where((o) => o.kind == 1)) {
    final p = Offset(o.x, o.y);
    c.drawCircle(p.translate(8, 11), o.r + 3, Paint()..color = const Color(0x55000000));
    c.drawCircle(p, o.r + 5, Paint()..color = const Color(0xFF7A6E5C));
    c.drawCircle(
        p.translate(0, -3),
        o.r,
        Paint()
          ..shader = ui.Gradient.radial(p.translate(-o.r * 0.4, -o.r * 0.6), o.r * 1.6,
              [const Color(0xFFF1EADB), const Color(0xFFC2B59B), const Color(0xFF8C7E66)], [0, 0.5, 1]));
    c.drawCircle(p.translate(0, -3), o.r * 0.62, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0x33000000));
  }
  // 石塊
  for (final o in g.obstacles.where((o) => o.kind == 0)) {
    final p = Offset(o.x, o.y);
    c.drawPath(_blob(o.x + 6, o.y + 9, o.r, o.seed, pts: 7, wobble: 0.22), Paint()..color = const Color(0x55000000));
    c.drawPath(
        _blob(o.x, o.y, o.r, o.seed, pts: 7, wobble: 0.22),
        Paint()
          ..shader = ui.Gradient.radial(p.translate(-o.r * 0.4, -o.r * 0.5), o.r * 1.5,
              [const Color(0xFFCFD8DC), const Color(0xFF90A4AE), const Color(0xFF546E7A)], [0, 0.5, 1]));
    c.drawPath(_blob(o.x - o.r * 0.25, o.y - o.r * 0.3, o.r * 0.38, o.seed + 3, pts: 6), Paint()..color = const Color(0x44FFFFFF));
  }
  // 邊界：外圍深色 + 木樁
  c.drawCircle(Offset.zero, R + 40, Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 80
    ..color = const Color(0xFF16261A));
  for (var i = 0; i < 160; i++) {
    final a = i * math.pi * 2 / 160;
    final px = math.cos(a) * (R + 10), py = math.sin(a) * (R + 10);
    c.drawCircle(Offset(px + 2, py + 3), 7, Paint()..color = Colors.black38);
    c.drawCircle(Offset(px, py), 6.5, Paint()..color = const Color(0xFF5D4037));
    c.drawCircle(Offset(px - 1.5, py - 1.5), 3, Paint()..color = const Color(0xFF8D6E63));
  }
  return rec.endRecording();
}

// ---------------- 世界 ----------------
class _WorldPainter extends CustomPainter {
  final _SickleStormScreenState s;
  _WorldPainter(this.s) : super(repaint: s._repaint);

  static final _textCache = <String, TextPainter>{};
  static final _bushShape = <int, List<(Offset, double, int)>>{};

  TextPainter _label(String t, Color color, double size) {
    final key = '$t|${color.toARGB32()}|$size';
    return _textCache.putIfAbsent(key, () {
      if (_textCache.length > 400) _textCache.clear();
      return TextPainter(
        text: TextSpan(
            text: t,
            style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w800, shadows: const [
              Shadow(color: Colors.black, blurRadius: 3),
            ])),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = s._g;
    if (s._mapFor != g) {
      s._mapPic?.dispose();
      s._mapPic = _buildMapPicture(g);
      s._mapFor = g;
    }
    final me = s._meOrNull;
    final base = math.min(size.width, size.height);
    final scale = base / 470 * s._zoom;
    final shake = s._fx.shake;
    final sx = shake > 0.3 ? (s._rng.nextDouble() - 0.5) * shake : 0.0;
    final sy = shake > 0.3 ? (s._rng.nextDouble() - 0.5) * shake : 0.0;

    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF16261A));
    canvas.save();
    canvas.translate(size.width / 2 + sx, size.height / 2 + sy);
    canvas.scale(scale);
    canvas.translate(-s._camX, -s._camY);

    final hw = size.width / 2 / scale, hh = size.height / 2 / scale;
    final view = Rect.fromLTRB(s._camX - hw - 60, s._camY - hh - 60, s._camX + hw + 60, s._camY + hh + 60);
    canvas.drawPicture(s._mapPic!);
    // 邊界發光（會呼吸，不能放進底圖）
    canvas.drawCircle(
        Offset.zero,
        ssArenaR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = const Color(0xFFFF7043).withValues(alpha: 0.55 + 0.3 * math.sin(g.time * 3)));

    // 地上的鐮刀
    for (final p in g.pickups) {
      if (!view.contains(Offset(p.x, p.y))) continue;
      final bob = math.sin(g.time * 3 + p.phase);
      final gc = _gradeColors[p.grade];
      final sz = 25.0 + p.grade * 3.5;
      canvas.drawOval(Rect.fromCenter(center: Offset(p.x, p.y + sz * 0.45), width: sz * 0.9, height: sz * 0.25), Paint()..color = const Color(0x33000000));
      if (p.grade > 0) {
        canvas.drawCircle(
            Offset(p.x, p.y),
            sz * 0.85,
            Paint()
              ..shader = ui.Gradient.radial(Offset(p.x, p.y), sz * 0.85, [gc.withValues(alpha: 0.45 + 0.15 * bob), gc.withValues(alpha: 0)]));
      }
      if (p.grade >= 3) {
        // 紫、橘：旋轉的光芒
        final ray = Paint()
          ..color = gc.withValues(alpha: 0.35)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < 6; i++) {
          final a = g.time * 1.5 + p.phase + i * math.pi / 3;
          canvas.drawLine(Offset(p.x + math.cos(a) * sz * 0.5, p.y + math.sin(a) * sz * 0.5),
              Offset(p.x + math.cos(a) * sz * 1.05, p.y + math.sin(a) * sz * 1.05), ray);
        }
      }
      _drawSickle(canvas, p.x - sz * 0.2, p.y + bob * 2 + sz * 0.1, p.phase + math.sin(g.time * 1.2 + p.phase) * 0.3, sz, 0, fill: _gradeFill[p.grade]);
      if (bob > 0.85) {
        // 閃一下
        final gx = p.x + 3, gy = p.y - 6;
        final gp = Paint()
          ..color = Colors.white.withValues(alpha: (bob - 0.85) * 6)
          ..strokeWidth = 1.2;
        canvas.drawLine(Offset(gx - 4, gy), Offset(gx + 4, gy), gp);
        canvas.drawLine(Offset(gx, gy - 4), Offset(gx, gy + 4), gp);
      }
    }

    // 道具
    for (final it in g.items) {
      if (!view.contains(Offset(it.x, it.y))) continue;
      final col = _itemColors[it.type]!;
      final bob = math.sin(g.time * 2.5 + it.phase);
      final y = it.y + bob * 4;
      canvas.drawOval(Rect.fromCenter(center: Offset(it.x, it.y + 30), width: 40 - bob * 4, height: 10), Paint()..color = Colors.black26);
      canvas.drawCircle(
          Offset(it.x, y), 52, Paint()..shader = ui.Gradient.radial(Offset(it.x, y), 52, [col.withValues(alpha: 0.55), col.withValues(alpha: 0)]));
      final halo = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = col.withValues(alpha: 0.9);
      for (var i = 0; i < 6; i++) {
        final a = g.time * 1.8 + it.phase + i * math.pi / 3;
        canvas.drawArc(Rect.fromCircle(center: Offset(it.x, y), radius: 33), a, 0.6, false, halo);
      }
      canvas.drawCircle(
          Offset(it.x, y), 26, Paint()..shader = ui.Gradient.radial(Offset(it.x - 8, y - 10), 34, [Colors.white, const Color(0xFFCFD8DC)]));
      canvas.drawCircle(
          Offset(it.x, y),
          26,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = col);
      canvas.save();
      canvas.translate(it.x, y);
      _drawItemIcon(canvas, it.type, 17);
      canvas.restore();
      final tp = _label(ssItemName[it.type]!, col, 12);
      tp.paint(canvas, Offset(it.x - tp.width / 2, y + 36));
    }

    // 衝擊波
    for (final w in s._fx.waves) {
      final k = w.t / w.dur;
      final r = w.maxR * Curves.easeOutCubic.transform(k);
      canvas.drawCircle(
          Offset(w.x, w.y),
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 10 * (1 - k) + 1
            ..color = w.color.withValues(alpha: (1 - k) * 0.8));
    }

    // 人＋鐮刀圈：小的先畫，大的蓋在上面；躲在草叢裡的別人只看得到淡淡的影子
    final list = g.fighters.where((f) => f.alive).toList()..sort((a, b) => a.n.compareTo(b.n));
    for (final f in list) {
      final r = f.reach + 20;
      if (!view.inflate(r).contains(Offset(f.x, f.y))) continue;
      final ghost = f.hidden && f.id != s._meId;
      if (ghost) {
        canvas.saveLayer(Rect.fromCircle(center: Offset(f.x, f.y), radius: r + 30), Paint()..color = const Color(0x40FFFFFF));
        _drawFighter(canvas, f, g.time);
        canvas.restore();
      } else {
        _drawFighter(canvas, f, g.time);
      }
    }

    // 草叢蓋在人上面；自己躲在裡面時那叢變半透明
    for (final b in g.bushes) {
      if (!view.inflate(b.r + 20).contains(Offset(b.x, b.y))) continue;
      final mine = me != null && me.alive && me.hidden && (Offset(me.x, me.y) - Offset(b.x, b.y)).distance < b.r;
      if (mine) canvas.saveLayer(Rect.fromCircle(center: Offset(b.x, b.y), radius: b.r * 1.5), Paint()..color = const Color(0x80FFFFFF));
      _drawBush(canvas, b, g.time);
      if (mine) canvas.restore();
    }

    // 粒子
    for (final p in s._fx.parts) {
      final a = (p.life / p.maxLife).clamp(0.0, 1.0);
      switch (p.kind) {
        case 0:
          canvas.drawLine(
              Offset(p.x, p.y),
              Offset(p.x - p.vx * 0.03, p.y - p.vy * 0.03),
              Paint()
                ..color = p.color.withValues(alpha: a)
                ..strokeWidth = p.size
                ..strokeCap = StrokeCap.round);
        case 1:
          canvas.drawCircle(Offset(p.x, p.y), p.size * (0.5 + a * 0.5), Paint()..color = p.color.withValues(alpha: a));
        case 2:
          canvas.drawCircle(Offset(p.x, p.y), p.size * a, Paint()..color = p.color.withValues(alpha: a * 0.8));
        case 3:
          _drawSickle(canvas, p.x, p.y, p.rot, p.size, 0, alpha: a * 0.8);
      }
    }

    // 收割：鐮刀飛向擊殺者
    for (final f in s._fx.flies) {
      if (f.t < f.delay) continue;
      final k = ((f.t - f.delay) / f.dur).clamp(0.0, 1.0);
      final tgt = g.byId(f.target);
      if (tgt == null) continue;
      final e = Curves.easeInCubic.transform(k);
      final dx = tgt.x - f.sx, dy = tgt.y - f.sy;
      // 走一條弧線，不要直直飛
      final px = -dy * f.arc * math.sin(k * math.pi) * 0.5, py = dx * f.arc * math.sin(k * math.pi) * 0.5;
      final x = f.sx + dx * e + px, y = f.sy + dy * e + py;
      final sz = 26 * (1 - 0.4 * k);
      canvas.drawCircle(Offset(x, y), sz * 0.7, Paint()..color = Color(ssBladeColors[f.color]).withValues(alpha: 0.3 * (1 - k)));
      _drawBlade(canvas, x, y, f.spin * (f.t - f.delay), sz, f.color, tgt.tier);
    }

    // 飄字
    for (final t in s._fx.texts) {
      final k = t.t / 1.2;
      final tp = _label(t.text, t.color, t.size);
      canvas.save();
      canvas.translate(t.x, t.y - 50 * Curves.easeOut.transform(k));
      final sc = k < 0.15 ? 0.5 + k / 0.15 * 0.7 : 1.2 - (k - 0.15) * 0.25;
      canvas.scale(sc / s._zoom.clamp(0.4, 1.0));
      canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: (1 - math.max(0, k - 0.6) / 0.4).clamp(0, 1)));
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
      canvas.restore();
    }

    canvas.restore();

    // 虛擬搖桿（螢幕座標）
    final o = s._joyOrigin, n = s._joyNow;
    if (o != null && n != null && s._phase == _Phase.play) {
      canvas.drawCircle(o, 50, Paint()..color = Colors.white.withValues(alpha: 0.08));
      canvas.drawCircle(
          o,
          50,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white.withValues(alpha: 0.25));
      var d = n - o;
      if (d.distance > 50) d = d / d.distance * 50;
      canvas.drawCircle(o + d, 22, Paint()..color = Colors.white.withValues(alpha: 0.35));
    }

    // 暗角
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.radial(
              size.center(Offset.zero), size.longestSide * 0.7, [Colors.transparent, Colors.black.withValues(alpha: 0.35)], [0.6, 1]));
  }

  void _drawBush(Canvas c, SsBush b, double time) {
    final shape = _bushShape.putIfAbsent(b.seed, () {
      final r = math.Random(b.seed);
      final l = <(Offset, double, int)>[];
      for (var i = 0; i < 9; i++) {
        final a = i * math.pi * 2 / 9 + r.nextDouble() * 0.4;
        final d = b.r * (0.35 + r.nextDouble() * 0.35);
        l.add((Offset(math.cos(a) * d, math.sin(a) * d), b.r * (0.42 + r.nextDouble() * 0.18), r.nextInt(3)));
      }
      l.add((Offset.zero, b.r * 0.55, 1));
      return l;
    });
    final o = Offset(b.x, b.y);
    c.drawCircle(o.translate(8, 12), b.r * 0.95, Paint()..color = const Color(0x40000000));
    const dark = [Color(0xFF2E6B2A), Color(0xFF2A6226), Color(0xFF336F2E)];
    const mid = [Color(0xFF3F8A38), Color(0xFF468F3B), Color(0xFF3A7F34)];
    for (final (off, r, k) in shape) {
      c.drawCircle(o + off, r, Paint()..color = dark[k]);
    }
    final sway = math.sin(time * 1.3 + b.seed) * 1.5;
    for (final (off, r, k) in shape) {
      c.drawCircle(o + off.translate(-r * 0.12 + sway, -r * 0.16), r * 0.8, Paint()..color = mid[k]);
    }
    for (final (off, r, _) in shape) {
      c.drawCircle(o + off.translate(-r * 0.3 + sway, -r * 0.35), r * 0.32, Paint()..color = const Color(0x5581C784));
    }
  }

  void _drawFighter(Canvas c, SsFighter f, double time) {
    final cx = f.x, cy = f.y;
    final tier = f.tier;
    final R = f.ringR;
    final bs = f.bladeSize;
    final isMe = f.id == s._meId;

    // 影子
    c.drawOval(Rect.fromCenter(center: Offset(cx + 3, cy + ssBodyR * 0.9), width: ssBodyR * 2.2, height: ssBodyR * 0.9),
        Paint()..color = Colors.black.withValues(alpha: 0.35));

    // 金光暴風：外層光暈 + 旋轉風紋
    if (tier == 2) {
      final pulse = 0.5 + 0.5 * math.sin(time * 5 + f.id);
      c.drawCircle(
          Offset(cx, cy),
          R + bs * 1.2,
          Paint()
            ..shader = ui.Gradient.radial(Offset(cx, cy), R + bs * 1.2, [
              _gold.withValues(alpha: 0.0),
              _gold.withValues(alpha: 0.08 + 0.05 * pulse),
              _goldDeep.withValues(alpha: 0.22 + 0.08 * pulse),
              _goldDeep.withValues(alpha: 0),
            ], [
              0,
              0.55,
              0.8,
              1
            ]));
      final wind = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 5; i++) {
        final a0 = f.angle * 1.6 + i * math.pi * 2 / 5;
        final rr = R * (0.5 + 0.1 * (i % 3));
        wind
          ..strokeWidth = 2.5 + (i % 3) * 1.2
          ..color = (i.isEven ? Colors.white : _gold).withValues(alpha: 0.3);
        c.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: rr), a0, 0.8, false, wind);
      }
    } else if (tier == 1) {
      c.drawCircle(
          Offset(cx, cy),
          R + bs * 0.6,
          Paint()
            ..shader = ui.Gradient.radial(
                Offset(cx, cy), R + bs * 0.6, [const Color(0x0081D4FA), const Color(0x1C81D4FA), const Color(0x0081D4FA)], [0.5, 0.85, 1]));
    }

    // 很淡的軌道線（看得出圈的範圍，但空隙還是看得清楚）
    if (f.n > 0) {
      c.drawCircle(
          Offset(cx, cy),
          R + bs * 0.12,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = Colors.white.withValues(alpha: 0.12));
    }

    // 鐮刀：一格一把，同格疊了好幾把就畫成一疊彩色刀片
    final m = f.slots;
    if (m > 0) {
      final gap = math.pi * 2 / m;
      const layers = 1;
      final rect = Rect.fromCircle(center: Offset(cx, cy), radius: R + bs * 0.3);
      final trailLen = math.min(0.6, gap * 0.4);
      final trail = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = bs * 0.24
        ..strokeCap = StrokeCap.round;
      for (var k = 0; k < m; k++) {
        final a = f.angle + k * gap;
        final col = Color(ssBladeColors[f.slotColor(k, m)]);
        c.drawArc(rect, a - trailLen, trailLen * 0.6, false, trail..color = col.withValues(alpha: tier == 2 ? 0.35 : 0.22));
      }
      for (var k = 0; k < m; k++) {
        final a = f.angle + k * gap;
        for (var l = layers - 1; l >= 0; l--) {
          final la = a - l * 0.12;
          final sz = bs * (1 - 0.08 * l);
          final rb = R - sz * 0.15 - l * 2;
          _drawBlade(c, cx + math.cos(la) * rb, cy + math.sin(la) * rb, la + math.pi / 2, sz, f.slotColor(k, m, l), tier,
              handle: l == 0 && m <= 10);
        }
      }
    }

    // 道具效果
    if (f.has(SsItemType.magnet)) {
      final mr = (math.min(R, 70.0) + 10) * 2 + 260;
      final mp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF7C4DFF).withValues(alpha: 0.35);
      for (var i = 0; i < 16; i++) {
        final a = -time * 0.8 + i * math.pi / 8;
        c.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: mr), a, 0.22, false, mp);
      }
    }
    if (f.has(SsItemType.rage)) {
      final pulse = 0.5 + 0.5 * math.sin(time * 10);
      c.drawCircle(
          Offset(cx, cy),
          R + bs * 0.4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = bs * 0.9
            ..color = const Color(0xFFFF1744).withValues(alpha: 0.10 + 0.10 * pulse));
    }
    if (f.has(SsItemType.boots)) {
      final sp = math.sqrt(f.vx * f.vx + f.vy * f.vy);
      if (sp > 30) {
        for (var i = 1; i <= 3; i++) {
          c.drawCircle(Offset(cx - f.vx * 0.045 * i, cy - f.vy * 0.045 * i), ssBodyR * (1 - i * 0.12),
              Paint()..color = const Color(0xFF4DD0E1).withValues(alpha: 0.35 - i * 0.09));
        }
      }
    }

    // 保護罩
    if (f.shield > 0) {
      c.drawCircle(
          Offset(cx, cy),
          ssBodyR + 8,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white.withValues(alpha: 0.3 + 0.3 * math.sin(time * 12)));
    }

    // 身體：斗篷 + 兜帽 + 眼睛
    final col = Color(f.color);
    final hsl = HSLColor.fromColor(col);
    final dark = hsl.withLightness((hsl.lightness * 0.45).clamp(0, 1)).toColor();
    final light = hsl.withLightness((hsl.lightness * 1.15).clamp(0, 0.92)).toColor();
    if (isMe || (f.human && s._online)) {
      c.drawCircle(
          Offset(cx, cy + 2),
          ssBodyR + 5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = (isMe ? const Color(0xFF64B5F6) : col).withValues(alpha: 0.85));
    }
    c.drawCircle(Offset(cx, cy), ssBodyR, Paint()..shader = ui.Gradient.radial(Offset(cx - 5, cy - 6), ssBodyR * 1.6, [light, col, dark], [0, 0.5, 1]));
    // 兜帽陰影（朝臉的方向開口）
    final fx = f.faceX, fy = f.faceY;
    c.drawCircle(Offset(cx + fx * 6, cy + fy * 6), ssBodyR * 0.62, Paint()..color = const Color(0xFF1A1A1A));
    final eye = Paint()..color = f.has(SsItemType.rage) ? const Color(0xFFFF1744) : (isMe ? const Color(0xFF80D8FF) : (tier == 2 ? _gold : Colors.white));
    final px = -fy, py = fx;
    c.drawCircle(Offset(cx + fx * 9 + px * 3.4, cy + fy * 9 + py * 3.4), 2.1, eye);
    c.drawCircle(Offset(cx + fx * 9 - px * 3.4, cy + fy * 9 - py * 3.4), 2.1, eye);
    // 手（握柄）
    c.drawCircle(Offset(cx - fy * 13 + fx * 4, cy + fx * 13 + fy * 4), 4, Paint()..color = dark);
    if (f.flash > 0) {
      c.drawCircle(Offset(cx, cy), ssBodyR + 1, Paint()..color = Colors.white.withValues(alpha: (f.flash / 0.12).clamp(0, 1) * 0.8));
    }
    if (f.has(SsItemType.guard)) {
      final gp = 0.5 + 0.5 * math.sin(time * 6);
      c.drawCircle(Offset(cx, cy), ssBodyR + 15, Paint()..color = const Color(0xFFFFCA28).withValues(alpha: 0.16 + 0.08 * gp));
      c.drawCircle(
          Offset(cx, cy),
          ssBodyR + 15,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = const Color(0xFFFFE082).withValues(alpha: 0.75 + 0.25 * gp));
      c.drawArc(
          Rect.fromCircle(center: Offset(cx, cy), radius: ssBodyR + 10),
          math.pi * 1.1,
          0.8,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: 0.8));
    }
    if (tier == 2) {
      // 皇冠
      final crown = Path()
        ..moveTo(cx - 9, cy - ssBodyR - 2)
        ..lineTo(cx - 10, cy - ssBodyR - 12)
        ..lineTo(cx - 4, cy - ssBodyR - 6)
        ..lineTo(cx, cy - ssBodyR - 14)
        ..lineTo(cx + 4, cy - ssBodyR - 6)
        ..lineTo(cx + 10, cy - ssBodyR - 12)
        ..lineTo(cx + 9, cy - ssBodyR - 2)
        ..close();
      c.drawPath(crown, Paint()..color = _gold);
      c.drawPath(
          crown,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = _goldDeep);
    }

    // 名字＋鐮刀數
    final z = s._zoom.clamp(0.35, 1.0);
    final tp = _label('${isMe ? '你' : f.name}  ${f.n}', s._nameColor(f), 13);
    c.save();
    c.translate(cx, cy - f.reach - 8 / z);
    c.scale(1 / z);
    tp.paint(c, Offset(-tp.width / 2, -tp.height));
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _WorldPainter old) => true;
}

class _MiniMap extends CustomPainter {
  final SsGame g;
  final int meId;
  _MiniMap(this.g, this.meId);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final k = (r - 4) / ssArenaR;
    final c = Offset(r, r);
    canvas.drawCircle(c, r - 3, Paint()..color = const Color(0xFF3D6B36).withValues(alpha: 0.6));
    canvas.drawCircle(c, 258 * k, Paint()..color = const Color(0x66D7CCB4));
    for (final b in g.bushes) {
      canvas.drawCircle(c + Offset(b.x * k, b.y * k), b.r * k, Paint()..color = const Color(0xAA1B5E20));
    }
    final rock = Paint()..color = const Color(0xCCB0A890);
    for (final o in g.obstacles) {
      if (o.kind == 2) {
        canvas.drawCircle(c + Offset(o.x * k, o.y * k), o.r * k, Paint()..color = const Color(0xCC29B6F6));
      } else if (o.wall) {
        canvas.drawLine(c + Offset(o.x * k, o.y * k), c + Offset(o.x2 * k, o.y2 * k), rock..strokeWidth = math.max(1.5, o.r * 2 * k));
      } else {
        canvas.drawCircle(c + Offset(o.x * k, o.y * k), math.max(1.2, o.r * k), rock);
      }
    }
    for (final p in g.pickups) {
      if (p.grade < 2) continue;
      canvas.drawCircle(c + Offset(p.x * k, p.y * k), 1.3, Paint()..color = _gradeColors[p.grade]);
    }
    for (final it in g.items) {
      final o = c + Offset(it.x * k, it.y * k);
      canvas.drawRect(Rect.fromCenter(center: o, width: 4.5, height: 4.5), Paint()..color = _itemColors[it.type]!);
    }
    SsFighter? me;
    for (final f in g.fighters) {
      if (f.id == meId) me = f;
    }
    for (final f in g.fighters) {
      if (!f.alive || f.id == meId || f.hidden) continue;
      final rr = math.max(2.0, f.ringR * k * 1.4);
      final col = f.human && g.multi
          ? Color(f.color)
          : (f.tier == 2 ? _gold : (me != null && f.n > me.n ? const Color(0xFFFF5252) : Colors.white70));
      canvas.drawCircle(c + Offset(f.x * k, f.y * k), rr, Paint()..color = col);
    }
    if (me != null && me.alive) {
      final o = c + Offset(me.x * k, me.y * k);
      canvas.drawCircle(o, math.max(3.5, me.ringR * k * 1.4) + 1, Paint()..color = Colors.white);
      canvas.drawCircle(o, math.max(3.5, me.ringR * k * 1.4), Paint()..color = const Color(0xFF40C4FF));
    }
  }

  @override
  bool shouldRepaint(covariant _MiniMap old) => true;
}

class _ItemIconPainter extends CustomPainter {
  final SsItemType t;
  final double k; // 剩餘比例，外圈畫倒數
  _ItemIconPainter(this.t, this.k);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = Colors.white.withValues(alpha: 0.9));
    canvas.drawArc(
        Rect.fromCircle(center: c, radius: r - 1.5),
        -math.pi / 2,
        math.pi * 2 * k,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = _itemColors[t]!);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    _drawItemIcon(canvas, t, r * 0.62);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ItemIconPainter old) => old.t != t || (old.k - k).abs() > 0.01;
}

class _IconSickle extends CustomPainter {
  final int tier;
  _IconSickle(this.tier);
  @override
  void paint(Canvas canvas, Size size) {
    _drawSickle(canvas, size.width * 0.38, size.height * 0.62, 0.5, size.width * 0.95, tier);
  }

  @override
  bool shouldRepaint(covariant _IconSickle old) => old.tier != tier;
}
