import 'package:shared_preferences/shared_preferences.dart';

/// TCP 连接「历史记录」持久化。
///
/// 仅保存 `host:port` 字符串，最新在前，去重并裁剪到 [_max] 条。
/// 与具体页面解耦，供 TCP 相关页面（如 [TcpRawDetailPage]）调用。
class TcpHistoryService {
  static const String _key = 'tcp_history_v1';
  static const int _max = 10;

  /// 读取历史连接列表（最新在前）。失败时返回空列表。
  static Future<List<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_key) ?? [];
    } catch (_) {
      return [];
    }
  }

  /// 记录一次成功连接：去重并放到最前，超过 [_max] 裁剪。
  /// 返回更新后的完整列表（已持久化）。
  static Future<List<String>> add(String host, int port) async {
    final entry = '$host:$port';
    final list = await load();
    list.removeWhere((e) => e == entry);
    list.insert(0, entry);
    if (list.length > _max) list.length = _max;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, list);
    } catch (_) {
      // 持久化失败时仍返回内存结果，不影响本次使用。
    }
    return list;
  }

  /// 直接覆盖保存整个历史列表（用于删除单条 / 清空）。
  static Future<void> save(List<String> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, list);
    } catch (_) {
      // 持久化失败时静默忽略。
    }
  }
}
