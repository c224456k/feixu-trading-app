import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_client.dart';
import '../widgets/monster_art.dart';
import 'archer_rogue_logic.dart';

// 弓箭肉鴿：遊戲在前端跑（規則在 archer_rogue_logic.dart），每天一局、復活扣水晶、過關回報與 20 關獎金走伺服器（rogue_game.py）。

const _floorColors = [
  (Color(0xFF7CB342), Color(0xFF689F38)), // 草原
  (Color(0xFF6D5D4E), Color(0xFF5D4E41)), // 洞窟
  (Color(0xFF5E6273), Color(0xFF51556A)), // 墓地
  (Color(0xFF4E342E), Color(0xFF3E2723)), // 熔岩
  (Color(0xFF3A2440), Color(0xFF2E1B35)), // 魔王城
];
const _wallColors = [Color(0xFF5D4037), Color(0xFF3E2C22), Color(0xFF37474F), Color(0xFF212121), Color(0xFF1A1020)];

class ArcherRogueScreen extends StatefulWidget {
  const ArcherRogueScreen({super.key});

  @override
  State<ArcherRogueScreen> createState() => _ArcherRogueScreenState();
}

class _ArcherRogueScreenState extends State<ArcherRogueScreen> with SingleTickerProviderStateMixin {
  RgGame _g = RgGame();
  final _focus = FocusNode();
  final _floorCache = _FloorCache();
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _acc = 0;
  bool _started = false;
  bool _paused = false;
  RgPhase _shownPhase = RgPhase.play;
  // 伺服器
  final _api = ApiClient();
  Map<String, dynamic>? _state;
  String? _error;
  bool _busy = false;
  int? _runId;
  int _crystals = 0;
  int _reported = -1; // 已回報過關的關卡
  String? _reportMsg;
  int _reward = 0;
  // 搖桿（arena 座標，像素）
  Offset? _joyOrigin;
  Offset? _joyNow;
  // 雙人合作（試玩）：房主（side 0）跑模擬傳畫面，客人（side 1）自己移動、照畫面畫
  _CoopNet? _net;
  int _side = -1; // -1 = 單人
  List<String> _names = const [];
  int _frame = 0;
  bool _selfOff = false; // 自己斷線、重連中
  bool _peerOff = false; // 隊友斷線、等他回來
  bool get _coop => _side >= 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _loadState();
  }

  @override
  void dispose() {
    _net?.close();
    _ticker.dispose();
    _repaint.dispose();
    _focus.dispose();
    super.dispose();
  }

  Map<String, dynamic>? get _run => _state?['run'] as Map<String, dynamic>?;
  int get _reviveCost => (_state?['revive_cost'] as num?)?.toInt() ?? 300; // 第一次復活的價格
  int _nextCost = 300; // 這一局下一次復活的價格（每次 ×2，伺服器算）

  Future<void> _loadState() async {
    setState(() => _error = null);
    try {
      final s = await _api.rogueState();
      if (!mounted) return;
      setState(() {
        _state = s;
        _crystals = (s['crystals'] as num?)?.toInt() ?? 0;
        final run = s['run'] as Map<String, dynamic>?;
        _nextCost = (run?['next_revive_cost'] as num?)?.toInt() ?? _reviveCost;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 呼叫伺服器；ok=false 時跳訊息並回傳 null
  Future<Map<String, dynamic>?> _call(Future<Map<String, dynamic>> Function() f) async {
    if (_busy) return null;
    setState(() => _busy = true);
    try {
      final r = await f();
      if (r['crystals'] != null) _crystals = (r['crystals'] as num).toInt();
      if (r['next_revive_cost'] != null) _nextCost = (r['next_revive_cost'] as num).toInt();
      if (r['ok'] != true) {
        _toast(r['message']?.toString() ?? '失敗');
        return null;
      }
      return r;
    } catch (e) {
      _toast('$e');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _startRun() async {
    final r = await _call(_api.rogueStart);
    if (r == null) return _loadState();
    _runId = ((r['run'] as Map)['id'] as num).toInt();
    _nextCost = _reviveCost;
    _g.newRun();
    _enterGame();
  }

  Future<void> _resumeRun() async {
    final run = _run;
    if (run == null) return;
    final id = (run['id'] as num).toInt();
    final r = await _call(() => _api.rogueResume(id));
    if (r == null) return _loadState();
    _runId = id;
    final ch = (r['chapter'] as num).toInt();
    final stats = r['stats'];
    if (ch == 0 || stats == null) {
      _g.newRun();
    } else {
      _g.startChapter(ch, RgStats.fromJson(Map<String, dynamic>.from(stats as Map)));
    }
    _g.revives = (r['revives'] as num?)?.toInt() ?? (run['revives'] as num).toInt();
    _enterGame();
  }

  void _enterGame() {
    _started = true;
    _paused = false;
    _reported = _g.chapter - 1;
    _reportMsg = null;
    _reward = 0;
    _sync();
  }

  void _backToMenu() {
    _started = false;
    _runId = null;
    _loadState();
    _sync();
  }

  /// 過關（或全破）時回報伺服器
  Future<void> _report() async {
    final id = _runId;
    if (id == null || _reported >= _g.chapter) return;
    final ch = _g.chapter;
    _reported = ch;
    _reportMsg = '記錄中…';
    final stats = (_g.phase == RgPhase.victory ? _g.st : _g.nextStats()).toJson();
    try {
      final r = await _api.rogueProgress(id, ch, stats);
      if (r['ok'] == true) {
        _reward = (r['reward'] as num?)?.toInt() ?? 0;
        _reportMsg = null;
      } else {
        _reportMsg = '⚠️ ${r['message']}';
      }
    } catch (e) {
      _reported = ch - 1; // 讓玩家可以重試
      _reportMsg = '⚠️ 連線失敗：$e';
    }
    if (mounted) setState(() {});
  }

  Future<void> _nextChapter() async {
    final id = _runId;
    if (id == null) return;
    final r = await _call(() => _api.rogueBegin(id));
    if (r == null) return;
    _g.nextChapter();
    _sync();
  }

  Future<void> _revive() async {
    final id = _runId;
    if (id == null) return;
    final r = await _call(() => _api.rogueRevive(id));
    if (r == null) return;
    _g.revive();
    _sync();
  }

  Future<void> _giveUp() async {
    final id = _runId;
    if (id != null) await _call(() => _api.rogueGiveUp(id));
    _backToMenu();
  }

  void _sync() {
    _shownPhase = _g.phase;
    setState(() {});
    _focus.requestFocus();
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
    final k = math.min(1.0, l / 40) / l;
    return (d.dx * k, d.dy * k);
  }

  void _onTick(Duration now) {
    final dt = _last == Duration.zero ? 0.0 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (_coop) return _coopTick(dt);
    if (!_started || _paused || _g.phase != RgPhase.play) {
      _acc = 0;
      return;
    }
    _acc += math.min(dt, 0.1);
    final (mx, my) = _input();
    var n = 0;
    final chapterBefore = _g.chapter;
    while (_acc >= rgDt && n < 6) {
      _g.step(mx, my);
      _acc -= rgDt;
      n++;
      if (_g.phase != RgPhase.play) break;
    }
    if (n > 0) _repaint.value++;
    if (_g.phase != _shownPhase || _g.chapter != chapterBefore) {
      if (_g.phase == RgPhase.chapterDone || _g.phase == RgPhase.victory) _report();
      _sync();
    }
  }

  // ---------------- 雙人合作 ----------------
  void _openCoop() {
    final net = _CoopNet(_api, onMsg: _onCoopMsg, onChanged: () {
      if (mounted) setState(() {});
    });
    setState(() => _net = net);
    net.connect();
  }

  void _closeCoop() {
    _net?.close();
    _net = null;
    _leaveCoopGame();
    _loadState();
  }

  void _leaveCoopGame() {
    _net?.stayConnected = false;
    _selfOff = _peerOff = false;
    _side = -1;
    _started = false;
    _g = RgGame();
    _sync();
  }

  void _quitCoop() {
    _net?.send({'t': 'leave'});
    _leaveCoopGame();
  }

  void _onCoopMsg(Map<String, dynamic> m) {
    if (!mounted) return;
    switch (m['t']) {
      case 'start' || 'resume':
        final side = (m['side'] as num).toInt();
        _names = [for (final n in m['names'] as List) '$n'];
        _net?.stayConnected = true;
        _selfOff = _peerOff = false;
        // 只是網路斷一下、畫面還在：遊戲直接接著跑
        if (m['t'] == 'resume' && _started && _side == side) return setState(() {});
        _side = side;
        _g = RgGame(seed: (m['seed'] as num).toInt(), players: 2)..local = _side;
        _g.heroes[1].remote = true;
        _frame = 0;
        _acc = 0;
        if (_side == 0) {
          final snap = m['snap'];
          if (snap is Map<String, dynamic>) {
            _g.restoreFrom(snap);
          } else {
            _g.newRun();
          }
        }
        _started = true;
        _paused = false;
        _sync();
        if (m['t'] == 'resume') _toast(_side == 0 ? '重新連上了，從這一間重來' : '重新連上了');
      case 'drop':
        if (_started) setState(() => _selfOff = true);
      case 'peer':
        if (_started) setState(() => _peerOff = m['on'] != true);
      case 'noroom':
        if (_started) {
          _toast('這場已經結束了（隊友離開或斷線太久）');
          _leaveCoopGame();
        }
      case 'r':
        final d = m['d'];
        if (d is Map<String, dynamic>) _onCoopData(d);
      case 'gone':
        if (_started) {
          _toast('${m['msg'] ?? '隊友離開了'}，這場結束');
          _leaveCoopGame();
        }
    }
  }

  static double _n(Object? v) => (v as num).toDouble();
  static int _skillCount(RgHero p) => p.st.sk.values.fold(0, (a, b) => a + b);

  void _onCoopData(Map<String, dynamic> d) {
    if (!_started) return;
    switch (d['k']) {
      case 's':
        if (_side == 1) _g.applySnap(d['s'] as Map<String, dynamic>);
      case 'in':
        if (_side == 0) _g.setRemote(1, _n(d['x']), _n(d['y']), _n(d['fx']), _n(d['fy']), d['mv'] == 1, seq: (d['q'] as num?)?.toInt());
      case 'pick':
        // n = 客人選之前的技能總數，避免同一次選擇（網路重送／畫面還沒更新又點一次）算兩次
        if (_side == 0 && _skillCount(_g.heroes[1]) == (d['n'] as num).toInt()) _g.chooseFor(1, d['id'] as String);
      case 'angel':
        if (_side == 0) _g.chooseAngelFor(1, d['heal'] == true);
    }
  }

  void _coopPick(String id) {
    _net?.relay({'k': 'pick', 'id': id, 'n': _skillCount(_g.me)});
    _g.me.offer = []; // 等房主的畫面帶回下一組
  }

  void _coopAngel(bool heal) {
    _net?.relay({'k': 'angel', 'heal': heal});
    _g.me.needAngel = false;
  }

  void _coopTick(double dt) {
    if (!_started) return;
    if (_selfOff || _peerOff) {
      _acc = 0; // 有人斷線：遊戲停住等他
      return;
    }
    _acc += math.min(dt, 0.1);
    final (mx, my) = _input();
    final chapter = _g.chapter;
    var n = 0;
    while (_acc >= rgDt && n < 6) {
      _acc -= rgDt;
      n++;
      _frame++;
      if (_side == 0) {
        _g.step(mx, my);
        if (_frame % (_g.phase == RgPhase.play ? 4 : 15) == 0) _net?.relay({'k': 's', 's': _g.snap()});
      } else {
        _g.guestMove(mx, my);
        _g.guestTick();
        final p = _g.me;
        if (_frame % 2 == 0 && _g.phase == RgPhase.play && !p.down) {
          double r2(double v) => (v * 100).roundToDouble() / 100;
          _net?.relay({'k': 'in', 'x': r2(p.x), 'y': r2(p.y), 'fx': r2(p.faceX), 'fy': r2(p.faceY), 'mv': p.moving ? 1 : 0, 'q': _g.roomSeq});
        }
      }
    }
    if (_acc > 0.2) _acc = 0;
    if (n > 0) _repaint.value++;
    if (_g.phase != _shownPhase || _g.chapter != chapter) {
      _sync();
    } else if (_g.phase != RgPhase.play && _frame % 15 == 0 && n > 0) {
      setState(() {}); // 等隊友選擇時，選完要更新畫面
    }
  }

  // ---------------- 畫面 ----------------
  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (n, e) {
        final keys = {
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.space,
        };
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyP && _started && !_coop) {
          setState(() => _paused = !_paused);
          return KeyEventResult.handled;
        }
        return keys.contains(e.logicalKey) ? KeyEventResult.handled : KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF14161C),
        appBar: AppBar(
          title: Text(_coop || _net != null ? '弓箭肉鴿・雙人合作' : '弓箭肉鴿'),
          leading: _net != null && !_started ? BackButton(onPressed: _closeCoop) : null,
          actions: [
            if (_started && !_coop)
              IconButton(
                onPressed: () => setState(() => _paused = !_paused),
                icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                tooltip: '暫停（P）',
              ),
          ],
        ),
        body: SafeArea(child: _started ? _game() : (_net != null ? _coopMenu() : _menu())),
      ),
    );
  }

  Widget _menu() {
    final st = _state;
    final run = _run;
    final active = run != null && run['status'] == 'active';
    final canStart = st?['can_start'] == true;
    final reward = (st?['reward'] as num?)?.toInt() ?? 500000;
    String status;
    if (run == null) {
      status = '今天還沒挑戰';
    } else if (active) {
      status = '進行中：已通過 ${run['cleared']} / $rgChapters 關（復活 ${run['revives']} 次）';
    } else if (run['today'] == true) {
      status = switch (run['status']) {
        'won' => '🏆 今天已經全破！（復活 ${run['revives']} 次）明天再來',
        _ => '今天的挑戰結束：通過 ${run['cleared']} / $rgChapters 關，明天再來',
      };
    } else {
      status = '今天還沒挑戰';
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🏹 弓箭肉鴿', style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 6),
              Text('通過全部 $rgChapters 關獎金 ${_fmtMoney(reward)} 元', style: const TextStyle(color: Colors.amberAccent, fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Text(
                '• 拖曳畫面（或 WASD／方向鍵）移動，移動時不會射擊；停下來自動射最近的敵人\n'
                '• 清完房間撿經驗、升級時三選一技能，技能整局累積\n'
                '• 每關 4 個房間 + 頭目，共 $rgChapters 關，難度非常高\n'
                '• 每天只能挑戰一局\n'
                '• 死掉可以花水晶原地滿血復活，同一局越復活越貴：$_reviveCost → ${_reviveCost * 2} → ${_reviveCost * 4} …（每次加倍）；不復活整局結束\n'
                '• 打到一半關掉網頁，回來要花一次復活的水晶從那一關開頭重來（也算進加倍）',
                style: const TextStyle(color: Colors.white70, height: 1.7),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: const Color(0xFF263238), borderRadius: BorderRadius.circular(10)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('💎', style: TextStyle(fontSize: 16)),
                    const SizedBox(width: 6),
                    Text('水晶 ${_fmtMoney(_crystals)}', style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (st != null) Text(status, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                TextButton(onPressed: _loadState, child: const Text('重試')),
              ],
              const SizedBox(height: 20),
              if (st == null && _error == null) const CircularProgressIndicator(),
              if (active)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _resumeRun,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(run['in_chapter'] == true
                        ? '繼續第 ${(run['cleared'] as num).toInt() + 1} 關（花 ${_fmtMoney(_nextCost)} 水晶重來這關）'
                        : '繼續：第 ${(run['cleared'] as num).toInt() + 1} 關'),
                  ),
                ),
              if (canStart)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _startRun,
                    icon: const Icon(Icons.flag),
                    label: const Text('開始今天的挑戰'),
                  ),
                ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openCoop,
                  icon: const Icon(Icons.group),
                  label: const Text('👥 雙人合作（試玩：不限次數、不扣水晶、沒有獎金）'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtMoney(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  Widget _game() {
    return Column(
      children: [
        _hud(),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final w = math.min(c.maxWidth, c.maxHeight * rgCols / rgRows);
            final h = w * rgRows / rgCols;
            return Center(
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(
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
                            painter: _ArenaPainter(_g, _floorCache, _repaint, () => (_joyOrigin, _joyNow), names: _coop ? _names : null),
                            size: Size(w, h),
                          ),
                        ),
                      ),
                    ),
                    if (_g.boss != null) Positioned(left: 8, right: 8, top: 6, child: _bossBar(_g.boss!)),
                    if (_paused) Positioned.fill(child: _pauseOverlay()),
                    if (_g.phase != RgPhase.play) Positioned.fill(child: _phaseOverlay()),
                    if (_coop && (_selfOff || _peerOff)) Positioned.fill(child: _offlineOverlay()),
                  ],
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _hud() {
    final st = _g.st;
    return ValueListenableBuilder(
      valueListenable: _repaint,
      builder: (context, _, _) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF232733), Color(0xFF14161C)]),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFF37474F), borderRadius: BorderRadius.circular(8)),
                  child: Text('第 ${_g.chapter + 1} 關・${rgChapterNames[_g.chapter]}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
                const SizedBox(width: 10),
                for (var i = 0; i < rgRoomsPerChapter; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: i == rgRoomsPerChapter - 1
                        ? Text('👑', style: TextStyle(fontSize: 13, color: i <= _g.room ? null : Colors.white24))
                        : Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i < _g.room || i == _g.room && _g.cleared
                                  ? const Color(0xFF69F0AE)
                                  : i == _g.room
                                      ? Colors.amberAccent
                                      : Colors.white24,
                            ),
                          ),
                  ),
                const Spacer(),
                Text('擊殺 ${_g.kills}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Text('❤️', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
                Expanded(
                  child: _bar(st.hp / st.maxHp, const [Color(0xFFFF5252), Color(0xFFC62828)], '${st.hp.round()} / ${st.maxHp.round()}'),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Container(
                  width: 34,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: const Color(0xFF0277BD), borderRadius: BorderRadius.circular(9)),
                  child: Text('Lv${st.level}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 6),
                Expanded(child: _bar(st.xp / st.xpNeed, const [Color(0xFF80D8FF), Color(0xFF0288D1)], null, height: 7)),
              ],
            ),
            if (_coop)
              for (final p in _g.heroes)
                if (p != _g.me) ...[
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      SizedBox(
                        width: 70,
                        child: Text(_names.length > p.idx ? _names[p.idx] : '隊友',
                            overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF82B1FF), fontSize: 11)),
                      ),
                      Expanded(
                        child: _bar(p.st.hp / p.st.maxHp, const [Color(0xFF82B1FF), Color(0xFF1565C0)],
                            p.down ? '倒地！快去扶' : 'Lv${p.st.level}  ${p.st.hp.round()} / ${p.st.maxHp.round()}',
                            height: 12),
                      ),
                    ],
                  ),
                ],
            if (st.sk.isNotEmpty) ...[
              const SizedBox(height: 6),
              SizedBox(
                height: 24,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final e in st.sk.entries)
                      if (e.key != 'heal')
                        Tooltip(
                          message: rgSkill(e.key).name,
                          child: Container(
                            margin: const EdgeInsets.only(right: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF263238),
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.35)),
                            ),
                            alignment: Alignment.center,
                            child: Text('${rgSkill(e.key).icon}${e.value > 1 ? ' ${e.value}' : ''}',
                                style: const TextStyle(fontSize: 12, color: Colors.white)),
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bar(double v, List<Color> c, String? label, {double height = 15}) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: Colors.black, width: 1),
        color: const Color(0xFF0B0C10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: Stack(
          children: [
            FractionallySizedBox(
              widthFactor: v.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: c)),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: height * 0.4,
              child: Container(color: Colors.white.withValues(alpha: 0.18)),
            ),
            if (label != null)
              Center(
                child: Text(label,
                    style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 2)])),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bossBar(RgEnemy b) {
    return ValueListenableBuilder(
      valueListenable: _repaint,
      builder: (context, _, _) => Column(
        children: [
          Text(b.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12, shadows: [Shadow(blurRadius: 3)])),
          const SizedBox(height: 2),
          _bar(b.hp / b.maxHp, const [Color(0xFFE040FB), Color(0xFF7B1FA2)], null, height: 10),
        ],
      ),
    );
  }

  Widget _dim(Widget child) => Container(
        color: Colors.black.withValues(alpha: 0.72),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(child: child),
      );

  Widget _pauseOverlay() => GestureDetector(
        onTap: () => setState(() => _paused = false),
        child: _dim(const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.pause_circle, size: 64, color: Colors.white),
            SizedBox(height: 8),
            Text('暫停中，點一下繼續', style: TextStyle(color: Colors.white)),
          ],
        )),
      );

  Widget _phaseOverlay() {
    if (_coop) return _coopOverlay();
    switch (_g.phase) {
      case RgPhase.pick:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_g.st.sk.isEmpty ? '選一個起始技能' : '升級！選一個技能',
                style: const TextStyle(color: Colors.amberAccent, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 14),
            for (final id in _g.offer) _skillCard(id),
          ],
        ));
      case RgPhase.angel:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('😇', style: TextStyle(fontSize: 48)),
            const Text('天使出現了', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('前方就是頭目，選一個祝福', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            _choiceButton('💚 回復 50% 生命', () => _g.chooseAngel(true)),
            const SizedBox(height: 10),
            _choiceButton('✨ 額外技能（三選一）', () => _g.chooseAngel(false)),
          ],
        ));
      case RgPhase.dead:
        final canRevive = _crystals >= _nextCost;
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💀', style: TextStyle(fontSize: 48)),
            const Text('你倒下了', style: TextStyle(color: Colors.redAccent, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('第 ${_g.chapter + 1} 關 ${_g.isBossRoom ? '頭目房' : '第 ${_g.room + 1} 間'}・被 ${_g.lastHitBy ?? '?'} 打倒',
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 4),
            Text('💎 水晶 ${_fmtMoney(_crystals)}・這局已復活 ${_g.revives} 次', style: const TextStyle(color: Colors.lightBlueAccent)),
            const SizedBox(height: 18),
            _asyncButton(canRevive ? '💎 花 ${_fmtMoney(_nextCost)} 水晶原地復活' : '水晶不足（要 ${_fmtMoney(_nextCost)}）', canRevive ? _revive : null),
            const SizedBox(height: 4),
            Text('下一次復活會變成 ${_fmtMoney(_nextCost * 2)}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 10),
            _asyncButton('🏳️ 放棄（今天的挑戰結束）', () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('確定放棄？'),
                  content: Text('今天就不能再玩了（目前通過 ${_g.chapter} 關）。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('放棄')),
                  ],
                ),
              );
              if (ok == true) await _giveUp();
            }),
          ],
        ));
      case RgPhase.chapterDone:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🏆', style: TextStyle(fontSize: 48)),
            Text('第 ${_g.chapter + 1} 關 通關！', style: const TextStyle(color: Colors.amberAccent, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('下一關：第 ${_g.chapter + 2} 關 ${rgChapterNames[_g.chapter + 1]}（進關回復 20% 生命）', style: const TextStyle(color: Colors.white70)),
            if (_reportMsg != null) ...[
              const SizedBox(height: 6),
              Text(_reportMsg!, style: const TextStyle(color: Colors.orangeAccent)),
            ],
            const SizedBox(height: 18),
            if (_reported < _g.chapter)
              _asyncButton('🔄 重新記錄過關', () async {
                await _report();
              })
            else
              _asyncButton('▶ 前往第 ${_g.chapter + 2} 關', _reportMsg == null ? _nextChapter : null),
            const SizedBox(height: 10),
            _asyncButton('🏠 先休息（之後從下一關繼續）', _reportMsg == null ? () async => _backToMenu() : null),
          ],
        ));
      case RgPhase.victory:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('👑', style: TextStyle(fontSize: 56)),
            Text('全破 $rgChapters 關！', style: const TextStyle(color: Colors.amberAccent, fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('等級 ${_g.st.level}・擊殺 ${_g.kills}・復活 ${_g.revives} 次', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            if (_reward > 0)
              Text('💰 獲得獎金 ${_fmtMoney(_reward)} 元！', style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold))
            else
              Text(_reportMsg ?? '記錄中…', style: const TextStyle(color: Colors.orangeAccent)),
            const SizedBox(height: 18),
            if (_reported < _g.chapter) _asyncButton('🔄 重新記錄', () async => _report()),
            _asyncButton('🏠 回主選單', () async => _backToMenu()),
          ],
        ));
      case RgPhase.play:
        return const SizedBox.shrink();
    }
  }

  Widget _coopMenu() {
    final net = _net!;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('👥 雙人合作', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 4),
              const Text('試玩版：不限次數、不扣水晶、沒有獎金', style: TextStyle(color: Colors.amberAccent)),
              const SizedBox(height: 14),
              const Text(
                '• 兩個人一起打 $rgChapters 關，技能各自選，怪物血量 ×1.5\n'
                '• 倒地時隊友站在旁邊 2.5 秒可以扶起來；清完房間也會自動站起來\n'
                '• 兩個人都倒地＝全滅，房主可以免費從那一間重來\n'
                '• 兩個人都走到門口才會進下一間\n'
                '• 遊戲在房主的裝置上跑，房主網路要穩',
                style: TextStyle(color: Colors.white70, height: 1.7),
              ),
              const SizedBox(height: 20),
              if (net.error != null) ...[
                Text(net.error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                if (!net.connected) TextButton(onPressed: net.connect, child: const Text('重新連線')),
              ],
              if (!net.connected && net.error == null) const CircularProgressIndicator(),
              if (net.connected && net.waiting != null) ...[
                Text('房間 #${net.waiting} 等待隊友加入…', style: const TextStyle(color: Colors.white, fontSize: 16)),
                const SizedBox(height: 12),
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () {
                    net.send({'t': 'leave'});
                    setState(() => net.waiting = null);
                  },
                  child: const Text('取消'),
                ),
              ],
              if (net.connected && net.waiting == null) ...[
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => net.send({'t': 'create'}),
                    icon: const Icon(Icons.add),
                    label: const Text('開新房間（我當房主）'),
                  ),
                ),
                const SizedBox(height: 20),
                const Align(alignment: Alignment.centerLeft, child: Text('等待中的房間', style: TextStyle(color: Colors.white54))),
                const SizedBox(height: 6),
                if (net.rooms.isEmpty) const Text('目前沒有人開房，開一間叫朋友加入吧', style: TextStyle(color: Colors.white38)),
                for (final r in net.rooms)
                  Card(
                    color: const Color(0xFF263238),
                    child: ListTile(
                      leading: const Text('🏹', style: TextStyle(fontSize: 22)),
                      title: Text('${r['host']} 的房間', style: const TextStyle(color: Colors.white)),
                      subtitle: Text('#${r['id']}', style: const TextStyle(color: Colors.white38)),
                      trailing: FilledButton(onPressed: () => net.send({'t': 'join', 'room': r['id']}), child: const Text('加入')),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _offlineOverlay() => _dim(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(_selfOff ? '連線中斷，重新連線中…' : '隊友斷線了，等他回來（最多 90 秒）…',
              style: const TextStyle(color: Colors.white, fontSize: 16)),
          const SizedBox(height: 4),
          const Text('遊戲先暫停，連回來會接著玩', style: TextStyle(color: Colors.white54)),
          const SizedBox(height: 16),
          _choiceButton('🏠 不等了，離開這場', _quitCoop),
        ],
      ));

  Widget _coopOverlay() {
    final me = _g.me;
    final host = _side == 0;
    Widget wait(String s) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(s, style: const TextStyle(color: Colors.white70)),
          ],
        );
    final quit = _choiceButton('🏠 離開這場', _quitCoop);
    switch (_g.phase) {
      case RgPhase.pick:
        if (me.pendingPicks > 0 && me.offer.isNotEmpty) {
          return _dim(Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(me.st.sk.isEmpty ? '選一個起始技能' : '升級！選一個技能',
                  style: const TextStyle(color: Colors.amberAccent, fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              for (final id in me.offer) _skillCard(id),
            ],
          ));
        }
        return _dim(wait('等待隊友選技能…'));
      case RgPhase.angel:
        if (!me.needAngel) return _dim(wait('等待隊友選祝福…'));
        void angel(bool heal) => host ? _g.chooseAngel(heal) : _coopAngel(heal);
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('😇', style: TextStyle(fontSize: 48)),
            const Text('天使出現了', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('前方就是頭目，選一個祝福（各選各的）', style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            _choiceButton('💚 回復 50% 生命', () => angel(true)),
            const SizedBox(height: 10),
            _choiceButton('✨ 額外技能（三選一）', () => angel(false)),
          ],
        ));
      case RgPhase.dead:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💀', style: TextStyle(fontSize: 48)),
            const Text('全滅了', style: TextStyle(color: Colors.redAccent, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('第 ${_g.chapter + 1} 關 ${_g.isBossRoom ? '頭目房' : '第 ${_g.room + 1} 間'}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            if (host) _choiceButton('🔄 從這一間重來（免費，兩人滿血）', _g.retryRoom) else wait('等待房主決定要不要重來…'),
            const SizedBox(height: 10),
            quit,
          ],
        ));
      case RgPhase.chapterDone:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🏆', style: TextStyle(fontSize: 48)),
            Text('第 ${_g.chapter + 1} 關 通關！', style: const TextStyle(color: Colors.amberAccent, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('下一關：第 ${_g.chapter + 2} 關 ${rgChapterNames[_g.chapter + 1]}（進關回復 20% 生命）', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            if (host) _choiceButton('▶ 前往第 ${_g.chapter + 2} 關', _g.nextChapter) else wait('等待房主前往下一關…'),
            const SizedBox(height: 10),
            quit,
          ],
        ));
      case RgPhase.victory:
        return _dim(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('👑', style: TextStyle(fontSize: 56)),
            Text('兩人合作全破 $rgChapters 關！', style: const TextStyle(color: Colors.amberAccent, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text('等級 ${me.st.level}・擊殺 ${_g.kills}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            quit,
          ],
        ));
      case RgPhase.play:
        return const SizedBox.shrink();
    }
  }

  Widget _asyncButton(String label, Future<void> Function()? onTap) => SizedBox(
        width: 280,
        child: FilledButton(
          onPressed: onTap == null || _busy
              ? null
              : () async {
                  await onTap();
                  if (mounted) setState(() {});
                },
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(label, textAlign: TextAlign.center)),
        ),
      );

  Widget _choiceButton(String label, VoidCallback onTap) => SizedBox(
        width: 260,
        child: FilledButton(
          onPressed: () {
            onTap();
            _sync();
          },
          child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(label)),
        ),
      );

  Widget _skillCard(String id) {
    final s = rgSkill(id);
    final lv = _g.st.lv(id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF263238),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            if (_side == 1) {
              _coopPick(id);
            } else {
              _g.choose(id);
            }
            _sync();
          },
          child: Container(
            width: 300,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6)),
            ),
            child: Row(
              children: [
                Text(s.icon, style: const TextStyle(fontSize: 30)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.max > 1 && id != 'heal' ? '${s.name}  Lv$lv→${lv + 1}' : s.name,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(s.desc, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 地板＋岩石不會變，錄成 Picture 快取（換房間或尺寸才重畫）
class _FloorCache {
  String key = '';
  ui.Picture? pic;
}

double _hash(int x, int y, int salt) {
  var h = (x * 73856093) ^ (y * 19349663) ^ (salt * 83492791);
  h = (h ^ (h >> 13)) * 1274126177;
  return ((h ^ (h >> 16)) & 0xFFFF) / 0xFFFF;
}

class _ArenaPainter extends CustomPainter {
  final RgGame g;
  final _FloorCache cache;
  final (Offset?, Offset?) Function() joy;
  final List<String>? names; // 合作模式：頭上顯示名字
  _ArenaPainter(this.g, this.cache, Listenable repaint, this.joy, {this.names}) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / rgCols;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (g.shake > 0) {
      final k = g.shake * 10;
      canvas.translate(math.sin(g.time * 90) * k, math.cos(g.time * 77) * k);
    }
    final key = '${g.chapter}/${g.room}/${g.roomSeq}/${size.width.toStringAsFixed(1)}';
    if (cache.key != key || cache.pic == null) {
      final rec = ui.PictureRecorder();
      _staticFloor(Canvas(rec), s, size);
      cache.pic?.dispose();
      cache.pic = rec.endRecording();
      cache.key = key;
    }
    canvas.drawPicture(cache.pic!);
    _liquids(canvas, s);
    _door(canvas, s);
    _ambient(canvas, s, size);
    _zones(canvas, s);
    _portals(canvas, s);
    _telegraphs(canvas, s);
    for (final h in g.hearts) {
      _heart(canvas, Offset(h.x * s, h.y * s), s * 0.22);
    }
    _gems(canvas, s);
    final sorted = List.of(g.en)..sort((a, b) => a.y.compareTo(b.y));
    final py = g.me.y;
    for (final e in sorted) {
      if (e.y <= py) _enemy(canvas, e, s);
    }
    for (final p in g.heroes) {
      if (p != g.me) _player(canvas, s, p);
    }
    _player(canvas, s, g.me);
    for (final e in sorted) {
      if (e.y > py) _enemy(canvas, e, s);
    }
    _fx(canvas, s);
    _bullets(canvas, s);
    _floats(canvas, s);
    canvas.restore();
    _vignette(canvas, size);
    _banner(canvas, size, s);
    _joystick(canvas);
  }

  // ---------- 靜態地板 ----------
  void _staticFloor(Canvas c, double s, Size size) {
    final ch = g.theme;
    final (a, b) = _floorColors[ch];
    for (var y = 0; y < rgRows; y++) {
      for (var x = 0; x < rgCols; x++) {
        final r = Rect.fromLTWH(x * s, y * s, s + 0.5, s + 0.5);
        final n = _hash(x, y, ch);
        final base = Color.lerp((x + y).isEven ? a : b, n > 0.5 ? Colors.white : Colors.black, (n - 0.5).abs() * 0.12)!;
        c.drawRect(r, Paint()..color = base);
        _tileDeco(c, ch, x, y, s);
      }
    }
    // 四周牆壁的陰影
    final edge = s * 0.6;
    for (final (rect, begin) in [
      (Rect.fromLTWH(0, 0, size.width, edge), Alignment.topCenter),
      (Rect.fromLTWH(0, size.height - edge, size.width, edge), Alignment.bottomCenter),
      (Rect.fromLTWH(0, 0, edge, size.height), Alignment.centerLeft),
      (Rect.fromLTWH(size.width - edge, 0, edge, size.height), Alignment.centerRight),
    ]) {
      c.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(begin: begin, end: -begin, colors: const [Color(0x88000000), Color(0x00000000)])
                .createShader(rect));
    }
    // 上方牆面
    final wall = Rect.fromLTWH(0, 0, size.width, s * 0.32);
    c.drawRect(wall, Paint()..color = _wallColors[ch]);
    for (var i = 0; i < rgCols * 2; i++) {
      c.drawLine(Offset(i * s / 2, 0), Offset(i * s / 2, s * 0.32), Paint()
        ..color = const Color(0x33000000)
        ..strokeWidth = 1);
    }
    c.drawLine(Offset(0, s * 0.32), Offset(size.width, s * 0.32), Paint()
      ..color = const Color(0x66000000)
      ..strokeWidth = 2);
    for (var y = 0; y < rgRows; y++) {
      for (var x = 0; x < rgCols; x++) {
        if (g.grid[y][x] == '#') _rock(c, ch, x, y, s);
      }
    }
  }

  void _tileDeco(Canvas c, int ch, int x, int y, double s) {
    if (g.grid[y][x] != '.') return;
    final n1 = _hash(x, y, 11 + ch), n2 = _hash(x, y, 29 + ch), n3 = _hash(x, y, 47 + ch);
    final o = Offset((x + 0.2 + n2 * 0.6) * s, (y + 0.2 + n3 * 0.6) * s);
    switch (ch) {
      case 0: // 草叢、小花
        if (n1 < 0.35) {
          final p = Paint()
            ..color = const Color(0xFF33691E).withValues(alpha: 0.6)
            ..strokeWidth = s * 0.03
            ..strokeCap = StrokeCap.round;
          for (var i = -1; i <= 1; i++) {
            c.drawLine(o, o + Offset(i * s * 0.06, -s * 0.13), p);
          }
        } else if (n1 < 0.42) {
          final col = n2 < 0.5 ? const Color(0xFFFFF176) : const Color(0xFFF8BBD0);
          for (var i = 0; i < 5; i++) {
            final a = i * 2 * math.pi / 5;
            c.drawCircle(o + Offset(math.cos(a), math.sin(a)) * s * 0.05, s * 0.035, Paint()..color = col);
          }
          c.drawCircle(o, s * 0.03, Paint()..color = const Color(0xFFFF8F00));
        }
      case 1: // 碎石、裂縫
        if (n1 < 0.3) {
          c.drawOval(Rect.fromCenter(center: o, width: s * 0.14, height: s * 0.09), Paint()..color = const Color(0x55000000));
          c.drawOval(Rect.fromCenter(center: o - Offset(0, s * 0.015), width: s * 0.12, height: s * 0.07),
              Paint()..color = const Color(0xFF8D7B6A));
        } else if (n1 < 0.45) {
          _crack(c, o, s, const Color(0x44000000));
        }
      case 2: // 裂縫、骨頭
        if (n1 < 0.25) {
          _crack(c, o, s, const Color(0x55000000));
        } else if (n1 < 0.32) {
          final p = Paint()
            ..color = const Color(0xFFD7CCC8).withValues(alpha: 0.7)
            ..strokeWidth = s * 0.035
            ..strokeCap = StrokeCap.round;
          final d = Offset(math.cos(n2 * 6), math.sin(n2 * 6)) * s * 0.12;
          c.drawLine(o - d, o + d, p);
          c.drawCircle(o - d, s * 0.03, p);
          c.drawCircle(o + d, s * 0.03, p);
        }
      case 3: // 發光岩漿裂縫
        if (n1 < 0.35) _crack(c, o, s, const Color(0xCCFF6D00), width: 0.03);
      case 4: // 大理石磁磚的金邊
        final r = Rect.fromLTWH(x * s, y * s, s, s).deflate(s * 0.04);
        c.drawRect(
            r,
            Paint()
              ..color = const Color(0x22FFD54F)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
        if (n1 < 0.2) _crack(c, o, s, const Color(0x33FFFFFF), width: 0.015);
    }
  }

  void _crack(Canvas c, Offset o, double s, Color col, {double width = 0.02}) {
    final p = Path()..moveTo(o.dx - s * 0.18, o.dy - s * 0.05);
    p.lineTo(o.dx - s * 0.04, o.dy + s * 0.03);
    p.lineTo(o.dx + s * 0.05, o.dy - s * 0.04);
    p.lineTo(o.dx + s * 0.18, o.dy + s * 0.06);
    p.moveTo(o.dx + s * 0.05, o.dy - s * 0.04);
    p.lineTo(o.dx + s * 0.08, o.dy - s * 0.15);
    c.drawPath(
        p,
        Paint()
          ..color = col
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * width);
  }

  void _rock(Canvas c, int ch, int x, int y, double s) {
    final r = Rect.fromLTWH(x * s, y * s, s, s);
    final n = _hash(x, y, 5);
    c.drawOval(Rect.fromLTWH(r.left + s * 0.05, r.bottom - s * 0.25, s * 0.95, s * 0.3), Paint()..color = const Color(0x66000000));
    if (ch == 2) {
      // 墓碑
      final t = RRect.fromRectAndCorners(Rect.fromLTWH(r.left + s * 0.18, r.top + s * 0.08, s * 0.64, s * 0.84),
          topLeft: Radius.circular(s * 0.32), topRight: Radius.circular(s * 0.32), bottomLeft: Radius.circular(s * 0.04),
          bottomRight: Radius.circular(s * 0.04));
      c.drawRRect(t, Paint()..shader = const LinearGradient(colors: [Color(0xFFB0BEC5), Color(0xFF607D8B)]).createShader(r));
      c.drawRRect(t, Paint()
        ..color = const Color(0x55000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
      final cp = Paint()
        ..color = const Color(0x88263238)
        ..strokeWidth = s * 0.06;
      c.drawLine(r.topLeft + Offset(s * 0.5, s * 0.25), r.topLeft + Offset(s * 0.5, s * 0.6), cp);
      c.drawLine(r.topLeft + Offset(s * 0.36, s * 0.37), r.topLeft + Offset(s * 0.64, s * 0.37), cp);
      return;
    }
    if (ch == 4) {
      // 石柱
      final col = Rect.fromLTWH(r.left + s * 0.15, r.top + s * 0.02, s * 0.7, s * 0.92);
      c.drawRect(col,
          Paint()..shader = const LinearGradient(colors: [Color(0xFF4A3B5C), Color(0xFF9575CD), Color(0xFF4A3B5C)]).createShader(col));
      for (final yy in [col.top, col.bottom - s * 0.12]) {
        c.drawRect(Rect.fromLTWH(r.left + s * 0.08, yy, s * 0.84, s * 0.12), Paint()..color = const Color(0xFFFFD54F).withValues(alpha: 0.85));
      }
      return;
    }
    final colors = switch (ch) {
      0 => const [Color(0xFFBDBDBD), Color(0xFF757575), Color(0xFF424242)],
      1 => const [Color(0xFFA1887F), Color(0xFF6D4C41), Color(0xFF3E2723)],
      _ => const [Color(0xFF616161), Color(0xFF303030), Color(0xFF121212)],
    };
    final p = Path();
    const pts = 8;
    for (var i = 0; i < pts; i++) {
      final a = i * 2 * math.pi / pts;
      final rr = s * (0.40 + _hash(x * 8 + i, y, 3) * 0.08);
      final pt = Offset(r.center.dx + math.cos(a) * rr, r.center.dy + math.sin(a) * rr * 0.9);
      if (i == 0) {
        p.moveTo(pt.dx, pt.dy);
      } else {
        p.lineTo(pt.dx, pt.dy);
      }
    }
    p.close();
    c.drawPath(p, Paint()..shader = RadialGradient(center: const Alignment(-0.4, -0.5), colors: colors).createShader(r));
    c.drawPath(p, Paint()
      ..color = const Color(0x66000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
    if (ch == 0 && n < 0.6) {
      // 青苔
      c.drawOval(Rect.fromLTWH(r.left + s * 0.2, r.top + s * 0.14, s * 0.4, s * 0.18), Paint()..color = const Color(0xAA558B2F));
    }
    if (ch == 3) _crack(c, r.center, s * 0.8, const Color(0xFFFF6D00), width: 0.04);
    c.drawCircle(r.center + Offset(-s * 0.15, -s * 0.18), s * 0.06, Paint()..color = const Color(0x44FFFFFF));
  }

  // ---------- 動態 ----------
  void _liquids(Canvas c, double s) {
    final lava = g.theme >= 3;
    for (var y = 0; y < rgRows; y++) {
      for (var x = 0; x < rgCols; x++) {
        if (g.grid[y][x] != '~') continue;
        final r = Rect.fromLTWH(x * s, y * s, s + 0.5, s + 0.5);
        final glow = 0.5 + 0.5 * math.sin(g.time * 2 + x * 0.7 + y);
        c.drawRect(
            r,
            Paint()
              ..color = lava
                  ? Color.lerp(const Color(0xFFD84315), const Color(0xFFFF9100), glow * 0.5)!
                  : Color.lerp(const Color(0xFF1565C0), const Color(0xFF29B6F6), glow * 0.3)!);
        final wave = Paint()
          ..color = (lava ? const Color(0xFFFFE082) : Colors.white).withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.035;
        for (var k = 0; k < 2; k++) {
          final p = Path();
          final yy = y * s + s * (0.3 + k * 0.4);
          for (var i = 0; i <= 6; i++) {
            final xx = x * s + i * s / 6;
            final dy = math.sin(g.time * 3 + i * 0.9 + x * 2 + k * 2) * s * 0.05;
            if (i == 0) {
              p.moveTo(xx, yy + dy);
            } else {
              p.lineTo(xx, yy + dy);
            }
          }
          c.drawPath(p, wave);
        }
        if (lava && _hash(x, y, (g.time * 1.5).floor()) < 0.25) {
          final ph = (g.time * 1.5) % 1;
          c.drawCircle(r.center + Offset((_hash(x, y, 9) - 0.5) * s * 0.5, 0), s * 0.08 * (1 - ph),
              Paint()..color = const Color(0xFFFFF59D).withValues(alpha: 1 - ph));
        }
      }
    }
  }

  void _door(Canvas c, double s) {
    final door = Rect.fromLTWH(3.6 * s, 0, 1.8 * s, 0.4 * s);
    if (g.cleared) {
      final pulse = 0.5 + 0.5 * math.sin(g.time * 5);
      c.drawRect(
          Rect.fromLTWH(3.3 * s, 0, 2.4 * s, 1.6 * s),
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [const Color(0xFF69F0AE).withValues(alpha: 0.35 + 0.2 * pulse), const Color(0x0069F0AE)],
            ).createShader(Rect.fromLTWH(3.3 * s, 0, 2.4 * s, 1.6 * s)));
      c.drawRect(door, Paint()..color = const Color(0xFF0D3B26));
      c.drawRect(door.deflate(2), Paint()..color = Color.lerp(const Color(0xFF00E676), Colors.white, pulse * 0.5)!);
      for (var i = 0; i < 2; i++) {
        final yy = (0.7 + i * 0.45) * s - ((g.time * 1.2) % 1) * s * 0.45;
        final a = (1 - i * 0.4) * (0.5 + 0.5 * pulse);
        final p = Path()
          ..moveTo(4.2 * s, yy + s * 0.18)
          ..lineTo(4.5 * s, yy)
          ..lineTo(4.8 * s, yy + s * 0.18);
        c.drawPath(
            p,
            Paint()
              ..color = Colors.white.withValues(alpha: a)
              ..style = PaintingStyle.stroke
              ..strokeWidth = s * 0.07
              ..strokeCap = StrokeCap.round);
      }
    } else {
      c.drawRect(door, Paint()..color = const Color(0xFF1A1110));
      for (var i = 0; i < 5; i++) {
        final xx = (3.75 + i * 0.37) * s;
        c.drawLine(Offset(xx, 0), Offset(xx, 0.4 * s), Paint()
          ..color = const Color(0xFF9E9E9E)
          ..strokeWidth = s * 0.07);
        c.drawCircle(Offset(xx, 0.4 * s), s * 0.05, Paint()..color = const Color(0xFF757575));
      }
    }
  }

  // 環境粒子：草原螢火蟲、熔岩火星、魔王城紫光（用時間公式算，不存狀態）
  void _ambient(Canvas c, double s, Size size) {
    final col = switch (g.theme) {
      0 => const Color(0xFFF0F4C3),
      1 => const Color(0xFFFFE0B2),
      2 => const Color(0xFFB2EBF2),
      3 => const Color(0xFFFF9100),
      _ => const Color(0xFFE1BEE7),
    };
    final rising = g.theme >= 3;
    for (var i = 0; i < 14; i++) {
      final sp = 0.15 + _hash(i, 1, 7) * 0.25;
      final ph = (g.time * sp + _hash(i, 2, 7)) % 1;
      final x = (_hash(i, 3, 7) * rgCols + math.sin(g.time * 0.7 + i) * 0.4) * s;
      final y = rising ? (1 - ph) * size.height : (_hash(i, 4, 7) * rgRows + math.cos(g.time * 0.5 + i) * 0.5) * s;
      final a = rising ? math.sin(ph * math.pi) : 0.5 + 0.5 * math.sin(g.time * 2 + i * 1.7);
      c.drawCircle(Offset(x, y), s * 0.09, Paint()..color = col.withValues(alpha: 0.15 * a));
      c.drawCircle(Offset(x, y), s * 0.035, Paint()..color = col.withValues(alpha: 0.7 * a));
    }
  }

  void _zones(Canvas c, double s) {
    for (final z in g.zones) {
      final k = 1 - (z.t / z.total).clamp(0.0, 1.0);
      final o = Offset(z.x * s, z.y * s);
      c.drawCircle(o, z.r * s, Paint()..color = Color.fromRGBO(255, 23, 68, 0.12 + 0.15 * k));
      c.drawCircle(o, z.r * s, Paint()
        ..color = const Color(0xDDFF1744)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
      c.drawCircle(o, z.r * s * k, Paint()..color = const Color(0x55FF5722));
      // 從天而降的石頭影子
      final rock = o.translate(0, -(1 - k) * s * 3);
      c.drawCircle(rock, s * 0.25 * (0.5 + k * 0.5), Paint()..color = const Color(0xFF5D4037).withValues(alpha: k));
    }
  }

  void _portals(Canvas c, double s) {
    for (final p in g.portals) {
      final o = Offset(p.x * s, p.y * s);
      final k = (1 - p.t).clamp(0.0, 1.0);
      final r = s * (0.25 + 0.3 * k);
      c.drawCircle(o, r * 1.4, Paint()..color = const Color(0x337C4DFF));
      c.drawOval(Rect.fromCenter(center: o, width: r * 2, height: r * 1.2), Paint()..color = const Color(0xAA311B92));
      for (var i = 0; i < 3; i++) {
        c.drawArc(
            Rect.fromCenter(center: o, width: r * 2 * (1 - i * 0.25), height: r * 1.2 * (1 - i * 0.25)),
            g.time * 6 + i * 2, 2.2, false,
            Paint()
              ..color = (p.elite ? const Color(0xFFFFD54F) : const Color(0xFFB388FF)).withValues(alpha: 0.9)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
      }
    }
  }

  void _telegraphs(Canvas c, double s) {
    for (final e in g.en) {
      final o = Offset(e.x * s, e.y * s);
      final dashing = (e.type == 'w' || e.type == 'B2') && e.st == 1 || e.type == 'B5' && e.st == 5;
      if (dashing) {
        final len = s * 6;
        c.save();
        c.translate(o.dx, o.dy);
        c.rotate(e.ang);
        final w = e.r * 2 * s;
        final lane = Rect.fromLTWH(0, -w / 2, len, w);
        c.drawRect(
            lane,
            Paint()
              ..shader = const LinearGradient(colors: [Color(0x88FF1744), Color(0x00FF1744)]).createShader(lane));
        for (var i = 0; i < 4; i++) {
          final xx = ((g.time * 4 + i / 4) % 1) * len;
          final p = Path()
            ..moveTo(xx, -w * 0.3)
            ..lineTo(xx + w * 0.3, 0)
            ..lineTo(xx, w * 0.3);
          c.drawPath(
              p,
              Paint()
                ..color = Colors.white.withValues(alpha: 0.5 * (1 - xx / len))
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2);
        }
        c.restore();
      } else if (e.type == 'a' && e.st == 1) {
        final dir = Offset(math.cos(e.ang), math.sin(e.ang));
        final p = Paint()
          ..color = const Color(0xBBFF1744)
          ..strokeWidth = 1.5;
        for (var d = 0.4; d < 12; d += 0.35) {
          c.drawLine(o + dir * d * s, o + dir * (d + 0.18) * s, p);
        }
      } else if (e.type == 'B1' && (e.st == 1 || e.st == 2)) {
        final t = Offset(e.tx * s, e.ty * s);
        final pulse = 0.5 + 0.5 * math.sin(g.time * 16);
        c.drawCircle(t, e.r * s * 1.15, Paint()..color = Color.fromRGBO(255, 23, 68, 0.2 + 0.15 * pulse));
        c.drawCircle(t, e.r * s * 1.15, Paint()
          ..color = const Color(0xDDFF1744)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
      }
    }
  }

  void _enemy(Canvas c, RgEnemy e, double s) {
    var o = Offset(e.x * s, e.y * s);
    final sz = e.r * 2.9 * s;
    final fade = (e.spawnT / 0.5).clamp(0.0, 1.0);
    if (e.airborne) {
      final k = (e.t / 0.7).clamp(0.0, 1.0);
      c.drawOval(Rect.fromCenter(center: o, width: e.r * 2 * s * (1 - 0.4 * math.sin(k * math.pi)), height: e.r * s * 0.7),
          Paint()..color = const Color(0x66000000));
      o = o.translate(0, -math.sin(k * math.pi) * s * 2.2);
    }
    if (e.elite) {
      c.drawCircle(o, e.r * s * 1.4, Paint()..color = const Color(0x33FFD54F));
      c.drawArc(Rect.fromCircle(center: o, radius: e.r * s * 1.35), g.time * 3, 4.2, false,
          Paint()
            ..color = const Color(0xCCFFD54F)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
    if (e.windup) {
      final pulse = 0.5 + 0.5 * math.sin(g.time * 30);
      c.drawCircle(o, e.r * s * 1.35, Paint()..color = Color.fromRGBO(255, 40, 40, 0.18 + 0.25 * pulse));
      _text(c, '!', o.translate(0, -e.r * s * 2.1), s * 0.45, const Color(0xFFFF1744));
    }
    c.save();
    c.translate(o.dx - sz / 2, o.dy - sz / 2 - sz * 0.08);
    MonsterPainter(
      kind: e.kind,
      band: rgThemeBands[g.theme],
      boss: e.boss,
      flash: e.flash > 0 ? 0.8 : 0,
      opacity: fade,
      t: g.time + e.seed,
    ).paint(c, Size(sz, sz));
    c.restore();
    if (e.frozeT > 0) {
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCircle(center: o, radius: e.r * s * 1.1), Radius.circular(e.r * s * 0.3)),
          Paint()..color = const Color(0x8881D4FA));
    } else if (e.slowT > 0) {
      c.drawCircle(o, e.r * s * 1.1, Paint()
        ..color = const Color(0x8881D4FA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
    if (e.burnT > 0) {
      for (var i = 0; i < 3; i++) {
        final ph = (g.time * 2 + i / 3) % 1;
        c.drawCircle(o + Offset((i - 1) * e.r * s * 0.5, -ph * e.r * s * 1.4), s * 0.06 * (1 - ph),
            Paint()..color = Color.fromRGBO(255, 109 + (ph * 100).round(), 0, 1 - ph));
      }
    }
    if (e.poison > 0) {
      final ph = (g.time * 1.5) % 1;
      c.drawCircle(o + Offset(-e.r * s * 0.6, -ph * e.r * s), s * 0.05, Paint()..color = const Color(0xFF76FF03).withValues(alpha: 1 - ph));
    }
    if (!e.boss && e.hp < e.maxHp && fade >= 1) {
      final w = e.r * 2.2 * s;
      final r = Rect.fromLTWH(o.dx - w / 2, o.dy - e.r * s * 1.6, w, s * 0.1);
      c.drawRRect(RRect.fromRectAndRadius(r.inflate(1), const Radius.circular(2)), Paint()..color = Colors.black87);
      c.drawRect(Rect.fromLTWH(r.left, r.top, w * (e.hp / e.maxHp).clamp(0.0, 1.0), r.height),
          Paint()..color = e.elite ? const Color(0xFFFFB300) : const Color(0xFFFF5252));
    }
  }

  void _player(Canvas c, double s, RgHero p) {
    final o0 = Offset(p.x * s, p.y * s);
    final r = g.pr * s;
    final blue = p.idx == 1; // 合作模式第二位玩家：藍色披風
    final name = names != null && p.idx < names!.length ? names![p.idx] : null;
    if (p.down) {
      _downHero(c, s, p, o0, r, name);
      return;
    }
    // 腳下光圈
    c.drawOval(Rect.fromCenter(center: o0 + Offset(0, r * 0.85), width: r * 2.8, height: r * 1.0),
        Paint()
          ..color = (blue ? const Color(0xFF82B1FF) : const Color(0xFF64FFDA)).withValues(alpha: p == g.me ? 0.55 : 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    // 旋轉刀刃
    final orbs = 2 * p.st.lv('orb');
    for (var i = 0; i < orbs; i++) {
      final a = g.orbAng + 2 * math.pi * i / orbs;
      final p = o0 + Offset(math.cos(a), math.sin(a)) * 1.15 * s;
      c.drawCircle(p, s * 0.24, Paint()..color = const Color(0x2280DEEA));
      c.save();
      c.translate(p.dx, p.dy);
      c.rotate(g.time * 12);
      final blade = Path()
        ..moveTo(0, -s * 0.2)
        ..lineTo(s * 0.07, 0)
        ..lineTo(0, s * 0.2)
        ..lineTo(-s * 0.07, 0)
        ..close();
      c.drawPath(blade, Paint()..color = const Color(0xFFE0F7FA));
      c.rotate(math.pi / 2);
      c.drawPath(blade, Paint()..color = const Color(0xFF80DEEA));
      c.restore();
    }
    if (p.inv > 0 && p.hurtT > 0 && (g.time * 20).floor().isOdd && g.phase == RgPhase.play) return;
    final bob = p.moving ? math.sin(g.time * 16).abs() * r * 0.25 : 0.0;
    final o = o0.translate(0, -bob);
    c.drawOval(Rect.fromCenter(center: o0 + Offset(0, r * 0.85), width: r * 1.8, height: r * 0.6), Paint()..color = const Color(0x66000000));
    final fa = math.atan2(p.faceY, p.faceX);
    // 披風（往面向的反方向飄）
    final back = Offset(-p.faceX, -p.faceY);
    final sway = math.sin(g.time * (p.moving ? 14 : 3)) * r * 0.15;
    final cape = Path()
      ..moveTo(o.dx - r * 0.75, o.dy - r * 0.2)
      ..quadraticBezierTo(o.dx + back.dx * r * 1.4 - r * 0.6 + sway, o.dy + back.dy * r * 0.6 + r * 1.0,
          o.dx + back.dx * r * 0.9 + sway, o.dy + r * 1.05)
      ..quadraticBezierTo(o.dx + back.dx * r * 1.4 + r * 0.6 + sway, o.dy + back.dy * r * 0.6 + r * 1.0, o.dx + r * 0.75, o.dy - r * 0.2)
      ..close();
    c.drawPath(cape, Paint()..color = blue ? const Color(0xFF0D47A1) : const Color(0xFF1B5E20));
    // 身體
    c.drawOval(Rect.fromCenter(center: o + Offset(0, r * 0.25), width: r * 1.5, height: r * 1.3),
        Paint()..shader = LinearGradient(colors: blue ? const [Color(0xFF64B5F6), Color(0xFF1565C0)] : const [Color(0xFF66BB6A), Color(0xFF2E7D32)]).createShader(Rect.fromCircle(center: o, radius: r)));
    c.drawLine(o + Offset(-r * 0.6, r * 0.25), o + Offset(r * 0.6, r * 0.25), Paint()
      ..color = const Color(0xFF6D4C41)
      ..strokeWidth = r * 0.18);
    // 頭＋兜帽
    final head = o + Offset(0, -r * 0.45);
    c.drawCircle(head, r * 0.62, Paint()..color = blue ? const Color(0xFF1565C0) : const Color(0xFF2E7D32));
    c.drawCircle(head + Offset(p.faceX * r * 0.12, p.faceY * r * 0.08 + r * 0.05), r * 0.45, Paint()..color = const Color(0xFFFFCC80));
    final hood = Path()
      ..moveTo(head.dx - r * 0.66, head.dy + r * 0.05)
      ..quadraticBezierTo(head.dx - r * 0.5, head.dy - r * 0.8, head.dx + r * 0.15, head.dy - r * 1.05)
      ..quadraticBezierTo(head.dx + r * 0.3, head.dy - r * 0.6, head.dx + r * 0.66, head.dy + r * 0.05)
      ..quadraticBezierTo(head.dx, head.dy - r * 0.45, head.dx - r * 0.66, head.dy + r * 0.05);
    c.drawPath(hood, Paint()..color = blue ? const Color(0xFF1E88E5) : const Color(0xFF388E3C));
    c.drawCircle(head + Offset(r * 0.18, -r * 1.0), r * 0.1, Paint()..color = const Color(0xFFFF5252));
    if (p.faceY < 0.6) {
      final eye = Offset(p.faceX, p.faceY) * r * 0.15;
      for (final dx in [-0.17, 0.17]) {
        c.drawCircle(head + Offset(dx * r, r * 0.05) + eye, r * 0.075, Paint()..color = const Color(0xFF3E2723));
      }
    }
    // 弓：快射擊時拉弦
    final pull = p.moving ? 0.0 : (1 - (p.shootCd / p.st.interval).clamp(0.0, 1.0));
    c.save();
    c.translate(o.dx, o.dy + r * 0.1);
    c.rotate(fa);
    final bowR = r * 0.85;
    final bc = Offset(r * 0.55, 0);
    c.drawArc(Rect.fromCircle(center: bc, radius: bowR), -1.15, 2.3, false,
        Paint()
          ..color = const Color(0xFF8D6E63)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.2
          ..strokeCap = StrokeCap.round);
    final tipX = bc.dx + math.cos(1.15) * bowR, tipY = math.sin(1.15) * bowR;
    final nock = Offset(tipX - pull * r * 0.55, 0);
    final sp = Paint()
      ..color = Colors.white70
      ..strokeWidth = 1;
    c.drawLine(Offset(tipX, -tipY), nock, sp);
    c.drawLine(Offset(tipX, tipY), nock, sp);
    if (pull > 0.3 && g.en.isNotEmpty) {
      c.drawLine(nock, Offset(bc.dx + bowR + r * 0.2, 0), Paint()
        ..color = const Color(0xFFFFF59D)
        ..strokeWidth = r * 0.1);
    }
    c.restore();
    // 血條
    final w = s * 0.95;
    final hb = Rect.fromLTWH(o0.dx - w / 2, o0.dy + r * 1.4, w, s * 0.11);
    c.drawRRect(RRect.fromRectAndRadius(hb.inflate(1), const Radius.circular(3)), Paint()..color = Colors.black87);
    final frac = (p.st.hp / p.st.maxHp).clamp(0.0, 1.0);
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(hb.left, hb.top, w * frac, hb.height), const Radius.circular(2)),
        Paint()..color = frac < 0.3 ? const Color(0xFFFF5252) : const Color(0xFF00E676));
      if (name != null) _text(c, name, o0.translate(0, -r * 2.3), s * 0.2, blue ? const Color(0xFF82B1FF) : const Color(0xFFB9F6CA));
  }

  /// 合作模式倒地：躺著、灰色，旁邊一圈是隊友扶起來的進度
  void _downHero(Canvas c, double s, RgHero p, Offset o, double r, String? name) {
    c.drawOval(Rect.fromCenter(center: o + Offset(0, r * 0.4), width: r * 2.4, height: r * 1.1), Paint()..color = const Color(0xAA607D8B));
    c.drawCircle(o + Offset(-r * 0.9, r * 0.2), r * 0.5, Paint()..color = const Color(0xFF90A4AE));
    final k = (p.rescue / 2.5).clamp(0.0, 1.0);
    final ring = Rect.fromCircle(center: o, radius: s * 1.3);
    c.drawCircle(o, s * 1.3, Paint()
      ..color = const Color(0x5569F0AE)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    if (k > 0) {
      c.drawArc(ring, -math.pi / 2, 2 * math.pi * k, false, Paint()
        ..color = const Color(0xFF69F0AE)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4);
    }
    final blink = 0.6 + 0.4 * math.sin(g.time * 6);
    _text(c, '救我！', o.translate(0, -r * 2.0), s * 0.28, Color.fromRGBO(255, 82, 82, blink));
    if (name != null) _text(c, name, o.translate(0, r * 1.6), s * 0.2, Colors.white70);
  }

  void _gems(Canvas c, double s) {
    for (final gm in g.gems) {
      final o = Offset(gm.x * s, gm.y * s);
      final r = s * 0.09;
      c.drawCircle(o, r * 2, Paint()..color = const Color(0x3340C4FF));
      final p = Path()
        ..moveTo(o.dx, o.dy - r * 1.3)
        ..lineTo(o.dx + r, o.dy)
        ..lineTo(o.dx, o.dy + r * 1.3)
        ..lineTo(o.dx - r, o.dy)
        ..close();
      c.drawPath(p, Paint()..color = const Color(0xFF40C4FF));
      c.drawLine(o - Offset(r * 0.4, r * 0.4), o, Paint()
        ..color = Colors.white
        ..strokeWidth = 1);
    }
  }

  void _fx(Canvas c, double s) {
    for (final f in g.fx) {
      final k = (f.t / f.life).clamp(0.0, 1.0);
      final o = Offset(f.x * s, f.y * s);
      final col = Color(f.color);
      switch (f.kind) {
        case 0:
          c.drawCircle(o, f.size * s * (1 - k * 0.6), Paint()..color = col.withValues(alpha: 1 - k));
        case 1:
          c.drawCircle(o, f.size * s * (0.4 + k * 0.8), Paint()
            ..color = col.withValues(alpha: 0.8 * (1 - k))
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.08 * (1 - k) + 1);
        case 2:
          final pos = Offset(f.x * s, f.y * s);
          final col2 = Rect.fromCenter(center: pos.translate(0, -s * 1.5), width: s * (1.2 - k * 0.6), height: s * 3.5);
          c.drawRect(
              col2,
              Paint()
                ..shader = LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [col.withValues(alpha: 0.6 * (1 - k)), col.withValues(alpha: 0)],
                ).createShader(col2));
          c.drawCircle(pos, s * (0.5 + k * 1.5), Paint()
            ..color = col.withValues(alpha: 1 - k)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
          if (k < 0.8) _text(c, 'LEVEL UP!', pos.translate(0, -s * (1.2 + k)), s * 0.42, col.withValues(alpha: 1 - k));
      }
    }
  }

  void _bullets(Canvas c, double s) {
    for (final b in g.bl) {
      final o = Offset(b.x * s, b.y * s);
      final sp = math.sqrt(b.vx * b.vx + b.vy * b.vy) + 1e-6;
      final dir = Offset(b.vx / sp, b.vy / sp);
      if (b.mine) {
        final tail = o - dir * s * 0.42;
        c.drawLine(o - dir * s * 0.9, tail, Paint()
          ..color = const Color(0x33FFF59D)
          ..strokeWidth = s * 0.05);
        c.drawLine(tail, o, Paint()
          ..color = const Color(0xFFD7CCC8)
          ..strokeWidth = s * 0.045);
        final nrm = Offset(-dir.dy, dir.dx);
        final head = Path()
          ..moveTo(o.dx + dir.dx * s * 0.12, o.dy + dir.dy * s * 0.12)
          ..lineTo(o.dx + nrm.dx * s * 0.06, o.dy + nrm.dy * s * 0.06)
          ..lineTo(o.dx - nrm.dx * s * 0.06, o.dy - nrm.dy * s * 0.06)
          ..close();
        c.drawPath(head, Paint()..color = Colors.white);
        final fl = Paint()
          ..color = const Color(0xFFFF7043)
          ..strokeWidth = s * 0.035;
        c.drawLine(tail, tail - dir * s * 0.1 + nrm * s * 0.07, fl);
        c.drawLine(tail, tail - dir * s * 0.1 - nrm * s * 0.07, fl);
        continue;
      }
      final r = b.r * s;
      final (core, glow) = switch (b.style) {
        2 => (const Color(0xFFEA80FC), const Color(0xFFAA00FF)),
        3 => (const Color(0xFF8D6E63), const Color(0xFFFF6D00)),
        4 => (const Color(0xFFFFE082), const Color(0xFFFF3D00)),
        5 => (const Color(0xFFE0F7FA), const Color(0xFF00E5FF)),
        _ => (const Color(0xFFFF8A80), const Color(0xFFFF1744)),
      };
      if (b.style == 4 || b.style == 3) {
        for (var i = 1; i <= 3; i++) {
          c.drawCircle(o - dir * (r * i * 0.9), r * (1 - i * 0.22), Paint()..color = glow.withValues(alpha: 0.35 - i * 0.08));
        }
      }
      final pulse = 1 + 0.12 * math.sin(g.time * 20 + b.x * 3);
      c.drawCircle(o, r * 1.9 * pulse, Paint()..color = glow.withValues(alpha: 0.18));
      c.drawCircle(o, r * 1.35, Paint()..color = glow.withValues(alpha: 0.55));
      c.drawCircle(o, r, Paint()..color = core);
      if (b.style == 5) {
        // 穿牆彈：外面多一圈虛線般的亮框，一眼看得出不一樣
        c.drawCircle(o, r * 1.6 * pulse, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.3
          ..color = Colors.white.withValues(alpha: 0.7));
      }
      c.drawCircle(o - Offset(r * 0.3, r * 0.3), r * 0.38, Paint()..color = Colors.white.withValues(alpha: 0.85));
    }
  }

  void _text(Canvas c, String t, Offset center, double size, Color color, {bool outline = true}) {
    if (outline) {
      final tp2 = TextPainter(
        text: TextSpan(
          text: t,
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w900,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(2.0, size * 0.14)
              ..color = Colors.black.withValues(alpha: color.a * 0.9),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp2.paint(c, center - Offset(tp2.width / 2, tp2.height / 2));
    }
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w900)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _floats(Canvas c, double s) {
    for (final f in g.floats) {
      final a = (1 - f.t / 0.9).clamp(0.0, 1.0);
      final pop = f.t < 0.1 ? 1 + (0.1 - f.t) * 4 : 1.0;
      _text(c, f.s, Offset(f.x * s, f.y * s), s * (f.big ? 0.42 : 0.3) * pop, Color(f.color).withValues(alpha: a));
    }
  }

  void _heart(Canvas c, Offset o, double r) {
    final bob = math.sin(g.time * 4) * r * 0.25;
    o = o.translate(0, bob);
    c.drawCircle(o, r * 1.8, Paint()..color = const Color(0x33FF1744));
    final p = Path()
      ..moveTo(o.dx, o.dy + r * 0.9)
      ..cubicTo(o.dx - r * 1.6, o.dy - r * 0.2, o.dx - r * 0.6, o.dy - r * 1.2, o.dx, o.dy - r * 0.4)
      ..cubicTo(o.dx + r * 0.6, o.dy - r * 1.2, o.dx + r * 1.6, o.dy - r * 0.2, o.dx, o.dy + r * 0.9);
    c.drawPath(p, Paint()..color = const Color(0xFFFF1744));
    c.drawCircle(o + Offset(-r * 0.45, -r * 0.35), r * 0.2, Paint()..color = Colors.white70);
  }

  void _vignette(Canvas c, Size size) {
    final rect = Offset.zero & size;
    c.drawRect(
        rect,
        Paint()
          ..shader = const RadialGradient(radius: 0.85, colors: [Color(0x00000000), Color(0x00000000), Color(0x77000000)], stops: [0, 0.6, 1])
              .createShader(rect));
    final low = g.st.hp < g.st.maxHp * 0.3 && g.phase == RgPhase.play;
    final hurt = (g.hurtT / 0.35).clamp(0.0, 1.0);
    final lowA = low ? 0.25 + 0.2 * math.sin(g.time * 6) : 0.0;
    final a = math.max(hurt * 0.55, lowA);
    if (a > 0.01) {
      c.drawRect(
          rect,
          Paint()
            ..shader = RadialGradient(
              radius: 0.8,
              colors: [const Color(0x00FF1744), Color.fromRGBO(255, 23, 68, a)],
              stops: const [0.55, 1],
            ).createShader(rect));
    }
  }

  void _banner(Canvas c, Size size, double s) {
    final t = g.roomTime;
    if (t > 2.2) return;
    final a = t < 0.3 ? t / 0.3 : (t > 1.7 ? (2.2 - t) / 0.5 : 1.0);
    final center = Offset(size.width / 2, size.height * 0.42);
    if (g.isBossRoom) {
      final band = Rect.fromCenter(center: center, width: size.width, height: s * 1.6);
      c.drawRect(
          band,
          Paint()
            ..shader = LinearGradient(colors: [
              const Color(0x00000000),
              Colors.black.withValues(alpha: 0.75 * a),
              const Color(0x00000000),
            ]).createShader(band));
      _text(c, '⚠ 頭目出現 ⚠', center.translate(0, -s * 0.35), s * 0.32, const Color(0xFFFF5252).withValues(alpha: a));
      _text(c, g.boss?.name ?? '', center.translate(0, s * 0.25), s * 0.6, const Color(0xFFFFD54F).withValues(alpha: a));
    } else {
      _text(c, '${g.chapter + 1}-${g.room + 1}', center, s * 0.7, Colors.white.withValues(alpha: a * 0.85));
      if (g.wavesLeft > 0 && g.room > 0) {
        _text(c, '還有 ${g.wavesLeft} 波增援', center.translate(0, s * 0.65), s * 0.28, const Color(0xFFB388FF).withValues(alpha: a));
      }
    }
  }

  void _joystick(Canvas c) {
    final (o, n) = joy();
    if (o == null || n == null) return;
    c.drawCircle(o, 42, Paint()..color = const Color(0x22FFFFFF));
    c.drawCircle(o, 42, Paint()
      ..color = const Color(0x66FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    var d = n - o;
    if (d.distance > 42) d = d / d.distance * 42;
    c.drawCircle(o + d, 18, Paint()..color = const Color(0x99FFFFFF));
    c.drawCircle(o + d, 18, Paint()
      ..color = const Color(0xCCFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(covariant _ArenaPainter old) => true;
}

/// 雙人合作的 WebSocket（/ws/rogue2）：大廳、開房、配對，之後只轉送 {t:r, d} 給對方
class _CoopNet {
  final ApiClient api;
  final void Function(Map<String, dynamic>) onMsg;
  final VoidCallback onChanged;
  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  bool connected = false;
  bool _closed = false;
  bool stayConnected = false; // 遊戲中：斷線就自動重連（伺服器會留房間 90 秒）
  String? error;
  String? waiting; // 自己開的房間號碼（等人加入中）
  List<Map<String, dynamic>> rooms = [];
  _CoopNet(this.api, {required this.onMsg, required this.onChanged});

  Future<void> connect() async {
    error = null;
    onChanged();
    try {
      final (url, key, token) = await api.rogueCoopConnectInfo();
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
      _retry();
    }
    onChanged();
  }

  void _retry() {
    if (stayConnected && !_closed) Future.delayed(const Duration(seconds: 2), () => _closed || connected ? null : connect());
  }

  void _onDone() {
    if (_closed) return;
    connected = false;
    waiting = null;
    _ch = null;
    error = '連線中斷了';
    if (stayConnected) {
      onMsg({'t': 'drop'});
      _retry();
    } else {
      onMsg({'t': 'gone', 'msg': '連線中斷了'});
    }
    onChanged();
  }

  void _onRaw(dynamic raw) {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['t']) {
      case 'lobby':
        rooms = [for (final r in m['rooms'] as List) Map<String, dynamic>.from(r as Map)];
        onChanged();
      case 'waiting':
        waiting = '${m['room']}';
        onChanged();
      case 'start':
        waiting = null;
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
