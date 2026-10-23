import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_client.dart';
import '../widgets/monster_art.dart';
import '../widgets/volley_audio.dart';
import 'volley_sim.dart';

// 怪物打排球：仿《皮卡丘打排球》的連線雙人對戰，角色是百層塔的原創怪物。
// 連線對戰：物理在伺服器（25Hz），這裡傳按鍵、補間畫出收到的位置，自己的角色另外在本機預測（按了馬上動）。
// 電腦對戰：物理與電腦對手都在本機跑（volley_sim.dart），不連伺服器、不受網路影響。

final _money = NumberFormat('#,##0');
const _kindNames = ['史萊姆', '蝙蝠', '哥布林', '骷髏', '野狼', '獸人', '幽靈', '石像鬼', '飛龍', '惡魔'];
const _bandNames = ['草原', '洞窟', '墓地', '森林', '沼澤', '礦坑', '熔岩', '冰霜', '天空', '魔界'];
const _betChoices = [0, 10000, 50000, 100000, 500000, 1000000];

const double _cw = 432, _courtH = 304, _floor = 270, _netX = 216, _netTop = 182, _ballR = 20;

class VolleyScreen extends StatefulWidget {
  const VolleyScreen({super.key});

  @override
  State<VolleyScreen> createState() => _VolleyScreenState();
}

enum _Phase { connecting, lobby, waiting, playing, over }

class _Snap {
  final List<List<double>> p; // [x, y, state]
  final List<double> b; // [x, y, vx]
  final Duration at;
  _Snap(this.p, this.b, this.at);
}

class _Fx {
  final double x, y;
  final int kind; // 1 擊球 2 殺球 4 落地
  double age = 0;
  _Fx(this.x, this.y, this.kind);
}

class _VolleyScreenState extends State<VolleyScreen> with SingleTickerProviderStateMixin {
  final _api = ApiClient();
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  _Phase _phase = _Phase.connecting;
  String? _error;
  bool _closing = false;
  int _retry = 0;

  // 大廳
  List<Map<String, dynamic>> _rooms = [];
  List<Map<String, dynamic>> _top = [];
  double _cash = 0;
  int _myKind = 0, _myBand = 0;
  int _bet = 0, _points = 11;
  Timer? _lobbyTimer;

  // 對戰
  int _side = 0;
  int _betNow = 0, _pointsNow = 11;
  Map<String, dynamic> _me = {}, _opp = {};
  List<int> _score = [0, 0];
  List<int> _prevScore = [0, 0];
  int _server = 0;
  _Snap? _prev, _cur;
  Map<String, dynamic>? _endMsg;
  final List<_Fx> _fx = [];
  double _shake = 0;
  double _netShake = 0;
  String _banner = '';
  double _bannerT = 0;
  double _ballAng = 0;
  final List<Offset> _trail = [];

  // 輸入
  final Set<LogicalKeyboardKey> _keys = {};
  bool _tl = false, _tr = false, _tu = false, _th = false; // 觸控按鈕
  List<int> _lastSent = [0, 0, 0, 0];
  Timer? _inputTimer;

  // 電腦對戰（本機模擬）
  bool _local = false, _localOver = false;
  VolleyGame? _lg;
  VolleyBot? _lbot;
  double _acc = 0;

  // 連線對戰：自己角色的本機預測 + ping
  VolleyPlayer? _pred;
  double _predPx = 0, _predPy = 0, _predCx = 0, _predCy = 0;
  int _lastRs = -1;
  List<int> _inp = [0, 0, 0, 0];
  int _ping = -1;
  Timer? _pingTimer;

