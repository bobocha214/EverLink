import 'package:flutter/material.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/protocol_registry.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/services/settings_service.dart';
import 'package:everlink/ui/modbus_page.dart';
import 'package:everlink/ui/mqtt_page.dart';
import 'package:everlink/ui/websocket_page.dart';
import 'package:everlink/ui/http_page.dart';
import 'package:everlink/ui/opcua_page.dart';
import 'package:everlink/ui/widgets/add_device_sheet.dart';
import 'package:everlink/utils/app_routes.dart';

/// 首页：以卡片形式展示用户保存的所有设备，并汇总在线 / 离线 / 连接中数量。
///
/// 每张卡片自带连接 / 断开开关与“调试”入口，点击卡片主体也可直接进入调试页；
/// 支持按名称搜索、按协议类型、连接状态与设备筛选；长按编辑图标可重命名设备。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 按协议类型筛选（null 表示全部）。
  ProtocolType? _typeFilter;

  /// 按连接状态筛选（null 表示全部）。
  DeviceConnectionState? _statusFilter;

  /// 按设备名称筛选（null 表示全部）。
  String? _deviceFilter;

  /// 按设备名称搜索（不区分大小写）。
  String _nameQuery = '';

  @override
  void initState() {
    super.initState();
    SessionManager.instance.addListener(_onSessionsChanged);
    // 协议启用/停用后，筛选条与设备列表需实时跟随。
    SettingsService.instance.addListener(_onSessionsChanged);
  }

  @override
  void dispose() {
    SessionManager.instance.removeListener(_onSessionsChanged);
    SettingsService.instance.removeListener(_onSessionsChanged);
    super.dispose();
  }

  void _onSessionsChanged() {
    if (!mounted) return;
    setState(() {
      // 选中的协议若被停用，其标签会消失，同步重置筛选以免筛选条无高亮项。
      if (_typeFilter != null &&
          !SettingsService.instance.isProtocolEnabled(_typeFilter!)) {
        _typeFilter = null;
      }
    });
  }

  /// 经过名称 + 类型 + 状态 + 设备筛选后的设备列表。
  List<DeviceSession> get _visibleSessions {
    final q = _nameQuery.trim().toLowerCase();
    final mgr = SessionManager.instance;
    // 设备下拉框单选无法像 Chip 再点取消，做安全校验避免残留筛选卡死。
    final validDevices = mgr.sessions.map((s) => s.name).toSet();
    final deviceFilter =
        (_deviceFilter != null && validDevices.contains(_deviceFilter))
            ? _deviceFilter
            : null;
    // 协议被停用后其筛选标签会消失，忽略残留筛选避免列表一直为空。
    final typeFilter = (_typeFilter != null &&
            SettingsService.instance.isProtocolEnabled(_typeFilter!))
        ? _typeFilter
        : null;
    return mgr.sessions.where((s) {
      if (typeFilter != null && s.type != typeFilter) return false;
      if (_statusFilter != null && s.status != _statusFilter) return false;
      if (deviceFilter != null && s.name != deviceFilter) return false;
      if (q.isNotEmpty && !s.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  void _openDebug(DeviceSession s) {
    Widget page;
    switch (s.type) {
      case ProtocolType.modbusTcp:
        page = ModbusPage(session: s);
      case ProtocolType.mqtt:
        page = MqttPage(session: s);
      case ProtocolType.webSocket:
        page = WebSocketPage(session: s);
      case ProtocolType.http:
        page = HttpPage(session: s);
      case ProtocolType.opcUa:
        page = OpcUaPage(session: s);
    }
    AppRoutes.push(context, page);
  }

  /// 底部弹窗：选择协议 → 填写名称与参数 → 保存（不自动连接）。
  Future<void> _addDevice() async {
    final session = await showAddDeviceSheet(context);
    if (session != null && mounted) _openDebug(session);
  }

  /// 连接配置是否包含有效地址（添加设备时允许留空，需先到调试页填写）。
  bool _hasHost(DeviceSession s) {
    final c = s.config;
    if (c is ModbusConnectionConfig) return c.host.trim().isNotEmpty;
    if (c is MqttConnectionConfig) return c.host.trim().isNotEmpty;
    if (c is WebSocketConnectionConfig) return c.url.trim().isNotEmpty;
    if (c is HttpConnectionConfig) return c.baseUrl.trim().isNotEmpty;
    if (c is OpcUaConnectionConfig) return c.endpoint.trim().isNotEmpty;
    return true;
  }

  /// 卡片上的连接 / 断开开关。
  Future<void> _toggleConnection(DeviceSession s, ConnectionManager cm) async {
    if (cm.state == DeviceConnectionState.connected) {
      await cm.disconnect();
      return;
    }
    if (cm.state == DeviceConnectionState.connecting) return;
    if (!_hasHost(s)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在“调试”页填写连接地址后再连接')),
        );
      }
      return;
    }
    try {
      await cm.connect();
      final ok = cm.state == DeviceConnectionState.connected;
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: s.type,
          deviceName: s.name,
          op: HistoryOp.connect,
          success: ok,
          summary: ok ? '连接成功：${s.name}' : '连接失败：${s.name}',
          error: ok ? null : cm.lastError,
        ),
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败：${cm.lastError ?? '未知错误'}')),
        );
      }
    } catch (e) {
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: s.type,
          deviceName: s.name,
          op: HistoryOp.connect,
          success: false,
          summary: '连接失败：${s.name}',
          error: e.toString(),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败：${cm.lastError ?? e}')),
        );
      }
    }
  }

  /// 重命名设备。
  Future<void> _renameSession(DeviceSession s) async {
    final ctl = TextEditingController(text: s.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名设备'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '设备名称'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && newName != s.name && mounted) {
      await SessionManager.instance.renameSession(s.id, newName);
    }
  }

  Future<void> _confirmRemove(DeviceSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除设备'),
        content: Text('确定删除设备「${session.name}」吗？该操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await SessionManager.instance.removeSession(session.id);
  }

  @override
  Widget build(BuildContext context) {
    final mgr = SessionManager.instance;
    final sessions = _visibleSessions;

    return Scaffold(
      appBar: AppBar(
        title: const Text('EverLink 设备调试'),
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
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addDevice,
        icon: const Icon(Icons.add),
        label: const Text('添加设备'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildStatRow(mgr),
          const SizedBox(height: 12),
          if (mgr.sessions.isEmpty)
            _buildEmpty()
          else if (sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(
                child: Text('没有符合筛选条件的设备',
                    style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            ...sessions.map((s) => _buildSessionCard(s)),
        ],
      ),
    );
  }

  /// 是否有任意筛选条件生效（用于在筛选按钮上显示小红点）。
  bool get _hasFilter =>
      _typeFilter != null ||
      _statusFilter != null ||
      _deviceFilter != null ||
      _nameQuery.isNotEmpty;

  /// 打开右上角筛选面板：以底部弹层承载筛选内容，点击调整即时生效。
  void _showFilterSheet() {
    showModalBottomSheet(
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

  /// 设备筛选内容（可在底部弹层中复用）。[update] 同时刷新本页与弹层，
  /// 使 Chip / 下拉的选中态即时反馈，而设备列表随本页 setState 实时变化。
  Widget _buildFilterContent(void Function(void Function()) update) {
    final typeChips = <Widget>[
      _FilterChip(
        label: '全部',
        selected: _typeFilter == null,
        onSelected: () => update(() => _typeFilter = null),
      ),
      for (final d in SettingsService.instance.enabledDescriptors)
        _FilterChip(
          label: d.name,
          selected: _typeFilter == d.type,
          onSelected: () => update(
            () => _typeFilter = _typeFilter == d.type ? null : d.type,
          ),
        ),
    ];
    final statusChips = <Widget>[
      _FilterChip(
        label: '全部状态',
        selected: _statusFilter == null,
        onSelected: () => update(() => _statusFilter = null),
      ),
      _FilterChip(
        label: '在线',
        selected: _statusFilter == DeviceConnectionState.connected,
        onSelected: () => update(() => _statusFilter =
            _statusFilter == DeviceConnectionState.connected
                ? null
                : DeviceConnectionState.connected),
      ),
      _FilterChip(
        label: '离线',
        selected: _statusFilter == DeviceConnectionState.disconnected,
        onSelected: () => update(() => _statusFilter =
            _statusFilter == DeviceConnectionState.disconnected
                ? null
                : DeviceConnectionState.disconnected),
      ),
      _FilterChip(
        label: '异常',
        selected: _statusFilter == DeviceConnectionState.error,
        onSelected: () => update(() => _statusFilter =
            _statusFilter == DeviceConnectionState.error
                ? null
                : DeviceConnectionState.error),
      ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('筛选设备',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 12),
        TextField(
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: '按设备名称搜索',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
          ),
          onChanged: (v) => update(() => _nameQuery = v),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: typeChips,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: statusChips,
        ),
        const SizedBox(height: 8),
        _buildDeviceDropdown(update),
      ],
    );
  }

  /// 首页设备下拉框：按设备名过滤列表（设备多时比一排 Chip 更省空间）。
  Widget _buildDeviceDropdown(void Function(void Function()) update) {
    final deviceNames = SessionManager.instance.sessions
        .map((s) => s.name)
        .where((n) => n.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (deviceNames.isEmpty) return const SizedBox.shrink();
    return InputDecorator(
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
          value: (_deviceFilter != null && deviceNames.contains(_deviceFilter))
              ? _deviceFilter
              : null,
          hint: const Text('按设备筛选'),
          items: [
            const DropdownMenuItem<String>(
              value: null,
              child: Text('全部设备'),
            ),
            for (final d in deviceNames)
              DropdownMenuItem<String>(
                value: d,
                child: Text(d),
              ),
          ],
          onChanged: (v) => update(() => _deviceFilter = v),
        ),
      ),
    );
  }

  Widget _buildStatRow(SessionManager mgr) {
    return Row(
      children: [
        Expanded(child: _StatCard(label: '在线', value: mgr.onlineCount, color: Colors.green)),
        const SizedBox(width: 12),
        Expanded(child: _StatCard(label: '连接中', value: mgr.connectingCount, color: Colors.orange)),
        const SizedBox(width: 12),
        Expanded(child: _StatCard(label: '离线', value: mgr.offlineCount, color: Colors.grey)),
        const SizedBox(width: 12),
        Expanded(child: _StatCard(label: '异常', value: mgr.errorCount, color: Colors.red)),
      ],
    );
  }

  Widget _buildEmpty() {
    return const Padding(
      padding: EdgeInsets.only(top: 48),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.devices_other, size: 64, color: Colors.grey),
            SizedBox(height: 12),
            Text('还没有设备', style: TextStyle(color: Colors.grey, fontSize: 16)),
            SizedBox(height: 4),
            Text('点击右下角“添加设备”开始调试', style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionCard(DeviceSession s) {
    final descriptor = ProtocolRegistry.get(s.type);
    // 取真实连接管理器，卡片状态与调试页、首页统计保持一致。
    final cm = SessionManager.instance.ensureManager(s);
    final state = cm.state;
    final connected = state == DeviceConnectionState.connected;
    final connecting = state == DeviceConnectionState.connecting;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Icon(descriptor.icon, size: 32, color: Colors.teal),
                const SizedBox(width: 12),
                Expanded(
                  // 点击卡片主体进入调试。
                  child: GestureDetector(
                    onTap: () => _openDebug(s),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text(descriptor.name,
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 12)),
                        const SizedBox(height: 4),
                        _StatusChip(status: state),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  icon: connecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          connected ? Icons.link_off : Icons.link,
                          color: connected ? Colors.red : Colors.green,
                        ),
                  tooltip: connected ? '断开' : '连接',
                  onPressed: () => _toggleConnection(s, cm),
                ),
              ],
            ),
            const Divider(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => _openDebug(s),
                  icon: const Icon(Icons.terminal, size: 18),
                  label: const Text('调试'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.edit_note),
                  tooltip: '重命名',
                  onPressed: () => _renameSession(s),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  tooltip: '删除',
                  onPressed: () => _confirmRemove(s),
                ),
                const Spacer(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

/// 状态小标签。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final DeviceConnectionState status;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      DeviceConnectionState.connected => ('在线', Colors.green),
      DeviceConnectionState.connecting => ('连接中', Colors.orange),
      DeviceConnectionState.error => ('异常', Colors.red),
      _ => ('离线', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}

/// 筛选条上的可点选标签。
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}
