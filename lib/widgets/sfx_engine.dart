// 短音效播放器：網頁版用 Web Audio（每個音效只解碼一次，之後直接播，不會每次都開新的 <audio>）；
// 其他平台（含 widget 測試）什麼都不做。
export 'sfx_engine_stub.dart' if (dart.library.js_interop) 'sfx_engine_web.dart';
