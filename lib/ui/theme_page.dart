import 'package:flutter/material.dart';

import 'package:everlink/services/settings_service.dart';

/// 主题：跟随系统 / 浅色 / 深色。
class ThemePage extends StatelessWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('主题')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: RadioGroup<ThemeMode>(
                groupValue: settings.themeMode,
                onChanged: (v) {
                  if (v != null) settings.setThemeMode(v);
                },
                child: const Column(
                  children: [
                    _ThemeTile(
                      title: '跟随系统',
                      subtitle: '根据系统浅色 / 深色模式自动切换',
                      value: ThemeMode.system,
                    ),
                    Divider(height: 1),
                    _ThemeTile(
                      title: '浅色',
                      subtitle: '始终使用浅色主题',
                      value: ThemeMode.light,
                    ),
                    Divider(height: 1),
                    _ThemeTile(
                      title: '深色',
                      subtitle: '始终使用深色主题',
                      value: ThemeMode.dark,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.title,
    required this.subtitle,
    required this.value,
  });
  final String title;
  final String subtitle;
  final ThemeMode value;

  @override
  Widget build(BuildContext context) => RadioListTile<ThemeMode>(
        value: value,
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      );
}
