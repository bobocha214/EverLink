import 'package:flutter/material.dart';

import 'package:everlink/services/connection_manager.dart';

/// 通用连接状态条：展示当前连接状态、错误信息，并提供连接 / 断开按钮。
class ConnectionPanel extends StatelessWidget {
  const ConnectionPanel({
    super.key,
    required this.manager,
    this.onConnectPressed,
  });

  final ConnectionManager manager;

  /// 点击“连接”按钮时的回调。若不传，则使用当前配置直接连接。
  final VoidCallback? onConnectPressed;

  @override
  Widget build(BuildContext context) {
    final state = manager.state;
    final connected = state == DeviceConnectionState.connected;
    final connecting = state == DeviceConnectionState.connecting;
    final color = switch (state) {
      DeviceConnectionState.connected => Colors.green,
      DeviceConnectionState.connecting => Colors.orange,
      DeviceConnectionState.error => Colors.red,
      _ => Colors.grey,
    };
    final label = switch (state) {
      DeviceConnectionState.connected => '已连接',
      DeviceConnectionState.connecting => '连接中…',
      DeviceConnectionState.error => '连接错误',
      _ => '未连接',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.circle, color: color, size: 14),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (manager.lastError != null && state == DeviceConnectionState.error)
                    Text(
                      manager.lastError!,
                      style: const TextStyle(fontSize: 12, color: Colors.red),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (connected)
              FilledButton.tonal(
                onPressed: () async => manager.disconnect(),
                child: const Text('断开'),
              )
            else
              FilledButton(
                onPressed: connecting
                    ? null
                    : (onConnectPressed ?? () => manager.connect(manager.config)),
                child: Text(connecting ? '连接中' : '连接'),
              ),
          ],
        ),
      ),
    );
  }
}
