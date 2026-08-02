import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:modbus_client/modbus_client.dart';

import 'package:everlink/models/connection_config.dart';
import 'package:everlink/models/device_session.dart';
import 'package:everlink/models/modbus_models.dart';
import 'package:everlink/protocols/modbus_tcp_protocol.dart';
import 'package:everlink/services/connection_manager.dart';
import 'package:everlink/services/history_service.dart';
import 'package:everlink/services/session_manager.dart';
import 'package:everlink/ui/widgets/connection_panel.dart';

/// Modbus TCP 调试页：支持线圈 / 寄存器读写，并把每次操作沉淀到历史记录。
///
/// 寄存器读取可选择数据类型（16 位 / 32 位 / 浮点）与字节序；读取结果以可
/// 编辑行呈现，支持单点内联写回。线圈读取后点击卡片即可切换并写回。
class ModbusPage extends StatefulWidget {
  const ModbusPage({super.key, required this.session});

  final DeviceSession session;

  @override
  State<ModbusPage> createState() => _ModbusPageState();
}

class _ModbusPageState extends State<ModbusPage> {
  late final ConnectionManager _manager;
  final _formKey = GlobalKey<FormState>();

  final _hostCtl = TextEditingController();
  final _portCtl = TextEditingController();
  final _unitCtl = TextEditingController();
  final _timeoutCtl = TextEditingController();

  ModbusFunction _function = ModbusFunction.readHoldingRegisters;
  final _addrCtl = TextEditingController(text: '0');
  final _qtyCtl = TextEditingController(text: '10');
  final _valueCtl = TextEditingController(text: '1');

  /// 寄存器数据类型与字节序（仅寄存器读取使用）。
  ModbusDataType _dataType = ModbusDataType.uint16;
  ByteOrder _byteOrder = ByteOrder.abcd;

  /// 最近一次读取的结构化结果。
  ModbusFunction? _lastReadFunction;
  ModbusDataType _lastDataType = ModbusDataType.uint16;
  ByteOrder _lastByteOrder = ByteOrder.abcd;
  int _lastReadAddr = 0;
  List<num>? _regValues;
  List<bool>? _bitValues;
  DateTime? _lastReadTime;

  /// 每个寄存器行的可编辑值控制器（按行索引）。
  final List<TextEditingController> _regCtls = [];

  /// 与 [_regCtls] 对应的焦点节点，用于判断某行是否正在被用户编辑。
  final List<FocusNode> _regFocus = [];

  bool _busy = false;
  String? _error;
  String? _feedback;

