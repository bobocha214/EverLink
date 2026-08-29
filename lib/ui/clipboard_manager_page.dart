import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:everlink/services/clipboard_history/clipboard_history_manager.dart';
import 'package:everlink/ui/widgets/responsive_grid.dart';
import 'package:everlink/ui/widgets/responsive_sheet.dart';

/// 剪贴板管理工具页：本地记录本机所有复制内容（含其它 App），可查看、复制、删除。
class ClipboardManagerPage extends StatefulWidget {
  const ClipboardManagerPage({super.key});

  @override
  State<ClipboardManagerPage> createState() => _ClipboardManagerPageState();
}

class _ClipboardManagerPageState extends State<ClipboardManagerPage> {
  final manager = ClipboardHistoryManager.instance;

  @override
  void initState() {
    super.initState();
    manager.init();
    manager.onChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _copy(String text) async {
    await manager.copyAndRecord(text);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已复制')));
  }

  void _showDetail(ClipboardHistoryItem item) {
    showResponsiveSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                _SourceChip(source: item.source),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  tooltip: '删除',
                  onPressed: () {
                    Navigator.pop(context);
                    manager.remove(item.id);
                  },
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.55,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SelectableText(
                item.text,
                style: const TextStyle(fontSize: 14, height: 1.6),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('复制到剪贴板'),
                onPressed: () {
                  Navigator.pop(context);
                  _copy(item.text);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmClear() {
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('清空剪贴板历史'),
        content: const Text('将删除本地保存的所有复制记录，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(d);
              manager.clear();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = manager.items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('剪贴板管理'),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空全部',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            color: Colors.teal.withValues(alpha: 0.08),
            child: const Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: Colors.teal),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '自动记录本应用复制内容；在 EverLink 前台时也会记录其它 App 的复制（仅存本地）。',
                    style: TextStyle(fontSize: 12, color: Colors.teal),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      '还没有复制记录\n在其他 App 复制文字后会自动出现在这里',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: ResponsiveGrid(
                      spacing: 8,
                      children: [for (final item in items) _buildItemCard(item)],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemCard(ClipboardHistoryItem item) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Colors.grey.withValues(alpha: 0.15),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.preview,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _SourceChip(source: item.source),
                        const SizedBox(width: 8),
                        Text(
                          _timeText(item.time),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                color: Colors.teal,
                tooltip: '复制',
                onPressed: () => _copy(item.text),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: Colors.grey,
                tooltip: '删除',
                onPressed: () => manager.remove(item.id),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _timeText(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    final p = (int v) => v.toString().padLeft(2, '0');
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) {
      return '${p(t.hour)}:${p(t.minute)}';
    }
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${t.month}/${t.day}';
  }
}

class _SourceChip extends StatelessWidget {
  final String source;
  const _SourceChip({required this.source});

  @override
  Widget build(BuildContext context) {
    final isApp = source == 'app';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: isApp
            ? Colors.teal.withValues(alpha: 0.14)
            : Colors.grey.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        isApp ? '本机' : '其它 App',
        style: TextStyle(
          fontSize: 10,
          color: isApp ? Colors.teal : Colors.grey[700],
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
