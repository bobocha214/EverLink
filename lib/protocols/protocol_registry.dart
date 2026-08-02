import 'package:flutter/material.dart';

import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';
import 'package:everlink/protocols/modbus_tcp_protocol.dart';
import 'package:everlink/protocols/mqtt_protocol.dart';
import 'package:everlink/protocols/websocket_protocol.dart';
import 'package:everlink/protocols/http_protocol.dart';
import 'package:everlink/protocols/opcua_protocol.dart';

/// 协议描述符，用于在不依赖具体实现的情况下向 UI 暴露元信息。
class ProtocolDescriptor {
  const ProtocolDescriptor({
    required this.type,
    required this.name,
    required this.description,
    required this.icon,
    required this.create,
  });

  final ProtocolType type;
  final String name;
  final String description;
  final IconData icon;

  /// 创建该协议的一个新实例。
  final DeviceProtocol Function() create;
}

/// 协议注册表。
///
/// 集中管理所有可用协议。要扩展新的基于 TCP 的设备协议，只需：
/// 1. 创建继承自 [DeviceProtocol] 的实现类；
/// 2. 在 [all] 列表中添加一条描述符（或调用 [register]）。
/// UI 与连接管理逻辑无需改动即可识别新协议。
class ProtocolRegistry {
  static final List<ProtocolDescriptor> _descriptors = [
    ProtocolDescriptor(
      type: ProtocolType.modbusTcp,
      name: 'Modbus TCP',
      description: '工业 PLC / 仪表的线圈与寄存器读写',
      icon: Icons.router,
      create: () => ModbusTcpProtocol(),
    ),
    ProtocolDescriptor(
      type: ProtocolType.mqtt,
      name: 'MQTT',
      description: '物联网消息发布 / 订阅',
      icon: Icons.cloud_queue,
      create: () => MqttProtocol(),
    ),
    ProtocolDescriptor(
      type: ProtocolType.webSocket,
      name: 'WebSocket',
      description: '全双工长连接，向服务端收发消息',
      icon: Icons.cable,
      create: () => WebSocketProtocol(),
    ),
    ProtocolDescriptor(
      type: ProtocolType.http,
      name: 'HTTP',
      description: 'REST / HTTP 端点请求调试',
      icon: Icons.http,
      create: () => HttpProtocol(),
    ),
    ProtocolDescriptor(
      type: ProtocolType.opcUa,
      name: 'OPC UA',
      description: '工业设备地址空间浏览与变量读写',
      icon: Icons.account_tree,
      create: () => OpcUaProtocol(),
    ),
  ];

  /// 所有已注册协议的不可变列表。
  static List<ProtocolDescriptor> get all =>
      List.unmodifiable(_descriptors);

  /// 按类型查找协议描述符。
  static ProtocolDescriptor get(ProtocolType type) {
    return _descriptors.firstWhere(
      (d) => d.type == type,
      orElse: () => throw ArgumentError('未注册的协议类型：$type'),
    );
  }

  /// 注册一个新协议（若类型已存在则忽略）。
  static void register(ProtocolDescriptor descriptor) {
    if (!_descriptors.any((d) => d.type == descriptor.type)) {
      _descriptors.add(descriptor);
    }
  }
}
