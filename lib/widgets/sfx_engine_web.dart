import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:web/web.dart' as web;

class SfxEngine {
  web.AudioContext? _ctx;
  final Map<String, web.AudioBuffer> _buf = {};
  final Set<String> _loading = {};

  web.AudioContext get _c => _ctx ??= web.AudioContext();

  /// 先把音效載入、解碼好（之後播放不會卡）
  Future<void> load(List<String> assets) async {
    for (final a in assets) {
      if (_buf.containsKey(a) || !_loading.add(a)) continue;
      try {
        final data = await rootBundle.load(a);
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        // decodeAudioData 會拿走 ArrayBuffer，所以複製一份給它
        final copy = Uint8List.fromList(bytes);
        _buf[a] = await _c.decodeAudioData(copy.buffer.toJS).toDart;
      } catch (_) {
      } finally {
        _loading.remove(a);
      }
    }
  }

  /// 瀏覽器要使用者互動後才能出聲：每次播放前順便叫醒
  void unlock() {
    try {
      if (_c.state == 'suspended') _c.resume();
    } catch (_) {}
  }

  void play(String asset, double volume) {
    final b = _buf[asset];
    if (b == null) {
      load([asset]);
      return;
    }
    try {
      final c = _c;
      if (c.state == 'suspended') c.resume();
      final src = c.createBufferSource()..buffer = b;
      final g = c.createGain();
      g.gain.value = volume;
      src.connect(g);
      g.connect(c.destination);
      src.start();
    } catch (_) {}
  }
}
