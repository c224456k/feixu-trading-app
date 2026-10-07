import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../app_version.dart';
import '../web_reload.dart';

typedef BuildInfoFetcher = Future<Map<String, dynamic>?> Function();

// 包在整個 App 外面：底下顯示版次；網頁版會定時去抓部署時一起發佈的 build_info.json，
// 如果線上版次跟自己不一樣，就在最上面跳一條跑馬燈通知「有新版」，按「更新」重新載入。
class VersionShell extends StatefulWidget {
  final Widget child;
  final BuildInfoFetcher? fetcher; // 測試用：覆寫抓版本資訊的方式
  final bool? enabled; // 測試用：強制開關檢查（預設只有網頁版開）
  final String? currentBuild; // 測試用
  final Duration interval;
  const VersionShell({
    super.key,
    required this.child,
    this.fetcher,
    this.enabled,
    this.currentBuild,
    this.interval = const Duration(minutes: 2),
  });

  @override
  State<VersionShell> createState() => _VersionShellState();
}

class _VersionShellState extends State<VersionShell> {
  Timer? _timer;
  Timer? _firstCheck;
  String _version = '';
  String? _newBuild;
  String _notes = '';
  String? _dismissed;

  String get _build => widget.currentBuild ?? kAppBuild;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((p) {
      if (mounted) setState(() => _version = p.version);
    }).catchError((_) {});
    if (widget.enabled ?? kIsWeb) {
      _firstCheck = Timer(const Duration(seconds: 15), _check);
      _timer = Timer.periodic(widget.interval, (_) => _check());
    }
  }

  @override
  void dispose() {
    _firstCheck?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _fetch() async {
    final f = widget.fetcher;
    if (f != null) return f();
    final url = Uri.base.resolve('build_info.json?t=${DateTime.now().millisecondsSinceEpoch}');
    final r = await http.get(url);
    if (r.statusCode != 200) return null;
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> _check() async {
    if (_build == 'dev') return;
    try {
      final info = await _fetch();
      final remote = info?['build'] as String?;
      if (!mounted || remote == null || remote.isEmpty) return;
      setState(() {
        if (remote != _build) {
          _newBuild = remote;
          _notes = (info?['notes'] as String?) ?? '';
        } else {
          _newBuild = null;
        }
      });
    } catch (_) {
      // 抓不到就算了，下次再試
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final showBanner = _newBuild != null && _dismissed != _newBuild;
    final label = [if (_version.isNotEmpty) 'v$_version', 'build $_build'].join(' · ');
    return Column(
      children: [
        if (showBanner)
          Material(
            color: const Color(0xFF7A4B00),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 34,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: _Marquee(
                        text: '🆕 有新版本了（build $_newBuild）${_notes.isNotEmpty ? '：$_notes' : ''}　請按右邊「更新」重新載入',
                        style: const TextStyle(color: Color(0xFFFFE08A), fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        backgroundColor: const Color(0xFFFFB02E),
                        foregroundColor: Colors.black,
                      ),
                      onPressed: () => reloadForNewVersion(_newBuild!),
                      child: const Text('更新', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      color: Colors.white70,
                      onPressed: () => setState(() => _dismissed = _newBuild),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          // 頂部/底部的安全區讓這層處理，裡面的畫面不要再重複留白
          child: MediaQuery(
            data: mq.copyWith(
              padding: mq.padding.copyWith(top: showBanner ? 0 : mq.padding.top, bottom: 0),
              viewPadding: mq.viewPadding.copyWith(top: showBanner ? 0 : mq.viewPadding.top, bottom: 0),
            ),
            child: widget.child,
          ),
        ),
        Material(
          color: const Color(0xFF0B0F15),
          child: Padding(
            padding: EdgeInsets.only(bottom: mq.padding.bottom),
            child: SizedBox(
              height: 18,
              width: double.infinity,
              child: Center(
                child: Text('費許交易  $label', style: const TextStyle(color: Colors.white30, fontSize: 10)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// 簡單的橫向跑馬燈：文字重複排好，整排往左平移一個文字寬度後無縫接回。
class _Marquee extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _Marquee({required this.text, required this.style});

  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  double _unit = 0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tp = TextPainter(text: TextSpan(text: widget.text, style: widget.style), textDirection: TextDirection.ltr, maxLines: 1)..layout();
    const gap = 60.0;
    final unit = tp.width + gap;
    if (unit != _unit) {
      _unit = unit;
      _c.duration = Duration(milliseconds: (unit / 70 * 1000).round()); // 每秒約 70 像素
      _c.repeat();
    }
    return LayoutBuilder(builder: (context, box) {
      final copies = (box.maxWidth / unit).ceil() + 2;
      return ClipRect(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            child: Transform.translate(
              offset: Offset(-_c.value * unit, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < copies; i++) ...[
                    Text(widget.text, style: widget.style, maxLines: 1, softWrap: false),
                    const SizedBox(width: gap),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}
