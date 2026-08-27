import 'package:flutter/material.dart';

import 'package:everlink/services/settings_service.dart';
import 'package:everlink/ui/base_tool_page.dart';
import 'package:everlink/ui/clipboard_manager_page.dart';
import 'package:everlink/ui/lan_transfer_page.dart';
import 'package:everlink/ui/network_debug_page.dart';
import 'package:everlink/ui/server_sim_page.dart';
import 'package:everlink/ui/widgets/tool_list_card.dart';
import 'package:everlink/utils/app_routes.dart';

/// 工具聚合页：承载快传、网络诊断等独立工具入口。
class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('工具')),
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + (SettingsService.instance.navFloating ? 100 : 0),
        ),
        children: [
          ToolListCard(
            icon: Icons.rocket_launch_outlined,
            title: '快传',
            subtitle: '同一 WiFi 下，通过网页/扫码互传文件、文字、图片',
            onTap: () => AppRoutes.push(context, const LanTransferPage()),
          ),
          const SizedBox(height: 12),
          ToolListCard(
            icon: Icons.content_paste_outlined,
            title: '剪贴板管理',
            subtitle: '本地记录本机所有复制内容（含其它 App），可查看与复制',
            onTap: () => AppRoutes.push(context, const ClipboardManagerPage()),
          ),
          const SizedBox(height: 12),
          ToolListCard(
            icon: Icons.terminal_outlined,
            title: '网络调试',
            subtitle: '端口扫描、目标探测、局域网扫描、IP 子网计算、网络诊断',
            onTap: () => AppRoutes.push(context, const NetworkDebugPage()),
          ),
          const SizedBox(height: 12),
          ToolListCard(
            icon: Icons.swap_horiz_outlined,
            title: '进制工具',
            subtitle: '二/八/十/十六进制互转、补码、字节视图、文本⇄Hex、CRC16',
            onTap: () => AppRoutes.push(context, const BaseToolPage()),
          ),
          const SizedBox(height: 12),
          ToolListCard(
            icon: Icons.dns_outlined,
            title: '服务模拟',
            subtitle: '在手机上运行 TCP / Modbus TCP / OPC UA 服务端，便于联调',
            onTap: () => AppRoutes.push(context, const ServerSimPage()),
          ),
        ],
      ),
    );
  }
}
