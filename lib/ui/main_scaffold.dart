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

/// 底部导航项（设备 / 历史 / 工具 / 我的）。
///
/// [label] 不再作为常驻文字显示，只用于长按提示（Tooltip）与无障碍语义，
/// 让底栏保持纯图标的简洁观感。
class _NavItem {
  const _NavItem(this.outline, this.filled, this.label);

  final IconData outline;
  final IconData filled;
  final String label;
}

const List<_NavItem> _navItems = [
  _NavItem(Icons.devices_outlined, Icons.devices, '设备'),
  _NavItem(Icons.history_outlined, Icons.history, '历史'),
  _NavItem(Icons.network_ping_outlined, Icons.network_ping, '工具'),
  _NavItem(Icons.person_outline, Icons.person, '我的'),
];

/// 供普通（非悬浮）底栏使用的原生目标列表：隐藏文字标签，靠
/// 「outlined → filled 图标 + 胶囊 indicator」区分选中态。
List<NavigationDestination> _navDestinations(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final primary = scheme.primary;
  final unselected = scheme.onSurfaceVariant.withValues(alpha: 0.72);
  return [
    for (final item in _navItems)
      NavigationDestination(
        icon: Icon(item.outline, color: unselected),
        selectedIcon: Icon(item.filled, color: primary),
        label: item.label,
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
    final floating = settings.navFloating;
    return Scaffold(
      // 悬浮 dock 用 Stack 叠在页面之上、贴住屏幕底部居中，
      // 不依赖 bottomNavigationBar + extendBody 的固有排版（自定义 widget 在该
      // 布局下不可靠，页面内容不满屏时会被推到屏幕中间）。
      body: Stack(
        // 不裁剪，保留玻璃容器的外发光阴影。
        clipBehavior: Clip.none,
        children: [
          _pages[_index],
          if (floating)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _FloatingDock(
                index: _index,
                onChanged: (i) => setState(() => _index = i),
              ),
            ),
        ],
      ),
      // 非悬浮模式走原生 NavigationBar（同样隐藏文字），稳定贴底。
      bottomNavigationBar: floating
          ? null
          : _NavBar(
              index: _index,
              onChanged: (i) => setState(() => _index = i),
              floating: false,
            ),
    );
  }
}

/// 底部导航栏：悬浮时渲染为无文字的毛玻璃胶囊 dock，关闭时为原生
/// [NavigationBar]（同样隐藏文字标签，仅压低高度）。
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
    if (floating) {
      return _FloatingDock(index: index, onChanged: onChanged);
    }

    final scheme = Theme.of(context).colorScheme;
    return NavigationBar(
      height: 62,
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primary.withValues(alpha: 0.16),
      indicatorShape: const StadiumBorder(),
      selectedIndex: index,
      onDestinationSelected: onChanged,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      destinations: _navDestinations(context),
    );
  }
}

/// 无文字的毛玻璃胶囊 dock。
///
/// 选中态由一颗在轨道上平滑滑动的胶囊高亮表达（[AnimatedPositioned]），
/// 图标同时做 outlined → filled 切换与轻微放大，整体只用圆角几何，
/// 不出现任何直角与文字；文案通过长按 Tooltip 兜底。
///
/// 宽度按内容自适应（不写死），因此在任意屏宽下都不会横向溢出；
/// 底部安全区用 [MediaQuery.viewPaddingOf] 兜底，避免 dock 压在系统
/// 手势条 / 底部指示条上。
class _FloatingDock extends StatelessWidget {
  const _FloatingDock({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const double _inset = 10; // 玻璃外框内边距
  static const double _item = 60; // 单个图标按钮边长

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = SettingsService.instance;
    final barHeight = _item + _inset * 2;

    // 边缘到边缘模式下系统手势条只体现在 viewPadding 中（padding 为 0），
    // 故用 viewPadding 兜底底部安全区；无手势条的设备留 12 呼吸空间。
    final viewBottom = MediaQuery.viewPaddingOf(context).bottom;
    final bottomInset = viewBottom > 0 ? viewBottom : 12.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: GlassContainer(
            // 不传 width：玻璃容器按子组件（图标轨道）内容宽度自适应，
            // 从根本上避免固定宽度导致的横向溢出。
            height: barHeight,
            borderRadius: barHeight / 2, // 完整胶囊
            blur: AppTheme.glassBlur(settings.glassStrength),
            // 提高不透明度，使 dock 作为独立浮层从页面背景中清晰分离。
            surfaceAlpha: 0.85,
            child: _DockTrack(
              index: index,
              scheme: scheme,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    );
  }
}

/// dock 内部的图标轨道 + 滑动高亮。
///
/// [Row]（非定位子节点）决定整条轨道的固有宽度，[AnimatedPositioned]
/// 的高亮相对该宽度滑动；这样轨道宽度 = 内容宽度，外层玻璃容器得以
/// 自适应而不溢出。
class _DockTrack extends StatelessWidget {
  const _DockTrack({
    required this.index,
    required this.scheme,
    required this.onChanged,
  });

  final int index;
  final ColorScheme scheme;
  final ValueChanged<int> onChanged;

  static const double _inset = 10;
  static const double _item = 60;
  static const double _gap = 6;
  static const double _icon = 26;

  @override
  Widget build(BuildContext context) {
    final count = _navItems.length;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 滑动胶囊高亮（定位子节点，不影响轨道固有宽度）
        AnimatedPositioned(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          left: _inset + index * (_item + _gap),
          top: _inset,
          width: _item,
          height: _item,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_item / 2),
              border: Border.all(
                color: scheme.primary.withValues(alpha: 0.35),
                width: 1.5,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.primary.withValues(alpha: 0.45),
                  scheme.primary.withValues(alpha: 0.26),
                ],
              ),
              // 让选中高亮浮于轨道之上，与底色形成明确层次。
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
          ),
        ),
        // 图标轨道（非定位子节点 → 决定 Stack 固有宽度）
        Padding(
          padding: const EdgeInsets.all(_inset),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < count; i++) ...[
                if (i > 0) const SizedBox(width: _gap),
                _DockButton(
                  item: _navItems[i],
                  selected: i == index,
                  size: _item,
                  iconSize: _icon,
                  onTap: () => onChanged(i),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// dock 内单个图标按钮：圆形水波纹 + 选中放大 + outlined/filled 切换。
class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.item,
    required this.selected,
    required this.size,
    required this.iconSize,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final double size;
  final double iconSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? scheme.primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.5);

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: Tooltip(
        message: item.label,
        child: Material(
          color: Colors.transparent,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            splashColor: scheme.primary.withValues(alpha: 0.18),
            highlightColor: scheme.primary.withValues(alpha: 0.08),
            child: SizedBox(
              width: size,
              height: size,
              child: Center(
                child: AnimatedScale(
                  scale: selected ? 1.14 : 1,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: Icon(
                      selected ? item.filled : item.outline,
                      key: ValueKey<bool>(selected),
                      size: iconSize,
                      color: color,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
