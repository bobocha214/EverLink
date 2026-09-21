import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:everlink/models/mqtt_models.dart';

/// 单条 MQTT 消息展示卡片（MQTTX 风格）。
///
/// 顶部为“主题 + 时间”，中部为 QoS / RETAIN 标签，底部为按 [format]
/// 解码后的 payload（Plaintext / JSON / Base64 / Hex），可长按选择复制。
class MqttMessageTile extends StatelessWidget {
  const MqttMessageTile({
    super.key,
    required this.record,
    required this.format,
  });

  final MqttMessageRecord record;
  final MqttPayloadFormat format;

  List<int> get _bytes =>
      record.bytes.isNotEmpty ? record.bytes : utf8.encode(record.payload);

  String get _displayText {
    switch (format) {
      case MqttPayloadFormat.plain:
        return record.payload;
      case MqttPayloadFormat.json:
        try {
          final decoded = jsonDecode(record.payload);
          return const JsonEncoder.withIndent('  ').convert(decoded);
        } catch (_) {
          return record.payload;
        }
      case MqttPayloadFormat.base64:
        return base64Encode(_bytes);
      case MqttPayloadFormat.hex:
        return _bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ');
    }
  }

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay.fromDateTime(record.receivedAt).format(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(record.topic,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                        fontSize: 13)),
              ),
              Text(time,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('QoS ${record.qos}',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary)),
              ),
              if (record.retain) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('RETAIN',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.amber)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            _displayText,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 单条消息的 payload 展示格式切换下拉框（MQTTX 风格）。
class MqttFormatDropdown extends StatelessWidget {
  const MqttFormatDropdown({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final MqttPayloadFormat value;
  final ValueChanged<MqttPayloadFormat?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<MqttPayloadFormat>(
          value: value,
          isDense: true,
          icon: Icon(Icons.expand_more, size: 16, color: scheme.primary),
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.primary),
          items: MqttPayloadFormat.values
              .map((f) => DropdownMenuItem(
                    value: f,
                    child: Text(f.label),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}
