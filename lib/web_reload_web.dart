import 'package:web/web.dart' as web;

// 重新載入頁面。網址後面加 ?v=<新版次>：GitHub Pages 的 index.html 會被瀏覽器快取約 10 分鐘，
// 單純 reload 可能又拿到舊頁面，換一個網址才保證抓到新的。
void reloadForNewVersion(String build) {
  final uri = Uri.base.replace(queryParameters: {'v': build});
  web.window.location.replace(uri.toString());
}

// 在新分頁開外部網址（例如獨立部署的萌獸大冒險）。
bool openInNewTab(String url) {
  web.window.open(url, '_blank');
  return true;
}
