import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 賭場背景音樂（原創程式合成的爵士搖擺，循環播放）。
// 瀏覽器規定要玩家按過一下才能出聲，所以預設關閉；玩家開過之後會記住，
// 之後進任何賭場畫面都會自動接著播，離開所有賭場畫面就停。
class CasinoMusic {
  CasinoMusic._();
  static final CasinoMusic instance = CasinoMusic._();

  static const _prefKey = 'casino_music_on';

  final ValueNotifier<bool> on = ValueNotifier(false);
  AudioPlayer? _player;
  int _screens = 0;
  bool _loaded = false;

  Future<void> _loadPref() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      on.value = p.getBool(_prefKey) ?? false;
    } catch (_) {}
  }

  Future<void> enter() async {
    _screens++;
    await _loadPref();
    if (on.value) await _play();
  }

  Future<void> leave() async {
    _screens = (_screens - 1).clamp(0, 999);
    if (_screens == 0) {
      try {
        await _player?.pause();
      } catch (_) {}
    }
  }

  Future<void> toggle() async {
    on.value = !on.value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_prefKey, on.value);
    } catch (_) {}
    if (on.value) {
      await _play();
    } else {
      try {
        await _player?.pause();
      } catch (_) {}
    }
  }

  Future<void> _play() async {
    try {
      var p = _player;
      if (p == null) {
        p = AudioPlayer();
        _player = p;
        await p.setReleaseMode(ReleaseMode.loop);
        await p.setVolume(0.35);
        await p.play(AssetSource('audio/casino_swing.mp3'));
      } else {
        await p.resume();
      }
    } catch (_) {
      // 瀏覽器還沒允許自動播放：等玩家按喇叭按鈕就好
    }
  }
}

// 放在 AppBar 右邊的喇叭開關
class MusicButton extends StatelessWidget {
  const MusicButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: CasinoMusic.instance.on,
      builder: (context, isOn, _) => IconButton(
        onPressed: CasinoMusic.instance.toggle,
        icon: Icon(isOn ? Icons.volume_up : Icons.volume_off),
        tooltip: isOn ? '關閉背景音樂' : '開啟背景音樂',
      ),
    );
  }
}
