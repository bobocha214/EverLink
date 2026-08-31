import 'package:flutter/material.dart';

import 'package:everlink/services/settings_service.dart';
import 'package:everlink/ui/widgets/responsive_grid.dart';

import 'package:everlink/ui/modbus_slave_page.dart';
import 'package:everlink/ui/mqtt_broker_page.dart';
import 'package:everlink/ui/mqtt_publisher_page.dart';
import 'package:everlink/ui/opcua_server_page.dart';
import 'package:everlink/ui/tcp_server_page.dart';
import 'package:everlink/ui/widgets/tool_list_card.dart';
import 'package:everlink/utils/app_routes.dart';
import 'package:everlink/utils/app_theme.dart';

/// 服务模拟总入口：列出本地服务端模拟工具。
class ServerSimPage extends StatelessWidget {
  const ServerSimPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务模拟')),
      body: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + (SettingsService.instance.navFloating
            ? AppTheme.floatingNavClearance
            : 0),
        ),
        child: ResponsiveGrid(
          children: [
            ToolListCard(
              icon: Icons.alt_route_outlined,
              title: 'TCP 服务端',
              subtitle: '监听端口、接受多客户端、广播/定向发送，用于联调 TCP 客户端',
              onTap: () => AppRoutes.push(context, const TcpServerPage()),
            ),
            ToolListCard(
              icon: Icons.hub_outlined,
              title: 'OPC UA 服务端',
              subtitle: '模拟 OPC UA 服务器（None 安全策略），自定义节点与数量，支持 Read/Write/Browse',
              onTap: () => AppRoutes.push(context, const OpcUaServerPage()),
            ),
            ToolListCard(
              icon: Icons.looks_one_outlined,
              title: 'Modbus TCP 从站',
              subtitle: '模拟 Modbus TCP 从站，维护线圈 / 离散输入 / 输入 / 保持寄存器，可本地编辑供设备联调',
              onTap: () => AppRoutes.push(context, const ModbusSlavePage()),
            ),
            ToolListCard(
              icon: Icons.cloud_queue_outlined,
              title: 'MQTT Broker',
              subtitle: '本地 MQTT 3.1.1 服务器，接受客户端连接、转发消息、Retained、通配符',
              onTap: () => AppRoutes.push(context, const MqttBrokerPage()),
            ),
            ToolListCard(
              icon: Icons.send_outlined,
              title: 'MQTT 发布模拟',
              subtitle: '连接外部 Broker，按主题模板/数量/间隔循环发布模拟设备数据',
              onTap: () => AppRoutes.push(context, const MqttPublisherPage()),
            ),
          ],
        ),
      ),
    );
  }
}
