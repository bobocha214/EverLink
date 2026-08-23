import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:everlink/services/settings_service.dart';
import 'package:everlink/services/update_service.dart';
import 'package:everlink/ui/update_dialog.dart';

/// 检查更新：从 GitHub Releases 拉取最新版本。
class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  bool _checking = false;
  // 当前仅 GitHub（Gitee 暂时禁用，详见 UpdateSource.gitee 注释）。
  final UpdateSource _source = UpdateSource.github;

  Future<void> _checkUpdate() async {
    setState(() => _checking = true);
    final info = await PackageInfo.fromPlatform();
    final result = await UpdateService.instance.check(
      currentVersion: info.version,
      currentBuild: int.tryParse(info.buildNumber) ?? 0,
      source: _source,
    );
    if (!mounted) return;
    setState(() => _checking = false);

    if (result.hasUpdate && result.info != null) {
      final u = result.info!;
      final go = await showUpdateDialog(context, u);
      if (go && mounted) {
        await showDownloadDialog(context, u.url);
      }
    } else if (result.error != null) {
      _showInfo('检查更新失败', result.error!);
    } else {
      _showInfo('已是最新版本', '当前已是最新版本，无需更新。');
    }
  }

  void _showInfo(String title, String content) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('检查更新')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.code, size: 16, color: Colors.teal),
                        SizedBox(width: 6),
                        Text('更新源：GitHub Releases',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '从 GitHub 最新 Release 拉取版本信息（全球可用）。'
                      'Gitee 源已暂时禁用。',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启动时自动检查更新'),
                      subtitle: const Text('每次打开 App 时在后台检查新版本',
                          style: TextStyle(fontSize: 12)),
                      value: settings.autoCheckUpdate,
                      onChanged: (v) => settings.setAutoCheckUpdate(v),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _checking ? null : _checkUpdate,
                        icon: _checking
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.system_update_alt),
                        label: Text(_checking ? '检查中…' : '检查更新'),
                      ),
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