  late final Ticker _ticker;
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  Duration _lastTick = Duration.zero;
  double _clock = 0;
  Duration _now = Duration.zero;
  double _gapUs = 40000; // 快照平均到達間隔（微秒），補間時間跟著調

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    VolleyAudio.instance.enter();
    _connect();
    _inputTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_phase == _Phase.playing) _sendInput(force: true);
    });
    _lobbyTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_phase == _Phase.lobby) _send({'t': 'lobby'});
    });
    _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_local && _phase == _Phase.playing) _send({'t': 'ping', 'ts': DateTime.now().microsecondsSinceEpoch});
    });
  }

  @override
  void dispose() {
    _closing = true;
    VolleyAudio.instance.leave();
    _lobbyTimer?.cancel();
    _inputTimer?.cancel();
    _pingTimer?.cancel();
    _ticker.dispose();
    _repaint.dispose();
    _sub?.cancel();
    try {
      // 還在對戰中離開 = 認輸（伺服器收到 leave 才會結算；單純斷線有 20 秒重連時間）
      if (_phase == _Phase.waiting) _send({'t': 'cancel'});
      _ch?.sink.close();
    } catch (_) {}
    super.dispose();
  }

  // ---------------------------------------------------------------- 連線
  Future<void> _connect() async {
    try {
      final (url, key, token) = await _api.volleyConnectInfo();
      final ch = WebSocketChannel.connect(Uri.parse(url));
      await ch.ready;
      if (_closing) {
        ch.sink.close();
        return;
      }
      _ch = ch;
      _sub = ch.stream.listen(_onMsg, onDone: _onClosed, onError: (_) => _onClosed());
      _send({'t': 'auth', 'key': key, 'token': token});
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      _onClosed();
    }
  }

  void _onClosed() {
    if (_closing || !mounted) return;
    _ch = null;
    if (_phase == _Phase.over) return;
    if (_retry < 10) {
      _retry++;
      setState(() => _error = _phase == _Phase.playing ? '連線中斷，重連中…（20 秒內回來可以繼續）' : null);
      Future.delayed(const Duration(seconds: 2), () {
        if (!_closing && mounted && _ch == null) _connect();
      });
    } else {
      setState(() => _error = '連線失敗，請回上一頁再進來一次');
    }
  }

  void _send(Map<String, dynamic> m) {
    try {
      _ch?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  void _onMsg(dynamic raw) {
    if (!mounted) return;
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['t']) {
      case 'lobby':
        _retry = 0;
        setState(() {
          _error = null;
          if (_phase == _Phase.connecting || _phase == _Phase.lobby || _phase == _Phase.over) _phase = _Phase.lobby;
          _rooms = (m['rooms'] as List).cast<Map<String, dynamic>>();
          _top = (m['top'] as List).cast<Map<String, dynamic>>();
          _cash = (m['cash'] as num).toDouble();
        });
      case 'joined':
        setState(() {
          _error = null;
          _retry = 0;
          _side = m['side'] as int;
          _phase = m['status'] == 'playing' ? _Phase.playing : _Phase.waiting;
        });
      case 'start':
        VolleyAudio.instance.duck(true);
        setState(() {
          _phase = _Phase.playing;
          _side = m['side'] as int;
          _betNow = (m['bet'] as num).toInt();
          _pointsNow = m['points'] as int;
          _me = (m['me'] as Map).cast<String, dynamic>();
          _opp = (m['opp'] as Map).cast<String, dynamic>();
          _score = [0, 0];
          _prevScore = [0, 0];
          _prev = _cur = null;
          _pred = null;
          _lastRs = -1;
          _endMsg = null;
          _fx.clear();
          _trail.clear();
          _showBanner('準備！');
        });
        _sendInput(force: true);
      case 's':
        _onFrame(m);
      case 'pong':
        final ts = m['ts'];
        if (ts is int) setState(() => _ping = ((DateTime.now().microsecondsSinceEpoch - ts) / 1000).round());
      case 'end':
        VolleyAudio.instance.duck(false);
        final ew = m['winner'] as int;
        if (ew != -1) VolleyAudio.instance.play(ew == _side ? 'win' : 'lose', volume: 0.9);
        setState(() {
          _endMsg = m;
          _phase = _Phase.over;
        });
      case 'left':
        setState(() {
          _phase = _Phase.lobby;
          _error = m['msg'] as String?;
        });
        _send({'t': 'lobby'});
      case 'err':
        setState(() => _error = m['msg'] as String?);
        if (m['auth'] == true) _closing = true;
    }
  }

  void _showBanner(String s) {
    _banner = s;
    _bannerT = 1.2;
  }

  void _onFrame(Map<String, dynamic> m) {
    final p = [for (final q in m['p'] as List) [for (final v in q as List) (v as num).toDouble()]];
    final b = [for (final v in m['b'] as List) (v as num).toDouble()];
    // 新舊快照的過渡從「目前畫面上的位置」開始，封包晚到/早到時不會跳格
    final old = _cur;
    if (old != null) {
      final a = _alpha;
      final pr = _prev;
      final bp = _ballPos();
      _prev = _Snap([
        for (var i = 0; i < old.p.length; i++)
          pr == null
              ? old.p[i]
              : [pr.p[i][0] + (old.p[i][0] - pr.p[i][0]) * a, pr.p[i][1] + (old.p[i][1] - pr.p[i][1]) * a, old.p[i][2]]
      ], [bp.dx, bp.dy, old.b[2]], _now);
    }
    final gap = old == null ? 40000.0 : (_now - old.at).inMicroseconds.toDouble();
    _gapUs = _gapUs * 0.8 + gap.clamp(35000.0, 110000.0) * 0.2;
    _cur = _Snap(p, b, _now);
    if (!_local) _reconcile(m['rs'], p[_side][0], p[_side][1]);
    final sc = (m['sc'] as List).cast<int>();
    final ev = (m['ev'] as List).cast<int>();
    final scored = sc[0] != _score[0] || sc[1] != _score[1];
    final sv = m['sv'] as int;
    final hudChanged = scored || sv != _server;
    _score = sc;
    _server = sv;
    final au = VolleyAudio.instance;
    // 跳躍音：任一玩家從站立變成跳起
    final pc = _cur?.p, pp = _prev?.p;
    if (pc != null && pp != null) {
      for (var i = 0; i < 2; i++) {
        if (pp[i][2] == 0 && pc[i][2] == 1) au.play('jump', volume: i == _side ? 0.6 : 0.3);
      }
    }
    for (final e in ev) {
      switch (e) {
        case 1:
          au.play('hit');
        case 2:
          au.play('spike');
        case 3:
          au.play('bounce', volume: 0.6);
          if ((b[0] - _netX).abs() < 40) _netShake = 1;
        case 4:
          au.play('ground');
        case 5:
          au.play('whistle', volume: 0.7);
        case 6:
          au.play('dive', volume: 0.6);
      }
      if (e == 1 || e == 2) _fx.add(_Fx(b[0], b[1], e));
      if (e == 2) _shake = 0.25;
      if (e == 4) _fx.add(_Fx(b[0], _floor - 6, 4));
      if (e == 5) _showBanner('開球！');
    }
    if (scored) {
      _showBanner('${sc[0]} : ${sc[1]}');
      final mineUp = sc[_side] > (_prevScore[_side]);
      Future.delayed(const Duration(milliseconds: 250), () => au.play(mineUp ? 'point_win' : 'point_lose', volume: 0.8));
    }
    _prevScore = List<int>.from(sc);
    if (hudChanged && mounted) setState(() {});
  }

  // 自己的角色只受自己的按鍵影響（沒有碰撞），所以本機照同一套規則先跑，伺服器的位置只用來校正。
  void _reconcile(dynamic rs, double sx, double sy) {
    if (rs is! int) return; // 舊伺服器沒有 rs → 不預測
    var pr = _pred;
    if (pr == null || rs != _lastRs) {
      pr ??= _pred = VolleyPlayer(sx);
      pr.reset(_side == 0 ? 108.0 : 324.0);
      if (rs == _lastRs || _lastRs == -1) {
        pr.x = sx;
        pr.y = sy;
      }
      _predPx = _predCx = pr.x;
      _predPy = _predCy = pr.y;
      _lastRs = rs;
      return;
    }
    if ((pr.x - sx).abs() > 60 || (pr.y - sy).abs() > 80) {
      pr.x = sx;
      pr.y = sy;
      pr.vy = 0;
      _predPx = _predCx = sx;
      _predPy = _predCy = sy;
    }
  }

  /// 畫面上自己的角色位置（有預測就用預測）。
  (double, double, int)? myPredicted() {
    final pr = _pred;
    if (pr == null || _local || _phase != _Phase.playing) return null;
    final a = (_acc / volleyTick).clamp(0.0, 1.0);
    return (_predPx + (_predCx - _predPx) * a, _predPy + (_predCy - _predPy) * a, pr.state);
  }

  // ---------------------------------------------------------------- 輸入
  void _sendInput({bool force = false}) {
    final l = (_keys.contains(LogicalKeyboardKey.arrowLeft) || _keys.contains(LogicalKeyboardKey.keyA) || _tl) ? 1 : 0;
    final r = (_keys.contains(LogicalKeyboardKey.arrowRight) || _keys.contains(LogicalKeyboardKey.keyD) || _tr) ? 1 : 0;
    final u = (_keys.contains(LogicalKeyboardKey.arrowUp) || _keys.contains(LogicalKeyboardKey.keyW) || _keys.contains(LogicalKeyboardKey.space) || _tu) ? 1 : 0;
    final h = (_keys.contains(LogicalKeyboardKey.keyZ) || _keys.contains(LogicalKeyboardKey.keyK) || _keys.contains(LogicalKeyboardKey.enter) ||
            _keys.contains(LogicalKeyboardKey.arrowDown) || _keys.contains(LogicalKeyboardKey.keyS) || _th)
        ? 1
        : 0;
    final now = [l, r, u, h];
    _inp = now;
    if (_local) return;
    if (!force && now.toString() == _lastSent.toString()) return;
    _lastSent = now;
    _send({'t': 'in', 'l': l, 'r': r, 'u': u, 'h': h});
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (_phase != _Phase.playing) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _keys.add(e.logicalKey);
    } else if (e is KeyUpEvent) {
      _keys.remove(e.logicalKey);
    }
    _sendInput();
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- 動畫
  void _onTick(Duration d) {
    final dt = ((d - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastTick = d;
    _now = d;
    _clock += dt;
    if (_local) {
      if (_phase == _Phase.playing && !_localOver && _lg != null) {
        _acc += dt;
        var n = 0;
        while (_acc >= volleyTick && n < 3 && !_localOver) {
          _acc -= volleyTick;
          n++;
          _localStep();
        }
        if (n == 3 && _acc > volleyTick) _acc = 0;
      }
    } else if (_pred != null && _phase == _Phase.playing) {
      _acc += dt;
      var n = 0;
      while (_acc >= volleyTick && n < 3) {
        _acc -= volleyTick;
        n++;
        _predPx = _predCx;
        _predPy = _predCy;
        final pr = _pred!;
        pr.step(_side, _inp);
        _predCx = pr.x;
        _predCy = pr.y;
      }
      if (n == 3 && _acc > volleyTick) _acc = 0;
    }
    if (_bannerT > 0) _bannerT -= dt;
    if (_shake > 0) _shake -= dt;
    if (_netShake > 0) _netShake = math.max(0, _netShake - dt * 1.6);
    for (final f in _fx) {
      f.age += dt;
    }
    _fx.removeWhere((f) => f.age > 0.6);
    final c = _cur;
    if (c != null) {
      _ballAng += c.b[2] * 0.012 * dt * 25;
      final pos = _ballPos();
      if (_trail.isEmpty || (_trail.last - pos).distance > 3) _trail.add(pos);
      if (_trail.length > 7) _trail.removeAt(0);
    }
    _repaint.value++;
  }

  double get _alpha {
    final c = _cur;
    if (c == null) return 1;
    return ((_now - c.at).inMicroseconds / _gapUs).clamp(0.0, 1.0);
  }

  Offset _ballPos() {
    final c = _cur, p = _prev;
    if (c == null) return Offset.zero;
    if (p == null) return Offset(c.b[0], c.b[1]);
    final a = _alpha;
    return Offset(p.b[0] + (c.b[0] - p.b[0]) * a, p.b[1] + (c.b[1] - p.b[1]) * a);
  }

  // ---------------------------------------------------------------- 動作
  void _createBot(int level) {
    final rng = math.Random();
    VolleyAudio.instance.duck(true);
    setState(() {
      _local = true;
      _localOver = false;
      _error = null;
      _lg = VolleyGame(_points);
      _lbot = VolleyBot(1, level);
      _acc = 0;
      _side = 0;
      _phase = _Phase.playing;
      _betNow = 0;
      _pointsNow = _points;
      _me = {'name': '你', 'look': {'kind': _myKind, 'band': _myBand}};
      _opp = {'name': volleyBotName(level), 'look': {'kind': rng.nextInt(10), 'band': rng.nextInt(10)}};
      _score = [0, 0];
      _prevScore = [0, 0];
      _server = _lg!.server;
      _prev = _cur = null;
      _pred = null;
      _endMsg = null;
      _fx.clear();
      _trail.clear();
      _inp = [0, 0, 0, 0];
      _showBanner('準備！');
    });
  }

  void _localStep() {
    final g = _lg!, bot = _lbot!;
    final ev = g.step([_inp, bot.act(g)]);
    _onFrame(g.frame(ev));
    if (g.winner != null) {
      _localOver = true;
      final w = g.winner!;
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted || !_local) return;
        VolleyAudio.instance.duck(false);
        VolleyAudio.instance.play(w == _side ? 'win' : 'lose', volume: 0.9);
        setState(() {
          _endMsg = {'winner': w, 'reason': 'score', 'bet': 0, 'payout': 0, 'refund': 0};
          _phase = _Phase.over;
        });
      });
    }
  }
  void _create() => _send({'t': 'create', 'bet': _bet, 'points': _points, 'kind': _myKind, 'band': _myBand});
  void _join(Map room) => _send({'t': 'join', 'room': room['id'], 'kind': _myKind, 'band': _myBand});

  Future<bool> _confirmLeave() async {
    if (_phase != _Phase.playing) return true;
    if (_local) {
      VolleyAudio.instance.duck(false);
      return true;
    }
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('要認輸離開嗎？'),
              content: Text(_betNow > 0 ? '中途離開算認輸，賭金 ${_money.format(_betNow)} 會輸給對手。' : '中途離開算認輸。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('繼續打')),
                TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('認輸離開')),
              ],
            ));
    if (ok == true) _send({'t': 'leave'});
    return ok == true;
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _phase != _Phase.playing,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmLeave();
        if (leave && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0E1A2B),
        appBar: AppBar(
          title: const Text('🏐 怪物打排球'),
          backgroundColor: const Color(0xFF16263F),
          actions: [
            const VolleyAudioButton(),
            if (_phase == _Phase.lobby || _phase == _Phase.waiting)
              Padding(padding: const EdgeInsets.only(right: 14), child: Center(child: Text('💰 ${_money.format(_cash)}', style: const TextStyle(fontWeight: FontWeight.bold)))),
          ],
        ),
        body: switch (_phase) {
          _Phase.connecting => Center(child: _error != null ? Text(_error!, style: const TextStyle(color: Colors.redAccent)) : const CircularProgressIndicator()),
          _Phase.lobby => _lobby(),
          _Phase.waiting => _waiting(),
          _ => _game(),
        },
      ),
    );
  }

  Widget _monsterPicker() {
    return Card(
      color: const Color(0xFF16263F),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('我的角色：${_bandNames[_myBand]}${_kindNames[_myKind]}', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: 10,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => setState(() => _myKind = i),
                child: Container(
                  width: 64,
                  decoration: BoxDecoration(
                      color: Colors.black26, borderRadius: BorderRadius.circular(10), border: Border.all(color: i == _myKind ? Colors.amber : Colors.white12, width: 2)),
                  child: CustomPaint(painter: MonsterPainter(kind: i, band: _myBand, t: 0)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (var i = 0; i < 10; i++)
              ChoiceChip(label: Text(_bandNames[i]), selected: _myBand == i, onSelected: (_) => setState(() => _myBand = i), visualDensity: VisualDensity.compact),
          ]),
        ]),
      ),
    );
  }

  Widget _lobby() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
      _monsterPicker(),
      const SizedBox(height: 8),
      Card(
        color: const Color(0xFF16263F),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('跟電腦對戰（練習用，不賭錢、不計戰績）', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              for (final p in const [7, 11, 15]) ChoiceChip(label: Text('先得 $p 分'), selected: _points == p, onSelected: (_) => setState(() => _points = p)),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 4, children: [
              OutlinedButton.icon(onPressed: () => _createBot(0), icon: const Icon(Icons.smart_toy_outlined), label: const Text('新手')),
              OutlinedButton.icon(onPressed: () => _createBot(1), icon: const Icon(Icons.smart_toy_outlined), label: const Text('普通')),
              FilledButton.icon(onPressed: () => _createBot(2), icon: const Icon(Icons.smart_toy), label: const Text('高手')),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        color: const Color(0xFF16263F),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('建立房間', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final b in _betChoices)
                ChoiceChip(label: Text(b == 0 ? '友誼賽（不賭）' : '賭 ${_money.format(b)}'), selected: _bet == b, onSelected: (_) => setState(() => _bet = b)),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              for (final p in const [7, 11, 15]) ChoiceChip(label: Text('先得 $p 分'), selected: _points == p, onSelected: (_) => setState(() => _points = p)),
            ]),
            const SizedBox(height: 8),
            FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: Text(_bet == 0 ? '建立友誼賽房間' : '建立房間（先扣 ${_money.format(_bet)} 保管）')),
            const SizedBox(height: 6),
            const Text('贏家拿走雙方賭金扣 5% 抽水；平手、取消、伺服器重啟都原額退回。同一對玩家每天賭金淨轉移上限 200 萬，單場最高 100 萬。',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      const Text('等待中的房間', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      if (_rooms.isEmpty) const Padding(padding: EdgeInsets.all(14), child: Text('目前沒有人開房，自己開一間吧～', style: TextStyle(color: Colors.white54))),
      for (final r in _rooms)
        Card(
          color: const Color(0xFF1B3050),
          child: ListTile(
            leading: SizedBox(width: 46, height: 46, child: CustomPaint(painter: MonsterPainter(kind: (r['look']['kind'] as int), band: (r['look']['band'] as int)))),
            title: Text('${r['host']}'),
            subtitle: Text('先得 ${r['points']} 分｜${(r['bet'] as num) == 0 ? '友誼賽' : '賭金 ${_money.format(r['bet'])}'}'),
            trailing: FilledButton(onPressed: () => _join(r), child: const Text('加入')),
          ),
        ),
      const SizedBox(height: 12),
      const Text('🏆 勝場排行', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      for (var i = 0; i < _top.length; i++)
        ListTile(
          dense: true,
          leading: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
          title: Text('${_top[i]['name']}'),
          trailing: Text('${_top[i]['wins']} 勝 ${_top[i]['losses']} 敗  ${(_top[i]['net'] as num) >= 0 ? '+' : ''}${_money.format(_top[i]['net'])}'),
        ),
      const SizedBox(height: 10),
      const Text('操作：← → 移動、↑ / 空白鍵 跳、Z / ↓ 殺球（空中按著碰到球＝扣殺；在地上按＝撲救）。手機用畫面下方按鈕。',
          style: TextStyle(fontSize: 12, color: Colors.white54)),
    ]);
  }

  Widget _waiting() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        const Text('等待對手加入…', style: TextStyle(fontSize: 18)),
        const SizedBox(height: 6),
        const Text('離開這頁房間會取消並退款', style: TextStyle(color: Colors.white54)),
        const SizedBox(height: 16),
        OutlinedButton(
            onPressed: () {
              _send({'t': 'cancel'});
            },
            child: const Text('取消房間')),
      ]),
    );
  }

  Widget _hud() {
    Widget side(Map<String, dynamic> who, int s, bool right) {
      final serving = _server == s;
      return Expanded(
        child: Row(mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
          if (!right) SizedBox(width: 34, height: 34, child: CustomPaint(painter: MonsterPainter(kind: (who['look']['kind'] as int), band: (who['look']['band'] as int)))),
          Flexible(child: Text('${serving ? '🏐 ' : ''}${who['name']}${s == _side ? '（你）' : ''}', overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.bold, color: s == _side ? Colors.amber : Colors.white))),
          if (right) SizedBox(width: 34, height: 34, child: CustomPaint(painter: MonsterPainter(kind: (who['look']['kind'] as int), band: (who['look']['band'] as int)))),
        ]),
      );
    }

    final left = _side == 0 ? _me : _opp, right = _side == 0 ? _opp : _me;
    if (left.isEmpty || right.isEmpty) return const SizedBox(height: 40);
    return Container(
      color: const Color(0xFF16263F),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(children: [
        side(left, 0, false),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${_score[0]} : ${_score[1]}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFFFFE08A))),
              Text('先得 $_pointsNow 分${_betNow > 0 ? '｜賭 ${_money.format(_betNow)}' : '｜友誼賽'}', style: const TextStyle(fontSize: 10, color: Colors.white60)),
            ])),
        side(right, 1, true),
      ]),
    );
  }

  Widget _game() {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(children: [
        _hud(),
        if (_error != null) Container(width: double.infinity, color: Colors.red.shade900, padding: const EdgeInsets.all(4), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12))),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: _cw / _courtH,
              child: LayoutBuilder(
                  builder: (c, box) => Stack(fit: StackFit.expand, children: [
                        RepaintBoundary(child: CustomPaint(size: box.biggest, painter: _VolleyPainter(this, staticLayer: true))),
                        RepaintBoundary(child: CustomPaint(size: box.biggest, painter: _VolleyPainter(this))),
                        if (!_local && _ping >= 0)
                          Positioned(
                              right: 6,
                              top: 4,
                              child: Text('延遲 $_ping ms', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _ping < 80 ? Colors.greenAccent : (_ping < 160 ? Colors.amberAccent : Colors.redAccent)))),
                      ])),
            ),
          ),
        ),
        if (_phase == _Phase.playing) _touchPad() else _resultBar(),
      ]),
    );
  }

  Widget _padBtn(String label, void Function(bool) set, {double w = 64, Color? color}) {
    return Listener(
      onPointerDown: (_) {
        set(true);
        _sendInput();
      },
      onPointerUp: (_) {
        set(false);
        _sendInput();
      },
      onPointerCancel: (_) {
        set(false);
        _sendInput();
      },
      child: Container(
        width: w,
        height: 56,
        margin: const EdgeInsets.all(4),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color ?? Colors.white12, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white24)),
        child: Text(label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _touchPad() {
    return Container(
      color: const Color(0xFF101C30),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [_padBtn('◀', (v) => _tl = v), _padBtn('▶', (v) => _tr = v)]),
        Row(children: [_padBtn('跳', (v) => _tu = v), _padBtn('殺球', (v) => _th = v, w: 84, color: const Color(0x55FF7043))]),
      ]),
    );
  }

  Widget _resultBar() {
    final e = _endMsg;
    if (e == null) return const SizedBox.shrink();
    final w = e['winner'] as int;
    final reason = e['reason'];
    String title, sub;
    if (w == -1) {
      title = reason == 'error' ? '對局發生錯誤' : '平手';
      sub = (e['refund'] as num) > 0 ? '賭金 ${_money.format(e['refund'])} 已原額退回' : '';
    } else if (w == _side) {
      title = '🎉 你贏了！';
      sub = (e['bet'] as num) > 0 ? '拿走 ${_money.format(e['payout'])}（淨賺 ${_money.format((e['payout'] as num) - (e['bet'] as num))}）' : '友誼賽';
      if (reason == 'forfeit') sub += '｜對手認輸/斷線';
    } else {
      title = '😢 你輸了';
      sub = (e['bet'] as num) > 0 ? '輸掉 ${_money.format(e['bet'])}' : '友誼賽';
    }
    return Container(
      width: double.infinity,
      color: const Color(0xFF16263F),
      padding: const EdgeInsets.all(12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFFFFE08A))),
        if (sub.isNotEmpty) Text(sub),
        const SizedBox(height: 8),
        FilledButton(
            onPressed: () {
              setState(() {
                _phase = _Phase.lobby;
                _endMsg = null;
                _local = false;
                _lg = null;
                _lbot = null;
              });
              _send({'t': 'lobby'});
            },
            child: const Text('回大廳')),
      ]),
    );
  }
}

