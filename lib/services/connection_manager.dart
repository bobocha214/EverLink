import 'package:flutter/foundation.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';
import 'package:everlink/protocols/protocol_registry.dart';

export 'package:everlink/protocols/device_protocol.dart';

/// 连接管理器。
///
/// 把“协议描述符 + 连接配置 + 协议实例”三个概念组合在一起，统一管理
/// 连接生命周期，并在状态变化时通过 [ChangeNotifier] 通知 UI。各协议页
/// 只需持有并驱动一个 [ConnectionManager]，无需关心协议具体类型。
class ConnectionManager extends ChangeNotifier {
  ConnectionManager(this.descriptor)
      : protocol = descriptor.create(),
        _config = _defaultConfig(descriptor.type) {
    protocol.connectionStateStream.listen((s) {
      _state = s;
      notifyListeners();
    });
  }

  /// 协议描述符。
  final ProtocolDescriptor descriptor;

  /// 当前协议实例。
  final DeviceProtocol protocol;

  ConnectionConfig _config;
  DeviceConnectionState _state = DeviceConnectionState.disconnected;

  /// 当前连接配置。
  ConnectionConfig get config => _config;

  /// 当前连接状态。
  DeviceConnectionState get state => _state;

  /// 连接状态变化流（转发自协议实例），便于外部监听。
  Stream<DeviceConnectionState> get connectionStateStream =>
      protocol.connectionStateStream;

  /// 最近错误信息。
  String? get lastError => protocol.lastError;

  /// 更新连接配置（未连接时调用有效）。
  void updateConfig(ConnectionConfig config) {
    _config = config;
    notifyListeners();
  }

  /// 连接到设备。可选传入一次性配置，否则使用当前 [_config]。
  Future<void> connect([ConnectionConfig? config]) async {
    if (config != null) _config = config;
    await protocol.connect(_config);
    _state = protocol.connectionState;
    notifyListeners();
  }

  /// 断开连接。
  Future<void> disconnect() async {
    await protocol.disconnect();
    _state = DeviceConnectionState.disconnected;
    notifyListeners();
  }

  @override
  void dispose() {
    protocol.dispose();
    super.dispose();
  }

  static ConnectionConfig _defaultConfig(ProtocolType type) {
    switch (type) {
      case ProtocolType.modbusTcp:
        return const ModbusConnectionConfig(host: '127.0.0.1');
      case ProtocolType.mqtt:
        return MqttConnectionConfig(
          host: 'broker.emqx.io',
          clientId: 'everlink_${DateTime.now().millisecondsSinceEpoch}',
        );
      case ProtocolType.webSocket:
        return const WebSocketConnectionConfig(url: 'ws://echo.websocket.events');
      case ProtocolType.http:
        return const HttpConnectionConfig(baseUrl: 'https://httpbin.org');
      case ProtocolType.opcUa:
        return const OpcUaConnectionConfig();
    }
  }
}
