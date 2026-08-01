import 'dart:async';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/protocol_type.dart';

/// 连接状态。
enum DeviceConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// 设备协议抽象基类。
///
/// 所有可访问设备的协议（Modbus TCP、MQTT，以及未来扩展的其它基于 TCP
/// 的协议）都继承自本类。基类只约定“连接 / 断开 / 状态”这些通用能力，
/// 各协议特有的读写、订阅等方法在子类中按需扩展，从而保持扩展开放。
abstract class DeviceProtocol {
  DeviceProtocol({
    required this.type,
    required this.name,
    required this.description,
  });

  /// 协议类型。
  final ProtocolType type;

  /// 协议显示名称。
  final String name;

  /// 协议简介。
  final String description;

  /// 当前连接状态。
  DeviceConnectionState get connectionState;

  /// 连接状态变化流，UI 可监听以刷新界面。
  Stream<DeviceConnectionState> get connectionStateStream;

  /// 最近一次错误信息（若有）。
  String? get lastError;

  /// 连接到设备。需要传入与协议匹配的具体 [ConnectionConfig] 子类。
  Future<void> connect(ConnectionConfig config);

  /// 断开连接。
  Future<void> disconnect();

  /// 该协议是否支持“读取”语义（如 Modbus 读取寄存器）。
  bool get supportsRead => false;

  /// 该协议是否支持“写入”语义（如 Modbus 写寄存器、MQTT 发布）。
  bool get supportsWrite => false;

  /// 该协议是否支持“订阅”语义（如 MQTT 订阅主题）。
  bool get supportsSubscribe => false;

  /// 释放资源。
  void dispose();
}