  bool _autoRefresh = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    final c = widget.session.config as ModbusConnectionConfig;
    _hostCtl.text = c.host;
    _portCtl.text = '${c.port}';
    _unitCtl.text = '${c.unitId}';
    _timeoutCtl.text = '${c.timeout.inSeconds}';
    _manager = SessionManager.instance.ensureManager(widget.session);
    _manager.addListener(_onManagerChanged);
  }

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  /// 是否正在读取保持寄存器（可写回）。输入寄存器只读。
  bool get _lastIsHoldingRead =>
      _lastReadFunction == ModbusFunction.readHoldingRegisters;

  void _toggleAutoRefresh(bool value) {
    setState(() => _autoRefresh = value);
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (value) {
      _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_manager.state == DeviceConnectionState.connected &&
            !_busy &&
            _isRead) {
          _execute(log: false);
        }
      });
    }
  }

  void _syncConfigFromFields() {
    final cfg = ModbusConnectionConfig(
      host: _hostCtl.text.trim(),
      port: int.tryParse(_portCtl.text) ?? 502,
      unitId: int.tryParse(_unitCtl.text) ?? 1,
      timeout: Duration(seconds: int.tryParse(_timeoutCtl.text) ?? 3),
    );
    _manager.updateConfig(cfg);
    widget.session.config = cfg;
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;
    _syncConfigFromFields();
    try {
      await _manager.connect();
      final ok = _manager.state == DeviceConnectionState.connected;
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.connect,
          success: ok,
          summary: ok
              ? '连接成功：${widget.session.name}'
              : '连接失败：${widget.session.name}',
          error: ok ? null : _manager.lastError,
        ),
      );
    } catch (e) {
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.connect,
          success: false,
          summary: '连接失败：${widget.session.name}',
          error: e.toString(),
        ),
      );
    }
  }

  Future<void> _disconnect() async {
    await _manager.disconnect();
    HistoryService.instance.add(
      HistoryRecord(
        time: DateTime.now(),
        type: widget.session.type,
        deviceName: widget.session.name,
        op: HistoryOp.disconnect,
        success: true,
        summary: '断开连接：${widget.session.name}',
      ),
    );
  }

  Future<void> _execute({bool log = true}) async {
    setState(() {
      _busy = true;
      _error = null;
      _feedback = null;
    });
    final op = _function.canRead ? HistoryOp.read : HistoryOp.write;
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
          setState(() {
            _bitValues = bits;
            _regValues = null;
            _lastReadFunction = _function;
            _lastReadAddr = _addr;
            _lastReadTime = DateTime.now();
            _clearRegCtls();
          });
        case ModbusFunction.readHoldingRegisters:
        case ModbusFunction.readInputRegisters:
          final regs = await proto.readTypedRegisters(
            type: _function == ModbusFunction.readHoldingRegisters
                ? ModbusElementType.holdingRegister
                : ModbusElementType.inputRegister,
            address: _addr,
            count: _qty,
            dataType: _dataType,
            byteOrder: _byteOrder,
          );
          setState(() {
            _regValues = regs;
            _bitValues = null;
            _lastReadFunction = _function;
            _lastDataType = _dataType;
            _lastByteOrder = _byteOrder;
            _lastReadAddr = _addr;
            _lastReadTime = DateTime.now();
            _syncRegCtls(regs.length);
          });
        case ModbusFunction.writeSingleCoil:
          await proto.writeSingleCoil(_addr, _value != 0);
          _feedback = '已写线圈 地址 $_addr = ${_value != 0 ? 1 : 0}';
        case ModbusFunction.writeSingleRegister:
          await proto.writeSingleRegister(_addr, _value);
          _feedback = '已写保持寄存器 地址 $_addr = $_value';
        case ModbusFunction.writeMultipleCoils:
          final bits = _valueCtl.text
              .split(RegExp(r'[\s,]+'))
              .where((s) => s.isNotEmpty)
              .map((s) => s.trim() == '1' || s.toLowerCase() == 'true')
              .toList();
          await proto.writeMultipleCoils(_addr, bits);
          _feedback = '已写 ${bits.length} 个线圈，起始地址 $_addr';
        case ModbusFunction.writeMultipleRegisters:
          final vals = _valueCtl.text
              .split(RegExp(r'[\s,]+'))
              .where((s) => s.isNotEmpty)
              .map((s) => int.parse(s))
              .toList();
          await proto.writeMultipleRegisters(_addr, vals);
          _feedback = '已写 ${vals.length} 个保持寄存器，起始地址 $_addr';
      }
      if (log) {
        HistoryService.instance.add(
          HistoryRecord(
            time: DateTime.now(),
            type: widget.session.type,
            deviceName: widget.session.name,
            op: op,
            success: true,
            summary: _summaryFor(op),
            detail: _resultDetailText(),
          ),
        );
      }
    } catch (e) {
      _error = '${_summaryFor(op)} 失败：${e.toString()}';
      if (log) {
        HistoryService.instance.add(
          HistoryRecord(
            time: DateTime.now(),
            type: widget.session.type,
            deviceName: widget.session.name,
            op: op,
            success: false,
            summary: _summaryFor(op),
            error: e.toString(),
          ),
        );
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  /// 单点写回：把第 [index] 行编辑框中的值写到对应地址。
  Future<void> _writeRegisterAt(int index) async {
    final addr = _lastReadAddr + index * _lastDataType.registerCount;
    final text = _regCtls[index].text;
    num val;
    try {
      val = _lastDataType.isFloat
          ? double.parse(text)
          : int.parse(text);
    } catch (_) {
      setState(() => _error = '第 ${index + 1} 行的值“$text”不是合法数字');
      return;
    }
    setState(() => _busy = true);
    try {
      final proto = _manager.protocol as ModbusTcpProtocol;
      await proto.writeTypedRegister(
        address: addr,
        value: val,
        dataType: _lastDataType,
        byteOrder: _lastByteOrder,
      );
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.write,
          success: true,
          summary: '写入 ${_lastDataType.label} @$addr',
          detail: '值：$val',
        ),
      );
      _feedback = '已写 ${_lastDataType.label} 地址 $addr = $val';
      // 写后刷新该行，回显设备真实值。
      await _execute(log: false);
    } catch (e) {
      _error = '写入地址 $addr 失败：${e.toString()}';
    } finally {
      setState(() => _busy = false);
    }
  }

  /// 点击线圈卡片：切换 ON/OFF 并立即写回（仅线圈可写，离散输入只读）。
  Future<void> _toggleBit(int index) async {
    if (_lastReadFunction != ModbusFunction.readCoils) return;
    final addr = _lastReadAddr + index;
    final next = !(_bitValues![index]);
    setState(() => _bitValues![index] = next);
    try {
      final proto = _manager.protocol as ModbusTcpProtocol;
      await proto.writeSingleCoil(addr, next);
      HistoryService.instance.add(
        HistoryRecord(
          time: DateTime.now(),
          type: widget.session.type,
          deviceName: widget.session.name,
          op: HistoryOp.write,
          success: true,
          summary: '写线圈 @$addr',
          detail: '值：${next ? 1 : 0}',
        ),
      );
    } catch (e) {
      // 写失败则回滚显示。
      setState(() => _bitValues![index] = !next);
      _error = '写线圈 $addr 失败：${e.toString()}';
    }
  }

  /// 把读取到的寄存器值同步到编辑框（跳过正在编辑的行）。
  void _syncRegCtls(int count) {
    while (_regCtls.length < count) {
      _regCtls.add(TextEditingController());
      _regFocus.add(FocusNode());
    }
    while (_regCtls.length > count) {
      _regCtls.removeLast().dispose();
      _regFocus.removeLast().dispose();
    }
    final vals = _regValues;
    if (vals == null) return;
    for (var i = 0; i < count; i++) {
      if (!_regFocus[i].hasFocus) {
        _regCtls[i].text = _formatValue(vals[i], _lastDataType);
      }
    }
  }

  void _clearRegCtls() {
    for (final c in _regCtls) {
      c.dispose();
    }
    for (final f in _regFocus) {
      f.dispose();
    }
    _regCtls.clear();
    _regFocus.clear();
  }

  String _formatValue(num v, ModbusDataType dt) =>
      dt.isFloat ? v.toString() : v.toInt().toString();

  /// 把 [num] 值按数据类型与字节序编码为字节，用于显示原始寄存器内容。
  Uint8List _toBytes(num value, ModbusDataType dt, ByteOrder bo) {
    final len = dt.isMultiRegister ? 4 : 2;
    final bytes = Uint8List(len);
    final bd = ByteData.sublistView(bytes);
    switch (dt) {
      case ModbusDataType.uint16:
        bd.setUint16(0, value.toInt() & 0xFFFF, Endian.big);
      case ModbusDataType.int16:
        bd.setInt16(0, value.toInt(), Endian.big);
      case ModbusDataType.uint32:
        bd.setUint32(0, value.toInt(), Endian.big);
      case ModbusDataType.int32:
        bd.setInt32(0, value.toInt(), Endian.big);
      case ModbusDataType.float32:
        bd.setFloat32(0, value.toDouble(), Endian.big);
    }
    return _permute(bytes, bo);
  }

  /// 按字节序置换字节（库以 ABCD 大端为基准）。
  Uint8List _permute(Uint8List b, ByteOrder bo) {
    switch (bo) {
      case ByteOrder.abcd:
        return b;
      case ByteOrder.dcba:
        return Uint8List.fromList([b[3], b[2], b[1], b[0]]);
      case ByteOrder.cdab:
        return Uint8List.fromList([b[2], b[3], b[0], b[1]]);
      case ByteOrder.badc:
        return Uint8List.fromList([b[1], b[0], b[3], b[2]]);
    }
  }

  String _rawWords(num value, ModbusDataType dt, ByteOrder bo) {
    final bytes = _toBytes(value, dt, bo);
    final words = <String>[];
    for (var i = 0; i < bytes.length; i += 2) {
      final w = (bytes[i] << 8) | bytes[i + 1];
      words.add('0x${w.toRadixString(16).padLeft(4, '0').toUpperCase()}');
    }
    return words.join(' ');
  }

  String? _resultDetailText() {
    if (_regValues != null) {
      return _regValues!
          .asMap()
          .entries
          .map((e) =>
              '地址 ${_lastReadAddr + e.key * _lastDataType.registerCount}: '
              '${_formatValue(e.value, _lastDataType)} (${_rawWords(e.value, _lastDataType, _lastByteOrder)})')
          .join('\n');
    }
    if (_bitValues != null) {
      return _bitValues!
          .asMap()
          .entries
          .map((e) => '地址 ${_lastReadAddr + e.key}: ${e.value ? 1 : 0}')
          .join('\n');
    }
    return _feedback;
  }

  String _summaryFor(HistoryOp op) {
    final kind = _function.label;
    if (op == HistoryOp.read) {
      final typeLabel = _isRegisterRead ? '${_dataType.label} ' : '';
      return '读取 $kind($typeLabel@$_addr, $_qty 项)';
    }
    return '写入 $kind @$_addr';
  }

  int get _addr => int.tryParse(_addrCtl.text) ?? 0;
  int get _qty => int.tryParse(_qtyCtl.text) ?? 1;
  int get _value => int.tryParse(_valueCtl.text) ?? 0;

  bool get _isRead => _function.canRead;
  bool get _isWrite => _function.canWrite;
  bool get _isRegisterRead =>
      _function == ModbusFunction.readHoldingRegisters ||
      _function == ModbusFunction.readInputRegisters;

  @override
  Widget build(BuildContext context) {
    final connected = _manager.state == DeviceConnectionState.connected;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.name),
        actions: [
          IconButton(
            icon: Icon(connected ? Icons.link_off : Icons.link),
            tooltip: connected ? '断开' : '连接',
            onPressed: _manager.state == DeviceConnectionState.connecting
                ? null
                : (connected ? _disconnect : _connect),
          ),
        ],
      ),
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
              const Text('连接配置',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _hostCtl,
                      decoration: const InputDecoration(
                        labelText: 'IP 地址',
                        hintText: '请输入设备 IP 地址',
                      ),
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
                      decoration: const InputDecoration(labelText: '从站 ID'),
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
            const Text('读写操作',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            DropdownButtonFormField<ModbusFunction>(
              initialValue: _function,
              decoration: const InputDecoration(labelText: '功能'),
              items: ModbusFunction.values
                  .map((f) => DropdownMenuItem(value: f, child: Text(f.label)))
                  .toList(),
              onChanged: (v) => setState(() => _function = v!),
            ),
            if (_isRegisterRead) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<ModbusDataType>(
                initialValue: _dataType,
                decoration: const InputDecoration(labelText: '数据类型'),
                items: ModbusDataType.values
                    .map((d) =>
                        DropdownMenuItem(value: d, child: Text(d.label)))
                    .toList(),
                onChanged: (v) => setState(() => _dataType = v!),
              ),
              if (_dataType.isMultiRegister)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DropdownButtonFormField<ByteOrder>(
                    initialValue: _byteOrder,
                    decoration:
                        const InputDecoration(labelText: '字节序'),
                    items: ByteOrder.values
                        .map((b) =>
                            DropdownMenuItem(value: b, child: Text(b.label)))
                        .toList(),
                    onChanged: (v) => setState(() => _byteOrder = v!),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动刷新（实时读取）'),
                subtitle: const Text('每 2 秒轮询一次当前读取项'),
                value: _autoRefresh,
                onChanged: _toggleAutoRefresh,
              ),
            ],
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
                decoration: InputDecoration(
                  labelText: '数量（值的个数）',
                  hintText: _isRegisterRead && _dataType.isMultiRegister
                      ? '每个值占 2 个寄存器'
                      : '每个值占 1 个寄存器',
                ),
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
                onPressed: _busy ||
                        _manager.state != DeviceConnectionState.connected
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
                child: Text('请先连接设备',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    final connected = _manager.state == DeviceConnectionState.connected;
    final hasData = _regValues != null || _bitValues != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _lastReadFunction != null
                        ? '点位数据 · ${_lastReadFunction!.label}${_readRangeLabel()}'
                        : '点位数据',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
                if (_lastReadTime != null)
                  Text(_formatClock(_lastReadTime!),
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                if (connected)
                  IconButton(
                    onPressed: _busy ? null : () => _execute(log: false),
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            if (_autoRefresh && connected)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text('实时刷新中 · 每 2 秒',
                        style: TextStyle(fontSize: 12, color: Colors.teal)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.red)),
              ),
              const SizedBox(height: 8),
            ],
            if (_feedback != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_feedback!,
                    style: const TextStyle(color: Colors.green)),
              ),
            if (!connected && !hasData && _feedback == null)
              const Text('请先连接设备后读取点位',
                  style: TextStyle(color: Colors.grey)),
            if (hasData && _regValues != null) _buildRegisterRows(),
            if (hasData && _bitValues != null) _buildBitGrid(),
            if (connected && !hasData && _error == null && _feedback == null)
              const Text('点击「读取」获取点位数据',
                  style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  /// 寄存器读取结果：每行一个可编辑值与“写”按钮，下方显示原始寄存器内容。
  Widget _buildRegisterRows() {
    final canWrite = _lastIsHoldingRead;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.teal.shade50,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              const Expanded(
                  flex: 2,
                  child: Text('地址',
                      style: TextStyle(fontWeight: FontWeight.w600))),
              const Expanded(
                  flex: 3,
                  child: Text('值',
                      style: TextStyle(fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              if (canWrite)
                const SizedBox(
                    width: 40,
                    child: Text('',
                        style: TextStyle(fontWeight: FontWeight.w600))),
            ],
          ),
        ),
        const SizedBox(height: 4),
        ..._regValues!.asMap().entries.map((e) {
          final index = e.key;
          final addr = _lastReadAddr + index * _lastDataType.registerCount;
          final v = e.value;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$addr',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13)),
                      Text(
                        _rawWords(v, _lastDataType, _lastByteOrder),
                        style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                            fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _regCtls[index],
                    focusNode: _regFocus[index],
                    keyboardType: _lastDataType.isFloat
                        ? const TextInputType.numberWithOptions(decimal: true)
                        : TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      hintText: _lastDataType.label,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (canWrite)
                  SizedBox(
                    width: 40,
                    child: IconButton(
                      onPressed: _busy ? null : () => _writeRegisterAt(index),
                      icon: const Icon(Icons.save_outlined, size: 18),
                      tooltip: '写回',
                      visualDensity: VisualDensity.compact,
                      color: Colors.teal,
                    ),
                  ),
              ],
            ),
          );
        }),
        if (!canWrite)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('输入寄存器为只读，不支持写回。',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
      ],
    );
  }

  /// 线圈 / 离散输入读取结果：彩色 ON/OFF 卡片；线圈可点击切换并写回。
  Widget _buildBitGrid() {
    final rows = _bitValues!;
    final writable = _lastReadFunction == ModbusFunction.readCoils;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: rows.asMap().entries.map((e) {
            final addr = _lastReadAddr + e.key;
            final on = e.value;
            return InkWell(
              onTap: writable ? () => _toggleBit(e.key) : null,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 92,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: on ? Colors.green.shade50 : Colors.grey.shade100,
                  border: Border.all(
                    color: on ? Colors.green : Colors.grey.shade300,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$addr',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          on ? Icons.check_circle : Icons.circle_outlined,
                          size: 16,
                          color: on ? Colors.green : Colors.grey,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          on ? 'ON' : 'OFF',
                          style: TextStyle(
                            color: on ? Colors.green : Colors.grey,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
        if (writable)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('点击卡片即可切换 ON/OFF 并写回设备。',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
      ],
    );
  }

  String _readRangeLabel() {
    final n = _regValues?.length ?? _bitValues?.length ?? 0;
    if (n == 0) return '';
    final start = _lastReadAddr;
    final end = _lastReadAddr + (n - 1) * (_regValues != null ? _lastDataType.registerCount : 1);
    return ' · $start–$end';
  }

  String _formatClock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _manager.removeListener(_onManagerChanged);
    _clearRegCtls();
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
