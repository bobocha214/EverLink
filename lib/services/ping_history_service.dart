import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 单条 Ping 记录（一次完整探测的结果）。
class PingRecord {
  PingRecord({
    required this.host,
    required this.time,
    required this.sent,
    required this.received,
    this.minMs,
    this.avgMs,
    this.maxMs,
    required this.summary,
  });

  final String host;
  final DateTime time;
  final int sent;
  final int received;
  final int? minMs;
  final int? avgMs;
  final int? maxMs;

  /// 完整汇总文案（含丢包率 / min / avg / max / 不可达原因等）。
  final String summary;

  /// 是否有任何回显应答（即可达）。
  bool get reachable => received > 0;

  /// 丢包率百分比。
  int get lossPercent => sent == 0 ? 0 : ((sent - received) / sent * 100).round();

  Map<String, dynamic> toJson() => {
        'host': host,
        'time': time.toIso8601String(),
        'sent': sent,
        'received': received,
        'minMs': minMs,
        'avgMs': avgMs,
        'maxMs': maxMs,
        'summary': summary,
      };

  factory PingRecord.fromJson(Map<String, dynamic> j) => PingRecord(
        host: j['host'] as String,
        time: DateTime.parse(j['time'] as String),
        sent: j['sent'] as int,
        received: j['received'] as int,
        minMs: j['minMs'] as int?,
        avgMs: j['avgMs'] as int?,
        maxMs: j['maxMs'] as int?,
        summary: j['summary'] as String,
      );
}

/// Ping 历史记录服务（全局单例）。
///
/// 记录每一次 Ping 探测的结果（主机、时间、丢包率、时延等），最多保留 50 条。
/// 既用于「我的」页面底部的一键回填快捷列表，也用于右上角「历史记录」弹窗的查看与清理。
class PingHistoryService extends ChangeNotifier {
  PingHistoryService._();

  static final PingHistoryService instance = PingHistoryService._();

  List<PingRecord> _records = [];

  /// 全部 Ping 记录（最新的在最前）。
  List<PingRecord> get records => List.unmodifiable(_records);

  /// 历史主机列表（由记录派生，最新的在最前，去重），供一键回填使用。
  List<String> get hosts {
    final seen = <String>{};
    final out = <String>[];
    for (final r in _records) {
      if (seen.add(r.host)) out.add(r.host);
    }
    return out;
  }

  Future<void> init() async {
    try {
      final file = await _file;
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString()) as List<dynamic>;
        _records = raw
            .map((e) => PingRecord.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (_) {
      // 旧版（仅字符串）或解析失败时忽略，视为空历史。
    }
  }

  /// 记录一次完整的 Ping 探测结果。
  void addRecord(PingRecord record) {
    _records.insert(0, record);
    if (_records.length > 50) _records = _records.sublist(0, 50);
    notifyListeners();
    _save();
  }

  /// 删除指定下标的记录。
  void removeAt(int index) {
    if (index < 0 || index >= _records.length) return;
    _records.removeAt(index);
    notifyListeners();
    _save();
  }

  /// 删除某个主机的全部记录（用于快捷列表的删除）。
  void removeByHost(String host) {
    final before = _records.length;
    _records.removeWhere((r) => r.host == host);
    if (_records.length != before) {
      notifyListeners();
      _save();
    }
  }

  /// 清空全部历史记录。
  void clear() {
    if (_records.isEmpty) return;
    _records.clear();
    notifyListeners();
    _save();
  }

  Future<File> get _file async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/everlink_ping_history.json');
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
