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
  });

  final String version;
  final int? build;
  final String url;
  final String? notes;
  final bool forceUpdate;
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
///    优先取 `.apk` 附件，取不到则回退到 Release 页 `html_url`
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

      // 从 assets 中取出 .apk 的下载地址；取不到则回退到 Release 页面。
      String? downloadUrl;
      final assets = json['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is Map) {
            final name = (a['name'] as String? ?? '');
            if (name.endsWith('.apk')) {
              downloadUrl = a['browser_download_url'] as String?;
              break;
            }
          }
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
