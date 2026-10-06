import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../widgets/casino_bet.dart';
import '../widgets/casino_music.dart';

final _money = NumberFormat('#,##0');

// 網頁版老虎機：3 轉輪 × 3 列、5 條線。單人玩、不用入座。
// 每次旋轉的結果（停輪位置、中獎線、派彩）全由伺服器抽出並入帳，這個畫面只負責「演出」：
// 按下旋轉就先讓轉輪空轉，等伺服器回傳結果後，三個轉輪依序減速、停在伺服器指定的位置。
class SlotScreen extends StatefulWidget {
  const SlotScreen({super.key});

  @override
  State<SlotScreen> createState() => _SlotScreenState();
}

enum _Mode { idle, free, stopping, bounce }

class _Reel {
  double pos; // 轉輪位置（輪帶索引，浮點數）：輪帶第 k 格畫在 y = (pos - k) * 格高，所以 pos 增加 = 往下轉
  _Mode mode = _Mode.idle;
  double from = 0, dist = 0, t0 = 0, dur = 1, stopAt = 0;
  double bounceT0 = 0;
  _Reel(this.pos);
}

class _SlotScreenState extends State<SlotScreen>
    with SingleTickerProviderStateMixin {
  static const _freeSpeed = 70.0; // 空轉速度（格/秒）
  static const _len = 32;

  final _api = ApiClient();
  Map<String, dynamic>? _info;
  String? _error;

  late final Ticker _ticker;
  final _frame = ValueNotifier<int>(0);
  double _now = 0;
  double _lastIdleFrame = 0;

  final List<_Reel> _reels = [_Reel(0), _Reel(7), _Reel(15)];
  List<List<int>> _strips = [];
  List<List<int>> _lines = [];
  List<String> _symbols = [];

  int _bet = 10000;
  bool _spinning = false; // 從按下旋轉到最後一個轉輪停下
  bool _auto = false;
  double _cash = 0;
  double _shownCash = 0;
  Map<String, dynamic>? _result;
  bool _resultShown = false; // 轉輪都停了，開始演中獎
  double _resultAt = 0;
  List<Map<String, dynamic>> _wins = [];
  Timer? _spinSound;
  final List<_Coin> _coins = [];
  double _coinStart = -10;
  double _lever = 0; // 拉桿 0..1
  double _pool = 0; // 全服累積彩池
  int _poolMin = 5000;
  List<Map<String, dynamic>> _recentWins = [];
  Timer? _poolTimer;

  @override
  void initState() {
    super.initState();
    CasinoMusic.instance.enter();
    _ticker = createTicker(_onTick)..start();
    _load();
    _poolTimer = Timer.periodic(const Duration(seconds: 4), (_) => _refreshPool());
  }

  @override
  void dispose() {
    CasinoMusic.instance.leave();
    _ticker.dispose();
    _spinSound?.cancel();
    _poolTimer?.cancel();
    _frame.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await _api.fetchSlotInfo();
      if (!mounted) return;
      setState(() {
        _info = info;
        _strips = [
          for (final s in info['strips'] as List)
            [for (final v in s as List) (v as num).toInt()],
        ];
        _lines = [
          for (final l in info['lines'] as List)
            [for (final v in l as List) (v as num).toInt()],
        ];
        _symbols = [for (final s in info['symbols'] as List) s as String];
        _cash = (info['cash'] as num).toDouble();
        _shownCash = _cash;
        _applyJackpot(info['jackpot'] as Map<String, dynamic>?);
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _applyJackpot(Map<String, dynamic>? j) {
    if (j == null) return;
    _pool = (j['pool'] as num).toDouble();
    _poolMin = (j['min_bet'] as num).toInt();
    _recentWins = [for (final e in (j['recent'] as List? ?? const [])) (e as Map).cast<String, dynamic>()];
  }

  Future<void> _refreshPool() async {
    // 自己在轉的時候先不更新，避免彩池數字提前劇透這一把有沒有中
    if (_spinning || !mounted) return;
    try {
      final j = await _api.fetchSlotJackpot();
      if (mounted) setState(() => _applyJackpot(j));
    } catch (_) {}
  }

  // ===== 每個畫面更新：推進轉輪狀態 =====
  void _onTick(Duration d) {
    final prev = _now;
    _now = d.inMicroseconds / 1e6;
    final dt = math.min(0.05, _now - prev);
    var changed = false;
    for (var i = 0; i < 3; i++) {
      final r = _reels[i];
      switch (r.mode) {
        case _Mode.idle:
          break;
        case _Mode.free:
          r.pos += _freeSpeed * dt;
          changed = true;
          if (r.stopAt > 0 && _now >= r.stopAt) {
            // 開始減速：要多轉至少一圈再停在目標
            final target = r.dist; // 目前暫存的是停輪位置
            final cur = r.pos % _len;
            final need = ((target - cur) % _len + _len) % _len + _len;
            r.from = r.pos;
            r.dist = need;
            r.t0 = _now;
            r.dur = 1.15;
            r.mode = _Mode.stopping;
          }
        case _Mode.stopping:
          final p = ((_now - r.t0) / r.dur).clamp(0.0, 1.0);
          r.pos = r.from + r.dist * Curves.easeOutQuad.transform(p);
          changed = true;
          if (p >= 1) {
            r.pos = (r.from + r.dist).roundToDouble();
            r.mode = _Mode.bounce;
            r.bounceT0 = _now;
            CasinoMusic.instance.playSfx('reelstop');
            if (_reels.every(
              (e) => e.mode == _Mode.bounce || e.mode == _Mode.idle,
            )) {
              _spinSound?.cancel();
            }
          }
        case _Mode.bounce:
          if (_now - r.bounceT0 > 0.4) {
            r.mode = _Mode.idle;
            r.pos = r.pos.roundToDouble();
            _checkAllStopped();
          }
          changed = true;
      }
    }
    // 沒在轉的時候也要讓跑馬燈、中獎線、金幣動起來，但不用每個畫面都重畫（約 20 次/秒）
    if (changed || _now - _lastIdleFrame > 0.05) {
      _lastIdleFrame = _now;
      _frame.value++;
    }
  }

  void _checkAllStopped() {
    if (!_spinning) return;
    if (_reels.any((r) => r.mode != _Mode.idle)) return;
    _spinning = false;
    final res = _result;
    if (res == null) return;
    _resultShown = true;
    _resultAt = _now;
    final payout = (res['payout'] as num).toDouble();
    final bet = (res['bet'] as num).toDouble();
    setState(() => _shownCash = (res['cash'] as num).toDouble());
    _cash = _shownCash;
    final jp = (res['jackpot_win'] as num?)?.toDouble() ?? 0;
    if (res['jackpot_pool'] != null) setState(() => _pool = (res['jackpot_pool'] as num).toDouble());
    if (jp > 0) {
      CasinoMusic.instance.playSfx('jackpot');
      _startCoins(240);
      _showJackpotDialog(jp);
    } else if (payout > 0) {
      final big = res['big'] == true || payout >= bet * 10;
      CasinoMusic.instance.playSfx(big ? 'jackpot' : 'win');
      if (payout >= bet * 5) _startCoins(big ? 90 : 40);
    }
    // 自動旋轉：贏大獎就停下來讓玩家欣賞，否則稍等一下接著轉
    if (_auto) {
      if (res['big'] == true) {
        setState(() => _auto = false);
      } else {
        Future.delayed(Duration(milliseconds: payout > 0 ? 2200 : 900), () {
          if (mounted && _auto && !_spinning) _spin();
        });
      }
    }
  }

  void _showJackpotDialog(double amount) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(colors: [Color(0xFF8E1B2B), Color(0xFF3A0911)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
            border: Border.all(color: const Color(0xFFFFD54F), width: 4),
            boxShadow: const [BoxShadow(color: Color(0xAAFFC107), blurRadius: 40, spreadRadius: 4)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🏆', style: TextStyle(fontSize: 64)),
              ShaderMask(
                shaderCallback: (r) => const LinearGradient(colors: [Color(0xFFFFF8D0), Color(0xFFFFC107)]).createShader(r),
                child: const Text('JACKPOT!', style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: 4, color: Colors.white)),
              ),
              const SizedBox(height: 8),
              const Text('你抱走了累積彩池', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 6),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: amount),
                duration: const Duration(milliseconds: 2200),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => Text('+${_money.format(v)}', style: const TextStyle(color: Color(0xFFFFE066), fontSize: 34, fontWeight: FontWeight.w900)),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('太棒了！')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _jackpotBanner() {
    final recent = _recentWins.isEmpty ? null : _recentWins.first;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(colors: [Color(0xFF2B0A10), Color(0xFF5A1020), Color(0xFF2B0A10)]),
        border: Border.all(color: const Color(0xFFE0B341), width: 2.5),
        boxShadow: const [BoxShadow(color: Color(0x66FFC107), blurRadius: 16), BoxShadow(color: Colors.black87, blurRadius: 8, offset: Offset(0, 4))],
      ),
      child: Column(
        children: [
          const Text('🏆  累 積 彩 池  🏆', style: TextStyle(color: Color(0xFFFFE9A0), fontSize: 13, letterSpacing: 3, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          TweenAnimationBuilder<double>(
            tween: Tween(end: _pool),
            duration: const Duration(milliseconds: 1500),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => ShaderMask(
              shaderCallback: (r) => const LinearGradient(colors: [Color(0xFFFFF8D0), Color(0xFFFFC107), Color(0xFFFF8F00)], begin: Alignment.topCenter, end: Alignment.bottomCenter).createShader(r),
              child: Text(_money.format(v), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: Colors.white, fontFamily: 'monospace', letterSpacing: 1)),
            ),
          ),
          Text(
            '押 ${_money.format(_poolMin)} 以上才參與・每注 1.5% 進彩池・押越多中獎機率越高',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
            textAlign: TextAlign.center,
          ),
          if (recent != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('上一位得主：${recent['name']} 抱走 ${_money.format((recent['amount'] as num).toDouble())}', style: const TextStyle(color: Color(0xFFFFD54F), fontSize: 11)),
            ),
        ],
      ),
    );
  }

  void _startCoins(int n) {
    final rnd = math.Random();
    _coins
      ..clear()
      ..addAll(List.generate(n, (_) => _Coin(rnd)));
    _coinStart = _now;
  }

  Future<void> _spin() async {
    if (_spinning || _info == null) return;
    if (_cash < _bet) {
      _snack('現金不夠，這次要 ${_money.format(_bet)} 元');
      setState(() => _auto = false);
      return;
    }
    setState(() {
      _spinning = true;
      _resultShown = false;
      _result = null;
      _wins = [];
    });
    // 按下就先空轉 + 拉桿動畫
    for (final r in _reels) {
      r.mode = _Mode.free;
      r.stopAt = 0;
    }
    _spinSound?.cancel();
    CasinoMusic.instance.playSfx('chipdrop');
    CasinoMusic.instance.playSfx('reelspin');
    _spinSound = Timer.periodic(
      const Duration(milliseconds: 520),
      (_) => CasinoMusic.instance.playSfx('reelspin'),
    );
    _pullLever();
    // 扣掉下注額先顯示（結果出來前不要劇透輸贏）
    setState(() => _shownCash = _cash - _bet);

    final started = DateTime.now();
    Map<String, dynamic> res;
    try {
      res = await _api.slotSpin(_bet);
    } catch (e) {
      _abort(e.toString());
      return;
    }
    if (!mounted) return;
    if (res['ok'] != true) {
      _abort(res['message']?.toString() ?? '失敗');
      return;
    }
    // 至少空轉 0.8 秒才開始依序停輪，看起來才有「轉」的感覺
    final waited = DateTime.now().difference(started).inMilliseconds / 1000.0;
    final extra = math.max(0.0, 0.8 - waited);
    final stops = [for (final s in res['stops'] as List) (s as num).toInt()];
    _result = res;
    _wins = [
      for (final w in res['wins'] as List) (w as Map).cast<String, dynamic>(),
    ];
    for (var i = 0; i < 3; i++) {
      final r = _reels[i];
      r.dist = stops[i].toDouble(); // 暫存停輪位置，tick 裡換算成要轉的距離
      r.stopAt = _now + extra + 0.15 + i * 0.5;
    }
  }

  void _abort(String msg) {
    _spinSound?.cancel();
    for (final r in _reels) {
      r.mode = _Mode.idle;
      r.pos = r.pos.roundToDouble();
    }
    if (mounted) {
      setState(() {
        _spinning = false;
        _auto = false;
        _shownCash = _cash;
      });
      _snack(msg);
    }
  }

  void _pullLever() async {
    for (var i = 0; i <= 10; i++) {
      if (!mounted) return;
      setState(() => _lever = math.sin(i / 10 * math.pi));
      await Future.delayed(const Duration(milliseconds: 35));
    }
    if (mounted) setState(() => _lever = 0);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }

  // ===== 畫面 =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('老虎機'), actions: const [MusicButton()]),
      body: _info == null
          ? Center(
              child: _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    )
                  : const CircularProgressIndicator(),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _jackpotBanner(),
                      _machine(),
                      const SizedBox(height: 14),
                      _controls(),
                      const SizedBox(height: 10),
                      _history(),
                      const SizedBox(height: 8),
                      Text(
                        '3 轉輪 × 5 條線（上、中、下、兩條斜線），總下注平分到 5 條線。三個一樣依賠率派彩，'
                        '左邊起連續兩顆櫻桃也有小賠。基本遊戲回報率約 94.5%，加上彩池約 96%。結果由伺服器抽出，贏超過 20 倍或中彩池會公告到 Discord。',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _machine() {
    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: const LinearGradient(
              colors: [
                Color(0xFFFFF3B0),
                Color(0xFFE0B341),
                Color(0xFF8A6A12),
                Color(0xFFE0B341),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black87,
                blurRadius: 22,
                offset: Offset(0, 12),
              ),
              BoxShadow(
                color: Color(0x55E0B341),
                blurRadius: 24,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              // 縱向漸層 + 橫向光影：左右邊緣暗、中間亮，像圓弧的機身
              gradient: const LinearGradient(
                colors: [
                  Color(0xFFC2304A),
                  Color(0xFF8E1B2B),
                  Color(0xFF3A0911),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: LinearGradient(
                colors: [
                  Colors.black.withValues(alpha: 0.35),
                  Colors.transparent,
                  Colors.white.withValues(alpha: 0.10),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.35),
                ],
                stops: const [0, 0.18, 0.3, 0.8, 1],
              ),
            ),
            child: Column(
              children: [
                _marquee(),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF2B0A10), Color(0xFF14040A)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    border: Border.all(
                      color: const Color(0xFFE0B341),
                      width: 2,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black54,
                        blurRadius: 6,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ShaderMask(
                    shaderCallback: (r) => const LinearGradient(
                      colors: [
                        Color(0xFFFFF8D0),
                        Color(0xFFE0B341),
                        Color(0xFF9A7414),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ).createShader(r),
                    child: const Text(
                      'LUCKY  SLOT',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 6,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _reelWindow(),
                const SizedBox(height: 12),
                _ledRow(),
              ],
            ),
          ),
        ),
        // 右側拉桿
        Positioned(right: 0, top: 70, child: _leverWidget()),
        // 金幣雨
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _frame,
              builder: (context, _) =>
                  CustomPaint(painter: _CoinPainter(_coins, _now - _coinStart)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _leverWidget() {
    return Transform.translate(
      offset: const Offset(8, 0),
      child: SizedBox(
        width: 22,
        height: 120,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Positioned(
              top: 20,
              bottom: 0,
              child: Container(
                width: 8,
                decoration: BoxDecoration(
                  color: const Color(0xFFB0B7BF),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Positioned(
              top: 6 + 70 * _lever,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: [Color(0xFFFF6B6B), Color(0xFFB71C1C)],
                    center: Alignment(-0.3, -0.3),
                  ),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 4),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 跑馬燈：一圈燈泡輪流亮
  Widget _marquee() {
    return AnimatedBuilder(
      animation: _frame,
      builder: (context, _) {
        final phase = (_now * (_spinning ? 9 : 3)).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < 14; i++)
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (i + phase) % 3 == 0
                      ? const Color(0xFFFFF176)
                      : const Color(0xFF6B4A12),
                  boxShadow: (i + phase) % 3 == 0
                      ? [
                          const BoxShadow(
                            color: Color(0xFFFFD54F),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _reelWindow() {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        const gap = 6.0;
        final tileW = (w - 16 - gap * 2) / 3;
        final tileH = tileW * 0.92;
        final h = tileH * 3;
        return Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              colors: [
                Color(0xFFF4F6F8),
                Color(0xFF9AA5AE),
                Color(0xFF454E56),
                Color(0xFFB7C0C7),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black87,
                blurRadius: 10,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              gradient: const LinearGradient(
                colors: [Color(0xFF000000), Color(0xFF241217)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              boxShadow: const [
                BoxShadow(color: Colors.black, blurRadius: 8, spreadRadius: -2),
              ],
            ),
            child: AnimatedBuilder(
              animation: _frame,
              builder: (context, _) {
                final cells = <int>{};
                if (_resultShown) {
                  for (final wn in _wins) {
                    final line = _lines[(wn['line'] as num).toInt()];
                    for (
                      var col = 0;
                      col < (wn['count'] as num).toInt();
                      col++
                    ) {
                      cells.add(line[col] * 3 + col);
                    }
                  }
                }
                final pulse = 0.5 + 0.5 * math.sin(_now * 9);
                return SizedBox(
                  height: h,
                  child: Stack(
                    children: [
                      Row(
                        children: [
                          for (var col = 0; col < 3; col++) ...[
                            if (col > 0) const SizedBox(width: gap),
                            _reelColumn(col, tileW, tileH, cells, pulse),
                          ],
                        ],
                      ),
                      // 玻璃反光 + 上下暗角
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.45),
                                  Colors.transparent,
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.45),
                                ],
                                stops: const [0, 0.22, 0.78, 1],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_resultShown && _wins.isNotEmpty)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _LinePainter(
                                _wins,
                                _lines,
                                tileW,
                                tileH,
                                gap,
                                _now - _resultAt,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _reelColumn(
    int col,
    double tileW,
    double tileH,
    Set<int> winCells,
    double pulse,
  ) {
    final r = _reels[col];
    var pos = r.pos;
    if (r.mode == _Mode.bounce) {
      final p = ((_now - r.bounceT0) / 0.4).clamp(0.0, 1.0);
      pos += 0.18 * (1 - Curves.elasticOut.transform(p));
    }
    final fast =
        r.mode == _Mode.free ||
        (r.mode == _Mode.stopping && (_now - r.t0) / r.dur < 0.6);
    final strip = _strips[col];
    final base = pos.floor();
    final tiles = <Widget>[];
    for (var k = base - 3; k <= base + 2; k++) {
      final y = (pos - k) * tileH;
      if (y < -tileH || y > tileH * 3) continue;
      final sym = strip[((k % _len) + _len) % _len];
      final row = ((pos - k).round()).clamp(0, 2);
      final isWin =
          r.mode == _Mode.idle &&
          winCells.contains(row * 3 + col) &&
          (pos - k - row).abs() < 0.05;
      // 轉輪是圓柱：離中心越遠的格子越往後傾斜、越暗，看起來像真的滾筒
      final u = ((y + tileH / 2) - tileH * 1.5) / (tileH * 1.5);
      tiles.add(
        Positioned(
          top: y,
          left: 0,
          width: tileW,
          height: tileH,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0013)
              ..rotateX(u.clamp(-1.4, 1.4) * 0.8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _tile(sym, tileW, tileH, isWin, pulse),
                IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: Colors.black.withValues(
                        alpha: (u.abs() * u.abs() * 0.55).clamp(0.0, 0.7),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    Widget reel = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: tileW,
        height: tileH * 3,
        child: Stack(clipBehavior: Clip.hardEdge, children: tiles),
      ),
    );
    if (fast) {
      reel = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaY: 5, sigmaX: 0),
        child: reel,
      );
    }
    return reel;
  }

  Widget _tile(int sym, double w, double h, bool win, double pulse) {
    const glow = Color(0xFFFFE066);
    return Container(
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: win
              ? const [Color(0xFFFFFBE6), Color(0xFFFFD866)]
              : const [Color(0xFFFFFFFF), Color(0xFFE8E1CC), Color(0xFFC9C1A8)],
          stops: win ? null : const [0, 0.55, 1],
        ),
        border: Border.all(
          color: win
              ? Color.lerp(const Color(0xFFB8860B), glow, pulse)!
              : const Color(0xFF7A745F),
          width: win ? 3.5 : 1.2,
        ),
        boxShadow: [
          const BoxShadow(
            color: Colors.black54,
            blurRadius: 3,
            offset: Offset(0, 2),
          ),
          if (win)
            BoxShadow(
              color: glow.withValues(alpha: 0.4 + 0.4 * pulse),
              blurRadius: 14,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 上半部的玻璃高光
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: h * 0.4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(9),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.65),
                    Colors.white.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          Transform.scale(
            scale: win ? 1 + 0.08 * pulse : 1,
            child: _symbolWidget(sym, h * 0.52),
          ),
        ],
      ),
    );
  }

  // 星星和 7 用自己畫的（系統 emoji 的黃星、灰底 7 放在米色底上對比太低，看不清楚）
  Widget _symbolWidget(int sym, double size) {
    if (sym == 4) {
      return SizedBox(
        width: size * 1.3,
        height: size * 1.3,
        child: CustomPaint(painter: _StarPainter()),
      );
    }
    if (sym == 5) {
      return SizedBox(
        width: size * 1.3,
        height: size * 1.3,
        child: CustomPaint(painter: _SevenPainter()),
      );
    }
    return Text(_symbols[sym], style: TextStyle(fontSize: size, height: 1.0));
  }

  // 底下三個 LED 顯示：現金、下注、本次贏得
  Widget _ledRow() {
    final res = _resultShown ? _result : null;
    final payout = res == null ? 0.0 : (res['payout'] as num).toDouble();
    return Row(
      children: [
        Expanded(child: _led('現金', _shownCash, const Color(0xFF7CFFB0))),
        const SizedBox(width: 8),
        Expanded(
          child: _led(
            '下注',
            _bet.toDouble(),
            const Color(0xFFFFD54F),
            animate: false,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _led(
            '贏得',
            payout,
            payout > 0 ? const Color(0xFFFF8A65) : const Color(0xFF8D6E63),
          ),
        ),
      ],
    );
  }

  Widget _led(String label, double value, Color color, {bool animate = true}) {
    Widget text(double v) => FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        _money.format(v),
        style: TextStyle(
          color: color,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
          shadows: [Shadow(color: color, blurRadius: 6)],
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: const LinearGradient(
          colors: [Color(0xFF000000), Color(0xFF1A1208)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        border: Border.all(color: const Color(0xFF8A7230), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 3, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
          animate
              ? TweenAnimationBuilder<double>(
                  tween: Tween(end: value),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) => text(v),
                )
              : text(value),
        ],
      ),
    );
  }

  Widget _controls() {
    final busy = _spinning;
    return Column(
      children: [
        Opacity(
          opacity: busy ? 0.5 : 1,
          child: IgnorePointer(
            ignoring: busy,
            child: ChipSelector(
              selected: _bet,
              onSelect: (c) => setState(() => _bet = c),
            ),
          ),
        ),
        if (_bet < _poolMin)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('這個金額不參與累積彩池', style: TextStyle(color: Colors.white38, fontSize: 11)),
          ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _showPaytable,
              icon: const Icon(Icons.list_alt, size: 18),
              label: const Text('賠率表'),
            ),
            const SizedBox(width: 18),
            GestureDetector(
              onTap: busy ? null : _spin,
              child: SizedBox(
                width: 104,
                height: 108,
                child: Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    // 底座（深色，露出來的高度就是按鈕厚度）
                    Positioned(
                      bottom: 0,
                      child: Container(
                        width: 104,
                        height: 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [Color(0xFF9A6A00), Color(0xFF3F2A00)],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black87,
                              blurRadius: 12,
                              offset: Offset(0, 6),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 按鈕面：按下去會往下沉
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 90),
                      top: busy ? 8 : 0,
                      child: Container(
                        width: 104,
                        height: 100,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: busy
                                ? const [Color(0xFFB59B3F), Color(0xFF6F5E22)]
                                : const [
                                    Color(0xFFFFF3A8),
                                    Color(0xFFFFC62E),
                                    Color(0xFFD08A00),
                                  ],
                            stops: busy ? null : const [0, 0.55, 1],
                            center: const Alignment(-0.35, -0.5),
                            radius: 0.95,
                          ),
                          border: Border.all(
                            color: const Color(0xFFFFF8D0),
                            width: 2.5,
                          ),
                          boxShadow: busy
                              ? null
                              : [
                                  BoxShadow(
                                    color: const Color(
                                      0xFFFFC107,
                                    ).withValues(alpha: 0.6),
                                    blurRadius: 18,
                                  ),
                                ],
                        ),
                        child: Text(
                          busy ? '轉動中' : 'SPIN',
                          style: const TextStyle(
                            color: Color(0xFF4A2A00),
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1,
                            shadows: [
                              Shadow(
                                color: Color(0x88FFFFFF),
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 18),
            FilterChip(
              label: const Text('自動'),
              selected: _auto,
              avatar: const Icon(Icons.autorenew, size: 16),
              onSelected: (v) {
                setState(() => _auto = v);
                if (v && !_spinning) _spin();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _history() {
    final h = (_info?['history'] as List?) ?? const [];
    if (h.isEmpty) return const SizedBox.shrink();
    return Text(
      '先前幾次：${h.map((e) {
        final m = e as Map;
        final net = (m['payout'] as num) - (m['bet'] as num);
        return net > 0 ? '+${_money.format(net)}' : (net == 0 ? '平' : _money.format(net));
      }).join('　')}',
      style: const TextStyle(color: Colors.white38, fontSize: 11),
      textAlign: TextAlign.center,
    );
  }

  void _showPaytable() {
    final tp = (_info!['triple_pay'] as Map).map(
      (k, v) => MapEntry(int.parse(k as String), (v as num).toInt()),
    );
    final order = tp.keys.toList()..sort((a, b) => tp[b]!.compareTo(tp[a]!));
    final cp = (_info!['cherry_left_pay'] as Map).map(
      (k, v) => MapEntry(int.parse(k as String), (v as num).toInt()),
    );
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '賠率表（每條線的下注額 × 倍數）',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                '總下注會平分給 5 條線，所以每條線 = 總下注 ÷ 5。',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 10),
              for (final s in order)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Row(
                        children: [
                          for (var i = 0; i < 3; i++)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: _symbolWidget(s, 24),
                            ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        '× ${tp[s]}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Color(0xFFFFD54F),
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Row(
                      children: [
                        _symbolWidget(0, 24),
                        _symbolWidget(0, 24),
                        const SizedBox(width: 6),
                        const Text('（最左邊起）'),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      '× ${cp[2]}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Color(0xFFFFD54F),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 中獎線：把中獎的那幾條線依序畫出來（每條亮 0.9 秒輪播），線上有流動的亮點
class _LinePainter extends CustomPainter {
  final List<Map<String, dynamic>> wins;
  final List<List<int>> lines;
  final double tileW, tileH, gap, t;
  _LinePainter(this.wins, this.lines, this.tileW, this.tileH, this.gap, this.t);

  static const colors = [
    Color(0xFFFF5252),
    Color(0xFF40C4FF),
    Color(0xFFB2FF59),
    Color(0xFFFFAB40),
    Color(0xFFE040FB),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (wins.isEmpty) return;
    final idx = (t / 0.9).floor() % wins.length;
    final w = wins[idx];
    final li = (w['line'] as num).toInt();
    final line = lines[li];
    final pts = [
      for (var c = 0; c < 3; c++)
        Offset(c * (tileW + gap) + tileW / 2, line[c] * tileH + tileH / 2),
    ];
    final color = colors[li % colors.length];
    final path = Path()..moveTo(pts[0].dx - tileW * 0.35, pts[0].dy);
    for (final p in pts) {
      path.lineTo(p.dx, p.dy);
    }
    path.lineTo(pts[2].dx + tileW * 0.35, pts[2].dy);
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeJoin = StrokeJoin.round,
    );
    final amount = (w['amount'] as num).toInt();
    final tp = TextPainter(
      text: TextSpan(
        text: '+${_money.format(amount)}',
        style: TextStyle(
          color: color,
          fontSize: 20,
          fontWeight: FontWeight.w900,
          shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(size.width / 2 - tp.width / 2, size.height / 2 - tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}

class _Coin {
  final double x, vy, vx, r, spin, delay;
  _Coin(math.Random rnd)
    : x = rnd.nextDouble(),
      vy = 0.5 + rnd.nextDouble() * 0.7,
      vx = (rnd.nextDouble() - 0.5) * 0.3,
      r = 6 + rnd.nextDouble() * 6,
      spin = rnd.nextDouble() * 8,
      delay = rnd.nextDouble() * 0.8;
}

// 金幣雨：大獎時從上方掉下來的金色硬幣
class _CoinPainter extends CustomPainter {
  final List<_Coin> coins;
  final double t;
  _CoinPainter(this.coins, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    if (t < 0 || t > 3.5) return;
    for (final c in coins) {
      final tt = t - c.delay;
      if (tt < 0) continue;
      final y = -20 + tt * c.vy * size.height * 0.9 + 0.5 * 400 * tt * tt * 0.2;
      if (y > size.height + 20) continue;
      final x = (c.x + c.vx * tt) * size.width;
      final squish = (math.cos(tt * c.spin * 3)).abs() * 0.8 + 0.2;
      final rect = Rect.fromCenter(
        center: Offset(x, y),
        width: c.r * 2 * squish,
        height: c.r * 2,
      );
      canvas.drawOval(rect, Paint()..color = const Color(0xFFFFC107));
      canvas.drawOval(
        rect.deflate(c.r * 0.28),
        Paint()
          ..color = const Color(0xFFFFE082)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CoinPainter old) => true;
}

// 五角星：金黃漸層 + 深橘色粗描邊 + 高光，放在淺色底上也看得清楚
class _StarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final R = size.width / 2;
    final r = R * 0.48;
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final ang = -math.pi / 2 + i * math.pi / 5;
      final rad = i.isEven ? R : r;
      final p = Offset(c.dx + rad * math.cos(ang), c.dy + rad * math.sin(ang));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF1A0505)
        ..style = PaintingStyle.stroke
        ..strokeWidth = R * 0.3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFFF1744), Color(0xFFD50000)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFFD54F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = R * 0.07
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(
      Offset(c.dx - R * 0.18, c.dy - R * 0.22),
      R * 0.1,
      Paint()..color = Colors.white70,
    );
  }

  @override
  bool shouldRepaint(covariant _StarPainter old) => false;
}

// 紅色粗體 7：用路徑畫，位置正好置中（不靠字型，字型的上下留白會讓 7 偏掉）
class _SevenPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    Offset p(double x, double y) => Offset(x * w, y * h);
    final path = Path()
      ..moveTo(p(0.12, 0.10).dx, p(0.12, 0.10).dy)
      ..lineTo(p(0.88, 0.10).dx, p(0.88, 0.10).dy)
      ..lineTo(p(0.88, 0.27).dx, p(0.88, 0.27).dy)
      ..lineTo(p(0.47, 0.92).dx, p(0.47, 0.92).dy)
      ..lineTo(p(0.22, 0.92).dx, p(0.22, 0.92).dy)
      ..lineTo(p(0.60, 0.30).dx, p(0.60, 0.30).dy)
      ..lineTo(p(0.12, 0.30).dx, p(0.12, 0.30).dy)
      ..close();
    // 立體感：往右下偏移的深色陰影
    canvas.drawPath(
      path.shift(Offset(w * 0.04, h * 0.05)),
      Paint()..color = Colors.black54,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF1A0505)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.13
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFFF5252), Color(0xFFD50000), Color(0xFF8E0000)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFFD54F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.035
        ..strokeJoin = StrokeJoin.round,
    );
    // 上橫槓的高光
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.17, h * 0.135, w * 0.66, h * 0.045),
        Radius.circular(w * 0.02),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(covariant _SevenPainter old) => false;
}
