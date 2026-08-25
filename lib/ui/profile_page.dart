import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:everlink/services/settings_service.dart';
import 'package:everlink/ui/about_page.dart';
import 'package:everlink/ui/data_storage_page.dart';
import 'package:everlink/ui/protocol_config_page.dart';
import 'package:everlink/ui/settings_page.dart';
import 'package:everlink/ui/update_page.dart';
import 'package:everlink/utils/app_constants.dart';
import 'package:everlink/utils/app_routes.dart';

/// “我的”页面：六大板块菜单，点击进入对应配置页。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + (SettingsService.instance.navFloating ? 100 : 0),
        ),
        children: [
          _buildHeader(context),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                _MenuItem(
                  icon: Icons.bolt,
                  title: '协议配置',
                  subtitle: '管理可启用的通信协议',
                  onTap: () => AppRoutes.push(context, const ProtocolConfigPage()),
                ),
                const Divider(height: 1),
                _MenuItem(
                  icon: Icons.storage,
                  title: '数据存储',
                  subtitle: '查看与清理本地数据',
                  onTap: () => AppRoutes.push(context, const DataStoragePage()),
                ),
                const Divider(height: 1),
                _MenuItem(
                  icon: Icons.settings,
                  title: '系统设置',
                  subtitle: '主题、外观、背景与导航',
                  onTap: () => AppRoutes.push(context, const SettingsPage()),
                ),
                const Divider(height: 1),
                _MenuItem(
                  icon: Icons.menu_book,
                  title: '帮助文档',
                  subtitle: '使用手册与在线文档',
                  trailingIcon: Icons.open_in_new,
                  onTap: () => _launch(AppConstants.docsUrl),
                ),
                const Divider(height: 1),
                _MenuItem(
                  icon: Icons.system_update_alt,
                  title: '检查更新',
                  subtitle: '从 GitHub 检查新版本',
                  onTap: () => AppRoutes.push(context, const UpdatePage()),
                ),
                const Divider(height: 1),
                _MenuItem(
                  icon: Icons.info_outline,
                  title: '关于 EverLink',
                  subtitle: '版本信息与开源仓库',
                  onTap: () => AppRoutes.push(context, const AboutPage()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: scheme.primary,
            child: Icon(Icons.cable, color: scheme.onPrimary, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('EverLink',
                    style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer)),
                const SizedBox(height: 2),
                Text('工业设备协议调试工具',
                    style: TextStyle(
                        color: scheme.onPrimaryContainer.withValues(alpha: 0.72),
                        fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailingIcon = Icons.chevron_right,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final IconData trailingIcon;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: Icon(trailingIcon, size: 18),
        onTap: onTap,
      );
}
