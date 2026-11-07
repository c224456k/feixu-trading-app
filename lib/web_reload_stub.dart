// 非網頁平台（Android / Windows）沒有「重新載入網頁」這回事。
void reloadForNewVersion(String build) {}

// 非網頁平台沒有分頁可開，回傳 false 讓畫面改顯示網址。
bool openInNewTab(String url) => false;
