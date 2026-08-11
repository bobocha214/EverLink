import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:everlink/models/protocol_type.dart';

/// 历史记录的操作类型。
enum HistoryOp {
  connect,
  disconnect,
  read,
  write,
  subscribe,
  publish,
  receive,
}

extension HistoryOpX on HistoryOp {
  /// 面向用户的中文名称。
  String get label {
    switch (this) {
      case HistoryOp.connect:
        return '连接';
      case HistoryOp.disconnect:
        return '断开';
      case HistoryOp.read:
        return '读取';
      case HistoryOp.write:
        return '写入';
      case HistoryOp.subscribe:
        return '订阅';
      case HistoryOp.publish:
        return '发布';
      case HistoryOp.receive:
        return '接收';
    }
  }

  /// 对应的图标。
  IconData get icon {
    switch (this) {
      case HistoryOp.connect:
        return Icons.link;
      case HistoryOp.disconnect:
        return Icons.link_off;
      case HistoryOp.read:
        return Icons.download;
      case HistoryOp.write:
        return Icons.upload;
      case HistoryOp.subscribe:
        return Icons.notifications_active;
      case HistoryOp.publish:
        return Icons.send;
      case HistoryOp.receive:
        return Icons.inbox;
    }
  }
}

/// 一条历史记录。
///
/// 无论是连接成功/失败，还是 Modbus 读写、MQTT 订阅/发布/接收，都会沉淀为
/// 一条记录，方便事后追溯设备交互过程。
class HistoryRecord {
  HistoryRecord({
    required this.time,
    required this.type,
    required this.deviceName,
    required this.op,
    this.success = true,
    required this.summary,
    this.detail,
    this.error,
  }) : id =
            '${time.microsecondsSinceEpoch.toRadixString(36)}_${(time.millisecond)}';

  final String id;
  final DateTime time;
  final ProtocolType type;
  final String deviceName;
  final HistoryOp op;
  final bool success;
  final String summary;

  /// 详细内容（如寄存器结果、消息体），可空。
  final String? detail;

  /// 失败时的错误描述。
  final String? error;

  Map<String, dynamic> toJson() => {
        'id': id,
        'time': time.toIso8601String(),
        'type': type.name,
        'deviceName': deviceName,
        'op': op.name,
        'success': success,
        'summary': summary,
        'detail': detail,
        'error': error,
      };

  factory HistoryRecord.fromJson(Map<String, dynamic> j) => HistoryRecord(
        time: DateTime.parse(j['time'] as String),
        type: ProtocolType.values.firstWhere((t) => t.name == j['type']),
        deviceName: j['deviceName'] as String,
        op: HistoryOp.values.firstWhere((o) => o.name == j['op']),
        success: j['success'] as bool,
        summary: j['summary'] as String,
        detail: j['detail'] as String?,
        error: j['error'] as String?,
      );
}

/// 历史记录服务（全局单例），负责内存缓存 + JSON 持久化，并对外广播变化。
class HistoryService extends ChangeNotifier {
  HistoryService._();

  static final HistoryService instance = HistoryService._();

  final List<HistoryRecord> _records = [];

  /// 全部记录（按时间倒序，最新的在最前）。
  List<HistoryRecord> get all =>
      List.unmodifiable(_records.reversed.toList());

  /// 按协议类型筛选。
  List<HistoryRecord> byType(ProtocolType? type) =>
      type == null ? all : all.where((r) => r.type == type).toList();

  /// 新增一条记录并落盘。
  void add(HistoryRecord record) {
    _records.add(record);
    _save();
    notifyListeners();
  }

  /// 清空全部历史。
  Future<void> clear() async {
    _records.clear();
    await _save();
    notifyListeners();
  }

  Future<void> init() async {
    try {
      final file = await _file;
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString()) as List<dynamic>;
        _records.addAll(raw.map((e) => HistoryRecord.fromJson(e as Map<String, dynamic>)));
        notifyListeners();
      }
    } catch (_) {
      // 忽略加载失败。
    }
  }

  Future<File> get _file async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/everlink_history.json');
  }

  Future<void> _save() async {
    try {
      final file = await _file;
      await file.writeAsString(
        jsonEncode(_records.map((r) => r.toJson()).toList()),
      );
    } catch (_) {
      // 忽略写入失败。
    }
  }
}
