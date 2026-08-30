import 'dart:convert';
import 'dart:io';

import 'package:everlink/utils/app_constants.dart';

/// 更新来源平台。
enum UpdateSource {
  /// GitHub（Releases API）。
  github,

  // Gitee 暂时禁用（2026-08-11）：
  // 取消注释并补全 UpdateService._checkGitee 后即可启用。
  // gitee,
}

/// 一次可用的版本更新信息。
class UpdateInfo {
  UpdateInfo({
    required this.version,
    this.build,
    required this.url,
    this.notes,
    this.forceUpdate = false,
    this.assetName,
  });

  final String version;
  final int? build;
  final String url;
  final String? notes;
  final bool forceUpdate;

  /// 命中的安装包文件名（如 EverLink-1.2.0-windows-x64-setup.exe），
  /// 用于向用户展示「本次更新是什么平台的包」，避免 Android 包被推到 Windows。
  final String? assetName;
}

/// 检查更新的结果。
class UpdateCheckResult {
  UpdateCheckResult._({
    this.info,
    this.error,
    this.upToDate = false,
  });

  /// 服务端存在更高版本。
  factory UpdateCheckResult.updateAvailable(UpdateInfo info) =>
      UpdateCheckResult._(info: info);

  /// 已是最新版。
  factory UpdateCheckResult.upToDate() => UpdateCheckResult._(upToDate: true);

  /// 检查过程出错（网络 / 解析 / 格式）。
  factory UpdateCheckResult.error(String message) =>
      UpdateCheckResult._(error: message);

  final UpdateInfo? info;
  final String? error;
  final bool upToDate;

  bool get hasUpdate => info != null;
}