// ==================================================================== 繪圖
class _VolleyPainter extends CustomPainter {
  final _VolleyScreenState s;
  final bool staticLayer; // true：只畫不會動的背景（外面包 RepaintBoundary，只畫一次）
  _VolleyPainter(this.s, {this.staticLayer = false}) : super(repaint: staticLayer ? null : s._repaint);

  double _h(int i, int k) {
    var h = (i * 73856093) ^ (k * 19349663);
    h = (h ^ (h >> 13)) * 1274126177;
    return ((h ^ (h >> 16)) & 0xFFFF) / 0xFFFF;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / _cw;
    if (staticLayer) {
      canvas.scale(k);
      _backgroundStatic(canvas);
      _courtStatic(canvas);
      return;
    }
    canvas.save();
    if (s._shake > 0) {
      canvas.translate((math.sin(s._clock * 90) * 3) * s._shake * 4 * k, (math.cos(s._clock * 70) * 2) * s._shake * 4 * k);
    }
    canvas.scale(k);
    _backgroundDynamic(canvas);
    _net(canvas);
    final c = s._cur;
    if (c != null) {
      _players(canvas);
      _ball(canvas);
      _effects(canvas);
    }
    canvas.restore();
    // 橫幅
    if (s._bannerT > 0 && s._banner.isNotEmpty) {
      final a = (s._bannerT / 0.4).clamp(0.0, 1.0);
      _text(canvas, s._banner, Offset(size.width / 2, size.height * 0.3), 30 * k, const Color(0xFFFFE08A).withValues(alpha: a));
    }
  }

