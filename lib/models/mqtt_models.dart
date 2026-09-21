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

/// 判断消息主题 [topic] 是否匹配订阅 [pattern]（支持 MQTT 通配符 # 与 +）。
///
/// - `#` 只能作为最后一段，匹配父层级及所有子层级（如 `test/#` 匹配 `test`、`test/abc`）。
/// - `+` 匹配单层级任意值（如 `test/+/x` 匹配 `test/abc/x`）。
/// - 无通配符则为精确相等；`#` 作为独立主题匹配所有。
bool mqttTopicMatches(String pattern, String topic) {
  if (pattern == '#') return true;
  if (pattern == topic) return true;
  final pLevels = pattern.split('/');
  final tLevels = topic.split('/');
  // # 必须出现在末尾：去掉末尾 # 后，前面层级需逐段匹配（+ 通配单层）。
  if (pLevels.last == '#') {
    final head = pLevels.sublist(0, pLevels.length - 1);
    if (head.length > tLevels.length) return false;
    for (var i = 0; i < head.length; i++) {
      final h = head[i];
      if (h != '+' && h != tLevels[i]) return false;
    }
    return true;
  }
  if (pLevels.length != tLevels.length) return false;
  for (var i = 0; i < pLevels.length; i++) {
    final p = pLevels[i];
    if (p == '+') continue;
    if (p != tLevels[i]) return false;
  }
  return true;
}
