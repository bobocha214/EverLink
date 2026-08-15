import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// TCP 通讯记录持久化（按 `host:port` 维度）。
///
/// 仅保存序列化的日志条目（收发方向、字节、时间、附加校验信息），最新在前，
/// 单连接上限 [_max] 条。用于「TCP 原始连接」详情页退出后再进入时恢复历史记录。
///
/// 写入采用内存缓冲 + 定时批量落盘（约 400ms），避免高频收发时反复读写的开销；
/// 页面销毁时调用 [flushNow] 立即落盘，确保不丢最新一条。
class TcpLogStore {
  TcpLogStore._();

  static const String _key = 'tcp_log_v1';
  static const int _max = 500;

  /// 内存缓冲：key = `host:port`，value 为最新在前(insert(0))的条目列表。
  static final Map<String, List<Map<String, dynamic>>> _buffer = {};

  /// 定时批量落盘计时器。
  static Timer? _flushTimer;

  /// 串行化读写，避免并发覆盖。
  static Future<void> _chain = Future.value();

  static String _connKey(String host, int port) => '$host:$port';

  /// 读取全部连接的日志（JSON map）。
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
      // 写入失败静默忽略，内存中的 _log 仍可用。
    }
  }

  /// 串行执行一个读写操作，确保不会相互覆盖。
  static Future<T> _locked<T>(Future<T> Function() fn) {
    final prev = _chain;
    final completer = Completer<T>();
    _chain = completer.future;
    Future<T> run() async {
      try {
        await prev;
      } catch (_) {
        // 前序任务失败不影响后续。
      }
      try {
        return await fn();
      } finally {
        completer.complete();
      }
    }

    run();
    return completer.future;
  }

  /// 载入指定连接的已保存记录（最新在前）。
  static Future<List<Map<String, dynamic>>> load(String host, int port) async {
    final all = await _readAll();
    final list = all[_connKey(host, port)];
    if (list is List) {
      return List<Map<String, dynamic>>.from(list);
    }
    return <Map<String, dynamic>>[];
  }

  /// 追加一条记录（写入内存缓冲，并安排定时落盘）。
  static void append(String host, int port, Map<String, dynamic> entry) {
    final k = _connKey(host, port);
    final buf = _buffer.putIfAbsent(k, () => []);
    buf.insert(0, entry);
    if (buf.length > _max) buf.length = _max;
    _flushTimer ??= Timer(const Duration(milliseconds: 400), _flush);
  }

  /// 清空指定连接的记录（缓冲与持久化一并清除）。
  static Future<void> clear(String host, int port) async {
    _buffer.remove(_connKey(host, port));
    await _locked(() async {
      final all = await _readAll();
      all.remove(_connKey(host, port));
      await _writeAll(all);
    });
  }

  /// 立即把内存缓冲落盘（页面销毁时调用，不保证完成但会尽快执行）。
  static Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
  }

  static Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    await _locked(() async {
      // 拷贝快照，避免落盘过程中新追加的条目被清掉。
      final snapshot = <String, List<Map<String, dynamic>>>{};
      for (final e in _buffer.entries) {
        snapshot[e.key] = List<Map<String, dynamic>>.from(e.value);
      }
      _buffer.clear();
      final all = await _readAll();
      for (final e in snapshot.entries) {
        final existing =
            List<Map<String, dynamic>>.from(all[e.key] as List? ?? []);
        // 缓冲最新在前，整体前置到已有列表之前。
        final merged = <Map<String, dynamic>>[...e.value, ...existing];
        if (merged.length > _max) merged.length = _max;
        all[e.key] = merged;
      }
      await _writeAll(all);
    });
  }
}
