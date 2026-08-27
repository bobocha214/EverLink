import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';

/// MQTT 服务质量等级。
enum MqttQosLevel {
  atMostOnce(0, 'QoS 0（最多一次）'),
  atLeastOnce(1, 'QoS 1（至少一次）'),
  exactlyOnce(2, 'QoS 2（恰好一次）');

  const MqttQosLevel(this.level, this.label);

  final int level;
  final String label;

  MqttQos toMqttQos() => MqttQos.values[level];
}

/// 消息 payload 展示格式，对齐 MQTTX 的常用选项。
enum MqttPayloadFormat {
  plain('Plaintext'),
  json('JSON'),
  base64('Base64'),
  hex('Hex');

  const MqttPayloadFormat(this.label);

  final String label;

  static MqttPayloadFormat fromName(String? name) {
    if (name == null) return plain;
    return MqttPayloadFormat.values.firstWhere(
      (e) => e.name == name,
      orElse: () => plain,
    );
  }
}

/// 一条接收到的 MQTT 消息记录。
class MqttMessageRecord {
  final String topic;

  /// 已解码的文本载荷（UTF-8 优先，失败则按 mqtt_client 回退）。
  final String payload;

  /// 原始字节，用于 Hex / Base64 等无损展示。
  final List<int> bytes;

  final DateTime receivedAt;

  /// 收到消息时的 QoS 等级（0/1/2）。
  final int qos;

  /// 收到消息时是否 Retain。
  final bool retain;

  MqttMessageRecord({
    required this.topic,
    required this.payload,
    this.bytes = const [],
    required this.receivedAt,
    this.qos = 0,
    this.retain = false,
  });

  Map<String, dynamic> toJson() => {
        'topic': topic,
        'payload': payload,
        'bytes': base64Encode(bytes),
        't': receivedAt.millisecondsSinceEpoch,
        'qos': qos,
        'retain': retain,
      };

  factory MqttMessageRecord.fromJson(Map<String, dynamic> j) {
    final rawBytes = j['bytes'] as String?;
    return MqttMessageRecord(
      topic: j['topic'] as String,
      payload: j['payload'] as String,
      bytes: rawBytes == null
          ? const []
          : base64Decode(rawBytes),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
      qos: (j['qos'] as int?) ?? 0,
      retain: (j['retain'] as bool?) ?? false,
    );
  }
}
