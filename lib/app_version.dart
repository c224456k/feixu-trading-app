// 版次：網頁版由 GitHub Actions 編譯時用 --dart-define=APP_BUILD=<流水號>-<commit 前 7 碼> 帶入，
// 本機直接跑沒帶就是 'dev'（dev 不做「有新版」檢查）。
const String kAppBuild = String.fromEnvironment('APP_BUILD', defaultValue: 'dev');
