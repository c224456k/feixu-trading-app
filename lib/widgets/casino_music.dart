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
  static const _sfxKey = 'casino_sfx_on';

  final ValueNotifier<bool> on = ValueNotifier(false);
  final ValueNotifier<bool> sfx = ValueNotifier(true); // 音效預設開（玩家按下去時瀏覽器就允許出聲）
  final Set<String> _played = {};
  AudioPlayer? _player;
  int _screens = 0;
  bool _loaded = false;

  Future<void> _loadPref() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      on.value = p.getBool(_prefKey) ?? false;
      sfx.value = p.getBool(_sfxKey) ?? true;
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

  Future<void> toggleSfx() async {
    sfx.value = !sfx.value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_sfxKey, sfx.value);
    } catch (_) {}
    if (sfx.value) playSfx('chip');
  }

  // 播一次短音效（chip / chipdrop / win / card / dice）；每個音效用自己的播放器，播完就釋放，可以重疊。
  Future<void> playSfx(String name) async {
    await _loadPref();
    if (!sfx.value) return;
    try {
      final p = AudioPlayer();
      await p.setReleaseMode(ReleaseMode.release);
      await p.setVolume(0.8);
      p.onPlayerComplete.first.then((_) => p.dispose());
      await p.play(AssetSource('audio/$name.mp3'));
    } catch (_) {}
  }

  // 同一個事件（例如某一局的贏錢）只播一次；key 要包含局號
  void playSfxOnce(String key, String name) {
    if (!_played.add(key)) return;
    if (_played.length > 200) _played.remove(_played.first);
    playSfx(name);
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

// 放在 AppBar 右邊的聲音選單：背景音樂、音效各自開關
class MusicButton extends StatelessWidget {
  const MusicButton({super.key});

  @override
  Widget build(BuildContext context) {
    final m = CasinoMusic.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: m.on,
      builder: (context, musicOn, _) => ValueListenableBuilder<bool>(
        valueListenable: m.sfx,
        builder: (context, sfxOn, _) => PopupMenuButton<String>(
          tooltip: '聲音設定',
          icon: Icon(musicOn || sfxOn ? Icons.volume_up : Icons.volume_off),
          onSelected: (v) => v == 'music' ? m.toggle() : m.toggleSfx(),
          itemBuilder: (_) => [
            CheckedPopupMenuItem(value: 'music', checked: musicOn, child: const Text('背景音樂')),
            CheckedPopupMenuItem(value: 'sfx', checked: sfxOn, child: const Text('籌碼音效')),
          ],
        ),
      ),
    );
  }
}
