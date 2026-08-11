import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:everlink/utils/app_constants.dart';

/// 关于 EverLink：版本信息、简介与开源仓库链接。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _launch(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于 EverLink')),
      body: ListView(
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
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: Colors.teal,
                        child: Icon(Icons.cable, color: Colors.white, size: 24),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('EverLink',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold)),
                            Text('工业设备协议调试工具',
                                style: TextStyle(color: Colors.grey, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '一款设备协议调试工具，支持 Modbus TCP、MQTT、WebSocket、'
                    'HTTP、OPC UA 的连接与读写，并提供 Ping 测试和局域网快传。',
                    style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  FutureBuilder<PackageInfo>(
                    future: PackageInfo.fromPlatform(),
                    builder: (context, snap) {
                      final version = snap.data?.version ?? '1.0.0';
                      final build = snap.data?.buildNumber ?? '1';
                      return Column(
                        children: [
                          _InfoRow(label: '版本号', value: version),
                          const Divider(height: 1),
                          _InfoRow(label: '构建号', value: build),
                        ],
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.code, color: Colors.teal),
                    title: const Text('GitHub 仓库'),
                    subtitle: const Text('源码与 Release 下载'),
                    trailing: const Icon(Icons.open_in_new, size: 18),
                    onTap: () => _launch(AppConstants.githubRepoUrl),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cloud, color: Colors.teal),
                    title: const Text('Gitee 仓库'),
                    subtitle: const Text('国内镜像，加速下载'),
                    trailing: const Icon(Icons.open_in_new, size: 18),
                    onTap: () => _launch(AppConstants.giteeRepoUrl),
                  ),
                  const SizedBox(height: 12),
                  const Center(
                    child: Text(
                      '© 2026 EverLink · 仅供设备调试与学习使用',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(color: Colors.grey)),
        trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      );
}
