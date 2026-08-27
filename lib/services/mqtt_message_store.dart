import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:everlink/models/mqtt_models.dart';

/// MQTT 订阅消息持久化（按 `sessionId` 维度）。
///
/// 保存每个 MQTT 设备会话收到的消息记录，退出详情页后再进入可恢复历史。
/// 写入采用内存缓冲 + 定时批量落盘（约 400ms），页面销毁时调用 [flushNow]
/// 立即落盘，避免高频收发时反复读写 SharedPreferences。
class MqttMessageStore {
  MqttMessageStore._();

  static const String _key = 'mqtt_messages_v1';
  static const int _max = 200;

  /// 内存缓冲：key = sessionId，value 为最新在前(insert(0))的消息列表。
  static final Map<String, List<Map<String, dynamic>>> _buffer = {};

  /// 定时批量落盘计时器。
  static Timer? _flushTimer;

  /// 串行化读写，避免并发覆盖。
  static Future<void> _chain = Future.value();

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

  static Future<T> _locked<T>(Future<T> Function() fn) {
    final prev = _chain;
    final completer = Completer<T>();
    _chain = completer.future;
    Future<T> run() async {
      try {
        await prev;
      } catch (_) {}
      try {
        return await fn();
      } finally {
        completer.complete();
      }
    }

    run();
    return completer.future;
  }

  /// 载入指定会话的已保存消息（最新在前）。
  static Future<List<MqttMessageRecord>> load(String sessionId) async {
    final all = await _readAll();
    final list = all[sessionId];
    if (list is List) {
      return list
          .map((e) => MqttMessageRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return <MqttMessageRecord>[];
  }

  /// 追加一条消息（写入内存缓冲，并安排定时落盘）。
  static void append(String sessionId, MqttMessageRecord record) {
    final buf = _buffer.putIfAbsent(sessionId, () => []);
    buf.insert(0, record.toJson());
    if (buf.length > _max) buf.length = _max;
    _flushTimer ??= Timer(const Duration(milliseconds: 400), _flush);
  }

  /// 清空指定会话的消息（缓冲与持久化一并清除）。
  static Future<void> clear(String sessionId) async {
    _buffer.remove(sessionId);
    await _locked(() async {
      final all = await _readAll();
      all.remove(sessionId);
      await _writeAll(all);
    });
  }

  /// 立即把内存缓冲落盘（页面销毁时调用）。
  static Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
  }

  static Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    await _locked(() async {
      final snapshot = <String, List<Map<String, dynamic>>>{};
      for (final e in _buffer.entries) {
        snapshot[e.key] = List<Map<String, dynamic>>.from(e.value);
      }
      _buffer.clear();
      final all = await _readAll();
      for (final e in snapshot.entries) {
        final existing =
            List<Map<String, dynamic>>.from(all[e.key] as List? ?? []);
        final merged = <Map<String, dynamic>>[...e.value, ...existing];
        if (merged.length > _max) merged.length = _max;
        all[e.key] = merged;
      }
      await _writeAll(all);
    });
  }
}
