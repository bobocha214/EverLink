import 'package:flutter/material.dart';

import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/protocol_registry.dart';
import 'package:everlink/ui/modbus_page.dart';
import 'package:everlink/ui/mqtt_page.dart';

/// 首页：展示所有可用协议，供用户选择进入对应调试界面。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  void _openProtocol(BuildContext context, ProtocolType type) {
    switch (type) {
      case ProtocolType.modbusTcp:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ModbusPage()),
        );
      case ProtocolType.mqtt:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const MqttPage()),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final protocols = ProtocolRegistry.all;
    return Scaffold(
      appBar: AppBar(title: const Text('EverLink 设备调试')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: protocols.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final p = protocols[index];
          return Card(
            elevation: 2,
            child: ListTile(
              leading: Icon(p.icon, size: 36, color: Colors.teal),
              title: Text(p.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              subtitle: Text(p.description),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openProtocol(context, p.type),
            ),
          );
        },
      ),
    );
  }
}
