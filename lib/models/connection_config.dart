import 'package:modbus_client/modbus_client.dart';

import 'package:everlink/models/opcua_models.dart';
import 'package:everlink/models/protocol_type.dart';

/// 连接配置基类。
///
/// 每种协议都有自己的配置子类。通过统一的基类约束，[ConnectionManager]
/// 可以在不关心具体协议细节的情况下管理连接生命周期。
abstract class ConnectionConfig {
  const ConnectionConfig();

  /// 序列化为 JSON（用于本地持久化）。
  Map<String, dynamic> toJson();

  ConnectionConfig copyWithConfig();
}

/// Modbus TCP 连接配置。
class ModbusConnectionConfig extends ConnectionConfig {
  /// 设备 IP 地址。
  final String host;

  /// 设备端口，默认 502。
  final int port;

  /// 从站 ID（Slave / Unit ID），默认 1。
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

  @override
  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'unitId': unitId,
        'timeout': timeout.inSeconds,
        'endianness': endianness.index,
      };

  factory ModbusConnectionConfig.fromJson(Map<String, dynamic> j) =>
      ModbusConnectionConfig(
        host: j['host'] as String,
        port: j['port'] as int,
        unitId: j['unitId'] as int,
        timeout: Duration(seconds: j['timeout'] as int),
        endianness: ModbusEndianness.values[j['endianness'] as int],
      );

  @override
  ConnectionConfig copyWithConfig() => copyWith();
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

  /// 是否使用干净会话（Clean Session）。true 表示断开后 Broker 不保留
  /// 订阅与未确认消息；false 表示保留（用于离线消息接收）。
  final bool cleanSession;

  /// 遗嘱主题（Will Topic）：连接异常断开时 Broker 自动向该主题发布的消息。
  final String? willTopic;

  /// 遗嘱消息内容。
  final String? willPayload;

  /// 遗嘱消息是否保留（Retain）。
  final bool willRetain;

  const MqttConnectionConfig({
    required this.host,
    this.port = 1883,
    required this.clientId,
    this.username,
    this.password,
    this.useTls = false,
    this.keepAlive = 60,
    this.cleanSession = true,
    this.willTopic,
    this.willPayload,
    this.willRetain = false,
  });

  MqttConnectionConfig copyWith({
    String? host,
    int? port,
    String? clientId,
    String? username,
    String? password,
    bool? useTls,
    int? keepAlive,
    bool? cleanSession,
    String? willTopic,
    String? willPayload,
    bool? willRetain,
  }) {
    return MqttConnectionConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      clientId: clientId ?? this.clientId,
      username: username ?? this.username,
      password: password ?? this.password,
      useTls: useTls ?? this.useTls,
      keepAlive: keepAlive ?? this.keepAlive,
      cleanSession: cleanSession ?? this.cleanSession,
      willTopic: willTopic ?? this.willTopic,
      willPayload: willPayload ?? this.willPayload,
      willRetain: willRetain ?? this.willRetain,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'clientId': clientId,
        'username': username,
        'password': password,
        'useTls': useTls,
        'keepAlive': keepAlive,
        'cleanSession': cleanSession,
        'willTopic': willTopic,
        'willPayload': willPayload,
        'willRetain': willRetain,
      };

  factory MqttConnectionConfig.fromJson(Map<String, dynamic> j) =>
      MqttConnectionConfig(
        host: j['host'] as String,
        port: j['port'] as int,
        clientId: j['clientId'] as String,
        username: j['username'] as String?,
        password: j['password'] as String?,
        useTls: j['useTls'] as bool,
        keepAlive: j['keepAlive'] as int,
        cleanSession: j['cleanSession'] as bool? ?? true,
        willTopic: j['willTopic'] as String?,
        willPayload: j['willPayload'] as String?,
        willRetain: j['willRetain'] as bool? ?? false,
      );

  @override
  ConnectionConfig copyWithConfig() => copyWith();
}

/// WebSocket 连接配置。
class WebSocketConnectionConfig extends ConnectionConfig {
  /// 连接地址，形如 ws://host:port/path 或 wss://...（wss 表示 TLS 加密）。
  final String url;

  /// 可选的子协议列表（Sec-WebSocket-Protocol）。
  final List<String>? protocols;

  /// 可选的连接请求头。
  final Map<String, String>? headers;

  /// 连接超时时间。
  final Duration timeout;

  const WebSocketConnectionConfig({
    required this.url,
    this.protocols,
    this.headers,
    this.timeout = const Duration(seconds: 5),
  });

