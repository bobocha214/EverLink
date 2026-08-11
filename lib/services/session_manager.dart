import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:everlink/models/device_session.dart';
import 'package:everlink/protocols/protocol_registry.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/history_service.dart';

/// 设备会话管理器（全局单例）。
///
/// 负责：
/// 1. 维护用户保存的所有设备会话列表（含持久化）；
/// 2. 为每个“已打开/已连接”的会话持有对应的 [ConnectionManager]，使首页能
///    实时反映设备的在线 / 离线 / 连接中状态；
/// 3. 在状态变化时把会话状态落盘，并触发 UI 刷新。
class SessionManager extends ChangeNotifier {
  SessionManager._();

  static final SessionManager instance = SessionManager._();

  final List<DeviceSession> _sessions = [];

  /// 活跃连接：sessionId -> 持续持有的 [ConnectionManager]。
  final Map<String, ConnectionManager> _active = {};

  List<DeviceSession> get sessions => List.unmodifiable(_sessions);

  int get total => _sessions.length;

  int get onlineCount =>
      _sessions.where((s) => s.status == DeviceConnectionState.connected).length;

  int get connectingCount =>
      _sessions.where((s) => s.status == DeviceConnectionState.connecting).length;

  int get offlineCount =>
      _sessions.where((s) => s.status == DeviceConnectionState.disconnected).length;

  int get errorCount =>
      _sessions.where((s) => s.status == DeviceConnectionState.error).length;

  DeviceSession? find(String id) {
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 返回指定会话的 [ConnectionManager]，若尚未创建则新建并登记。
  ///
  /// 新创建的 manager 会挂接状态监听：把状态同步到会话、记录“断开”历史、
  /// 落盘并通知 UI。
  ConnectionManager ensureManager(DeviceSession session) {
    final existing = _active[session.id];
    if (existing != null) return existing;

    final cm = ConnectionManager(ProtocolRegistry.get(session.type));
    cm.updateConfig(session.config);
    // 新建的 manager 初始一定是“未连接”。立即把会话状态同步成同一来源，
    // 保证首页（读 session.status）与详情页（读 manager.state）口径一致。
    if (session.status != cm.state) {
      session.status = cm.state;
      session.lastError = null;
    }
    cm.connectionStateStream.listen((st) {
      final previous = session.status;
      session.status = st;
      if (st == DeviceConnectionState.error) session.lastError = cm.lastError;
      session.updatedAt = DateTime.now();
      if (st == DeviceConnectionState.disconnected &&
          previous == DeviceConnectionState.connected) {
        HistoryService.instance.add(
          HistoryRecord(
            time: DateTime.now(),
            type: session.type,
            deviceName: session.name,
            op: HistoryOp.disconnect,
            success: true,
            summary: '断开连接：${session.name}',
          ),
        );
      }
      _save();
      notifyListeners();
    });
    _active[session.id] = cm;
    return cm;
  }

  /// 新增一个会话并落盘。
  Future<void> addSession(DeviceSession session) async {
    _sessions.add(session);
    await _save();
    notifyListeners();
  }

  /// 删除会话：同时释放其活跃连接。
  Future<void> removeSession(String id) async {
    _active.remove(id)?.dispose();
    _sessions.removeWhere((s) => s.id == id);
    await _save();
    notifyListeners();
  }

  /// 重命名会话并落盘（历史记录仍按设备名字符串关联，旧记录不受影响）。
  Future<void> renameSession(String id, String newName) async {
    final s = find(id);
    if (s != null && newName.trim().isNotEmpty) {
      s.name = newName.trim();
      s.updatedAt = DateTime.now();
      await _save();
      notifyListeners();
    }
  }

  /// 立即把会话列表落盘并通知 UI。
  ///
  /// 调试页（如 Modbus）修改连接参数后调用，使 IP / 端口 / 从站等改动持久化，
  /// 并让首页设备卡片同步显示最新配置。
  Future<void> persist() async {
    await _save();
    notifyListeners();
  }

  /// 从持久化文件加载会话列表。
  Future<void> init() async {
    try {
      final file = await _file;
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString()) as List<dynamic>;
        _sessions
          ..clear()
          ..addAll(raw.map((e) => DeviceSession.fromJson(e as Map<String, dynamic>)));
        // 启动时没有任何真实连接，必须把会话状态重置为离线。持久化里的
        // status 只是上次运行遗留的“镜像”，不可信——否则会出现“首页显示
        // 已连接、点进去却是未连接”的矛盾（详情页读的是真实 ConnectionManager）。
        for (final s in _sessions) {
          s.status = DeviceConnectionState.disconnected;
          s.lastError = null;
        }
        notifyListeners();
      }
    } catch (_) {
      // 加载失败时忽略，保持空列表。
    }
  }

  Future<File> get _file async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/everlink_sessions.json');
  }

  Future<void> _save() async {
    try {
      final file = await _file;
      await file.writeAsString(
        jsonEncode(_sessions.map((s) => s.toJson()).toList()),
      );
    } catch (_) {
      // 写入失败忽略。
    }
  }
}
