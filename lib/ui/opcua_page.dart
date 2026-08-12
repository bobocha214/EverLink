import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/models/opcua_models.dart';
import 'package:everlink/protocols/opcua_protocol.dart';
import 'package:everlink/services/data_point.dart';
import 'package:everlink/ui/point_monitor_page.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/ui/widgets/connection_panel.dart';
import 'package:everlink/utils/app_routes.dart';

/// 监控轮询间隔（秒）。
const Duration _kMonitorInterval = Duration(seconds: 2);

/// OPC UA 调试页：端点配置、连接 / 断开、地址空间浏览、节点读写、实时监
/// 控。整体分为「浏览」与「监控」两个 Tab：
/// - 浏览：在地址空间里逐层下钻节点，变量节点可一键加入监控；
/// - 监控：展示已加入的变量节点，并以固定间隔轮询最新值。
class OpcUaPage extends StatefulWidget {
  const OpcUaPage({super.key, required this.session});

  final DeviceSession session;

  @override
  State<OpcUaPage> createState() => _OpcUaPageState();
}

class _OpcUaPageState extends State<OpcUaPage>
    with SingleTickerProviderStateMixin {
  late final ConnectionManager _manager;
  late final TabController _tab;

  final _endpointCtl = TextEditingController();

  /// 安全策略选择（UI 即时态，连接时映射为 URI 写入配置）。
  OpcUaSecurityPolicyKind _policyKind = OpcUaSecurityPolicyKind.none;

  /// 认证方式选择。
  OpcUaAuthMode _authMode = OpcUaAuthMode.anonymous;

  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _certCtl = TextEditingController();
  final _keyCtl = TextEditingController();
  final _keyPassCtl = TextEditingController();

  /// 原始报文记录（链路收发字节），由协议 trafficStream 推入。
  final List<OpcUaTrafficRecord> _traffic = [];
  StreamSubscription<OpcUaTrafficRecord>? _trafficSub;
  static const int _kMaxTraffic = 500;

  /// 树形浏览的根节点列表（自动从 OPC UA 标准入口扫描得到）。
  List<OpcUaBrowseNode> _tree = [];
  bool _treeLoading = false;
  String? _treeError;

  String? _error;

  /// 监控点位持久化键（按会话隔离）。
  late final String _storeKey;

  /// 监控项列表（会话级，随页面存在，并持久化到本地）。
  final List<OpcUaMonitorItem> _monitorItems = [];
  Timer? _pollTimer;
  bool _polling = false;

  // —— 点位序列缓存：仅用于跳转「点位监控页」时带上已有历史曲线 ——
  // 本页不再内嵌图表，因此累积数据时不触发重绘。
  final Map<String, List<DataPoint>> _series = <String, List<DataPoint>>{};
  StreamSubscription<DataPoint>? _dpSub;

  @override
  void initState() {
    super.initState();
    _manager = SessionManager.instance.ensureManager(widget.session);
    _storeKey = 'opcua_monitors_${widget.session.id}';
    final cfg = _manager.config;
    if (cfg is OpcUaConnectionConfig) {
      _endpointCtl.text = cfg.endpoint;
      _policyKind = OpcUaSecurityPolicyKind.fromUri(cfg.securityPolicy);
      _authMode = cfg.authMode;
      _userCtl.text = cfg.username ?? '';
      _passCtl.text = cfg.password ?? '';
      _certCtl.text = cfg.clientCert ?? '';
      _keyCtl.text = cfg.clientKey ?? '';
      _keyPassCtl.text = cfg.clientKeyPassword ?? '';
    }
    _manager.addListener(_onState);
    _tab = TabController(length: 3, vsync: this);
    // 订阅原始报文流，驱动“报文”视图。
    _trafficSub = _proto.trafficStream.listen((r) {
      if (!mounted) return;
      setState(() {
        _traffic.add(r);
        if (_traffic.length > _kMaxTraffic) {
          _traffic.removeRange(0, _traffic.length - _kMaxTraffic);
        }
      });
    });
    // 先载入已保存的监控点位，再按需启动扫描 / 轮询。
    _loadMonitors().then((_) {
      if (!mounted) return;
      if (_connected) {
        _ensurePolling();
        _scanTree();
      }
    });
    // 订阅本设备 OPC UA 数据点，缓存序列供「点位监控页」作为曲线初值。
    _dpSub = DataPointBus.instance.stream
        .where((p) => p.source == 'opcua')
        .listen(_onPoint);
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
    // 连接状态变化时，按需启停轮询与扫描。
    if (_manager.state == DeviceConnectionState.connected) {
      _ensurePolling();
      _scanTree();
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      // 断开后清空树与报文，避免展示陈旧节点/报文。
      setState(() {
        _tree = [];
        _traffic.clear();
      });
    }
  }

  OpcUaProtocol get _proto => _manager.protocol as OpcUaProtocol;

  bool get _connected => _manager.state == DeviceConnectionState.connected;

  @override
  void dispose() {
    _pollTimer?.cancel();
    _trafficSub?.cancel();
    _dpSub?.cancel();
    _tab.dispose();
    _manager.removeListener(_onState);
    _endpointCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    _certCtl.dispose();
    _keyCtl.dispose();
    _keyPassCtl.dispose();
    super.dispose();
  }

  Future<void> _toggleConnection() async {
    if (_manager.state == DeviceConnectionState.connected) {
      await _manager.disconnect();
      return;
    }
    if (_manager.state == DeviceConnectionState.connecting) return;
    setState(() => _error = null);
    final ep = _endpointCtl.text.trim();
    if (ep.isEmpty) {
      setState(() => _error = '请填写 OPC UA 端点（opc.tcp://host:port）');
      return;
    }
    try {
      await _manager.connect(OpcUaConnectionConfig(
        endpoint: ep,
        securityPolicy: _policyKind.uri,
        authMode: _authMode,
        username: _authMode == OpcUaAuthMode.userName ? _userCtl.text.trim() : null,
        password: _authMode == OpcUaAuthMode.userName ? _passCtl.text : null,
        clientCert: _authMode == OpcUaAuthMode.certificate ? _certCtl.text.trim() : null,
        clientKey: _authMode == OpcUaAuthMode.certificate ? _keyCtl.text.trim() : null,
        clientKeyPassword:
            _authMode == OpcUaAuthMode.certificate ? _keyPassCtl.text : null,
      ));
      _log(HistoryOp.connect, _connected,
          '连接 OPC UA：$ep');
      if (!_connected && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败：${_manager.lastError ?? '未知错误'}')),
        );
      } else {
        // 连接成功后，若有监控项立即开始轮询。
        _ensurePolling();
      }
    } catch (e) {
      _log(HistoryOp.connect, false, '连接 OPC UA：$ep', error: e.toString());
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('连接失败：$e')));
      }
    }
  }

  /// 自动扫描地址空间：从 OPC UA 标准入口（Objects / Types / Views）开始构建
  /// 树的根节点，并自动展开 Objects 以立即呈现内容。用户无需知道起始节点 ID。
  Future<void> _scanTree() async {
    if (!_connected) {
      if (!mounted) return;
      setState(() => _treeError = '请先连接 OPC UA 服务');
      return;
    }
    if (!mounted) return;
    setState(() {
      _treeLoading = true;
      _treeError = null;
    });
    try {
      // OPC UA 标准地址空间入口（Well-known NodeIds）。
      const roots = [
        ('ns=0;i=85', 'Objects'),
        ('ns=0;i=86', 'Types'),
        ('ns=0;i=87', 'Views'),
      ];
      _tree = roots
          .map((r) => OpcUaBrowseNode(OpcUaNodeEntry(
                nodeId: r.$1,
                browseName: r.$2,
                displayName: r.$2,
                nodeClass: 1, // Object（文件夹）
              )))
          .toList();
      // 自动展开 Objects 一层，让用户立刻看到内容。
      await _toggleExpand(_tree.first);
    } catch (e) {
      if (!mounted) return;
      setState(() => _treeError = '扫描地址空间失败：$e');
    } finally {
      if (mounted) setState(() => _treeLoading = false);
    }
  }

  /// 展开 / 收起一个树节点：首次展开时懒加载其子节点。
  Future<void> _toggleExpand(OpcUaBrowseNode node) async {
    // 已加载过：仅切换展开状态。
    if (node.loaded || node.loading) {
      if (!mounted) return;
      setState(() => node.expanded = !node.expanded);
      return;
    }
    if (!mounted) return;
    setState(() => node.loading = true);
    try {
      final entries = await _proto.browse(node.entry.nodeId);
      if (!mounted) return;
      node.children
        ..clear()
        ..addAll(entries.map((e) => OpcUaBrowseNode(e)));
      node.loaded = true;
      node.expanded = true;
      node.loadError = null;
    } catch (e) {
      if (!mounted) return;
      node.loadError = e.toString();
    } finally {
      if (mounted) setState(() => node.loading = false);
    }
  }

  // ---------------- 监控 ----------------

  /// 从一个本地存储键载入已保存的监控点位（按会话隔离）。
  Future<void> _loadMonitors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storeKey);
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final items = list.map(OpcUaMonitorItem.fromJson).toList();
      if (!mounted) return;
      setState(() => _monitorItems.addAll(items));
    } catch (_) {
      // 持久化读取失败不影响内存中的监控列表。
    }
  }

  /// 把当前监控点位写入本地存储。
  Future<void> _persistMonitors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode(_monitorItems.map((e) => e.toJson()).toList());
      await prefs.setString(_storeKey, raw);
    } catch (_) {
      // 持久化失败不影响内存中的监控列表。
    }
  }

  /// 把一个变量节点加入监控列表（去重），并启动轮询。
  /// 不会跳转页面，方便从树形浏览中连续添加多个点位。无提示弹窗。
  void _addToMonitor(OpcUaNodeEntry e) {
    final item = OpcUaMonitorItem(
      nodeId: e.nodeId,
      displayName: e.displayName.isNotEmpty ? e.displayName : e.browseName,
    );
    if (_monitorItems.contains(item)) return;
    setState(() => _monitorItems.add(item));
    _persistMonitors();
    _ensurePolling();
    // 立即读取一次，避免列表里先显示“读取中”。
    _readMonitorItem(item);
  }

  void _removeMonitor(OpcUaMonitorItem item) {
    setState(() => _monitorItems.remove(item));
    _persistMonitors();
    if (_monitorItems.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  /// 清空全部监控点位。
  void _clearMonitors() {
    setState(() => _monitorItems.clear());
    _persistMonitors();
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 按需启停轮询定时器：仅当已连接且有监控项时才轮询。
  void _ensurePolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_connected || _monitorItems.isEmpty) return;
    _pollTimer = Timer.periodic(_kMonitorInterval, (_) => _pollMonitors());
  }

  /// 轮询所有监控项（并行读取，单点失败不影响其它项）。
  ///
  /// 用 [_polling] 防止上一次轮询尚未结束时定时器再次触发，避免请求堆积。
  Future<void> _pollMonitors() async {
    if (!_connected || _polling) return;
    _polling = true;
    try {
      await Future.wait(_monitorItems.map((item) => _readMonitorItem(item)));
    } finally {
      _polling = false;
    }
  }

  Future<void> _readMonitorItem(OpcUaMonitorItem item) async {
    if (!_connected) return;
    try {
      final r = await _proto.read(item.nodeId);
      if (mounted) {
        setState(() {
          item.latest = r;
          item.updatedAt = DateTime.now();
        });
      }
    } catch (e) {
      // 单次读取失败不阻断整体监控，保留上一次的值。
      if (mounted) {
        setState(() => item.updatedAt = DateTime.now());
      }
    }
  }

  /// 写入后若监控列表包含该节点，立即刷新其显示。
  void _refreshMonitorItem(String nodeId) {
    final idx = _monitorItems.indexWhere((i) => i.nodeId == nodeId);
    if (idx >= 0) _readMonitorItem(_monitorItems[idx]);
  }

  /// 监控卡片内的“下发”：向节点写入值，并立即刷新其显示。
  Future<void> _writeMonitorItem(String nodeId, OpcUaWriteType type, String value) async {
    await _proto.write(nodeId, type, value);
    _log(HistoryOp.write, true, '下发 $nodeId = $value');
    _refreshMonitorItem(nodeId);
  }

  bool _isMonitored(String nodeId) =>
      _monitorItems.any((i) => i.nodeId == nodeId);

  void _log(HistoryOp op, bool success, String summary,
      {String? detail, String? error}) {
    HistoryService.instance.add(
      HistoryRecord(
        time: DateTime.now(),
        type: widget.session.type,
        deviceName: widget.session.name,
        op: op,
        success: success,
        summary: summary,
        detail: detail,
        error: error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.name),
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(icon: Icon(Icons.account_tree), text: '浏览'),
            Tab(icon: Icon(Icons.monitor_heart), text: '监控'),
            Tab(icon: Icon(Icons.terminal), text: '报文'),
          ],
        ),
        actions: [
          IconButton(
            icon: _manager.state == DeviceConnectionState.connecting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_connected ? Icons.link_off : Icons.link),
            tooltip: _connected ? '断开' : '连接',
            onPressed: _toggleConnection,
          ),
        ],
      ),
      body: Column(
        children: [
          ConnectionPanel(manager: _manager, onConnectPressed: _toggleConnection),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _buildBrowseTab(),
                _buildMonitorTab(),
                _buildTrafficTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrowseTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildEndpointCard(),
        const SizedBox(height: 12),
        _buildSecurityCard(),
        const SizedBox(height: 12),
        _buildBrowseCard(),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_error!, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ],
    );
  }

  /// 安全设置卡片：安全策略 + 认证方式 + 凭据输入。
  ///
  /// 由于底层库当前仅完整支持 None + 匿名，选中受限能力时显示警告横幅，
  /// 并在连接时被协议层以明确错误拒绝（能力降级，与设计文档边界一致）。
  Widget _buildSecurityCard() {
    final limited = !_policyKind.supported || _authMode != OpcUaAuthMode.anonymous;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('安全设置',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            DropdownButtonFormField<OpcUaSecurityPolicyKind>(
              isDense: true,
              value: _policyKind,
              decoration: const InputDecoration(
                labelText: '安全策略',
                isDense: true,
              ),
              items: [
                for (final p in OpcUaSecurityPolicyKind.values)
                  DropdownMenuItem(
                    value: p,
                    child: Text(p.label,
                        style: TextStyle(
                            fontSize: 13,
                            color: p.supported ? null : Colors.orange)),
                  ),
              ],
              onChanged: (v) => setState(() => _policyKind = v ?? _policyKind),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<OpcUaAuthMode>(
              isDense: true,
              value: _authMode,
              decoration: const InputDecoration(
                labelText: '认证方式',
                isDense: true,
              ),
              items: [
                for (final a in OpcUaAuthMode.values)
                  DropdownMenuItem(
                    value: a,
                    child: Text(a.label, style: const TextStyle(fontSize: 13)),
                  ),
              ],
              onChanged: (v) => setState(() => _authMode = v ?? _authMode),
            ),
            if (_authMode == OpcUaAuthMode.userName) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _userCtl,
                decoration: const InputDecoration(
                  labelText: '用户名',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passCtl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码',
                  isDense: true,
                ),
              ),
            ],
            if (_authMode == OpcUaAuthMode.certificate) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _certCtl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '客户端证书 (PEM)',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keyCtl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '客户端私钥 (PEM)',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keyPassCtl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '私钥口令（可选）',
                  isDense: true,
                ),
              ),
            ],
            if (limited) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: const Text(
                  '当前底层库 mcp_io_opcua 0.2.1 仅完整支持 None 安全策略 + 匿名'
                  '登录；签名策略与用户名/证书登录已记录为连接意图，连接时会被'
                  '明确拒绝（需底层库升级）。建议使用 None + 匿名。',
                  style: TextStyle(color: Colors.orange, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEndpointCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('端点配置',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _endpointCtl,
              decoration: const InputDecoration(
                labelText: 'OPC UA 端点',
                hintText: 'opc.tcp://host:4840',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowseCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('地址空间（树形浏览）',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_treeLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton.icon(
                    onPressed: _connected ? _scanTree : null,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重新扫描'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (!_connected)
              const Text('请先连接 OPC UA 服务，连接后将自动扫描地址空间',
                  style: TextStyle(color: Colors.grey))
            else if (_treeError != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_treeError!, style: const TextStyle(color: Colors.red)),
              )
            else if (_tree.isEmpty && !_treeLoading)
              const Text('暂无节点', style: TextStyle(color: Colors.grey))
            else
              ..._tree.map((n) => _buildTreeNode(n, 0)),
          ],
        ),
      ),
    );
  }

  /// 递归渲染一个树节点（含其子节点），[depth] 用于缩进。
  Widget _buildTreeNode(OpcUaBrowseNode node, int depth) {
    final e = node.entry;
    final isFolder = !e.isVariable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            if (isFolder) {
              _toggleExpand(node);
            }
            // 变量节点通过右侧 ＋ 按钮加入监控，点击整行不再触发读写。
          },
          child: Padding(
            padding:
                EdgeInsets.only(left: 8.0 + depth * 16, top: 2, bottom: 2),
            child: Row(
              children: [
                if (isFolder)
                  SizedBox(
                    width: 20,
                    child: node.loading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            node.expanded
                                ? Icons.expand_more
                                : Icons.chevron_right,
                            size: 18,
                          ),
                  )
                else
                  const SizedBox(width: 20),
                Icon(
                  isFolder ? Icons.folder : Icons.data_object,
                  size: 18,
                  color: isFolder ? Colors.amber : Colors.teal,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e.displayName.isNotEmpty ? e.displayName : e.browseName,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                if (isFolder)
                  const Icon(Icons.chevron_right, size: 16, color: Colors.grey)
                else
                  IconButton(
                    icon: Icon(
                      _isMonitored(e.nodeId)
                          ? Icons.check_circle
                          : Icons.add_circle_outline,
                      size: 20,
                      color:
                          _isMonitored(e.nodeId) ? Colors.green : Colors.teal,
                    ),
                    tooltip: _isMonitored(e.nodeId) ? '已在监控中' : '加入监控',
                    onPressed: () => _addToMonitor(e),
                  ),
              ],
            ),
          ),
        ),
        if (node.loadError != null)
          Padding(
            padding: EdgeInsets.only(left: 8.0 + depth * 16 + 28),
            child: Text('加载失败：${node.loadError}',
                style: const TextStyle(color: Colors.red, fontSize: 11)),
          ),
        if (node.expanded)
          if (node.children.isEmpty)
            Padding(
              padding: EdgeInsets.only(
                  left: 8.0 + depth * 16 + 28, top: 2, bottom: 2),
              child: const Text('（无子节点）',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            )
          else
            ...node.children.map((c) => _buildTreeNode(c, depth + 1)),
      ],
    );
  }

  Widget _buildMonitorTab() {
    if (_monitorItems.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.monitor_heart_outlined,
                size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            const Text('还没有监控节点',
                style: TextStyle(color: Colors.grey, fontSize: 15)),
            const SizedBox(height: 6),
            const Text('在“浏览”页点击变量节点的 ＋ 按钮即可加入',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text('监控列表（${_monitorItems.length}）',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
            const Spacer(),
            if (_monitorItems.isNotEmpty)
              TextButton.icon(
                onPressed: _clearMonitors,
                icon: const Icon(Icons.delete_sweep, size: 16),
                label: const Text('清空'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red.shade600,
                ),
              ),
            if (_pollTimer != null)
              Row(
                children: [
                  Icon(Icons.autorenew, size: 14, color: Colors.green.shade600),
                  const SizedBox(width: 4),
                  Text('实时轮询中',
                      style: TextStyle(
                          fontSize: 12, color: Colors.green.shade600)),
                ],
              ),
          ],
        ),
        const SizedBox(height: 10),
        ..._monitorItems.map(_buildMonitorItem),
      ],
    );
  }

  /// 原始报文视图：列出链路收发的字节块（方向 + 时间 + 长度 + hex dump）。
  ///
  /// 这不是 pcap 抓包，仅记录本应用经 TCP 实际收发的字节流；None 策略下为
  /// 明文 OPC UA 二进制，加密策略下为链路密文。连接断开时清空，避免展示
  /// 陈旧报文。
  Widget _buildTrafficTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '原始报文（${_traffic.length}）',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              if (_traffic.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() => _traffic.clear()),
                  icon: const Icon(Icons.delete_sweep, size: 16),
                  label: const Text('清空'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red.shade600,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _traffic.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.terminal_outlined,
                          size: 56, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      const Text('还没有报文', style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 6),
                      const Text('连接后这里会显示收发原始字节',
                          style: TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _traffic.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _buildTrafficRow(_traffic[i]),
                ),
        ),
      ],
    );
  }

  Widget _buildTrafficRow(OpcUaTrafficRecord r) {
    final tx = r.direction == OpcUaTrafficDirection.tx;
    final color = tx ? Colors.blue : Colors.green;
    final label = tx ? 'TX →' : 'RX ←';
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: color.withValues(alpha: 0.12),
            child: Row(
              children: [
                Icon(Icons.circle, size: 8, color: color),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        fontFamily: 'monospace')),
                const Spacer(),
                Text('${r.length} B',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(width: 8),
                Text(_fmtTime(r.time),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: SelectableText(
              _hexDump(r.bytes),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 把字节序列格式化为带偏移量的 hex dump 文本（每行 16 字节）。
  String _hexDump(Uint8List bytes, {int bytesPerLine = 16}) {
    final buf = StringBuffer();
    for (var i = 0; i < bytes.length; i += bytesPerLine) {
      final end = (i + bytesPerLine < bytes.length)
          ? i + bytesPerLine
          : bytes.length;
      final hex = <String>[];
      final ascii = <String>[];
      for (var j = i; j < end; j++) {
        hex.add(bytes[j].toRadixString(16).padLeft(2, '0'));
        final c = bytes[j];
        ascii.add(c >= 32 && c < 127 ? String.fromCharCode(c) : '.');
      }
      final offset = i.toRadixString(16).padLeft(8, '0');
      buf.writeln('$offset  ${hex.join(' ')}  ${ascii.join()}');
    }
    return buf.toString();
  }

  Widget _buildMonitorItem(OpcUaMonitorItem item) {
    final r = item.latest;
    final good = r?.good ?? true;
    final color = good ? Colors.green : Colors.red;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部状态条：用颜色区分在线/异常
          Container(
            height: 4,
            color: color,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      // 点击点位 → 打开实时监控页（趋势 / 仪表盘 / 统计）
                      child: InkWell(
                        onTap: () => _openMonitor(item),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              const Icon(Icons.show_chart,
                                  size: 18, color: Colors.teal),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(item.displayName,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15)),
                                    const SizedBox(height: 2),
                                    Text(item.nodeId,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                            fontFamily: 'monospace')),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: '移除监控',
                      color: Colors.grey,
                      onPressed: () => _removeMonitor(item),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 值 + 状态
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(Icons.circle, size: 9, color: color),
                    const SizedBox(width: 6),
                    Text(
                      good ? '正常' : '异常 (0x${r?.statusCode.toRadixString(16) ?? '??'})',
                      style: TextStyle(color: color, fontSize: 12),
                    ),
                    const Spacer(),
                    if (item.updatedAt != null)
                      Text('更新于 ${_fmtTime(item.updatedAt!)}',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 6),
                if (r == null)
                  const Text('读取中…',
                      style: TextStyle(color: Colors.grey, fontSize: 18))
                else ...[
                  Text('${r.value}',
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 22,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('类型：${r.typeName}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  if (r.sourceTimestamp != null)
                    Text('时间戳：${r.sourceTimestamp}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
                const Divider(height: 20),
                // 可视化已改为点击点位跳转独立监控页，此处仅保留入口提示。
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _openMonitor(item),
                    icon: const Icon(Icons.timeline, size: 18),
                    label: const Text('查看实时曲线'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // 下发（写值）
                _MonitorWriteRow(
                  key: ValueKey(item.nodeId),
                  nodeId: item.nodeId,
                  onWrite: _writeMonitorItem,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  void _onPoint(DataPoint p) {
    final list = _series.putIfAbsent(p.tag, () => <DataPoint>[]);
    list.add(p);
    if (list.length > 300) list.removeAt(0);
  }

  /// 打开单点位监控页：实时趋势 + 仪表盘 + 统计。
  void _openMonitor(OpcUaMonitorItem item) {
    AppRoutes.push(context, PointMonitorPage(
          source: 'opcua',
          tag: item.nodeId,
          label: item.displayName,
          initial:
              List<DataPoint>.from(_series[item.nodeId] ?? const <DataPoint>[]),
        ));
  }
}

/// 监控卡片内的“下发”行：自带输入与类型选择，写入后由父级回调刷新显示。
///
/// 作为独立 StatefulWidget，父级每 2 秒轮询造成的重建不会清空本行已输入的内容。
class _MonitorWriteRow extends StatefulWidget {
  const _MonitorWriteRow({
    super.key,
    required this.nodeId,
    required this.onWrite,
  });

  final String nodeId;
  final Future<void> Function(String nodeId, OpcUaWriteType type, String value)
      onWrite;

  @override
  State<_MonitorWriteRow> createState() => _MonitorWriteRowState();
}

class _MonitorWriteRowState extends State<_MonitorWriteRow> {
  final _ctl = TextEditingController();
  OpcUaWriteType _type = OpcUaWriteType.int32;
  bool _busy = false;
  String? _msg;
  bool _ok = true;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final v = _ctl.text.trim();
    if (v.isEmpty) {
      setState(() {
        _msg = '请输入要下发的值';
        _ok = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      await widget.onWrite(widget.nodeId, _type, v);
      setState(() {
        _ok = true;
        _msg = '下发成功';
      });
    } catch (e) {
      setState(() {
        _ok = false;
        _msg = '下发失败：$e';
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctl,
                decoration: const InputDecoration(
                  labelText: '下发值',
                  hintText: '要写入的数据',
                  isDense: true,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 96,
              child: DropdownButtonFormField<OpcUaWriteType>(
                initialValue: _type,
                isDense: true,
                decoration: const InputDecoration(
                  labelText: '类型',
                  isDense: true,
                ),
                items: [
                  for (final t in OpcUaWriteType.values)
                    DropdownMenuItem(value: t, child: Text(t.label, style: const TextStyle(fontSize: 12))),
                ],
                onChanged: (v) => setState(() => _type = v ?? _type),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('下发'),
            ),
          ],
        ),
        if (_msg != null) ...[
          const SizedBox(height: 6),
          Text(
            _msg!,
            style: TextStyle(
              fontSize: 12,
              color: _ok ? Colors.green : Colors.red,
            ),
          ),
        ],
      ],
    );
  }
}
