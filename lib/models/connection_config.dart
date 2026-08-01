import 'package:modbus_client/modbus_client.dart';

/// 连接配置基类。
///
/// 每种协议都有自己的配置子类。通过统一的基类约束，[ConnectionManager]
/// 可以在不关心具体协议细节的情况下管理连接生命周期。
abstract class ConnectionConfig {
  const ConnectionConfig();
}

/// Modbus TCP 连接配置。
class ModbusConnectionConfig extends ConnectionConfig {
  /// 设备 IP 地址。
  final String host;

  /// 设备端口，默认 502。
  final int port;

  /// 从站单元 ID（Slave/Unit ID），默认 1。
  final int unitId;

  /// 单次请求超时时间。
  final Duration timeout;

  /// 寄存器字节序，用于处理 32 位/浮点等多字数据。
  final ModbusEndianness endianness;

  const ModbusConnectionConfig({
    required this.host,
    this.port = 502,
    this.unitId = 1,
    this.timeout = const Duration(seconds: 3),
    this.endianness = ModbusEndianness.ABCD,
  });

  ModbusConnectionConfig copyWith({
    String? host,
    int? port,
    int? unitId,
    Duration? timeout,
    ModbusEndianness? endianness,
  }) {
    return ModbusConnectionConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      unitId: unitId ?? this.unitId,
      timeout: timeout ?? this.timeout,
      endianness: endianness ?? this.endianness,
    );
  }
}

/// MQTT 连接配置。
class MqttConnectionConfig extends ConnectionConfig {
  /// Broker 主机地址（IP 或域名）。
  final String host;

  /// Broker 端口，明文 1883，TLS 8883。
  final int port;

  /// 客户端标识，Broker 用于区分会话。
  final String clientId;

  /// 用户名（可选）。
  final String? username;

  /// 密码（可选）。
  final String? password;

  /// 是否使用 TLS/SSL 加密连接。
  final bool useTls;

  /// 心跳保活间隔（秒）。
  final int keepAlive;

  const MqttConnectionConfig({
    required this.host,
    this.port = 1883,
    required this.clientId,
    this.username,
    this.password,
    this.useTls = false,
    this.keepAlive = 60,
  });

  MqttConnectionConfig copyWith({
    String? host,
    int? port,
    String? clientId,
    String? username,
    String? password,
    bool? useTls,
    int? keepAlive,
  }) {
    return MqttConnectionConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      clientId: clientId ?? this.clientId,
      username: username ?? this.username,
      password: password ?? this.password,
      useTls: useTls ?? this.useTls,
      keepAlive: keepAlive ?? this.keepAlive,
    );
  }
}
