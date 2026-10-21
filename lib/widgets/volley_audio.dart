import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 怪物打排球的音效與背景音樂（原創程式合成，產生腳本：DClab/gen_volley_audio.py）。
// 設定獨立存（不跟賭場共用）；瀏覽器擋自動播放時，玩家按一下喇叭選單就會開始。
class VolleyAudio {
  VolleyAudio._();
  static final VolleyAudio instance = VolleyAudio._();

  static const _musicKey = 'volley_music_on';
  static const _sfxKey = 'volley_sfx_on';

  final ValueNotifier<bool> music = ValueNotifier(true);
  final ValueNotifier<bool> sfx = ValueNotifier(true);
  AudioPlayer? _player;
  bool _loaded = false;
  bool _active = false;
  final Map<String, DateTime> _lastPlay = {};

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      music.value = p.getBool(_musicKey) ?? true;
      sfx.value = p.getBool(_sfxKey) ?? true;
    } catch (_) {}
  }

  Future<void> enter() async {
    await _load();
    _active = true;
    if (music.value) await _playMusic();
  }

  Future<void> leave() async {
    _active = false;
    try {
      await _player?.stop();
      await _player?.dispose();
    } catch (_) {}
    _player = null;
  }

  Future<void> _playMusic() async {
    try {
      var p = _player;
      if (p == null) {
        p = AudioPlayer();
        _player = p;
        await p.setReleaseMode(ReleaseMode.loop);
        await p.setVolume(0.3);
        await p.play(AssetSource('audio/volley_theme.mp3'));
      } else {
        await p.resume();
      }
    } catch (_) {}
  }

  /// 對戰中把音樂壓小聲，讓擊球聲聽得清楚；回大廳恢復。
  Future<void> duck(bool on) async {
    try {
      await _player?.setVolume(on ? 0.16 : 0.3);
    } catch (_) {}
  }

  Future<void> toggleMusic() async {
    music.value = !music.value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_musicKey, music.value);
    } catch (_) {}
    if (music.value && _active) {
      await _playMusic();
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
    if (sfx.value) play('hit');
  }

  /// 播一次音效（volley_名稱.mp3）。同一個音效 40ms 內不重複播，避免連續事件爆音。
  Future<void> play(String name, {double volume = 0.9}) async {
    if (!sfx.value) return;
    final now = DateTime.now();
    final last = _lastPlay[name];
    if (last != null && now.difference(last).inMilliseconds < 40) return;
    _lastPlay[name] = now;
    try {
      final p = AudioPlayer();
      await p.setReleaseMode(ReleaseMode.release);
      await p.setVolume(volume);
      p.onPlayerComplete.first.then((_) => p.dispose());
      await p.play(AssetSource('audio/volley_$name.mp3'));
    } catch (_) {}
  }
}

class VolleyAudioButton extends StatelessWidget {
  const VolleyAudioButton({super.key});

  @override
  Widget build(BuildContext context) {
    final a = VolleyAudio.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: a.music,
      builder: (context, musicOn, _) => ValueListenableBuilder<bool>(
        valueListenable: a.sfx,
        builder: (context, sfxOn, _) => PopupMenuButton<String>(
          tooltip: '聲音設定',
          icon: Icon(musicOn || sfxOn ? Icons.volume_up : Icons.volume_off),
          onSelected: (v) => v == 'music' ? a.toggleMusic() : a.toggleSfx(),
          itemBuilder: (_) => [
            CheckedPopupMenuItem(value: 'music', checked: musicOn, child: const Text('背景音樂')),
            CheckedPopupMenuItem(value: 'sfx', checked: sfxOn, child: const Text('遊戲音效')),
          ],
        ),
      ),
    );
  }
}