/// 检查更新服务。
///
/// 当前使用 **GitHub Releases API** 拉取最新 Release：
///   GET https://api.github.com/repos/bobocha214/everlink/releases/latest
///
/// 返回 JSON 中：
///  - `tag_name`：版本标签（如 `v1.2.3`，自动去掉前缀 `v`）
///  - `body`：更新说明（Release 正文）
///  - `assets[]`：附件列表，`browser_download_url` 为下载地址；
///    按**当前运行平台**筛选对应安装包（Android→.apk / Windows→.exe /
///    Linux→.AppImage·.deb·.snap / macOS→.dmg / iOS→.ipa），取不到则
///    回退到 Release 页 `html_url`。这样 Windows 客户端永远不会被提示下载
///    Android 的 .apk，反之亦然。
///
/// Gitee 源已暂时禁用（见 [UpdateSource.gitee] 注释）。
class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  Future<UpdateCheckResult> check({
    required String currentVersion,
    required int currentBuild,
    UpdateSource source = UpdateSource.github,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // Gitee 暂时禁用（2026-08-11）：
    // if (source == UpdateSource.gitee) {
    //   return _checkGitee(currentVersion, currentBuild, timeout);
    // }
    return _checkGithub(currentVersion, currentBuild, timeout);
  }

  Future<UpdateCheckResult> _checkGithub(
    String currentVersion,
    int currentBuild,
    Duration timeout,
  ) async {
    return _checkRelease(
      url: AppConstants.githubReleasesUrl,
      platformName: 'GitHub',
      userAgent: 'EverLink',
      currentVersion: currentVersion,
      currentBuild: currentBuild,
      timeout: timeout,
    );
  }

  // Gitee 暂时禁用（2026-08-11）：启用时取消注释并实现。
  // Future<UpdateCheckResult> _checkGitee(
  //   String currentVersion,
  //   int currentBuild,
  //   Duration timeout,
  // ) async {
  //   return _checkRelease(
  //     url: AppConstants.giteeReleasesUrl,
  //     platformName: 'Gitee',
  //     userAgent: 'EverLink',
  //     currentVersion: currentVersion,
  //     currentBuild: currentBuild,
  //     timeout: timeout,
  //   );
  // }

  /// 通用 Release 解析（GitHub / Gitee 共用）。
  Future<UpdateCheckResult> _checkRelease({
    required String url,
    required String platformName,
    required String userAgent,
    required String currentVersion,
    required int currentBuild,
    required Duration timeout,
  }) async {
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      client.close();

      if (response.statusCode != 200) {
        return UpdateCheckResult.error(
            '$platformName 返回 HTTP ${response.statusCode}');
      }

      final json = jsonDecode(body) as Map<String, dynamic>;

      // 解析版本号（自动去掉前缀 v）。
      final tag = (json['tag_name'] as String? ?? '').trim();
      final version = tag.startsWith('v') ? tag.substring(1) : tag;
      if (version.isEmpty) {
        return UpdateCheckResult.error('Release 缺少 tag_name 字段');
      }

      final notes = json['body'] as String?;

      // 根据当前运行平台，从 assets 中选出对应安装包（Android→.apk，
      // Windows→.exe，Linux→.AppImage/.deb/.snap，macOS→.dmg，iOS→.ipa）。
      // 取不到则回退到 Release 页面（html_url）。
      String? downloadUrl;
      String? assetName;
      final assets = json['assets'];
      if (assets is List) {
        final sel = _selectPlatformAsset(assets);
        if (sel != null) {
          downloadUrl = sel.url;
          assetName = sel.name;
        }
      }
      downloadUrl ??= json['html_url'] as String?;
      if (downloadUrl == null || downloadUrl.isEmpty) {
        return UpdateCheckResult.error('Release 未提供下载地址');
      }

      if (!_isNewer(version, currentVersion)) {
        return UpdateCheckResult.upToDate();
      }
      return UpdateCheckResult.updateAvailable(
        UpdateInfo(
          version: version,
          url: downloadUrl,
          notes: notes,
          assetName: assetName,
        ),
      );
    } on SocketException {
      return UpdateCheckResult.error('无法连接 $platformName，请检查网络');
    } on FormatException {
      return UpdateCheckResult.error('Release 数据解析失败');
    } catch (e) {
      return UpdateCheckResult.error('检查更新失败：$e');
    }
  }

  /// 当前运行平台对应的安装包筛选规则：
  /// 返回 (平台关键字, 扩展名优先级列表，越靠前越优先)。
  (String, List<String>) _platformAssetRule() {
    if (Platform.isAndroid) return ('android', ['.apk']);
    if (Platform.isWindows) return ('windows', ['.exe', '.zip']);
    if (Platform.isLinux) return ('linux', ['.AppImage', '.deb', '.snap']);
    if (Platform.isMacOS) return ('macos', ['.dmg', '.zip']);
    if (Platform.isIOS) return ('ios', ['.ipa']);
    // Web / 其它：宽松匹配所有常见安装包。
    return ('', ['.apk', '.exe', '.zip', '.dmg', '.AppImage', '.deb', '.snap', '.ipa']);
  }

  /// 从 Release assets 中选出当前平台对应的安装包。
  ///
  /// 必须是「平台关键字」命中（如 windows 包名含 'windows'）且扩展名在优先级
  /// 列表内；优先取优先级最高（列表最前）的条目。这样 Windows 永远拿不到
  /// Android 的 .apk，反之亦然。取不到返回 null（由调用方回退到 Release 页）。
  ({String url, String name})? _selectPlatformAsset(List assets) {
    final rule = _platformAssetRule();
    final keyword = rule.$1.toLowerCase();
    final exts = rule.$2.map((e) => e.toLowerCase()).toList();
    String? bestUrl;
    String? bestName;
    var bestPriority = exts.length; // 越小越优先
    for (final a in assets) {
      if (a is! Map) continue;
      final name = ((a['name'] as String?) ?? '').toLowerCase();
      final url = a['browser_download_url'] as String?;
      if (url == null || url.isEmpty) continue;
      if (keyword.isNotEmpty && !name.contains(keyword)) continue;
      final priority = exts.indexWhere((ext) => name.endsWith(ext));
      if (priority < 0) continue;
      if (priority < bestPriority) {
        bestPriority = priority;
        bestUrl = url;
        bestName = a['name'] as String?;
      }
    }
    if (bestUrl == null || bestName == null) return null;
    return (url: bestUrl, name: bestName);
  }

  /// 比较远端版本是否比当前更新（仅比对版本号）。
  bool _isNewer(String remoteVersion, String currentVersion) {
    return _compareVersion(remoteVersion, currentVersion) > 0;
  }

  int _compareVersion(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }
}
