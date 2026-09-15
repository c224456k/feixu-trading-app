import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

// 直接查 GitHub 公開的 Release API，不用另外維護一個「最新版本是幾號」的後端端點——
// 只要每次發新版都建一個 GitHub Release，這裡永遠自動抓得到最新的，不會忘記同步。
class UpdateInfo {
  final String latestVersion;
  final String releaseUrl;

  UpdateInfo({required this.latestVersion, required this.releaseUrl});
}

class UpdateChecker {
  static const _latestReleaseApi =
      'https://api.github.com/repos/c224456k/feixu-trading-app/releases/latest';

  /// 查不到、逾時、解析失敗都直接回傳 null，不要因為這個擋住正常使用 App。
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final current = await PackageInfo.fromPlatform();
      final resp = await http.get(Uri.parse(_latestReleaseApi)).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String).replaceFirst(RegExp(r'^v'), '');
      final htmlUrl = json['html_url'] as String;

      if (_isNewer(tag, current.version)) {
        return UpdateInfo(latestVersion: tag, releaseUrl: htmlUrl);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _isNewer(String latest, String current) {
    List<int> parse(String v) => v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final l = parse(latest);
    final c = parse(current);
    for (var i = 0; i < 3; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv != cv) return lv > cv;
    }
    return false;
  }
}
