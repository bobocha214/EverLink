import 'package:flutter/material.dart';

import 'package:everlink/ui/mqtt_broker_page.dart';
import 'package:everlink/ui/mqtt_publisher_page.dart';
import 'package:everlink/ui/opcua_server_page.dart';
import 'package:everlink/ui/tcp_server_page.dart';
import 'package:everlink/utils/app_routes.dart';

/// 服务模拟总入口：列出本地服务端模拟工具。
class ServerSimPage extends StatelessWidget {
  const ServerSimPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务模拟')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _ServerCard(
            icon: Icons.alt_route_outlined,
            color: Colors.blue,
            title: 'TCP 服务端',
            subtitle: '监听端口、接受多客户端、广播/定向发送，用于联调 TCP 客户端',
            page: TcpServerPage(),
          ),
          SizedBox(height: 12),
          _ServerCard(
            icon: Icons.hub_outlined,
            color: Colors.indigo,
            title: 'OPC UA 服务端',
            subtitle: '模拟 OPC UA 服务器（None 安全策略），自定义节点与数量，支持 Read/Write/Browse',
            page: OpcUaServerPage(),
          ),
          SizedBox(height: 12),
          _ServerCard(
            icon: Icons.cloud_queue_outlined,
            color: Colors.green,
            title: 'MQTT Broker',
            subtitle: '本地 MQTT 3.1.1 服务器，接受客户端连接、转发消息、Retained、通配符',
            page: MqttBrokerPage(),
          ),
          SizedBox(height: 12),
          _ServerCard(
            icon: Icons.send_outlined,
            color: Colors.orange,
            title: 'MQTT 发布模拟',
            subtitle: '连接外部 Broker，按主题模板/数量/间隔循环发布模拟设备数据',
            page: MqttPublisherPage(),
          ),
        ],
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.page,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => AppRoutes.push(context, page),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
