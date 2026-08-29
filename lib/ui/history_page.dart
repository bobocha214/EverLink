import 'package:flutter/material.dart';

import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/settings_service.dart';
import 'package:everlink/ui/history_detail_page.dart';
import 'package:everlink/ui/widgets/responsive_grid.dart';
import 'package:everlink/ui/widgets/responsive_sheet.dart';
import 'package:everlink/utils/app_routes.dart';

/// 操作类别，用于历史筛选。
enum _HistCat {
  all,
  connection,
  data,
  message,
}

extension _HistCatX on _HistCat {
  String get label {
    switch (this) {
      case _HistCat.all:
        return '全部';
      case _HistCat.connection:
        return '连接';
      case _HistCat.data:
        return '数据';
      case _HistCat.message:
        return '消息';
    }
  }
}

_HistCat _catOf(HistoryOp op) {
  switch (op) {
    case HistoryOp.connect:
    case HistoryOp.disconnect:
      return _HistCat.connection;
    case HistoryOp.read:
    case HistoryOp.write:
      return _HistCat.data;
    case HistoryOp.subscribe:
    case HistoryOp.publish:
    case HistoryOp.receive:
      return _HistCat.message;
  }
}

/// 历史记录页：按设备 + 操作类别（连接 / 数据 / 消息）筛选，聚焦设备交互数据。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  _HistCat _cat = _HistCat.all;
  String? _device;
  ProtocolType? _typeFilter;
  bool? _successFilter; // null=全部, true=成功, false=失败
  String _query = '';

  @override
  void initState() {
    super.initState();
    HistoryService.instance.addListener(_onChanged);
    // 协议启用/停用后，筛选条需实时增减对应标签。
    SettingsService.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    HistoryService.instance.removeListener(_onChanged);
    SettingsService.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {
      // 选中的协议若被停用，其标签会消失，同步重置筛选以免筛选条无高亮项。
      if (_typeFilter != null &&
          !SettingsService.instance.isProtocolEnabled(_typeFilter!)) {
        _typeFilter = null;
      }
    });
  }

  /// 已停用协议的记录数（用于在筛选条下方提示，避免用户误以为记录丢失）。
  int _hiddenByProtocol = 0;

  List<HistoryRecord> get _records {
    final q = _query.trim().toLowerCase();
    final settings = SettingsService.instance;
    // 设备下拉框由历史记录中的设备名驱动；做安全校验避免筛选卡死。
    final validDevices = HistoryService.instance.all
        .map((r) => r.deviceName)
        .toSet();
    final deviceFilter =
        (_device != null && validDevices.contains(_device)) ? _device : null;
    // 协议若被停用，其筛选标签会消失，此处忽略残留筛选避免列表一直为空。
    final typeFilter =
        (_typeFilter != null && settings.isProtocolEnabled(_typeFilter!))
            ? _typeFilter
            : null;
    final all = HistoryService.instance.all;
    var hidden = 0;
    final result = all.where((r) {
      // 停用协议的记录不再展示（数据保留，重新启用即恢复）。
      if (!settings.isProtocolEnabled(r.type)) {
        hidden++;
        return false;
      }
      if (_cat != _HistCat.all && _catOf(r.op) != _cat) return false;
      if (deviceFilter != null && r.deviceName != deviceFilter) return false;
      if (typeFilter != null && r.type != typeFilter) return false;
      if (_successFilter != null && r.success != _successFilter) return false;
      if (q.isNotEmpty &&
          !r.deviceName.toLowerCase().contains(q) &&
          !r.summary.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
    _hiddenByProtocol = hidden;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史记录'),
        actions: [
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.filter_list),
                tooltip: '筛选',
                onPressed: _showFilterSheet,
              ),
              if (_hasFilter)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          if (records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: '清空历史',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: records.isEmpty ? _buildEmpty() : _buildList(records),
          ),
        ],
      ),
    );
  }

  /// 是否有任意筛选条件生效（用于在筛选按钮上显示小红点）。
  bool get _hasFilter =>
      _cat != _HistCat.all ||
      _device != null ||
      _typeFilter != null ||
      _successFilter != null ||
      _query.isNotEmpty;

  /// 打开右上角筛选面板：以底部弹层承载筛选内容，点击调整即时生效。
  void _showFilterSheet() {
    showResponsiveSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: _buildFilterContent((fn) {
              setState(fn);
              setModal(fn);
            }),
          ),
        ),
      ),
    );
  }

  /// 历史筛选内容（可在底部弹层中复用）。[update] 同时刷新本页与弹层。
  Widget _buildFilterContent(void Function(void Function()) update) {
    final settings = SettingsService.instance;
    // 设备列表仅取自「已启用协议」的记录，避免选中后列表为空。
    final devices = HistoryService.instance.all
        .where((r) => settings.isProtocolEnabled(r.type))
        .map((r) => r.deviceName)
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('筛选历史',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 12),
        TextField(
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: '搜索设备名或操作摘要',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
          ),
          onChanged: (v) => update(() => _query = v),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in _HistCat.values)
              ChoiceChip(
                label: Text(c.label),
                selected: _cat == c,
                onSelected: (_) => update(() => _cat = c),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Chip(
                label: '全部协议',
                selected: _typeFilter == null,
                onTap: () => update(() => _typeFilter = null)),
            // 仅显示设置中已启用的协议，与首页保持一致。
            for (final d in settings.enabledDescriptors)
              _Chip(
                label: d.name,
                selected: _typeFilter == d.type,
                onTap: () => update(() => _typeFilter =
                    _typeFilter == d.type ? null : d.type),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Chip(
              label: '全部结果',
              selected: _successFilter == null,
              onTap: () => update(() => _successFilter = null),
            ),
            _Chip(
              label: '成功',
              selected: _successFilter == true,
              onTap: () => update(() => _successFilter =
                  _successFilter == true ? null : true),
            ),
            _Chip(
              label: '失败',
              selected: _successFilter == false,
              onTap: () => update(() => _successFilter =
                  _successFilter == false ? null : false),
            ),
          ],
        ),
        if (devices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InputDecorator(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.devices_outlined, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  // value 为 null 时匹配“全部设备”项。
                  value: (_device != null && devices.contains(_device))
                      ? _device
                      : null,
                  hint: const Text('按设备筛选'),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('全部设备'),
                    ),
                    for (final d in devices)
                      DropdownMenuItem<String>(
                        value: d,
                        child: Text(d),
                      ),
                  ],
                  onChanged: (v) => update(() => _device = v),
                ),
              ),
            ),
          ),
        if (_hiddenByProtocol > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                const Icon(Icons.visibility_off_outlined,
                    size: 14, color: Colors.grey),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$_hiddenByProtocol 条记录因协议已停用而隐藏，可在设置中重新启用',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history_toggle_off, size: 64, color: Colors.grey),
          SizedBox(height: 12),
          Text('暂无历史记录', style: TextStyle(color: Colors.grey, fontSize: 16)),
          SizedBox(height: 4),
          Text('连接设备并读写后，交互数据会显示在这里',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildList(List<HistoryRecord> records) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        16 + (SettingsService.instance.navFloating ? 100 : 0),
      ),
      child: ResponsiveGrid(
        spacing: 8,
        children: [for (final r in records) _buildRecordCard(r)],
      ),
    );
  }

  Widget _buildRecordCard(HistoryRecord r) {
    final color = r.success ? Colors.teal : Colors.red;
    final hasDetail = r.detail != null && r.detail!.isNotEmpty;
    final hasError = r.error != null && r.error!.isNotEmpty;
    return Card(
      child: ListTile(
        leading: Icon(r.op.icon, color: color),
        title: Text(r.summary),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${r.type.label} · ${r.deviceName} · ${_formatTime(r.time)}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (hasError)
              Text(
                r.error!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.red),
              )
            else if (hasDetail)
              Text(
                r.detail!.replaceAll('\n', ' '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    fontFamily: 'monospace'),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            r.success
                ? const Icon(Icons.check_circle, color: Colors.green, size: 18)
                : const Icon(Icons.error, color: Colors.red, size: 18),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
          ],
        ),
        isThreeLine: hasDetail || hasError,
        onTap: () => AppRoutes.push(context, HistoryDetailPage(record: r)),
      ),
    );
  }

  Future<void> _confirmClear() async {
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
    }
  }

  String _formatTime(DateTime t) {
    return '${t.month}/${t.day} ${t.hour}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  }
}

/// 筛选条上的可点选标签。
class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}
