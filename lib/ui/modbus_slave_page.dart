import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:everlink/services/modbus_slave.dart';
import 'package:everlink/services/server_registry.dart';
import 'package:everlink/ui/widgets/byte_log_list.dart';

/// Modbus TCP 从站模拟页：在本机暴露一个 Modbus TCP 从站，供上位机 / 其它
/// 客户端联调。支持四类数据区（线圈 / 离散输入 / 输入寄存器 / 保持寄存器），
/// 可本地编辑数值以模拟设备状态；同时记录所有收发报文。
class ModbusSlavePage extends StatefulWidget {
  const ModbusSlavePage({super.key});

  @override
  State<ModbusSlavePage> createState() => _ModbusSlavePageState();
}

class _ModbusSlavePageState extends State<ModbusSlavePage> {
  final _portCtl = TextEditingController(text: '502');
  final _slaveCtl = TextEditingController(text: '1');
  final _coilCtl = TextEditingController(text: '200');
  final _discreteCtl = TextEditingController(text: '200');
  final _inputCtl = TextEditingController(text: '100');
  final _holdingCtl = TextEditingController(text: '100');

  final _log = <ByteLogEntry>[];
  final _clients = <Map<String, String>>[];

  late final ModbusTcpSlaveServer _server;
  StreamSubscription<ModbusSlaveEvent>? _sub;

