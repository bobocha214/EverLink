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

/// 一条接收到的 MQTT 消息记录。
class MqttMessageRecord {
  final String topic;
  final String payload;
  final DateTime receivedAt;

  MqttMessageRecord({
    required this.topic,
    required this.payload,
    required this.receivedAt,
  });
}
