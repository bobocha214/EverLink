/// 协议类型枚举。
///
/// 新增一种基于 TCP 的可访问设备协议时，只需在此枚举中加入一项，
/// 并在 [ProtocolRegistry] 中注册对应的 [DeviceProtocol] 实现即可。
enum ProtocolType {
  modbusTcp,
  mqtt,
  webSocket,
  http,
  opcUa,
  tcpRaw,
}

extension ProtocolTypeX on ProtocolType {
  /// 面向用户的中文名称。
  String get label {
    switch (this) {
      case ProtocolType.modbusTcp:
        return 'Modbus TCP';
      case ProtocolType.mqtt:
        return 'MQTT';
      case ProtocolType.webSocket:
        return 'WebSocket';
      case ProtocolType.http:
        return 'HTTP';
      case ProtocolType.opcUa:
        return 'OPC UA';
      case ProtocolType.tcpRaw:
        return 'TCP Client';
    }
  }
}
