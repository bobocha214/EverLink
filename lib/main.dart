import 'package:flutter/material.dart';

import 'package:everlink/services/clipboard_history/clipboard_history_manager.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/ping_history_service.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/services/settings_service.dart';
import 'package:everlink/ui/main_scaffold.dart';
import 'package:everlink/utils/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SessionManager.instance.init();
  await HistoryService.instance.init();
  await PingHistoryService.instance.init();
  await SettingsService.instance.init();
  // 启动本地剪贴板历史监听：记录本应用内复制，并在 EverLink 处于前台时记录系统剪贴板变化。
  // 注：Android 10+ 禁止后台应用读取剪贴板，故其它 App 的复制仅在 EverLink 前台时才会被捕获。
  await ClipboardHistoryManager.instance.init();
  runApp(const EverlinkApp());
}

/// 应用根组件。
///
/// 监听 [SettingsService] 以实时应用主题（浅色 / 深色 / 跟随系统）。
class EverlinkApp extends StatefulWidget {
  const EverlinkApp({super.key});

  @override
  State<EverlinkApp> createState() => _EverlinkAppState();
}

class _EverlinkAppState extends State<EverlinkApp> {
  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return MaterialApp(
      title: 'EverLink',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(Brightness.light),
      darkTheme: AppTheme.build(Brightness.dark),
      themeMode: settings.themeMode,
      home: const MainScaffold(),
    );
  }
}
