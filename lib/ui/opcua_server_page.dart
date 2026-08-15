import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mcp_io_opcua/mcp_io_opcua.dart';

import 'package:everlink/services/opcua_server.dart';
import 'package:everlink/services/server_registry.dart';
import 'package:everlink/services/opcua_nodes_store.dart';
import 'package:everlink/services/tcp_server.dart';
import 'package:everlink/ui/widgets/byte_log_list.dart';

/// OPC UA 服务端模拟页：自定义节点与数量，支持 Read/Write/Browse（None 安全策略）。
class OpcUaServerPage extends StatefulWidget {
  const OpcUaServerPage({super.key});

  @override
  State<OpcUaServerPage> createState() => _OpcUaServerPageState();
}

class _OpcUaServerPageState extends State<OpcUaServerPage> {
  final _portCtl = TextEditingController(text: '4840');
  final _log = <ByteLogEntry>[];
  final _clients = <Map<String, String>>[];
  final _nodes = <OpcUaNode>[];

  late final OpcUaServer _server;
  StreamSubscription<OpcUaServerEvent>? _sub;

  bool _listening = false;
  bool _busy = false;
  String _ip = '0.0.0.0'; // 监听网卡；0.0.0.0 = 全部接口
  List<String> _ipOptions = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    // 使用常驻单例：退出页面不会停止服务，可后台运行。
    _server = ServerRegistry.instance.opcua;
    // 先填默认示例，确保服务端立即可用；随后异步加载已保存的自定义节点覆盖。
    _nodes.addAll(defaultOpcUaNodes());
    _server.addressSpace = OpcUaAddressSpace(nodes: _nodes);
    _sub = _server.events.listen(_onEvent);
    _loadNodes();
    TcpServer.localAddresses().then((list) {
      if (!mounted) return;
      setState(() {
        _ipOptions = list;
        if (_listening && _ip != '0.0.0.0' && !list.contains(_ip)) {
          _ipOptions = [...list, _ip];
        }
      });
    });
    // 服务可能在本页之前已在后台运行，恢复运行态与端口/IP/客户端。
    if (_server.listening) {
      _listening = true;
      final p = _server.port;
      if (p != null) _portCtl.text = p.toString();
      _ip = _server.bindAddress;
      _clients
        ..clear()
        ..addAll(_server.clientList);
    }
  }

  /// 恢复上次保存的自定义节点；无记录则保留默认示例。
  Future<void> _loadNodes() async {
    final saved = await OpcUaNodesStore.load();
    if (saved != null && saved.isNotEmpty && mounted) {
      // 复用同一 List 引用，保证 OpcUaServer.addressSpace 同步更新。
      setState(() {
        _nodes.clear();
        _nodes.addAll(saved);
      });
    }
  }

  /// 把当前节点列表持久化到本地（新增/编辑/删除后调用）。
  Future<void> _persistNodes() => OpcUaNodesStore.save(_nodes);

  void _onEvent(OpcUaServerEvent e) {
    if (!mounted) return;
    if (e is OpcUaServerStateEvent) {
      setState(() {
        _listening = e.listening;
        _busy = false;
        if (e.listening) _error = null;
      });
    } else if (e is OpcUaServerClientEvent) {
      setState(() {
        if (e.connected) {
          _clients.add({'id': e.clientId, 'address': e.address});
        } else {
          _clients.removeWhere((c) => c['id'] == e.clientId);
        }
      });
    } else if (e is OpcUaServerDataEvent) {
      setState(() => _log.insert(
            0,
            ByteLogEntry(
              tx: e.tx,
              bytes: e.bytes,
              time: DateTime.now(),
              note: e.note,
            ),
          ));
    } else if (e is OpcUaServerErrorEvent) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _toggle() async {
    if (_listening) {
      _server.stop();
      setState(() => _log.clear());
      return;
    }
    final port = int.tryParse(_portCtl.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      setState(() => _error = '请填写合法端口（1-65535）');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _server.start(port, bindAddress: _ip == '0.0.0.0' ? null : _ip);
    } catch (ex) {
      setState(() {
        _busy = false;
        _error = '启动失败：$ex';
      });
    }
  }

  void _addNode() {
    setState(() => _nodes.add(OpcUaNode(
          namespaceIndex: 2,
          identifier: (_nodes.length + 1).toString(),
          name: 'Node${_nodes.length + 1}',
          builtInType: OpcUaBuiltInType.double_,
          valueText: '0',
        )));
    _persistNodes();
  }

  void _removeNode(int index) {
    setState(() => _nodes.removeAt(index));
    _persistNodes();
  }

  Future<void> _editNode(int index) async {
    final node = _nodes[index];
    final nsCtl = TextEditingController(text: node.namespaceIndex.toString());
    final idCtl = TextEditingController(text: node.identifier);
    final nameCtl = TextEditingController(text: node.name);
    final valCtl = TextEditingController(text: node.valueText);
    OpcUaBuiltInType type = node.builtInType;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('编辑节点'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nsCtl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '命名空间索引',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: idCtl,
                  decoration: const InputDecoration(
                    labelText: '节点标识（数字或字符串）',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(
                    labelText: '显示名 / BrowseName',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButton<OpcUaBuiltInType>(
                  value: type,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.boolean,
                        child: Text('Boolean')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.sByte, child: Text('SByte')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.byte, child: Text('Byte')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.int16, child: Text('Int16')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.uInt16, child: Text('UInt16')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.int32, child: Text('Int32')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.uInt32, child: Text('UInt32')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.int64, child: Text('Int64')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.uInt64, child: Text('UInt64')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.float, child: Text('Float')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.double_,
                        child: Text('Double')),
                    DropdownMenuItem(
                        value: OpcUaBuiltInType.string, child: Text('String')),
                  ],
                  onChanged: (v) => setSt(() => type = v ?? type),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: valCtl,
                  decoration: const InputDecoration(
                    labelText: '值',
                    isDense: true,
                    hintText: 'Boolean 用 true/false',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      final ns = int.tryParse(nsCtl.text.trim());
      if (ns == null) {
        setState(() => _error = '命名空间索引需为整数');
        return;
      }
      setState(() {
        node.namespaceIndex = ns;
        node.identifier = idCtl.text.trim();
        node.name = nameCtl.text.trim();
        node.builtInType = type;
        node.valueText = valCtl.text;
      });
      _persistNodes();
    }
  }

  @override
  void dispose() {
    // 仅取消订阅，不销毁服务：保持后台运行，下次进入可恢复。
    _sub?.cancel();
    _portCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _listening ? Colors.green : Colors.grey;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('OPC UA 服务端')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _portCtl,
                          enabled: !_listening,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '监听端口',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Row(
                        children: [
                          Icon(Icons.circle, size: 10, color: color),
                          const SizedBox(width: 6),
                          Text(_listening ? '监听中' : '已停止',
                              style: TextStyle(color: color, fontSize: 13)),
                        ],
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _busy ? null : _toggle,
                        icon: _busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Icon(_listening ? Icons.stop : Icons.play_arrow),
                        label: Text(_listening ? '停止' : '启动'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text('监听 IP', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _ip,
                          isDense: true,
                          disabledHint: const Text('监听中…'),
                          items: [
                            const DropdownMenuItem(
                                value: '0.0.0.0',
                                child: Text('全部接口 (0.0.0.0)')),
                            for (final a in _ipOptions)
                              DropdownMenuItem(value: a, child: Text(a)),
                          ],
                          onChanged: _listening
                              ? null
                              : (v) => setState(() => _ip = v ?? '0.0.0.0'),
                        ),
                      ),
                    ],
                  ),
                  if (_listening)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _ip == '0.0.0.0'
                            ? '已监听全部接口，客户端可连接本机任一 IP'
                            : '连接地址：$_ip:${_portCtl.text.trim()}',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Text('已连接客户端：${_clients.length}',
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                  if (_clients.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in _clients)
                            Chip(
                              avatar: const Icon(Icons.computer, size: 16),
                              label: Text(c['address']!),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  Text(
                      '安全策略：None（匿名）。地址空间：${_nodes.length} 个自定义变量节点（挂在自定义 Demo 根下）。',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('节点（${_nodes.length}）',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _addNode,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新增节点'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_nodes.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: Text('暂无节点，点击右上角新增')),
                    )
                  else
                    for (var i = 0; i < _nodes.length; i++)
                      _nodeRow(i, scheme),
                ],
              ),
            ),
          ),
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
          const SizedBox(height: 12),
          ByteLogList(
            entries: _log,
            showHex: true,
            onClear: () => setState(() => _log.clear()),
            emptyHint: '启动服务后，OPC UA 握手与 Read/Write/Browse 报文会显示在这里',
          ),
        ],
      ),
    );
  }

  Widget _nodeRow(int i, ColorScheme scheme) {
    final n = _nodes[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                  'ns=${n.namespaceIndex};'
                  '${n.identifierIsString ? "s" : "i"}=${n.identifier} · '
                  '${_typeLabel(n.builtInType)} = ${n.valueText}',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: '编辑',
            onPressed: () => _editNode(i),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: '删除',
            onPressed: () => _removeNode(i),
          ),
        ],
      ),
    );
  }

  String _typeLabel(OpcUaBuiltInType t) {
    switch (t) {
      case OpcUaBuiltInType.boolean:
        return 'Boolean';
      case OpcUaBuiltInType.sByte:
        return 'SByte';
      case OpcUaBuiltInType.byte:
        return 'Byte';
      case OpcUaBuiltInType.int16:
        return 'Int16';
      case OpcUaBuiltInType.uInt16:
        return 'UInt16';
      case OpcUaBuiltInType.int32:
        return 'Int32';
      case OpcUaBuiltInType.uInt32:
        return 'UInt32';
      case OpcUaBuiltInType.int64:
        return 'Int64';
      case OpcUaBuiltInType.uInt64:
        return 'UInt64';
      case OpcUaBuiltInType.float:
        return 'Float';
      case OpcUaBuiltInType.double_:
        return 'Double';
      case OpcUaBuiltInType.string:
        return 'String';
      default:
        return t.name;
    }
  }
}
