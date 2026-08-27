import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// MQTT 订阅主题持久化（按 `sessionId` 维度）。
///
/// 保存每个 MQTT 设备会话“曾订阅”的主题列表，退出详情页 / 重连后仍可恢复，
/// 连接成功时由页面据此自动重新订阅。与 [MqttMessageStore] 解耦、独立存储，
/// 订阅变更频率低，直接读写 SharedPreferences 即可，无需缓冲。
class MqttTopicStore {
  MqttTopicStore._();

  static const String _key = 'mqtt_topics_v1';

  static Future<Map<String, dynamic>> _readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 读取失败不影响本次使用，视为空。
    }
    return <String, dynamic>{};
  }

  static Future<void> _writeAll(Map<String, dynamic> all) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(all));
    } catch (_) {
      // 写入失败静默忽略，内存中的列表仍可用。
    }
  }

  /// 载入指定会话已保存的订阅主题（去重、保序）。
  static Future<List<String>> load(String sessionId) async {
    final all = await _readAll();
    final list = all[sessionId];
    if (list is List) {
      return list.map((e) => e.toString()).toList();
    }
    return const [];
  }

  /// 保存会话的订阅主题（去重、保序；为空则删除该会话项）。
  static Future<void> save(String sessionId, List<String> topics) async {
    final unique = <String>[];
    for (final t in topics) {
      if (!unique.contains(t)) unique.add(t);
    }
    final all = await _readAll();
    if (unique.isEmpty) {
      all.remove(sessionId);
    } else {
      all[sessionId] = unique;
    }
    await _writeAll(all);
  }

  /// 清除指定会话的订阅主题（取消全部订阅或删除会话时调用）。
  static Future<void> clear(String sessionId) async {
    final all = await _readAll();
    all.remove(sessionId);
    await _writeAll(all);
  }
}
