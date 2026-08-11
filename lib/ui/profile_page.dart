import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:everlink/ui/about_page.dart';
import 'package:everlink/ui/data_storage_page.dart';
import 'package:everlink/ui/protocol_config_page.dart';
import 'package:everlink/ui/theme_page.dart';
import 'package:everlink/ui/update_page.dart';
import 'package:everlink/utils/app_constants.dart';

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
        padding: const EdgeInsets.all(16),
        children: [
          _buildHeader(),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                _MenuItem(
                  icon: Icons.bolt,
                  title: '协议配置',
                  subtitle: '管理可启用的通信协议',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ProtocolConfigPage()),
                  ),
                ),
                const Divider(height: 1),
                _MenuItem(
                  icon: Icons.storage,
                  title: '数据存储',
                  subtitle: '查看与清理本地数据',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DataStoragePage()),
                  ),
                ),
                const Divider(height: 1),
                _MenuItem(
                  icon: Icons.palette,
                  title: '主题',
                  subtitle: '浅色 / 深色 / 跟随系统',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ThemePage()),
                  ),
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
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const UpdatePage()),
                  ),
                ),
                const Divider(height: 1),
                _MenuItem(
                  icon: Icons.info_outline,
                  title: '关于 EverLink',
                  subtitle: '版本信息与开源仓库',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AboutPage()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.teal.shade400, Colors.teal.shade600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.white24,
            child: Icon(Icons.cable, color: Colors.white, size: 28),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('EverLink 设备调试',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                SizedBox(height: 4),
                Text('工业设备协议调试工具', style: TextStyle(color: Colors.white70)),
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
        leading: Icon(icon, color: Colors.teal),
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: Icon(trailingIcon, size: 18),
        onTap: onTap,
      );
}