  bool _listening = false;
  bool _busy = false;
  bool _showHex = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 常驻单例：退出页面不停止服务，可后台运行。
    _server = ServerRegistry.instance.modbusSlave;
    _sub = _server.events.listen(_onEvent);
    if (_server.isListening) {
      _listening = true;
      final p = _server.port;
      if (p != null) _portCtl.text = p.toString();
      _clients
        ..clear()
        ..addAll(_server.clientList);
    }
  }

  void _onEvent(ModbusSlaveEvent e) {
    if (!mounted) return;
    if (e is ModbusSlaveStateEvent) {
      setState(() {
        _listening = e.listening;
        _busy = false;
        if (e.listening) _error = null;
      });
    } else if (e is ModbusSlaveClientEvent) {
      setState(() {
        if (e.connected) {
          _clients.add({'id': e.clientId, 'address': e.address});
        } else {
          _clients.removeWhere((c) => c['id'] == e.clientId);
        }
      });
    } else if (e is ModbusSlaveDataEvent) {
      setState(() => _log.insert(
            0,
            ByteLogEntry(
              tx: e.direction,
              bytes: e.bytes,
              time: DateTime.now(),
              note: _noteFor(e.bytes, e.direction),
            ),
          ));
    } else if (e is ModbusSlaveRegistersEvent) {
      // 数值被客户端写入改变，刷新寄存器表显示。
      setState(() {});
    } else if (e is ModbusSlaveErrorEvent) {
      setState(() => _error = e.message);
    }
  }

  String? _noteFor(Uint8List frame, bool tx) {
    if (frame.length < 8) return null;
    final func = frame[7];
    final base = func & 0x7F;
    const labels = {
      0x01: '读线圈',
      0x02: '读离散输入',
      0x03: '读保持寄存器',
      0x04: '读输入寄存器',
      0x05: '写单线圈',
      0x06: '写单寄存器',
      0x0F: '写多线圈',
      0x10: '写多寄存器',
    };
    final name = labels[base] ?? '功能码0x${base.toRadixString(16)}';
    return '${tx ? '响应' : '请求'} · $name';
  }

  Future<void> _toggle() async {
    if (_listening) {
      _server.stop();
      setState(() => _log.clear());
      return;
    }
    final port = int.tryParse(_portCtl.text.trim());
    final slave = int.tryParse(_slaveCtl.text.trim()) ?? 1;
    final coils = int.tryParse(_coilCtl.text.trim()) ?? 200;
    final discrete = int.tryParse(_discreteCtl.text.trim()) ?? 200;
    final inputs = int.tryParse(_inputCtl.text.trim()) ?? 100;
    final holdings = int.tryParse(_holdingCtl.text.trim()) ?? 100;
    if (port == null || port <= 0 || port > 65535) {
      setState(() => _error = '请填写合法端口（1-65535）');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _server.configure(
      slaveId: slave,
      coilCount: coils,
      discreteCount: discrete,
      inputCount: inputs,
      holdingCount: holdings,
    );
    await _server.start(port);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _portCtl.dispose();
    _slaveCtl.dispose();
    _coilCtl.dispose();
    _discreteCtl.dispose();
    _inputCtl.dispose();
    _holdingCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _listening ? Colors.green : Colors.grey;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Modbus TCP 从站')),
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
                            hintText: '默认 502',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _slaveCtl,
                          enabled: !_listening,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '从站 ID',
                            hintText: '1',
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
                  const Text('数据区容量',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _coilCtl,
                          enabled: !_listening,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '线圈',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _discreteCtl,
                          enabled: !_listening,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '离散输入',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputCtl,
                          enabled: !_listening,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '输入寄存器',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _holdingCtl,
                          enabled: !_listening,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '保持寄存器',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
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
                              label: Text('${c['id']} · ${c['address']}'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_error != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
            const SizedBox(height: 12),
          ],
          DefaultTabController(
            length: 4,
            child: Card(
              child: Column(
                children: [
                  const TabBar(
                    isScrollable: true,
                    tabs: [
                      Tab(text: '保持寄存器'),
                      Tab(text: '输入寄存器'),
                      Tab(text: '线圈'),
                      Tab(text: '离散输入'),
                    ],
                  ),
                  const Divider(height: 1),
                  SizedBox(
                    height: 320,
                    child: TabBarView(
                      children: [
                        _buildIntTable(
                          _server.holdingRegisters,
                          '4',
                          (i, v) => _server.setHolding(i, v),
                        ),
                        _buildIntTable(
                          _server.inputRegisters,
                          '3',
                          (i, v) => _server.setInput(i, v),
                        ),
                        _buildBoolTable(
                          _server.coils,
                          '0',
                          (i, v) => _server.setCoil(i, v),
                        ),
                        _buildBoolTable(
                          _server.discreteInputs,
                          '1',
                          (i, v) => _server.setDiscrete(i, v),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('HEX')),
                  ButtonSegment(value: false, label: Text('ASCII')),
                ],
                selected: {_showHex},
                onSelectionChanged: (s) => setState(() => _showHex = s.first),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 8),
          ByteLogList(
            entries: _log,
            showHex: _showHex,
            onClear: () => setState(() => _log.clear()),
          ),
        ],
      ),
    );
  }

  Widget _buildIntTable(
    List<int> data,
    String prefix,
    void Function(int, int) onChanged,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: data.length,
      itemBuilder: (context, i) => _IntRegisterRow(
        label: '$prefix x${(i + 1).toString().padLeft(4, '0')}',
        value: data[i],
        onChanged: (v) => onChanged(i, v),
      ),
    );
  }

  Widget _buildBoolTable(
    List<bool> data,
    String prefix,
    void Function(int, bool) onChanged,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: data.length,
      itemBuilder: (context, i) => _BoolRegisterRow(
        label: '$prefix x${(i + 1).toString().padLeft(4, '0')}',
        value: data[i],
        onChanged: (v) => onChanged(i, v),
      ),
    );
  }
}

/// 16 位寄存器行：标题为 Modbus 地址，右侧数字输入框。
///
/// 仅在失焦 / 提交时回写服务，避免输入过程中因数值刷新被打断；外部（客户端
/// 写入）导致的刷新在失焦时同步显示，不影响正在编辑的字段。
class _IntRegisterRow extends StatefulWidget {
  const _IntRegisterRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_IntRegisterRow> createState() => _IntRegisterRowState();
}

class _IntRegisterRowState extends State<_IntRegisterRow> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ctl.text = widget.value.toString();
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    final v = int.tryParse(_ctl.text);
    if (v != null) widget.onChanged(v);
  }

  @override
  void didUpdateWidget(covariant _IntRegisterRow old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus) _ctl.text = widget.value.toString();
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(widget.label, style: const TextStyle(fontSize: 13)),
      trailing: SizedBox(
        width: 110,
        child: TextField(
          controller: _ctl,
          focusNode: _focus,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.end,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          ),
          onSubmitted: (_) => _commit(),
        ),
      ),
    );
  }
}

/// 布尔寄存器行（线圈 / 离散输入），用开关表示状态。
class _BoolRegisterRow extends StatefulWidget {
  const _BoolRegisterRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<_BoolRegisterRow> createState() => _BoolRegisterRowState();
}

class _BoolRegisterRowState extends State<_BoolRegisterRow> {
  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      title: Text(widget.label, style: const TextStyle(fontSize: 13)),
      value: widget.value,
      onChanged: widget.onChanged,
    );
  }
}
