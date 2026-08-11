import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/services/history_service.dart';

/// 历史记录详情页。
///
/// 原先历史列表用 ExpansionTile 展开查看，但大多数记录的 `detail` 为空，
/// 展开后是一片空白，看上去像「查看不了详细」。这里改为独立详情页，
/// 无论有无 detail，都完整展示记录的全部字段，并支持复制。
class HistoryDetailPage extends StatelessWidget {
  const HistoryDetailPage({super.key, required this.record});

  final HistoryRecord record;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final color = r.success ? Colors.teal : Colors.red;
    return Scaffold(
      appBar: AppBar(
        title: const Text('记录详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制全部内容',
            onPressed: () => _copyAll(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 概要卡：操作 + 结果
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(r.op.icon, color: color, size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          r.op.label,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(
                        r.success ? Icons.check_circle : Icons.error,
                        color: r.success ? Colors.green : Colors.red,
                        size: 20,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        r.success ? '成功' : '失败',
                        style: TextStyle(
                            color: r.success ? Colors.green : Colors.red,
                            fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    r.summary,
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 基本信息
          _Section(
            title: '基本信息',
            child: Column(
              children: [
                _row('协议类型', r.type.label),
                _row('设备名称', r.deviceName),
                _row('操作类型', r.op.label),
                _row('发生时间', _fullTime(r.time)),
                _row('执行结果', r.success ? '成功' : '失败'),
                _row('记录编号', r.id),
              ],
            ),
          ),
          // 错误信息（失败时优先展示）
          if (r.error != null && r.error!.isNotEmpty) ...[
            const SizedBox(height: 12),
            _Section(
              title: '错误信息',
              titleColor: Colors.red,
              child: SelectableText(
                r.error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ),
          ],
          const SizedBox(height: 12),
          // 详细数据
          _Section(
            title: '详细数据',
            trailing: (r.detail != null && r.detail!.isNotEmpty)
                ? IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制数据',
                    onPressed: () => _copy(context, r.detail!, '详细数据'),
                  )
                : null,
            child: (r.detail != null && r.detail!.isNotEmpty)
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: SelectableText(
                      r.detail!,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 13),
                    ),
                  )
                : const Text(
                    '该记录未附带详细数据。\n'
                    '（连接/断开类记录通常只有概要；读写类记录会附带原始报文与解析结果）',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(k,
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ),
            Expanded(
              child: SelectableText(v, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );

  static String _fullTime(DateTime t) =>
      '${t.year}-${_p(t.month)}-${_p(t.day)} '
      '${_p(t.hour)}:${_p(t.minute)}:${_p(t.second)}';

  static String _p(int v) => v.toString().padLeft(2, '0');

  String _plainText() {
    final r = record;
    final b = StringBuffer()
      ..writeln('【${r.op.label}】${r.summary}')
      ..writeln('协议类型: ${r.type.label}')
      ..writeln('设备名称: ${r.deviceName}')
      ..writeln('发生时间: ${_fullTime(r.time)}')
      ..writeln('执行结果: ${r.success ? '成功' : '失败'}');
    if (r.error != null && r.error!.isNotEmpty) {
      b.writeln('错误信息: ${r.error}');
    }
    if (r.detail != null && r.detail!.isNotEmpty) {
      b
        ..writeln('---- 详细数据 ----')
        ..writeln(r.detail);
    }
    return b.toString();
  }

  Future<void> _copyAll(BuildContext context) =>
      _copy(context, _plainText(), '记录');

  Future<void> _copy(BuildContext context, String text, String what) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text('已复制$what')));
  }
}

/// 详情页里的分区卡片。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.trailing,
    this.titleColor,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: titleColor),
                ),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
