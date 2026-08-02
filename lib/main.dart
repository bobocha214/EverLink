import 'package:flutter/material.dart';

import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/ping_history_service.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/services/settings_service.dart';
import 'package:everlink/ui/main_scaffold.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SessionManager.instance.init();
  await HistoryService.instance.init();
  await PingHistoryService.instance.init();
  await SettingsService.instance.init();
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

  ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.teal,
        brightness: brightness,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return MaterialApp(
      title: 'EverLink 设备调试',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: settings.themeMode,
      home: const MainScaffold(),
    );
  }
}
