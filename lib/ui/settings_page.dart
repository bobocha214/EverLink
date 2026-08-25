import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:everlink/services/settings_service.dart';
import 'package:everlink/utils/app_theme.dart';

/// 系统设置：集中管理主题、外观、背景图与导航样式。
///
/// 所有改动即时写入 [SettingsService] 并触发全局重建（主题 / 背景 / 导航随之生效）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _picking = false;

  Future<void> _pickImage() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final srcPath = result.files.first.path;
      if (srcPath == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final bgDir = Directory('${dir.path}/backgrounds');
      if (!await bgDir.exists()) await bgDir.create(recursive: true);
      final ext = srcPath.contains('.')
          ? srcPath.substring(srcPath.lastIndexOf('.'))
          : '.jpg';
      final destName = 'bg_${DateTime.now().millisecondsSinceEpoch}$ext';
      final dest = await File(srcPath).copy('${bgDir.path}/$destName');
      await SettingsService.instance.setBackgroundImagePath(dest.path);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _clearImage() async {
    await SettingsService.instance.setBackgroundImagePath(null);
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    final imgPath = settings.backgroundImagePath;
    final imgExists = imgPath != null && File(imgPath).existsSync();

    return Scaffold(
      appBar: AppBar(title: const Text('系统设置')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SectionTitle('外观'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('主题模式',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    SegmentedButton<ThemeMode>(
                      selected: {settings.themeMode},
                      onSelectionChanged: (s) {
                        if (s.isNotEmpty) settings.setThemeMode(s.first);
                      },
                      segments: const [
                        ButtonSegment(
                            value: ThemeMode.system, label: Text('跟随系统')),
                        ButtonSegment(
                            value: ThemeMode.light, label: Text('浅色')),
                        ButtonSegment(
                            value: ThemeMode.dark, label: Text('深色')),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text('主题配色',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (int i = 0;
                            i < AppTheme.accentOptions.length;
                            i++)
                          _ColorChip(
                            name: AppTheme.accentOptions[i].$1,
                            color: AppTheme.accentOptions[i].$2,
                            selected: settings.accentIndex == i,
                            onTap: () => settings.setAccentIndex(i),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text('圆角风格',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    SegmentedButton<int>(
                      selected: {settings.cornerStyle},
                      onSelectionChanged: (s) {
                        if (s.isNotEmpty) settings.setCornerStyle(s.first);
                      },
                      segments: AppTheme.cornerOptions
                          .map((o) => ButtonSegment(
                              value: o.$2, label: Text(o.$1)))
                          .toList(),
                    ),
                    const SizedBox(height: 18),
                    const Text('玻璃质感',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    SegmentedButton<int>(
                      selected: {settings.glassStrength},
                      onSelectionChanged: (s) {
                        if (s.isNotEmpty) settings.setGlassStrength(s.first);
                      },
                      segments: AppTheme.glassOptions
                          .map((o) => ButtonSegment(
                              value: o.$2, label: Text(o.$1)))
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _SectionTitle('背景'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用自定义背景'),
                      subtitle: const Text('使用本地图片作为页面背景'),
                      value: settings.backgroundEnabled,
                      onChanged: (v) => settings.setBackgroundEnabled(v),
                    ),
                    if (settings.backgroundEnabled) ...[
                      const SizedBox(height: 8),
                      if (!imgExists)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                            '开启后请从下方选择一张本地图片作为背景。',
                            style:
                                TextStyle(fontSize: 13, color: Colors.grey),
                          ),
                        ),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _picking ? null : _pickImage,
                            icon: const Icon(Icons.image),
                            label: Text(_picking ? '处理中…' : '选择图片'),
                          ),
                          const SizedBox(width: 12),
                          if (imgExists)
                            TextButton(
                              onPressed: _clearImage,
                              child: const Text('清除'),
                            ),
                        ],
                      ),
                      if (imgPath != null && imgExists)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(imgPath),
                              height: 120,
                              width: double.infinity,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      const SizedBox(height: 14),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('模糊强度'),
                        subtitle: Slider(
                          value: settings.backgroundBlur,
                          min: 0,
                          max: 12,
                          divisions: 12,
                          label: settings.backgroundBlur.round().toString(),
                          onChanged: (v) => settings.setBackgroundBlur(v),
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('暗化'),
                        subtitle: Slider(
                          value: settings.backgroundDim,
                          min: 0,
                          max: 0.75,
                          divisions: 15,
                          label:
                              '${(settings.backgroundDim * 100).round()}%',
                          onChanged: (v) => settings.setBackgroundDim(v),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _SectionTitle('导航'),
            Card(
              child: SwitchListTile(
                title: const Text('菜单栏悬浮'),
                subtitle: const Text('以毛玻璃浮动样式呈现底部导航栏'),
                value: settings.navFloating,
                onChanged: (v) => settings.setNavFloating(v),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}

class _ColorChip extends StatelessWidget {
  const _ColorChip({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 64,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outline,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
              ),
            ),
            const SizedBox(height: 6),
            Text(name, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

