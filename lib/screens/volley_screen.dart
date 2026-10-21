import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_client.dart';
import '../widgets/monster_art.dart';

// 怪物打排球：仿《皮卡丘打排球》的連線雙人對戰，角色是百層塔的原創怪物。
// 物理全部在伺服器（25Hz），這裡只傳按鍵、把收到的位置補間畫出來。

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
  int _server = 0;
  _Snap? _prev, _cur;
  Map<String, dynamic>? _endMsg;
  final List<_Fx> _fx = [];
  double _shake = 0;
  String _banner = '';
  double _bannerT = 0;
  double _ballAng = 0;
  final List<Offset> _trail = [];

  // 輸入
  final Set<LogicalKeyboardKey> _keys = {};
  bool _tl = false, _tr = false, _tu = false, _th = false; // 觸控按鈕
  List<int> _lastSent = [0, 0, 0, 0];
  Timer? _inputTimer;

  late final Ticker _ticker;
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  Duration _lastTick = Duration.zero;
  double _clock = 0;
  Duration _now = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _connect();
    _inputTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_phase == _Phase.playing) _sendInput(force: true);
    });
    _lobbyTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_phase == _Phase.lobby) _send({'t': 'lobby'});
    });
  }

  @override
  void dispose() {
    _closing = true;
    _lobbyTimer?.cancel();
    _inputTimer?.cancel();
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
        setState(() {
          _phase = _Phase.playing;
          _side = m['side'] as int;
          _betNow = (m['bet'] as num).toInt();
          _pointsNow = m['points'] as int;
          _me = (m['me'] as Map).cast<String, dynamic>();
          _opp = (m['opp'] as Map).cast<String, dynamic>();
          _score = [0, 0];
          _prev = _cur = null;
          _endMsg = null;
          _fx.clear();
          _trail.clear();
          _showBanner('準備！');
        });
        _sendInput(force: true);
      case 's':
        _onFrame(m);
      case 'end':
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
    _prev = _cur;
    _cur = _Snap(p, b, _now);
    final sc = (m['sc'] as List).cast<int>();
    final ev = (m['ev'] as List).cast<int>();
    final scored = sc[0] != _score[0] || sc[1] != _score[1];
    final sv = m['sv'] as int;
    final hudChanged = scored || sv != _server;
    _score = sc;
    _server = sv;
    for (final e in ev) {
      if (e == 1 || e == 2) _fx.add(_Fx(b[0], b[1], e));
      if (e == 2) _shake = 0.25;
      if (e == 4) _fx.add(_Fx(b[0], _floor - 6, 4));
      if (e == 5) _showBanner('開球！');
    }
    if (scored) _showBanner('${sc[0]} : ${sc[1]}');
    if (hudChanged && mounted) setState(() {});
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
    if (_bannerT > 0) _bannerT -= dt;
    if (_shake > 0) _shake -= dt;
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
    return ((_now - c.at).inMicroseconds / 40000.0).clamp(0.0, 1.0);
  }

  Offset _ballPos() {
    final c = _cur, p = _prev;
    if (c == null) return Offset.zero;
    if (p == null) return Offset(c.b[0], c.b[1]);
    final a = _alpha;
    return Offset(p.b[0] + (c.b[0] - p.b[0]) * a, p.b[1] + (c.b[1] - p.b[1]) * a);
  }

  // ---------------------------------------------------------------- 動作
  void _create() => _send({'t': 'create', 'bet': _bet, 'points': _points, 'kind': _myKind, 'band': _myBand});
  void _join(Map room) => _send({'t': 'join', 'room': room['id'], 'kind': _myKind, 'band': _myBand});

  Future<bool> _confirmLeave() async {
    if (_phase != _Phase.playing) return true;
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
              child: LayoutBuilder(builder: (c, box) => CustomPaint(size: box.biggest, painter: _VolleyPainter(this))),
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
  _VolleyPainter(this.s) : super(repaint: s._repaint);

  double _h(int i, int k) {
    var h = (i * 73856093) ^ (k * 19349663);
    h = (h ^ (h >> 13)) * 1274126177;
    return ((h ^ (h >> 16)) & 0xFFFF) / 0xFFFF;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / _cw;
    canvas.save();
    if (s._shake > 0) {
      canvas.translate((math.sin(s._clock * 90) * 3) * s._shake * 4 * k, (math.cos(s._clock * 70) * 2) * s._shake * 4 * k);
    }
    canvas.scale(k);
    _background(canvas);
    _court(canvas);
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

  void _background(Canvas canvas) {
    final sky = const Rect.fromLTWH(0, 0, _cw, _floor);
    canvas.drawRect(sky, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF3FA9F5), Color(0xFF9BD8FF), Color(0xFFFFF0C9)]).createShader(sky));
    // 太陽
    canvas.drawCircle(const Offset(360, 56), 46, Paint()..shader = const RadialGradient(colors: [Color(0x99FFF59D), Color(0x00FFF59D)]).createShader(Rect.fromCircle(center: const Offset(360, 56), radius: 46)));
    canvas.drawCircle(const Offset(360, 56), 17, Paint()..color = const Color(0xFFFFEB3B));
    // 遠山
    final hills = Path()..moveTo(0, 215);
    for (var x = 0.0; x <= _cw; x += 12) {
      hills.lineTo(x, 200 - 22 * math.sin(x / 70 + 1) - 12 * math.sin(x / 26));
    }
    hills..lineTo(_cw, _floor)..lineTo(0, _floor)..close();
    canvas.drawPath(hills, Paint()..color = const Color(0xFF6FB48B));
    final hills2 = Path()..moveTo(0, 230);
    for (var x = 0.0; x <= _cw; x += 12) {
      hills2.lineTo(x, 224 - 14 * math.sin(x / 55 + 3) - 8 * math.sin(x / 19));
    }
    hills2..lineTo(_cw, _floor)..lineTo(0, _floor)..close();
    canvas.drawPath(hills2, Paint()..color = const Color(0xFF4E9E6B));
    // 雲（緩慢飄）
    for (var i = 0; i < 4; i++) {
      final x = ((_h(i, 1) * _cw + s._clock * (4 + i * 2)) % (_cw + 120)) - 60;
      final y = 26 + _h(i, 2) * 70;
      final cp = Paint()..color = Colors.white.withValues(alpha: 0.9);
      canvas.drawOval(Rect.fromCenter(center: Offset(x, y), width: 62, height: 20), cp);
      canvas.drawOval(Rect.fromCenter(center: Offset(x - 14, y - 7), width: 34, height: 22), cp);
      canvas.drawOval(Rect.fromCenter(center: Offset(x + 12, y - 9), width: 30, height: 22), cp);
    }
  }

  void _court(Canvas canvas) {
    // 沙地球場
    final g = Rect.fromLTWH(0, _floor, _cw, _courtH - _floor);
    canvas.drawRect(g, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFF1D79A), Color(0xFFD9B873)]).createShader(g));
    for (var i = 0; i < 40; i++) {
      canvas.drawCircle(Offset(_h(i, 5) * _cw, _floor + 3 + _h(i, 6) * (_courtH - _floor - 5)), 0.9, Paint()..color = const Color(0x33806040));
    }
    canvas.drawLine(const Offset(0, _floor), const Offset(_cw, _floor), Paint()..color = Colors.white..strokeWidth = 2);
    // 網：柱子 + 網格
    final post = Paint()..color = const Color(0xFF5D4037);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(_netX - 4, _netTop - 6, 8, _floor - _netTop + 8), const Radius.circular(3)), post);
    final mesh = Paint()..color = const Color(0xCCFFFFFF)..strokeWidth = 0.8;
    for (var y = _netTop + 4; y < _floor - 4; y += 7) {
      canvas.drawLine(Offset(_netX - 13, y), Offset(_netX + 13, y), mesh);
    }
    for (var x = _netX - 12; x <= _netX + 12; x += 6) {
      canvas.drawLine(Offset(x, _netTop + 2), Offset(x, _floor - 6), mesh);
    }
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(_netX - 14, _netTop - 2, 28, 7), const Radius.circular(3)), Paint()..color = Colors.white);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(_netX - 14, _netTop - 2, 28, 7), const Radius.circular(3)), Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0xFFB71C1C));
    canvas.drawCircle(const Offset(_netX, _netTop - 8), 5, Paint()..color = const Color(0xFFFFD54F));
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
      final st = c.p[i][2].toInt();
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
      MonsterPainter(kind: look['kind'] as int, band: look['band'] as int, t: s._clock + i).paint(canvas, const Size(sz, sz));
      canvas.restore();
      if (i == s._side) {
        // 自己頭上的小箭頭
        final tp = Offset(x, y - 50 + math.sin(s._clock * 6) * 2);
        canvas.drawPath(Path()..moveTo(tp.dx - 6, tp.dy - 8)..lineTo(tp.dx + 6, tp.dy - 8)..lineTo(tp.dx, tp.dy)..close(), Paint()..color = const Color(0xFFFFD54F));
      }
    }
  }

  void _ball(Canvas canvas) {
    final pos = s._ballPos();
    // 殘影
    for (var i = 0; i < s._trail.length; i++) {
      final t = (i + 1) / (s._trail.length + 1);
      canvas.drawCircle(s._trail[i], _ballR * (0.4 + 0.5 * t), Paint()..color = Colors.white.withValues(alpha: 0.12 * t));
    }
    // 影子
    final hh = (_floor - pos.dy).clamp(0.0, 300.0);
    canvas.drawOval(Rect.fromCenter(center: Offset(pos.dx, _floor + 4), width: 36 - hh * 0.06, height: 8), Paint()..color = Colors.black.withValues(alpha: (0.3 - hh * 0.0008).clamp(0.05, 0.3)));
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    canvas.rotate(s._ballAng);
    canvas.drawCircle(Offset.zero, _ballR, Paint()..shader = const RadialGradient(center: Alignment(-0.4, -0.4), colors: [Colors.white, Color(0xFFE8E8E8)]).createShader(Rect.fromCircle(center: Offset.zero, radius: _ballR)));
    final seam = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.2..color = const Color(0xFF1976D2);
    final seam2 = Paint()..style = PaintingStyle.stroke..strokeWidth = 2.2..color = const Color(0xFFFFC107);
    canvas.drawArc(Rect.fromCircle(center: const Offset(-_ballR * 0.9, 0), radius: _ballR * 1.1), -0.9, 1.8, false, seam);
    canvas.drawArc(Rect.fromCircle(center: const Offset(_ballR * 0.9, 0), radius: _ballR * 1.1), math.pi - 0.9, 1.8, false, seam2);
    canvas.drawArc(Rect.fromCircle(center: const Offset(0, -_ballR * 0.9), radius: _ballR * 1.1), 0.7, 1.75, false, seam);
    canvas.drawCircle(Offset.zero, _ballR, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = const Color(0xFF455A64));
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
  bool shouldRepaint(covariant _VolleyPainter old) => true;
}
