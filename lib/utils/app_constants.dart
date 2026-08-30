/// 应用级常量：文档地址、更新源 URL、仓库链接。
class AppConstants {
  AppConstants._();

  // ── 文档 ──────────────────────────────────────────────

  /// 项目文档主页（GitHub Pages）。
  static const String docsUrl = 'https://bobocha214.github.io/EverLinkPage/';

  // ── GitHub Releases（更新检查源） ─────────────────────
  //
  // 更新检查直接调用 GitHub Releases API 拉取最新 Release：
  //   https://api.github.com/repos/{owner}/{repo}/releases/latest
// 解析其中的 tag_name / body / assets，按**当前平台**选取对应安装包
// （Android→.apk / Windows→.exe / Linux→.AppImage·.deb·.snap / macOS→.dmg /
// iOS→.ipa），避免把 Android 包推给 Windows 等。不依赖 update.json，也不走
// Gitee（Gitee 未登录 API 限速较严）。

  /// GitHub 仓库坐标（owner/repo）。
  static const String githubRepo = 'bobocha214/everlink';

  /// GitHub Releases API（最新 Release）。
  static const String githubReleasesUrl =
      'https://api.github.com/repos/$githubRepo/releases/latest';

  // ── Gitee 暂时禁用（2026-08-11） ─────────────────────
  // 如需启用，取消下方注释，并在 UpdateService 内补全 Gitee 分支、
  // ProfilePage 恢复 Gitee 切换按钮、MainScaffold 恢复按设置选择源。
  // static const String giteeRepo = 'zhiyu_214/ever-link';
  // static const String giteeReleasesUrl =
  //     'https://gitee.com/api/v5/repos/$giteeRepo/releases/latest';

  // ── 仓库链接（关于页面展示用） ─────────────────────────

  /// GitHub 仓库地址。
  static const String githubRepoUrl = 'https://github.com/bobocha214/everlink';

  /// Gitee 仓库地址。
  static const String giteeRepoUrl = 'https://gitee.com/zhiyu_214/ever-link';
}
