import 'dart:math';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/device_protocol.dart';

/// 一个“设备会话”代表用户保存过的一个设备连接（如某台 Modbus PLC，或某个 MQTT Broker）。
///
/// 会话保存了协议类型、连接配置以及最近一次的连接状态。首页按会话展示
/// 设备的在线 / 离线 / 连接中状态，调试页也围绕会话展开。
class DeviceSession {
  DeviceSession({
    required this.id,
    required this.name,
    required this.type,
    required this.config,
    this.status = DeviceConnectionState.disconnected,
    this.lastError,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// 工厂方法：创建一条全新的会话（自动生成 id）。
  factory DeviceSession.create({
    required String name,
    required ProtocolType type,
    required ConnectionConfig config,
  }) {
    return DeviceSession(
      id: _newId(),
      name: name,
      type: type,
      config: config,
    );
  }

  /// 会话唯一标识。
  final String id;

  /// 用户给设备起的名字（如 “1号车间PLC”）。
  String name;

  /// 协议类型。
  final ProtocolType type;

  /// 连接配置（可随用户在调试页修改而更新）。
  ConnectionConfig config;

  /// 最近一次连接状态。
  DeviceConnectionState status;

  /// 最近一次错误信息（若有）。
  String? lastError;

  /// 最近更新时间。
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'config': configToJson(config),
        'status': status.index,
        'lastError': lastError,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory DeviceSession.fromJson(Map<String, dynamic> j) => DeviceSession(
        id: j['id'] as String,
        name: j['name'] as String,
        type: ProtocolType.values.firstWhere((t) => t.name == j['type']),
        config: configFromJson(j['config'] as Map<String, dynamic>),
        status: DeviceConnectionState.values[j['status'] as int],
        lastError: j['lastError'] as String?,
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );
}

String _newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${_rand.nextInt(1 << 30).toRadixString(36)}';

final Random _rand = Random();
