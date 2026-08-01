import 'package:flutter/material.dart';
import 'package:modbus_client/modbus_client.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/modbus_models.dart';
import 'package:everlink/models/protocol_type.dart';
import 'package:everlink/protocols/modbus_tcp_protocol.dart';
import 'package:everlink/protocols/protocol_registry.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/ui/widgets/connection_panel.dart';

/// Modbus TCP 调试页：支持线圈 / 寄存器读写，以及多寄存器解析。
class ModbusPage extends StatefulWidget {
  const ModbusPage({super.key});

  @override
  State<ModbusPage> createState() => _ModbusPageState();
}

class _ModbusPageState extends State<ModbusPage> {
  late final ConnectionManager _manager;
  final _formKey = GlobalKey<FormState>();

  // 连接表单控制器
  final _hostCtl = TextEditingController(text: '127.0.0.1');
  final _portCtl = TextEditingController(text: '502');
  final _unitCtl = TextEditingController(text: '1');
  final _timeoutCtl = TextEditingController(text: '3');

  // 操作控制器
  ModbusFunction _function = ModbusFunction.readHoldingRegisters;
  final _addrCtl = TextEditingController(text: '0');
  final _qtyCtl = TextEditingController(text: '10');
  final _valueCtl = TextEditingController(text: '1');

  List<String> _results = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _manager = ConnectionManager(ProtocolRegistry.get(ProtocolType.modbusTcp));
    _syncConfigFromFields();
  }

  void _syncConfigFromFields() {
    _manager.updateConfig(
      ModbusConnectionConfig(
        host: _hostCtl.text.trim(),
        port: int.tryParse(_portCtl.text) ?? 502,
        unitId: int.tryParse(_unitCtl.text) ?? 1,
        timeout: Duration(seconds: int.tryParse(_timeoutCtl.text) ?? 3),
      ),
    );
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;
    _syncConfigFromFields();
    try {
      await _manager.connect();
    } catch (_) {
      // 错误已在面板展示
    }
  }

  Future<void> _execute() async {
    setState(() {
      _busy = true;
      _error = null;
      _results = [];
    });
    try {
      final proto = _manager.protocol as ModbusTcpProtocol;
      switch (_function) {
        case ModbusFunction.readCoils:
        case ModbusFunction.readDiscreteInputs:
          final bits = await proto.readBits(
            _function == ModbusFunction.readCoils
                ? ModbusElementType.coil
                : ModbusElementType.discreteInput,
            _addr,
            _qty,
          );
          _results = bits
              .asMap()
              .entries
              .map((e) => '地址 ${_addr + e.key}: ${e.value ? 1 : 0}')
              .toList();
        case ModbusFunction.readHoldingRegisters:
        case ModbusFunction.readInputRegisters:
          final regs = await proto.readRegisters(
            _function == ModbusFunction.readHoldingRegisters
                ? ModbusElementType.holdingRegister
                : ModbusElementType.inputRegister,
            _addr,
            _qty,
          );
          _results = regs
              .asMap()
              .entries
              .map((e) =>
                  '地址 ${_addr + e.key}: 十进制 ${e.value} | 十六进制 0x${e.value.toRadixString(16).padLeft(4, '0').toUpperCase()} | 二进制 ${e.value.toRadixString(2).padLeft(16, '0')}')
              .toList();
        case ModbusFunction.writeSingleCoil:
          await proto.writeSingleCoil(_addr, _value != 0);
          _results = ['已写线圈 地址 $_addr = ${_value != 0 ? 1 : 0}'];
        case ModbusFunction.writeSingleRegister:
          await proto.writeSingleRegister(_addr, _value);
          _results = ['已写保持寄存器 地址 $_addr = $_value'];
        case ModbusFunction.writeMultipleCoils:
          final bits = _valueCtl.text
              .split(RegExp(r'[\s,]+'))
              .where((s) => s.isNotEmpty)
              .map((s) => s.trim() == '1' || s.toLowerCase() == 'true')
              .toList();
          await proto.writeMultipleCoils(_addr, bits);
          _results = ['已写 ${bits.length} 个线圈，起始地址 $_addr'];
        case ModbusFunction.writeMultipleRegisters:
          final vals = _valueCtl.text
              .split(RegExp(r'[\s,]+'))
              .where((s) => s.isNotEmpty)
              .map((s) => int.parse(s))
              .toList();
          await proto.writeMultipleRegisters(_addr, vals);
          _results = ['已写 ${vals.length} 个保持寄存器，起始地址 $_addr'];
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      setState(() => _busy = false);
    }
  }

  int get _addr => int.tryParse(_addrCtl.text) ?? 0;
  int get _qty => int.tryParse(_qtyCtl.text) ?? 1;
  int get _value => int.tryParse(_valueCtl.text) ?? 0;

  bool get _isRead => _function.canRead;
  bool get _isWrite => _function.canWrite;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Modbus TCP')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ConnectionPanel(manager: _manager, onConnectPressed: _connect),
          const SizedBox(height: 12),
          _buildConnectionForm(),
          const SizedBox(height: 12),
          _buildOperationCard(),
          const SizedBox(height: 12),
          _buildResultCard(),
        ],
      ),
    );
  }

  Widget _buildConnectionForm() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('连接配置', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _hostCtl,
                      decoration: const InputDecoration(labelText: 'IP 地址'),
                      validator: (v) => v!.isEmpty ? '必填' : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _portCtl,
                      decoration: const InputDecoration(labelText: '端口'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _unitCtl,
                      decoration: const InputDecoration(labelText: '单元 ID'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _timeoutCtl,
                      decoration: const InputDecoration(labelText: '超时(秒)'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOperationCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('读写操作', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            DropdownButtonFormField<ModbusFunction>(
              value: _function,
              decoration: const InputDecoration(labelText: '功能'),
              items: ModbusFunction.values
                  .map((f) => DropdownMenuItem(value: f, child: Text(f.label)))
                  .toList(),
              onChanged: (v) => setState(() => _function = v!),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _addrCtl,
              decoration: const InputDecoration(labelText: '起始地址'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            if (_isRead)
              TextFormField(
                controller: _qtyCtl,
                decoration: const InputDecoration(labelText: '数量 (线圈≤2000 / 寄存器≤125)'),
                keyboardType: TextInputType.number,
              ),
            if (_isWrite)
              TextFormField(
                controller: _valueCtl,
                decoration: InputDecoration(
                  labelText: _function == ModbusFunction.writeMultipleRegisters ||
                          _function == ModbusFunction.writeMultipleCoils
                      ? '值（多个用英文逗号分隔，线圈用 0/1）'
                      : '值',
                ),
                keyboardType: TextInputType.text,
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy || _manager.state != DeviceConnectionState.connected
                    ? null
                    : _execute,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_isRead ? '读取' : '写入'),
              ),
            ),
            if (_manager.state != DeviceConnectionState.connected)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('请先连接设备', style: TextStyle(color: Colors.grey, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('结果', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (_results.isEmpty && _error == null)
              const Text('暂无数据', style: TextStyle(color: Colors.grey)),
            ..._results.map(
              (r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SelectableText(r, style: const TextStyle(fontFamily: 'monospace')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _manager.dispose();
    _hostCtl.dispose();
    _portCtl.dispose();
    _unitCtl.dispose();
    _timeoutCtl.dispose();
    _addrCtl.dispose();
    _qtyCtl.dispose();
    _valueCtl.dispose();
    super.dispose();
  }
}
