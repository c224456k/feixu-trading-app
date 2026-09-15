import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_client.dart';
import '../models.dart';

class BossScreen extends StatefulWidget {
  const BossScreen({super.key});

  @override
  State<BossScreen> createState() => _BossScreenState();
}

class _BossScreenState extends State<BossScreen> with TickerProviderStateMixin {
  final _api = ApiClient();

  BossStatus? _status;
  String? _error;
  bool _loading = true;
  bool _attacking = false; // 動畫播放+API呼叫進行中，鎖住按鈕避免連點
  Timer? _refreshTimer;
  Timer? _clockTimer;

  // 怪物呼吸/晃動動畫：一直循環播放，讓玩家感覺牠「活著」。
  late final AnimationController _idleController;
  // 炸彈投擲動畫：按下按鈕才觸發一次。
  late final AnimationController _throwController;
  late final Animation<double> _throwProgress;

  @override
  void initState() {
    super.initState();
    _idleController = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _throwController = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _throwProgress = CurvedAnimation(parent: _throwController, curve: Curves.easeIn);

    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) => _load(silent: true));
    // 只是為了讓倒數計時的文字每秒重新畫一次，不用真的重抓資料。
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _idleController.dispose();
    _throwController.dispose();
    _refreshTimer?.cancel();
    _clockTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final status = await _api.fetchBossStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _throwBomb() async {
    if (_attacking) return;
    setState(() => _attacking = true);

    await _throwController.forward(from: 0);

    try {
      final result = await _api.attackBoss();
      if (!mounted) return;
      setState(() => _status = result.status);
      if (result.defeated) {
        _showResultDialog('🎉 打倒了！', result.message);
      } else if (!result.ok) {
        _showSnack(result.message);
      }
    } catch (e) {
      if (mounted) _showSnack('攻擊失敗：$e');
    } finally {
      _throwController.reset();
      if (mounted) setState(() => _attacking = false);
    }
  }

  void _showSnack(String text) {
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

    final hpPct = status.currentHp! / status.maxHp!;
    final hpColor = hpPct > 0.5 ? Colors.green : (hpPct > 0.25 ? Colors.orange : Colors.redAccent);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 怪物 + 炸彈飛行動畫
        SizedBox(
          height: 220,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _idleController,
                builder: (context, child) {
                  final sway = math.sin(_idleController.value * math.pi * 2) * 6;
                  final scale = 1.0 + _idleController.value * 0.05;
                  return Transform.translate(
                    offset: Offset(sway, 0),
                    child: Transform.scale(scale: scale, child: child),
                  );
                },
                child: const Text('👹', style: TextStyle(fontSize: 100)),
              ),
              AnimatedBuilder(
                animation: _throwProgress,
                builder: (context, child) {
                  final t = _throwProgress.value;
                  if (t <= 0 || t >= 1) return const SizedBox.shrink();
                  // 炸彈從畫面下方拋物線飛到怪物身上。
                  final dx = (1 - t) * 0 + t * 0; // 水平不特別偏移，維持置中丟過去的感覺
                  final dy = 90 - (t * 170) + math.sin(t * math.pi) * -40;
                  final opacity = t > 0.85 ? (1 - t) / 0.15 : 1.0;
                  return Transform.translate(
                    offset: Offset(dx, dy),
                    child: Opacity(
                      opacity: opacity.clamp(0.0, 1.0),
                      child: Text(t > 0.85 ? '💥' : '💣', style: const TextStyle(fontSize: 40)),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
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
                    Text('${status.currentHp}/${status.maxHp}', style: TextStyle(color: hpColor, fontWeight: FontWeight.bold)),
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
                _row('💣 炸彈價格', '${NumberFormat('#,##0').format(status.bombCost)} 元／顆（${status.bombDamage} 傷害）'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _attacking ? null : _throwBomb,
          icon: const Icon(Icons.local_fire_department),
          label: Text(_attacking ? '投擲中…' : '投擲炸彈（${NumberFormat('#,##0').format(status.bombCost)} 元）'),
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
                    title: Text(status.topDamage[i].userId),
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
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
