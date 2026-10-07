import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';
import '../widgets/hero_art.dart';
import '../widgets/monster_art.dart';

// 打 Boss：勇者（左）衝過去砍右邊的 Boss。傷害、費用、冷卻全由伺服器決定（跟以前丟炸彈完全一樣），
// 前端只負責播動畫。畫面開著的時候，別的玩家剛打出的攻擊會變成「從畫面上方丟下來轟炸 Boss 的炸彈」。

enum _Atk { idle, dash, wait, back }

class _Bomb {
  final double fromX; // 0~1，畫面寬度比例
  final String name;
  final int dmg;
  double t = 0; // 0~1 飛行進度
  bool boomed = false;
  double boomT = 0; // 0~1 爆炸進度
  _Bomb(this.fromX, this.name, this.dmg);
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

class BossScreen extends StatefulWidget {
  const BossScreen({super.key});

  @override
  State<BossScreen> createState() => _BossScreenState();
}

class _BossScreenState extends State<BossScreen> with SingleTickerProviderStateMixin {
  final _api = ApiClient();
  final _rng = math.Random();

  BossStatus? _status;
  String? _error;
  bool _loading = true;
  Timer? _refreshTimer;
  int? _myBombDamage; // 含裝備加成的個人傷害
  DateTime? _cooldownUntil; // 我的攻擊冷卻到什麼時候（本機時鐘）
  Map<String, ({String id, int tier})> _equipped = {};

  // 畫面動畫
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;
  double _t = 0;
  double _stageW = 360;
  static const _stageH = 300.0;
  static const _groundY = 252.0;
  static const _heroH = 170.0;
  static const _bossSize = 175.0;
  double _bossFlash = 0;
  double _heroFlash = 0;
  double _slashT = 0;
  final List<_Float> _floats = [];
  final List<_Bomb> _bombs = [];
  final List<BossHit> _pending = []; // 還沒播的別人的攻擊
  double _spawnCd = 0;
  int _displayHp = 0; // 畫面上血條顯示的血量（炸彈落地/勇者砍中才扣）
  int? _bossId;

  // 別人的攻擊：只播「比我看過的 id 更新」且不是我自己丟的
  int _lastHitId = 0;
  bool _hitsInit = false;
  final Set<int> _ownHitIds = {};

  // 我的攻擊
  bool _attacking = false;
  _Atk _atk = _Atk.idle;
  double _atkT = 0;
  BossAttackResult? _atkResult;
  Object? _atkError;

  int get _cooldownLeft {
    final t = _cooldownUntil;
    if (t == null) return 0;
    final s = t.difference(DateTime.now()).inSeconds + 1;
    return s > 0 ? s : 0;
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _load();
    // 3 秒抓一次現況：別的玩家的攻擊最多晚 3 秒就會在畫面上炸下來
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }

