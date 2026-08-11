import 'package:flutter/material.dart';

import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/session_manager.dart';

/// 数据存储：查看本地数据与清理。
class DataStoragePage extends StatefulWidget {
  const DataStoragePage({super.key});

  @override
  State<DataStoragePage> createState() => _DataStoragePageState();
}

class _DataStoragePageState extends State<DataStoragePage> {
  Future<void> _confirmClearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空历史记录'),
        content: const Text('确定清空全部历史记录吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await HistoryService.instance.clear();
      if (mounted) setState(() {});
    }
  }

  Future<void> _confirmClearDevices() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空所有设备'),
        content: const Text('确定删除全部已保存的设备会话吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final mgr = SessionManager.instance;
      for (final s in List.of(mgr.sessions)) {
        await mgr.removeSession(s.id);
      }
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final mgr = SessionManager.instance;
    final hist = HistoryService.instance;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('数据存储')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              _StatChip(
                label: '设备',
                value: '${mgr.total}',
                sub: '在线 ${mgr.onlineCount}',
              ),
              const SizedBox(width: 12),
              _StatChip(label: '历史记录', value: '${hist.all.length}'),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.history, color: Colors.teal),
                  title: const Text('清空历史记录'),
                  subtitle: Text('共 ${hist.all.length} 条，清空后不可恢复'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _confirmClearHistory,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.devices, color: Colors.teal),
                  title: const Text('清空所有设备'),
                  subtitle: Text('共 ${mgr.total} 个，清空后不可恢复'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _confirmClearDevices,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '数据仅保存在本机，用于设备会话与读写历史记录。',
              style: TextStyle(color: theme.colorScheme.outline, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value, this.sub});
  final String label;
  final String value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              sub != null ? '$label（$sub）' : label,
              style: TextStyle(color: theme.colorScheme.primary, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
