import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sfx_engine.dart';

// 鐮刀風暴的音效與背景音樂（原創程式合成，產生腳本：DClab/gen_sickle_audio.py）。
// 設定獨立存（不跟賭場共用）；瀏覽器擋自動播放時，玩家按一下喇叭選單就會開始。
class SickleAudio {
  SickleAudio._();
  static final SickleAudio instance = SickleAudio._();

  static const _musicKey = 'sickle_music_on';
  static const _sfxKey = 'sickle_sfx_on';

  final ValueNotifier<bool> music = ValueNotifier(true);
  final ValueNotifier<bool> sfx = ValueNotifier(true);
  AudioPlayer? _player;
  bool _loaded = false;
  bool _active = false;
  final Map<String, DateTime> _lastPlay = {};
  final SfxEngine _sfx = SfxEngine();
  static const _names = ['clash', 'knock', 'bounce', 'pickup', 'pickup_big', 'item', 'kill', 'die', 'level', 'mhit', 'mdie', 'win'];

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
    if (!kIsWeb) return; // 只有網頁版（也讓 widget 測試不用音效外掛）
    await _load();
    _sfx.load([for (final n in _names) 'assets/audio/sickle_$n.mp3']);
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
        await p.play(AssetSource('audio/sickle_theme.mp3'));
      } else {
        await p.resume();
      }
    } catch (_) {}
  }

  /// 對戰中把音樂壓小聲，讓刀聲聽得清楚；回選單恢復。
  Future<void> duck(bool on) async {
    try {
      await _player?.setVolume(on ? 0.16 : 0.3);
    } catch (_) {}
  }

  /// 玩家點一下畫面時叫醒音效（瀏覽器規定要互動後才能出聲）
  void unlock() => _sfx.unlock();

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
    if (sfx.value) play('clash');
  }

  /// 播一次音效（sickle_名稱.mp3）。同一個音效 60ms 內不重複播，避免連續事件爆音。
  Future<void> play(String name, {double volume = 0.9}) async {
    if (!kIsWeb || !sfx.value) return;
    final now = DateTime.now();
    final last = _lastPlay[name];
    if (last != null && now.difference(last).inMilliseconds < 60) return;
    _lastPlay[name] = now;
    _sfx.play('assets/audio/sickle_$name.mp3', volume);
  }
}

class SickleAudioButton extends StatelessWidget {
  const SickleAudioButton({super.key});

  @override
  Widget build(BuildContext context) {
    final a = SickleAudio.instance;
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