  // ---------- 資料 ----------
  Future<void> _load({bool silent = false}) async {
    if (silent && _attacking) return; // 我正在出手，這輪先不更新，免得把自己的攻擊又當成別人的
    if (!silent) setState(() => _loading = true);
    try {
      final status = await _api.fetchBossStatus();
      int cd = 0;
      int? myDamage;
      try {
        final r = await _api.fetchBossCooldown();
        cd = (r['seconds'] as num?)?.toInt() ?? 0;
        myDamage = (r['bomb_damage'] as num?)?.toInt();
      } catch (_) {}
      if (_equipped.isEmpty) {
        try {
          _equipped = _parseEquipped(await _api.fetchHeroEquipment());
        } catch (_) {}
      }
      if (!mounted || (silent && _attacking)) return;
      setState(() {
        _myBombDamage = myDamage;
        _cooldownUntil = cd > 0 ? DateTime.now().add(Duration(seconds: cd)) : null;
        _status = status;
        _error = null;
        _loading = false;
        _syncHits(status);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Map<String, ({String id, int tier})> _parseEquipped(Map<String, dynamic> eq) {
    final m = <String, ({String id, int tier})>{};
    for (final s in (eq['slots'] as List)) {
      final it = s['item'] as Map<String, dynamic>?;
      if (it != null) {
        m[s['key'] as String] = (id: it['id'] as String, tier: (it['tier'] as num).toInt());
      }
    }
    return m;
  }

  // 比對最近的攻擊紀錄：第一次載入只記下目前最大的 id（不重播舊的），之後出現的新紀錄排進「別人丟炸彈」佇列
  void _syncHits(BossStatus status) {
    if (!status.active) {
      _pending.clear();
      _bossId = null;
      _hitsInit = false;
      return;
    }
    final hits = status.recentHits;
    if (_bossId != status.bossId) {
      _bossId = status.bossId;
      _hitsInit = false;
      _pending.clear();
      _bombs.clear();
    }
    final maxId = hits.isEmpty ? 0 : hits.map((h) => h.id).reduce(math.max);
    if (!_hitsInit) {
      _hitsInit = true;
      _lastHitId = maxId;
      _displayHp = status.currentHp ?? 0;
      return;
    }
    for (final h in hits) {
      if (h.id > _lastHitId && !_ownHitIds.contains(h.id)) {
        _pending.add(h);
      }
    }
    if (maxId > _lastHitId) _lastHitId = maxId;
    if (_pending.isEmpty && _bombs.isEmpty && _atk == _Atk.idle) {
      _displayHp = status.currentHp ?? 0;
    }
  }

  // ---------- 我出手 ----------
  void _attack() {
    if (_attacking) return;
    setState(() {
      _attacking = true;
      _atk = _Atk.dash;
      _atkT = 0;
      _atkResult = null;
      _atkError = null;
    });
    _api.attackBoss().then((r) {
      _atkResult = r;
    }).catchError((Object e) {
      _atkError = e;
    });
  }

  void _applyOwnResult() {
    final r = _atkResult;
    if (r == null) {
      final e = _atkError;
      _showSnack('攻擊失敗：$e');
      return;
    }
    if (!r.ok) {
      _showSnack(r.message);
      _status = r.status.active ? r.status : _status;
      return;
    }
    if (r.hitId != null) {
      _ownHitIds.add(r.hitId!);
      if (r.hitId! > _lastHitId) _lastHitId = r.hitId!;
    }
    final dmg = r.damage ?? _myBombDamage ?? 50;
    _bossFlash = 1;
    _slashT = 0.35;
    _floats.add(_Float('-$dmg', _bossX - 20, _groundY - _bossSize * 0.7, const Color(0xFFFFD93D), 30));
    _displayHp = r.status.active ? (r.status.currentHp ?? 0) : 0;
    if (!r.defeated) {
      _status = r.status;
    }
    if (r.cooldownSeconds > 0) {
      _cooldownUntil = DateTime.now().add(Duration(seconds: r.cooldownSeconds));
    }
  }

  void _finishAttack() {
    final r = _atkResult;
    _attacking = false;
    if (r != null && r.ok && r.defeated) {
      _status = r.status;
      _showResultDialog('🎉 打倒了！', '${r.message}\n\n🎁 掉落的裝備已經放進勇者物品欄（首頁右上角盾牌）');
    }
  }

  // 別人的炸彈落地：扣血條、Boss 閃白、飄出「名字 -傷害」
  void _impact(_Bomb b) {
    _bossFlash = 1;
    _displayHp = math.max(0, _displayHp - b.dmg);
    _floats.add(_Float('${b.name} -${b.dmg}', _bossX + (_rng.nextDouble() - 0.5) * 60, _groundY - _bossSize * 0.75, const Color(0xFFFF9A3D), 18));
  }

  // ---------- 每幀 ----------
  double get _bossX => _stageW * 0.72;
  double get _heroX0 => _stageW * 0.2;
  double get _dashDist => math.max(40.0, _bossX - _bossSize * 0.45 - _heroX0 - 40);

  void _onTick(Duration elapsed) {
    final dt = math.min(0.1, (elapsed - _lastElapsed).inMicroseconds / 1e6);
    _lastElapsed = elapsed;
    if (!mounted) return;
    _t += dt;
    _bossFlash = math.max(0, _bossFlash - dt * 4);
    _heroFlash = math.max(0, _heroFlash - dt * 4);
    _slashT = math.max(0, _slashT - dt);
    for (final f in _floats) {
      f.age += dt;
    }
    _floats.removeWhere((f) => f.age > 1.2);

    // 別人的炸彈：佇列裡的依序丟下來（間隔 0.45 秒），最多同時 6 顆
    _spawnCd -= dt;
    if (_pending.isNotEmpty && _spawnCd <= 0 && _bombs.length < 6) {
      final h = _pending.removeAt(0);
      _bombs.add(_Bomb(0.1 + _rng.nextDouble() * 0.85, h.name, h.damage));
      _spawnCd = 0.45;
    }
    for (final b in _bombs) {
      if (!b.boomed) {
        b.t += dt / 0.85;
        if (b.t >= 1) {
          b.t = 1;
          b.boomed = true;
          _impact(b);
        }
      } else {
        b.boomT += dt / 0.55;
      }
    }
    _bombs.removeWhere((b) => b.boomed && b.boomT >= 1);
    if (_pending.isEmpty && _bombs.isEmpty && _atk == _Atk.idle && _status?.active == true && _displayHp != (_status!.currentHp ?? 0)) {
      _displayHp = _status!.currentHp ?? 0; // 動畫都播完了，血條對齊伺服器的真實血量
    }

    switch (_atk) {
      case _Atk.dash:
        _atkT += dt;
        if (_atkT >= 0.4) {
          _atk = _Atk.wait;
        }
      case _Atk.wait:
        if (_atkResult != null || _atkError != null) {
          _applyOwnResult();
          _atk = _Atk.back;
          _atkT = 0;
        }
      case _Atk.back:
        _atkT += dt;
        if (_atkT >= 0.45) {
          _atk = _Atk.idle;
          _finishAttack();
        }
      case _Atk.idle:
        break;
    }
    setState(() {});
  }

  double get _heroDx {
    switch (_atk) {
      case _Atk.dash:
        final p = (_atkT / 0.4).clamp(0.0, 1.0);
        return _dashDist * (1 - (1 - p) * (1 - p));
      case _Atk.wait:
        return _dashDist;
      case _Atk.back:
        return _dashDist * (1 - (_atkT / 0.45).clamp(0.0, 1.0));
      case _Atk.idle:
        return 0;
    }
  }

  // ---------- UI 小工具 ----------
  String _bonusText(BossStatus status) {
    final my = _myBombDamage;
    final base = status.bombDamage;
    if (my == null || base == null || my <= base) return '';
    return '，裝備加成 +${((my - base) * 100 / base).round()}%';
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _showResultDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('讚啦')),
        ],
      ),
    );
  }