  WebSocketConnectionConfig copyWith({
    String? url,
    List<String>? protocols,
    Map<String, String>? headers,
    Duration? timeout,
  }) {
    return WebSocketConnectionConfig(
      url: url ?? this.url,
      protocols: protocols ?? this.protocols,
      headers: headers ?? this.headers,
      timeout: timeout ?? this.timeout,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'url': url,
        'protocols': protocols,
        'headers': headers,
        'timeout': timeout.inSeconds,
      };

  factory WebSocketConnectionConfig.fromJson(Map<String, dynamic> j) =>
      WebSocketConnectionConfig(
        url: j['url'] as String,
        protocols: (j['protocols'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList(),
        headers: (j['headers'] as Map<dynamic, dynamic>?)
            ?.map((k, v) => MapEntry(k as String, v as String)),
        timeout: Duration(seconds: j['timeout'] as int? ?? 5),
      );

  @override
  ConnectionConfig copyWithConfig() => copyWith();
}

/// HTTP 连接配置（描述一个被调试的 REST / HTTP 端点）。
///
/// HTTP 是无状态的请求/响应协议，没有持久的“连接”概念；这里的配置描述
/// 被调试端点的基地址与默认请求头，“连接”在 UI 上表示一次可达性探针。
class HttpConnectionConfig extends ConnectionConfig {
  /// 基地址，形如 http://host:port 或 https://...。
  final String baseUrl;

  /// 单次请求超时时间。
  final Duration timeout;

  /// 每次请求默认附加的请求头。
  final Map<String, String>? defaultHeaders;

  const HttpConnectionConfig({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 8),
    this.defaultHeaders,
  });

  HttpConnectionConfig copyWith({
    String? baseUrl,
    Duration? timeout,
    Map<String, String>? defaultHeaders,
  }) {
    return HttpConnectionConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      timeout: timeout ?? this.timeout,
      defaultHeaders: defaultHeaders ?? this.defaultHeaders,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'timeout': timeout.inSeconds,
        'defaultHeaders': defaultHeaders,
      };

  factory HttpConnectionConfig.fromJson(Map<String, dynamic> j) =>
      HttpConnectionConfig(
        baseUrl: j['baseUrl'] as String,
        timeout: Duration(seconds: j['timeout'] as int? ?? 8),
        defaultHeaders: (j['defaultHeaders'] as Map<dynamic, dynamic>?)
            ?.map((k, v) => MapEntry(k as String, v as String)),
      );

  @override
  ConnectionConfig copyWithConfig() => copyWith();
}

/// OPC UA 连接配置。
///
/// 使用统一的 [endpoint]（形如 `opc.tcp://host:port/path`，默认端口 4840）
/// 标识服务端。MVP 阶段安全策略固定为 None（匿名连接）；[username] /
/// [password] 字段预留给后续 UserName 身份鉴权。
class OpcUaConnectionConfig extends ConnectionConfig {
  /// 端点 URL，形如 opc.tcp://host:port。
  final String endpoint;

  /// 安全策略：当前仅支持 'None'。
  final String securityPolicy;

  /// 认证方式（匿名 / 用户名密码 / X.509 证书）。
  ///
  /// 底层 `mcp_io_opcua 0.2.1` 仅完整实现匿名；用户名 / 证书方式可录入并
  /// 持久化，但连接时会被协议层以明确的 [UnsupportedError] 拒绝（能力降级）。
  final OpcUaAuthMode authMode;

  /// 用户名（用于 [OpcUaAuthMode.userName]，预留）。
  final String? username;

  /// 密码（用于 [OpcUaAuthMode.userName]，预留）。
  final String? password;

  /// 客户端证书 PEM（用于 [OpcUaAuthMode.certificate]，预留）。
  final String? clientCert;

  /// 客户端私钥 PEM（用于 [OpcUaAuthMode.certificate]，预留）。
  final String? clientKey;

  /// 私钥口令（用于 [OpcUaAuthMode.certificate]，可选）。
  final String? clientKeyPassword;

  const OpcUaConnectionConfig({
    this.endpoint = 'opc.tcp://localhost:4840',
    this.securityPolicy = 'None',
    this.authMode = OpcUaAuthMode.anonymous,
    this.username,
    this.password,
    this.clientCert,
    this.clientKey,
    this.clientKeyPassword,
  });

  OpcUaConnectionConfig copyWith({
    String? endpoint,
    String? securityPolicy,
    OpcUaAuthMode? authMode,
    String? username,
    String? password,
    String? clientCert,
    String? clientKey,
    String? clientKeyPassword,
  }) {
    return OpcUaConnectionConfig(
      endpoint: endpoint ?? this.endpoint,
      securityPolicy: securityPolicy ?? this.securityPolicy,
      authMode: authMode ?? this.authMode,
      username: username ?? this.username,
      password: password ?? this.password,
      clientCert: clientCert ?? this.clientCert,
      clientKey: clientKey ?? this.clientKey,
      clientKeyPassword: clientKeyPassword ?? this.clientKeyPassword,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'endpoint': endpoint,
        'securityPolicy': securityPolicy,
        'authMode': authMode.id,
        'username': username,
        'password': password,
        'clientCert': clientCert,
        'clientKey': clientKey,
        'clientKeyPassword': clientKeyPassword,
      };

  factory OpcUaConnectionConfig.fromJson(Map<String, dynamic> j) =>
      OpcUaConnectionConfig(
        endpoint: j['endpoint'] as String,
        securityPolicy: j['securityPolicy'] as String? ?? 'None',
        authMode: OpcUaAuthMode.fromId(j['authMode'] as String?),
        username: j['username'] as String?,
        password: j['password'] as String?,
        clientCert: j['clientCert'] as String?,
        clientKey: j['clientKey'] as String?,
        clientKeyPassword: j['clientKeyPassword'] as String?,
      );

  @override
  ConnectionConfig copyWithConfig() => copyWith();
}

/// TCP 原始连接配置（通用字节流通道，无应用层协议语义）。
///
/// 与 [ModbusConnectionConfig] 不同，这里不解析寄存器 / 报文结构，仅描述
/// 一个 host:port 的裸 TCP 端点，供 [TcpRawProtocol] 收发任意字节流。
class TcpRawConnectionConfig extends ConnectionConfig {
  /// 目标主机地址（IP 或域名）。
  final String host;

  /// 目标端口。
  final int port;

  /// 连接超时时间。
  final Duration timeout;

  const TcpRawConnectionConfig({
    this.host = '',
    this.port = 502,
    this.timeout = const Duration(seconds: 5),
  });

  TcpRawConnectionConfig copyWith({
    String? host,
    int? port,
    Duration? timeout,
  }) {
    return TcpRawConnectionConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      timeout: timeout ?? this.timeout,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'timeout': timeout.inSeconds,
      };

  factory TcpRawConnectionConfig.fromJson(Map<String, dynamic> j) =>
      TcpRawConnectionConfig(
        host: j['host'] as String? ?? '',
        port: j['port'] as int? ?? 502,
        timeout: Duration(seconds: j['timeout'] as int? ?? 5),
      );

  @override
  ConnectionConfig copyWithConfig() => copyWith();
}

/// 将具体配置对象序列化为带类型标记的 JSON。
Map<String, dynamic> configToJson(ConnectionConfig config) {
  if (config is ModbusConnectionConfig) {
    return {'type': ProtocolType.modbusTcp.name, 'config': config.toJson()};
  }
  if (config is MqttConnectionConfig) {
    return {'type': ProtocolType.mqtt.name, 'config': config.toJson()};
  }
  if (config is WebSocketConnectionConfig) {
    return {'type': ProtocolType.webSocket.name, 'config': config.toJson()};
  }
  if (config is HttpConnectionConfig) {
    return {'type': ProtocolType.http.name, 'config': config.toJson()};
  }
  if (config is OpcUaConnectionConfig) {
    return {'type': ProtocolType.opcUa.name, 'config': config.toJson()};
  }
  if (config is TcpRawConnectionConfig) {
    return {'type': ProtocolType.tcpRaw.name, 'config': config.toJson()};
  }
  throw ArgumentError('未知连接配置类型：${config.runtimeType}');
}

/// 从带类型标记的 JSON 反序列化为具体配置对象。
ConnectionConfig configFromJson(Map<String, dynamic> j) {
  final type = ProtocolType.values.firstWhere((t) => t.name == j['type']);
  switch (type) {
    case ProtocolType.modbusTcp:
      return ModbusConnectionConfig.fromJson(j['config'] as Map<String, dynamic>);
    case ProtocolType.mqtt:
      return MqttConnectionConfig.fromJson(j['config'] as Map<String, dynamic>);
    case ProtocolType.webSocket:
      return WebSocketConnectionConfig.fromJson(
          j['config'] as Map<String, dynamic>);
    case ProtocolType.http:
      return HttpConnectionConfig.fromJson(j['config'] as Map<String, dynamic>);
    case ProtocolType.opcUa:
      return OpcUaConnectionConfig.fromJson(j['config'] as Map<String, dynamic>);
    case ProtocolType.tcpRaw:
      return TcpRawConnectionConfig.fromJson(
          j['config'] as Map<String, dynamic>);
  }
}