  void _text(Canvas canvas, String text, Offset center, double size, Color color) {
    TextPainter mk(Paint? fg, Color? col) => TextPainter(
        text: TextSpan(text: text, style: TextStyle(fontSize: size, fontWeight: FontWeight.w900, color: col, foreground: fg)), textDirection: TextDirection.ltr)
      ..layout();
    final o = mk(Paint()..style = PaintingStyle.stroke..strokeWidth = size * 0.16..color = Colors.black.withValues(alpha: color.a), null);
    o.paint(canvas, Offset(center.dx - o.width / 2, center.dy - o.height / 2));
    final t = mk(null, color);
    t.paint(canvas, Offset(center.dx - t.width / 2, center.dy - t.height / 2));
  }

  Paint _fill(Color c) => Paint()..color = c;

  void _backgroundStatic(Canvas canvas) {
    // 天空
    final sky = const Rect.fromLTWH(0, 0, _cw, 190);
    canvas.drawRect(sky, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF2F95E8), Color(0xFF7CCBFF), Color(0xFFFFF3D0)]).createShader(sky));
    canvas.drawCircle(const Offset(352, 62), 60, Paint()..shader = const RadialGradient(colors: [Color(0xAAFFF59D), Color(0x00FFF59D)]).createShader(Rect.fromCircle(center: const Offset(352, 62), radius: 60)));
    canvas.drawCircle(const Offset(352, 62), 18, _fill(const Color(0xFFFFEB3B)));
    canvas.drawCircle(const Offset(352, 62), 14, _fill(const Color(0xFFFFF59D)));
    // 海（地平線 150 ~ 205）
    final sea = const Rect.fromLTWH(0, 148, _cw, 62);
    canvas.drawRect(sea, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1E88B8), Color(0xFF2FB5C9), Color(0xFF7BE0D8)]).createShader(sea));
    // 遠方小島
    final isl = Path()..moveTo(250, 150)..quadraticBezierTo(272, 128, 296, 150)..close();
    canvas.drawPath(isl, _fill(const Color(0xFF3F8F6B)));
    canvas.drawPath(Path()..moveTo(262, 150)..quadraticBezierTo(272, 136, 282, 150)..close(), _fill(const Color(0xFF2F7A57)));
    // 後方沙灘（較淺）
    final back = const Rect.fromLTWH(0, 205, _cw, 65);
    canvas.drawRect(back, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFFFF0C4), Color(0xFFF2D89C)]).createShader(back));
    canvas.drawPath(Path()..moveTo(0, 205)..quadraticBezierTo(60, 200, 130, 206)..quadraticBezierTo(250, 212, 330, 204)..quadraticBezierTo(390, 200, _cw, 205)..lineTo(_cw, 210)..lineTo(0, 210)..close(), _fill(Colors.white.withValues(alpha: 0.6)));
    // 遮陽傘、救生椅
    _parasol(canvas, 62, 232, const Color(0xFFE53935));
    _parasol(canvas, 372, 236, const Color(0xFF1E88E5));
    _lifeguard(canvas, 300, 232);
  }

  void _backgroundDynamic(Canvas canvas) {
    final clock = s._clock;
    // 雲
    for (var i = 0; i < 5; i++) {
      final x = ((_h(i, 1) * _cw + clock * (3 + i * 1.6)) % (_cw + 140)) - 70;
      final y = 18 + _h(i, 2) * 80;
      final sc = 0.7 + _h(i, 3) * 0.7;
      final cp = _fill(Colors.white.withValues(alpha: 0.92));
      final sh = _fill(const Color(0x1A4A7BB0));
      canvas.drawOval(Rect.fromCenter(center: Offset(x, y + 5 * sc), width: 70 * sc, height: 14 * sc), sh);
      canvas.drawOval(Rect.fromCenter(center: Offset(x, y), width: 66 * sc, height: 20 * sc), cp);
      canvas.drawOval(Rect.fromCenter(center: Offset(x - 15 * sc, y - 7 * sc), width: 36 * sc, height: 24 * sc), cp);
      canvas.drawOval(Rect.fromCenter(center: Offset(x + 12 * sc, y - 10 * sc), width: 32 * sc, height: 24 * sc), cp);
    }
    // 海鷗
    for (var i = 0; i < 3; i++) {
      final x = ((i * 150 + clock * (14 + i * 4)) % (_cw + 60)) - 30;
      final y = 60 + i * 22 + math.sin(clock * 1.5 + i) * 6;
      final flap = math.sin(clock * 7 + i * 2) * 4;
      canvas.drawPath(Path()..moveTo(x - 7, y + flap)..quadraticBezierTo(x - 3, y - 3, x, y)..quadraticBezierTo(x + 3, y - 3, x + 7, y + flap), Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = const Color(0xFF37474F)..strokeCap = StrokeCap.round);
    }
    // 太陽的反光
    for (var i = 0; i < 9; i++) {
      final y = 152 + i * 6.0;
      final w = 18 + i * 3.5 + math.sin(clock * 3 + i) * 3;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(352 + math.sin(clock * 2 + i * 1.7) * 4, y), width: w, height: 1.8), const Radius.circular(1)), _fill(Colors.white.withValues(alpha: 0.5 - i * 0.04)));
    }
    // 浪紋
    for (var i = 0; i < 26; i++) {
      final x = (_h(i, 7) * _cw + clock * (3 + _h(i, 8) * 5)) % _cw;
      final y = 156 + _h(i, 9) * 50;
      canvas.drawLine(Offset(x, y), Offset(x + 6 + _h(i, 10) * 8, y), Paint()..color = Colors.white.withValues(alpha: 0.25 + 0.2 * math.sin(clock * 2 + i))..strokeWidth = 1.2..strokeCap = StrokeCap.round);
    }
    // 帆船
    final bx = 90 + math.sin(clock * 0.15) * 20;
    canvas.drawPath(Path()..moveTo(bx - 14, 162)..lineTo(bx + 14, 162)..lineTo(bx + 9, 168)..lineTo(bx - 9, 168)..close(), _fill(const Color(0xFF6D4C41)));
    canvas.drawPath(Path()..moveTo(bx, 160)..lineTo(bx, 140)..lineTo(bx + 12, 158)..close(), _fill(Colors.white));
    canvas.drawPath(Path()..moveTo(bx - 1, 160)..lineTo(bx - 1, 144)..lineTo(bx - 10, 158)..close(), _fill(const Color(0xFFFFCDD2)));
    // 觀眾
    for (var i = 0; i < 16; i++) {
      final x = 118 + i * 14.0 + (_h(i, 21) - 0.5) * 6;
      if ((x > 190 && x < 250) || (x > 285 && x < 318)) continue;
      final bob = math.max(0.0, math.sin(clock * (4 + _h(i, 22) * 3) + i * 1.3)) * (s._cur != null ? 3 : 1);
      const skin = [Color(0xFFFFCCBC), Color(0xFFD7A57C), Color(0xFFF1B98F)];
      final cols = [const Color(0xFFEF5350), const Color(0xFF42A5F5), const Color(0xFFFFCA28), const Color(0xFF66BB6A), const Color(0xFFAB47BC)];
      final y = 246 + (_h(i, 23) - 0.5) * 6 - bob;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y + 6), width: 8, height: 11), const Radius.circular(3)), _fill(cols[i % 5]));
      canvas.drawCircle(Offset(x, y - 1), 4, _fill(skin[i % 3]));
      if (i % 4 == 0) canvas.drawCircle(Offset(x + 2, y - 7), 2.2, _fill(const Color(0xFFFFCA28)));
    }
    // 棕櫚樹
    _palm(canvas, 22, 245, 78, 1, clock);
    _palm(canvas, 410, 248, 70, -1, clock + 1.3);
  }

  void _parasol(Canvas canvas, double x, double y, Color c) {
    canvas.drawLine(Offset(x, y - 26), Offset(x + 1, y + 6), Paint()..color = const Color(0xFF8D6E63)..strokeWidth = 2);
    final p = Path()..moveTo(x - 24, y - 24)..quadraticBezierTo(x, y - 52, x + 24, y - 24)..close();
    canvas.drawPath(p, _fill(c));
    canvas.save();
    canvas.clipPath(p);
    for (var i = -2; i <= 2; i++) {
      canvas.drawLine(Offset(x + i * 9, y - 52), Offset(x + i * 5, y - 24), Paint()..color = Colors.white.withValues(alpha: 0.55)..strokeWidth = 5);
    }
    canvas.restore();
    canvas.drawOval(Rect.fromCenter(center: Offset(x + 6, y + 7), width: 36, height: 6), _fill(const Color(0x22000000)));
  }

  void _lifeguard(Canvas canvas, double x, double y) {
    canvas.drawRect(Rect.fromLTWH(x - 10, y - 14, 3, 18), _fill(const Color(0xFF8D6E63)));
    canvas.drawRect(Rect.fromLTWH(x + 7, y - 14, 3, 18), _fill(const Color(0xFF8D6E63)));
    canvas.drawRect(Rect.fromLTWH(x - 13, y - 18, 26, 5), _fill(const Color(0xFFFFFFFF)));
    canvas.drawRect(Rect.fromLTWH(x - 13, y - 18, 26, 2), _fill(const Color(0xFFEF5350)));
    canvas.drawRect(Rect.fromLTWH(x - 9, y - 32, 18, 14), _fill(const Color(0xFFFFF8E1)));
    canvas.drawPath(Path()..moveTo(x - 12, y - 32)..lineTo(x, y - 41)..lineTo(x + 12, y - 32)..close(), _fill(const Color(0xFFEF5350)));
    canvas.drawRect(Rect.fromLTWH(x - 5, y - 29, 10, 6), _fill(const Color(0xFF81D4FA)));
  }

  void _palm(Canvas canvas, double x, double y, double h, double dir, double clock) {
    final sway = math.sin(clock * 1.2) * 3;
    final top = Offset(x + dir * 14 + sway * 0.5, y - h);
    final trunk = Path()..moveTo(x - 4, y)..quadraticBezierTo(x + dir * 2, y - h * 0.5, top.dx - 2, top.dy)..lineTo(top.dx + 2, top.dy)..quadraticBezierTo(x + dir * 6, y - h * 0.5, x + 4, y)..close();
    canvas.drawPath(trunk, _fill(const Color(0xFF8D6E63)));
    for (var i = 1; i < 7; i++) {
      final f = i / 7;
      final px = x + dir * 8 * f * f + sway * 0.5 * f, py = y - h * f;
      canvas.drawLine(Offset(px - 4, py), Offset(px + 4, py - 1.5), Paint()..color = const Color(0x44000000)..strokeWidth = 1);
    }
    canvas.drawOval(Rect.fromCenter(center: Offset(x + 6, y + 2), width: 40, height: 7), _fill(const Color(0x22000000)));
    for (var i = 0; i < 7; i++) {
      final a = -math.pi * 0.95 + i * (math.pi * 0.9 / 6) + sway * 0.01;
      final len = 36.0 + (i == 3 ? 6 : 0);
      final tip = top + Offset(math.cos(a) * len, math.sin(a) * len * 0.6 + len * 0.28);
      final mid = top + Offset(math.cos(a) * len * 0.55, math.sin(a) * len * 0.75 - 4);
      final leaf = Path()..moveTo(top.dx, top.dy)..quadraticBezierTo(mid.dx, mid.dy - 4, tip.dx, tip.dy)..quadraticBezierTo(mid.dx, mid.dy + 5, top.dx, top.dy);
      canvas.drawPath(leaf, _fill(i.isEven ? const Color(0xFF2E7D32) : const Color(0xFF43A047)));
    }
    canvas.drawCircle(top + const Offset(-2, 3), 3.2, _fill(const Color(0xFF6D4C41)));
    canvas.drawCircle(top + const Offset(3, 4), 3.2, _fill(const Color(0xFF5D4037)));
  }

  void _courtStatic(Canvas canvas) {
    // 沙地球場（前景）
    final g = Rect.fromLTWH(0, _floor, _cw, _courtH - _floor);
    canvas.drawRect(g, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFF3D99B), Color(0xFFD8B46C)]).createShader(g));
    for (var i = 0; i < 70; i++) {
      canvas.drawCircle(Offset(_h(i, 5) * _cw, _floor + 2 + _h(i, 6) * (_courtH - _floor - 3)), 0.5 + _h(i, 12) * 0.8, Paint()..color = (i % 3 == 0 ? const Color(0x55FFFFFF) : const Color(0x33806040)));
    }
    // 沙紋
    for (var i = 0; i < 6; i++) {
      final y = _floor + 6 + i * 5.0;
      canvas.drawPath(Path()..moveTo(0, y)..quadraticBezierTo(_cw * 0.25, y - 1.5, _cw * 0.5, y)..quadraticBezierTo(_cw * 0.75, y + 1.5, _cw, y), Paint()..style = PaintingStyle.stroke..strokeWidth = 0.7..color = const Color(0x18806040));
    }
    // 場地白線：邊線、中線
    final line = Paint()..color = Colors.white..strokeWidth = 2.4..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(0, _floor), const Offset(_cw, _floor), line);
    canvas.drawLine(const Offset(6, _floor), const Offset(-4, _courtH), line);
    canvas.drawLine(const Offset(_cw - 6, _floor), const Offset(_cw + 4, _courtH), line);
    canvas.drawLine(const Offset(_netX, _floor), const Offset(_netX, _courtH), Paint()..color = Colors.white.withValues(alpha: 0.7)..strokeWidth = 1.6);
  }

  void _net(Canvas canvas) {
    // 網的影子
    canvas.drawOval(Rect.fromCenter(center: const Offset(_netX + 10, _floor + 5), width: 34, height: 5), _fill(const Color(0x33000000)));
    // 網：柱子（金屬帽 + 條紋）
    final sway = math.sin(s._clock * 14) * s._netShake * 3;
    final post = Rect.fromLTWH(_netX - 4, _netTop - 8, 8, _floor - _netTop + 10);
    canvas.drawRRect(RRect.fromRectAndRadius(post, const Radius.circular(3)), Paint()..shader = const LinearGradient(colors: [Color(0xFF4E342E), Color(0xFF8D6E63), Color(0xFF4E342E)]).createShader(post));
    for (var y = _netTop.toDouble() + 6; y < _floor - 4; y += 12) {
      canvas.drawRect(Rect.fromLTWH(_netX - 4, y, 8, 3), _fill(const Color(0x66FFFFFF)));
    }
    canvas.drawCircle(const Offset(_netX, _netTop - 9), 5, Paint()..shader = const RadialGradient(center: Alignment(-0.4, -0.4), colors: [Color(0xFFFFF59D), Color(0xFFFFB300)]).createShader(Rect.fromCircle(center: const Offset(_netX, _netTop - 9), radius: 5)));
    // 網面：菱形網格（隨球撞擊晃動）
    final meshRect = Rect.fromLTRB(_netX - 15 + sway, _netTop + 3, _netX + 15 + sway, _floor - 8);
    canvas.drawRect(meshRect, _fill(const Color(0x14FFFFFF)));
    final mesh = Paint()..color = const Color(0xDDFFFFFF)..strokeWidth = 0.7;
    canvas.save();
    canvas.clipRect(meshRect);
    for (var i = -6; i < 12; i++) {
      final x0 = meshRect.left + i * 5.0;
      canvas.drawLine(Offset(x0, meshRect.top), Offset(x0 + (meshRect.height * 0.5), meshRect.bottom), mesh);
      canvas.drawLine(Offset(x0 + 30, meshRect.top), Offset(x0 + 30 - (meshRect.height * 0.5), meshRect.bottom), mesh);
    }
    canvas.restore();
    // 網頂白帶 + 下緣黑帶
    final tape = Rect.fromLTWH(_netX - 16 + sway, _netTop - 2, 32, 8);
    canvas.drawRRect(RRect.fromRectAndRadius(tape, const Radius.circular(3)), _fill(Colors.white));
    canvas.drawRRect(RRect.fromRectAndRadius(tape, const Radius.circular(3)), Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0xFFB71C1C));
    canvas.drawLine(Offset(_netX - 15 + sway, _netTop + 4), Offset(_netX + 15 + sway, _netTop + 4), Paint()..color = const Color(0x55000000)..strokeWidth = 1);
    canvas.drawLine(Offset(_netX - 15, _floor - 8), Offset(_netX + 15, _floor - 8), Paint()..color = const Color(0xFF263238)..strokeWidth = 2);
    // 標桿（紅白）
    for (var i = 0; i < 6; i++) {
      canvas.drawLine(Offset(_netX + 17 + sway, _netTop - 30 + i * 6.0), Offset(_netX + 17 + sway, _netTop - 24 + i * 6.0), Paint()..color = i.isEven ? const Color(0xFFE53935) : Colors.white..strokeWidth = 2);
    }
  }

  void _players(Canvas canvas) {
    final c = s._cur!;
    final p = s._prev;
    final a = s._alpha;
    for (var i = 0; i < 2; i++) {
      var x = c.p[i][0], y = c.p[i][1];
      if (p != null) {
        x = p.p[i][0] + (c.p[i][0] - p.p[i][0]) * a;
        y = p.p[i][1] + (c.p[i][1] - p.p[i][1]) * a;
      }
      var st = c.p[i][2].toInt();
      if (i == s._side) {
        final mp = s.myPredicted();
        if (mp != null) {
          x = mp.$1;
          y = mp.$2;
          st = mp.$3;
        }
      }
      final who = (i == s._side ? s._me : s._opp);
      final look = who['look'] as Map?;
      if (look == null) continue;
      // 影子（越高越小）
      final h = ((_floor - 32) - y).clamp(0.0, 140.0);
      canvas.drawOval(Rect.fromCenter(center: Offset(x, _floor + 4), width: 56 - h * 0.18, height: 11 - h * 0.03), Paint()..color = Colors.black.withValues(alpha: 0.28));
      const sz = 88.0;
      canvas.save();
      canvas.translate(x, y + 32);
      final facing = i == 0 ? -1.0 : 1.0; // 怪物原圖朝左；左邊玩家要朝右 → 水平翻轉
      var rot = 0.0, sy = 1.0;
      if (st == 3) rot = i == 0 ? 1.15 : -1.15;
      if (st == 4) rot = i == 0 ? 1.45 : -1.45;
      if (st == 2) rot = i == 0 ? 0.35 : -0.35;
      if (st == 1) sy = 1.06;
      canvas.rotate(rot);
      canvas.scale(facing, sy);
      canvas.translate(-sz / 2, -sz * 0.92);
      final img = _sprite(look['kind'] as int, look['band'] as int);
      final breathe = 1 + math.sin((s._clock + i) * 3) * 0.012;
      canvas.translate(0, sz * (1 - breathe));
      canvas.scale(1, breathe);
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), const Rect.fromLTWH(0, 0, sz, sz), Paint()..filterQuality = FilterQuality.medium);
      canvas.restore();
      if (i == s._side) {
        // 自己頭上的小箭頭
        final tp = Offset(x, y - 50 + math.sin(s._clock * 6) * 2);
        canvas.drawPath(Path()..moveTo(tp.dx - 6, tp.dy - 8)..lineTo(tp.dx + 6, tp.dy - 8)..lineTo(tp.dx, tp.dy)..close(), Paint()..color = const Color(0xFFFFD54F));
      }
    }
  }

  // 怪物含漸層、saveLayer、模糊，每幀重畫兩隻手機會卡；改成每種造型只畫一次存成貼圖。
  static final Map<int, ui.Image> _sprites = {};
  ui.Image _sprite(int kind, int band) {
    return _sprites.putIfAbsent(kind * 100 + band, () {
      const px = 176.0;
      final rec = ui.PictureRecorder();
      MonsterPainter(kind: kind, band: band, t: 0).paint(Canvas(rec)..scale(px / 88), const Size(88, 88));
      return rec.endRecording().toImageSync(px.toInt(), px.toInt());
    });
  }

  void _ball(Canvas canvas) {
    final pos = s._ballPos();
    // 殘影（沿軌跡的拉長光暈）
    for (var i = 0; i < s._trail.length; i++) {
      final t = (i + 1) / (s._trail.length + 1);
      canvas.drawCircle(s._trail[i], _ballR * (0.35 + 0.6 * t), Paint()..color = const Color(0xFFFFF8E1).withValues(alpha: 0.10 * t));
    }
    // 影子（越高越小越淡）
    final hh = (_floor - pos.dy).clamp(0.0, 300.0);
    canvas.drawOval(Rect.fromCenter(center: Offset(pos.dx, _floor + 5), width: 34 - hh * 0.05, height: 7), Paint()..color = Colors.black.withValues(alpha: (0.32 - hh * 0.0009).clamp(0.06, 0.32)));
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    final circle = Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: _ballR));
    canvas.drawCircle(Offset.zero, _ballR + 1.5, _fill(const Color(0x28000000)));
    canvas.drawCircle(Offset.zero, _ballR, _fill(const Color(0xFFFFF8E1)));
    canvas.save();
    canvas.clipPath(circle);
    canvas.rotate(s._ballAng);
    // 三片彎曲的色帶（排球花紋）
    for (var k = 0; k < 3; k++) {
      canvas.save();
      canvas.rotate(k * 2 * math.pi / 3);
      final band = Path()..moveTo(-_ballR * 1.2, -_ballR * 0.1)..quadraticBezierTo(0, -_ballR * 1.15, _ballR * 1.2, -_ballR * 0.1);
      canvas.drawPath(band, Paint()..style = PaintingStyle.stroke..strokeWidth = 9..color = k == 1 ? const Color(0xFFFFC107) : const Color(0xFF1E88E5));
      canvas.drawPath(band, Paint()..style = PaintingStyle.stroke..strokeWidth = 8..color = k == 1 ? const Color(0xFFFFCA28) : const Color(0xFF2196F3));
      canvas.restore();
    }
    // 縫線
    canvas.drawCircle(Offset.zero, _ballR * 0.62, Paint()..style = PaintingStyle.stroke..strokeWidth = 0.7..color = const Color(0x44263238));
    canvas.restore();
    // 立體光影
    canvas.drawCircle(Offset.zero, _ballR, Paint()..shader = const RadialGradient(center: Alignment(-0.45, -0.5), radius: 1.05, colors: [Color(0x66FFFFFF), Color(0x00FFFFFF), Color(0x55102030)], stops: [0, 0.5, 1]).createShader(Rect.fromCircle(center: Offset.zero, radius: _ballR)));
    canvas.drawOval(Rect.fromCenter(center: const Offset(-7, -9), width: 8, height: 5), _fill(Colors.white.withValues(alpha: 0.75)));
    canvas.drawCircle(Offset.zero, _ballR, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.3..color = const Color(0xFF37474F));
    canvas.restore();
  }

  void _effects(Canvas canvas) {
    for (final f in s._fx) {
      final e = (f.age / 0.5).clamp(0.0, 1.0);
      if (f.kind == 4) {
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4 + 0.3;
          canvas.drawCircle(Offset(f.x + math.cos(a) * 22 * e, f.y - math.sin(a).abs() * 20 * e), 3 * (1 - e), Paint()..color = const Color(0xFFE8CD93).withValues(alpha: 1 - e));
        }
      } else {
        final col = f.kind == 2 ? const Color(0xFFFF7043) : const Color(0xFFFFFFFF);
        canvas.drawCircle(Offset(f.x, f.y), 14 + 26 * e, Paint()..style = PaintingStyle.stroke..strokeWidth = f.kind == 2 ? 4 * (1 - e) : 2.5 * (1 - e)..color = col.withValues(alpha: 1 - e));
        if (f.kind == 2) {
          for (var i = 0; i < 6; i++) {
            final a = i * math.pi / 3;
            canvas.drawLine(Offset(f.x + math.cos(a) * 16, f.y + math.sin(a) * 16), Offset(f.x + math.cos(a) * (16 + 22 * e), f.y + math.sin(a) * (16 + 22 * e)), Paint()..color = const Color(0xFFFFD54F).withValues(alpha: 1 - e)..strokeWidth = 2.5);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _VolleyPainter old) => !staticLayer || old.staticLayer != staticLayer;
}
