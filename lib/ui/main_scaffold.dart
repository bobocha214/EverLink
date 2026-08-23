import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:everlink/services/settings_service.dart';
import 'package:everlink/services/update_service.dart';
import 'package:everlink/ui/home_page.dart';
import 'package:everlink/ui/history_page.dart';
import 'package:everlink/ui/profile_page.dart';
import 'package:everlink/ui/tools_page.dart';
import 'package:everlink/ui/update_dialog.dart';

/// 应用主框架：底部导航栏承载"设备 / 历史 / 工具 / 我的"四个页面。
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
    // 延迟到首帧渲染完成后，在后台静默检查更新。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoCheckUpdate();
    });
  }

  /// 启动时自动检查更新（若已开启且距上次检查超过 6 小时）。
  Future<void> _autoCheckUpdate() async {
    final settings = SettingsService.instance;
    if (!settings.autoCheckUpdate) return;

    // 距上次检查不足 6 小时则跳过，避免频繁请求。
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - settings.lastAutoCheckMs < const Duration(hours: 6).inMilliseconds) {
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
    return Scaffold(
      body: _pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.devices_outlined),
            selectedIcon: Icon(Icons.devices),
            label: '设备',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: '历史',
          ),
          NavigationDestination(
            icon: Icon(Icons.network_ping_outlined),
            selectedIcon: Icon(Icons.network_ping),
            label: '工具',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
