import 'package:flutter/material.dart';

import 'package:everlink/protocols/protocol_registry.dart';
import 'package:everlink/services/settings_service.dart';

/// 协议配置：各通信协议的开关。
class ProtocolConfigPage extends StatelessWidget {
  const ProtocolConfigPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('协议配置')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 10),
              child: Text(
                '启用的协议会出现在首页的快捷连接中。',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
            Card(
              child: Column(
                children: ProtocolRegistry.all.map((d) {
                  final isLast = d == ProtocolRegistry.all.last;
                  return Column(
                    children: [
                      ListTile(
                        leading: Icon(d.icon, color: Colors.teal),
                        title: Text(d.name),
                        subtitle: Text(d.description),
                        trailing: Switch(
                          value: settings.isProtocolEnabled(d.type),
                          onChanged: (v) => settings.setProtocolEnabled(d.type, v),
                        ),
                      ),
                      if (!isLast) const Divider(height: 1),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