  String _formatCountdown(DateTime target) {
    final diff = target.difference(DateTime.now());
    if (diff.isNegative) return '即將結算…';
    final d = diff.inDays;
    final h = diff.inHours % 24;
    final m = diff.inMinutes % 60;
    final s = diff.inSeconds % 60;
    if (d > 0) return '$d 天 $h 時 $m 分';
    if (h > 0) return '$h 時 $m 分 $s 秒';
    return '$m 分 $s 秒';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('👹 打 Boss')),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: _loading && _status == null
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _status == null
                ? _buildErrorView()
                : _buildContent(),
      ),
    );
  }

  Widget _buildErrorView() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 60),
        Icon(Icons.cloud_off, size: 48, color: Colors.grey[600]),
        const SizedBox(height: 12),
        Text(_error ?? '', textAlign: TextAlign.center),
        const SizedBox(height: 20),
        FilledButton(onPressed: () => _load(), child: const Text('重試')),
      ],
    );
  }

  Widget _buildContent() {
    final status = _status!;
    if (!status.active) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 80),
          const Center(child: Text('😴', style: TextStyle(fontSize: 64))),
          const SizedBox(height: 16),
          const Center(
            child: Text('目前沒有 Boss', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          if (status.nextSpawnEta != null) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                '下一隻預計 ${_formatCountdown(status.nextSpawnEta!)} 後出現',
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ],
      );
    }

    final maxHp = status.maxHp!;
    final shownHp = _displayHp.clamp(0, maxHp);
    final hpPct = shownHp / maxHp;
    final hpColor = hpPct > 0.5 ? Colors.green : (hpPct > 0.25 ? Colors.orange : Colors.redAccent);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 舞台：勇者（左）VS Boss（右）；別人丟的炸彈從上面掉下來
        LayoutBuilder(builder: (context, c) {
          _stageW = c.maxWidth;
          return ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              height: _stageH,
              width: double.infinity,
              child: CustomPaint(painter: _BossStagePainter(this)),
            ),
          );
        }),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Boss 血量', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text('$shownHp/$maxHp', style: TextStyle(color: hpColor, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: hpPct,
                    minHeight: 16,
                    backgroundColor: Colors.grey[800],
                    color: hpColor,
                  ),
                ),
                const SizedBox(height: 16),
                _row('⏳ 剩餘時間', _formatCountdown(status.endsAt!)),
                _row('💰 獎金池', '${NumberFormat('#,##0').format(status.prizePool)} 元'),
                _row('⚔️ 出擊費用', '${NumberFormat('#,##0').format(status.bombCost)} 元／次（${_myBombDamage ?? status.bombDamage} 傷害${_bonusText(status)}）'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: (_attacking || _cooldownLeft > 0) ? null : _attack,
          icon: const Icon(Icons.flash_on),
          label: Text(_attacking
              ? '出擊中…'
              : _cooldownLeft > 0
                  ? '冷卻中 ${_cooldownLeft ~/ 60}:${(_cooldownLeft % 60).toString().padLeft(2, '0')}'
                  : '勇者出擊（${NumberFormat('#,##0').format(status.bombCost)} 元）'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.redAccent,
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        if (status.topDamage.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text('傷害排行榜', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                for (var i = 0; i < status.topDamage.length; i++)
                  ListTile(
                    dense: true,
                    leading: Text('#${i + 1}'),
                    title: Text(status.topDamage[i].name ?? status.topDamage[i].userId),
                    trailing: Text('${status.topDamage[i].damage} 傷害'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Flexible(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

// ======================= 舞台繪製 =======================
class _BossStagePainter extends CustomPainter {
  final _BossScreenState s;
  _BossStagePainter(this.s);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    const gy = _BossScreenState._groundY;
    _background(canvas, w, size.height, gy);

    final bx = s._bossX;
    final bossId = s._bossId ?? 0;
    final kind = bossId % 10;
    final band = (bossId ~/ 10 + 5) % 10;

    // Boss（影子 + 本體 + 血條）
    canvas.drawOval(Rect.fromCenter(center: Offset(bx, gy + 8), width: _BossScreenState._bossSize * 0.85, height: 16), Paint()..color = const Color(0x55000000));
    final sway = math.sin(s._t * 2) * 3;
    canvas.save();
    canvas.translate(bx - _BossScreenState._bossSize / 2 + sway, gy + 6 - _BossScreenState._bossSize);
    MonsterPainter(kind: kind, band: band, boss: true, flash: s._bossFlash, t: s._t).paint(canvas, const Size(_BossScreenState._bossSize, _BossScreenState._bossSize));
    canvas.restore();
    final maxHp = s._status?.maxHp ?? 1;
    _hpBar(canvas, Offset(bx, gy - _BossScreenState._bossSize - 6), 150, s._displayHp / maxHp, 'BOSS  ${s._displayHp}/$maxHp');

    // 勇者
    _drawHero(canvas, gy);

    // 斬擊光弧
    if (s._slashT > 0) {
      final p = 1 - s._slashT / 0.35;
      final arc = Rect.fromCircle(center: Offset(bx - _BossScreenState._bossSize * 0.35, gy - _BossScreenState._bossSize * 0.5), radius: 52 + p * 22);
      canvas.drawArc(
          arc,
          -math.pi * 0.7,
          math.pi * 1.0 * (0.4 + p * 0.6),
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8 * (1 - p) + 2
            ..strokeCap = StrokeCap.round
            ..color = Colors.white.withValues(alpha: 1 - p));
    }

    // 別人丟下來的炸彈
    for (final b in s._bombs) {
      final target = Offset(bx + (b.fromX * 7 % 1 - 0.5) * 70, gy - _BossScreenState._bossSize * 0.55);
      if (!b.boomed) {
        final p = b.t * b.t; // 越掉越快
        final start = Offset(b.fromX * w, -30);
        final pos = Offset.lerp(start, target, p)!;
        _drawBomb(canvas, pos, b.t * 8);
        _label(canvas, Offset(pos.dx, pos.dy - 16), b.name, 10, Colors.white70);
      } else {
        _explosion(canvas, target, b.boomT);
      }
    }

    for (final f in s._floats) {
      final a = (1 - f.age / 1.2).clamp(0.0, 1.0);
      _label(canvas, Offset(f.x, f.y - f.age * 40), f.text, f.size, f.color.withValues(alpha: a), bold: true, outline: true);
    }
  }

  void _drawHero(Canvas canvas, double gy) {
    const hh = _BossScreenState._heroH;
    const hw = hh * 0.45;
    final x = s._heroX0 + s._heroDx;
    final bob = s._atk == _Atk.idle ? math.sin(s._t * 3).abs() * 2 : (s._atk == _Atk.dash ? -math.sin(s._t * 25).abs() * 4 : 0.0);
    canvas.drawOval(Rect.fromCenter(center: Offset(x, gy + 8), width: 56, height: 10), Paint()..color = const Color(0x44000000));
    canvas.save();
    canvas.translate(x - hw / 2, gy + 6 - hh + bob);
    HeroPaperDoll(s._equipped).paint(canvas, const Size(hw, hh));
    canvas.restore();
  }

  void _drawBomb(Canvas c, Offset p, double rot) {
    c.save();
    c.translate(p.dx, p.dy);
    c.rotate(math.sin(rot) * 0.4);
    c.drawCircle(Offset.zero, 11, Paint()..color = const Color(0xFF222222));
    c.drawCircle(const Offset(-3.5, -3.5), 3.5, Paint()..color = Colors.white24);
    c.drawLine(const Offset(0, -10), const Offset(5, -17), Paint()
      ..color = const Color(0xFF8D6E63)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round);
    final flick = 3 + math.sin(s._t * 40) * 1.5;
    c.drawCircle(const Offset(6, -19), flick, Paint()..color = const Color(0xFFFFB300));
    c.drawCircle(const Offset(6, -19), flick * 0.5, Paint()..color = Colors.white);
    c.restore();
  }

  void _explosion(Canvas c, Offset p, double t) {
    final r = 20 + t * 60;
    final a = (1 - t).clamp(0.0, 1.0);
    c.drawCircle(
        p,
        r,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withValues(alpha: a),
            const Color(0xFFFFC107).withValues(alpha: a * 0.9),
            const Color(0xFFFF5722).withValues(alpha: a * 0.5),
            Colors.transparent,
          ], stops: const [0, 0.3, 0.65, 1])
              .createShader(Rect.fromCircle(center: p, radius: r)));
    final spark = Paint()
      ..color = const Color(0xFFFFE082).withValues(alpha: a)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 8; i++) {
      final ang = i * math.pi / 4 + 0.3;
      c.drawLine(p + Offset(math.cos(ang), math.sin(ang)) * (r * 0.5), p + Offset(math.cos(ang), math.sin(ang)) * (r * 0.5 + 14 * (1 - t)), spark);
    }
  }

  void _hpBar(Canvas canvas, Offset bottomCenter, double w, double ratio, String text) {
    final r = Rect.fromLTWH(bottomCenter.dx - w / 2, bottomCenter.dy - 9, w, 8);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), Paint()..color = Colors.black87);
    final fill = Rect.fromLTWH(r.left + 1, r.top + 1, (w - 2) * ratio.clamp(0.0, 1.0), 6);
    canvas.drawRRect(RRect.fromRectAndRadius(fill, const Radius.circular(3)), Paint()..color = const Color(0xFFFF5252));
    _label(canvas, Offset(bottomCenter.dx, r.top - 2), text, 11, Colors.white);
  }

  void _label(Canvas canvas, Offset bottomCenter, String text, double size, Color color, {bool bold = false, bool outline = false}) {
    void draw(Color col, {Paint? fg}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: TextStyle(color: fg == null ? col : null, foreground: fg, fontSize: size, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(bottomCenter.dx - tp.width / 2, bottomCenter.dy - tp.height));
    }

    draw(Colors.black,
        fg: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = outline ? 3.5 : 2.5
          ..color = Colors.black.withValues(alpha: outline ? color.a : 0.55));
    draw(color);
  }

  void _background(Canvas canvas, double w, double h, double gy) {
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()
          ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1A0A12), Color(0xFF4A1F2A)])
              .createShader(Rect.fromLTWH(0, 0, w, gy)));
    canvas.drawCircle(Offset(w * 0.82, 52), 26, Paint()..color = const Color(0xFFFF4D4D).withValues(alpha: 0.8));
    final far = Path()..moveTo(0, gy);
    for (var x = 0.0; x <= w + 20; x += 20) {
      far.lineTo(x, gy - 46 - math.sin(x / 47) * 20 - math.sin(x / 19) * 8);
    }
    far.lineTo(w + 20, gy);
    far.close();
    canvas.drawPath(far, Paint()..color = const Color(0xFF2B1220));
    for (var i = 0; i < 6; i++) {
      final x = ((i * 97 + 30) % math.max(1.0, w)).toDouble();
      canvas.drawPath(Path()..moveTo(x, gy)..lineTo(x + 10, gy - 36 - (i % 3) * 8)..lineTo(x + 24, gy)..close(), Paint()..color = const Color(0xFF1A0A12));
    }
    canvas.drawRect(Rect.fromLTWH(0, gy, w, h - gy), Paint()..color = const Color(0xFF2A1A14));
    canvas.drawRect(Rect.fromLTWH(0, gy, w, 3), Paint()..color = Colors.white.withValues(alpha: 0.15));
  }

  @override
  bool shouldRepaint(covariant _BossStagePainter old) => true;
}
