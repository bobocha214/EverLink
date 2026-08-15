import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';
import 'package:everlink/protocols/protocol_registry.dart';
import 'package:everlink/services/modbus/modbus_client.dart';

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
    // 内部统一状态流：既转发协议实例的真实连接变化，也接收 reflectState 注入的
    // 外部状态（例如 Modbus 调试页用自己的原始客户端连上了设备，需要把状态
    // 同步回首页）。这样 ensureManager 里的会话状态监听、首页统计与卡片都能
    // 拿到一致的连接状态，避免“首页与调试页状态不同步”。
    protocol.connectionStateStream.listen((s) {
      _state = s;
      _stateCtl.add(s);
      notifyListeners();
    });
  }

  /// 内部状态广播流（合并协议流与 reflectState 注入）。
  final StreamController<DeviceConnectionState> _stateCtl =
      StreamController<DeviceConnectionState>.broadcast();

  /// 协议描述符。
  final ProtocolDescriptor descriptor;

  /// 当前协议实例。
  final DeviceProtocol protocol;

  ConnectionConfig _config;
  DeviceConnectionState _state = DeviceConnectionState.disconnected;

  /// Modbus 调试页使用的原始 TCP 客户端（基于 [Socket] 自实现，支持原始报文
  /// 记录与自定义解析）。它由本管理器持有，随 [SessionManager] 按会话缓存而
  /// 存活，因此调试页退出后连接不丢失；首页断开或删除设备时统一在此回收。
  /// 非 Modbus 协议此字段为 null。
  ModbusTcpClient? modbusDebugClient;

  /// 当前连接配置。
  ConnectionConfig get config => _config;

  /// 当前连接状态。
  DeviceConnectionState get state => _state;

  /// 连接状态变化流（内部合并流：协议真实变化 + reflectState 注入）。
  Stream<DeviceConnectionState> get connectionStateStream => _stateCtl.stream;

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
    // 若 Modbus 调试页持有原始客户端，一并断开，保证“首页断开”与“调试页
    // 连接状态”一致（否则首页点断开后底层 socket 仍被 raw client 占用）。
    if (modbusDebugClient != null) {
      modbusDebugClient!.disconnect();
      modbusDebugClient = null;
    }
    await protocol.disconnect();
    _state = DeviceConnectionState.disconnected;
    _stateCtl.add(_state);
    notifyListeners();
  }

  /// 注入外部连接状态（不操作底层协议）。
  ///
  /// 用于“协议页自己持有真实连接”的场景：例如 Modbus 调试页使用独立的原始
  /// TCP 客户端读写寄存器，其连接状态需回写到共享管理器，使首页卡片、统计
  /// 与筛选保持一致。调用方负责在断线时同样注入 [DeviceConnectionState.disconnected]。
  void reflectState(DeviceConnectionState state) {
    if (_state == state) return;
    _state = state;
    _stateCtl.add(state);
    notifyListeners();
  }

  @override
  void dispose() {
    modbusDebugClient?.disconnect();
    modbusDebugClient = null;
    protocol.dispose();
    _stateCtl.close();
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
      case ProtocolType.tcpRaw:
        return const TcpRawConnectionConfig(host: '127.0.0.1');
    }
  }
}
