import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:everlink/services/settings_service.dart';
import 'package:everlink/services/update_service.dart';
import 'package:everlink/ui/home_page.dart';
import 'package:everlink/ui/history_page.dart';
import 'package:everlink/ui/profile_page.dart';
import 'package:everlink/ui/tools_page.dart';
import 'package:everlink/ui/update_dialog.dart';
import 'package:everlink/ui/widgets/glass.dart';
import 'package:everlink/utils/app_theme.dart';

/// 底部导航目标（设备 / 历史 / 工具 / 我的），悬浮与普通两种底栏共用。
///
/// 选中样式的核心是「outlined → filled 图标区分 + 圆润 indicator 高亮」，
/// 选中的 filled 图标统一染成品牌主色，使选中态一目了然。
List<NavigationDestination> _navDestinations(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final primary = scheme.primary;
  final unselected = scheme.onSurfaceVariant.withValues(alpha: 0.72);
  return [
    NavigationDestination(
      icon: Icon(Icons.devices_outlined, color: unselected),
      selectedIcon: Icon(Icons.devices, color: primary),
      label: '设备',
    ),
    NavigationDestination(
      icon: Icon(Icons.history_outlined, color: unselected),
      selectedIcon: Icon(Icons.history, color: primary),
      label: '历史',
    ),
    NavigationDestination(
      icon: Icon(Icons.network_ping_outlined, color: unselected),
      selectedIcon: Icon(Icons.network_ping, color: primary),
      label: '工具',
    ),
    NavigationDestination(
      icon: Icon(Icons.person_outline, color: unselected),
      selectedIcon: Icon(Icons.person, color: primary),
      label: '我的',
    ),
  ];
}

/// 应用主框架：底部导航栏承载"设备 / 历史 / 工具 / 我的"四个页面。
///
/// 菜单栏样式由 [SettingsService.navFloating] 控制：
/// - 开启：毛玻璃浮动栏（[GlassContainer] 包裹 [NavigationBar] + extendBody）；
/// - 关闭：原生内嵌 [NavigationBar]。
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _index = 0;

  final List<Widget> _pages = const [
    HomePage(),
    HistoryPage(),
    ToolsPage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onSettingsChanged);
    // 延迟到首帧渲染完成后，在后台静默检查更新。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoCheckUpdate();
    });
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  /// 启动时自动检查更新（若已开启且距上次检查超过 6 小时）。
  Future<void> _autoCheckUpdate() async {
    final settings = SettingsService.instance;
    if (!settings.autoCheckUpdate) return;

    // 距上次检查不足 6 小时则跳过，避免频繁请求。
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - settings.lastAutoCheckMs <
        const Duration(hours: 6).inMilliseconds) {
      return;
    }
    await settings.setLastAutoCheckMs(now);

    final info = await PackageInfo.fromPlatform();
    final result = await UpdateService.instance.check(
      currentVersion: info.version,
      currentBuild: int.tryParse(info.buildNumber) ?? 0,
      // Gitee 暂时禁用（2026-08-11），固定使用 GitHub Releases。
      source: UpdateSource.github,
    );

    if (!mounted) return;

    // 检测到新版本：直接弹出专用更新对话框（不再用底部 SnackBar）。
    if (result.hasUpdate && result.info != null) {
      final u = result.info!;
      final confirmed = await showUpdateDialog(context, u);
      if (!mounted) return;
      if (confirmed) {
        await showDownloadDialog(context, u.url);
      }
    }
    // 静默检查：无更新或出错时不打扰用户。
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return Scaffold(
      // 悬浮底栏需要内容延伸到导航栏之下。
      extendBody: settings.navFloating,
      body: _pages[_index],
      bottomNavigationBar: _NavBar(
        index: _index,
        onChanged: (i) => setState(() => _index = i),
        floating: settings.navFloating,
      ),
    );
  }
}

/// 底部导航栏：悬浮（毛玻璃浮动）与普通（嵌入表面）共用原生 [NavigationBar] 的
/// 选中范式，差异只在容器外观。
class _NavBar extends StatelessWidget {
  const _NavBar({
    required this.index,
    required this.onChanged,
    required this.floating,
  });
  final int index;
  final ValueChanged<int> onChanged;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = SettingsService.instance;

    final navBar = NavigationBar(
      backgroundColor: floating ? Colors.transparent : scheme.surface,
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
      indicatorShape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      surfaceTintColor: floating ? Colors.transparent : null,
      shadowColor: floating ? Colors.transparent : null,
      elevation: floating ? 0 : null,
      selectedIndex: index,
      onDestinationSelected: onChanged,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: _navDestinations(context),
    );

    if (floating) {
      return Container(
        margin: const EdgeInsets.fromLTRB(18, 0, 18, 16),
        child: GlassContainer(
          borderRadius: 26,
          blur: AppTheme.glassBlur(settings.glassStrength),
          surfaceAlpha: 0.72,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
          child: navBar,
        ),
      );
    }

    return navBar;
  }
}
